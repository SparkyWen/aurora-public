package com.aurora.vpn

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.system.StructStat
import java.io.Closeable
import java.io.File
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.channels.FileLock
import java.nio.channels.OverlappingFileLockException
import java.util.concurrent.ConcurrentHashMap

// API 21+ Android primitives: java.nio.file.Files would require API 26.
// The native no-backup base may contain the OS's /data/user/0 alias. Resolve
// that trusted base once; every owned entry is checked with lstat/O_NOFOLLOW.
internal class AuroraTailnetStoreFiles(noBackupDirectory: File) {
    private val base = try { noBackupDirectory.canonicalFile }
        catch (_: Exception) { throw AuroraTailnetStoreFailure("storage") }
    private val root = File(base, "aurora-tailnet")
    private val metadata = File(root, "settings.json")
    private val pending = File(root, "settings.next")

    private class Reservation {
        // Android's stream finalizer closes its channel even for a non-owned fd.
        // Retain it if an uncertain Lease is dropped; only explicit close frees it.
        var stream: FileOutputStream? = null
    }
    private class HeldLock(private val fd: FileDescriptor, private val stream: FileOutputStream, private val lock: FileLock,
                           private val path: String, private val reservation: Reservation) : Closeable {
        private var closed = false
        @Synchronized override fun close() {
            if (closed) return
            closed = true
            try { try { lock.release() } finally { stream.close() } } finally {
                // If close itself is unconfirmed, keep process admission closed.
                // Android streams constructed with an existing fd do not own it.
                Os.close(fd)
                owners.remove(path, reservation)
                reservation.stream = null
            }
        }
    }

    fun acquire(): Closeable {
        val reservation = Reservation()
        // POSIX fcntl locks are process-owned. Closing a second descriptor after
        // a failed local tryLock can release the first descriptor's kernel lock.
        // Reserve before opening owner.lock, including competing store instances.
        if (owners.putIfAbsent(root.path, reservation) != null) throw AuroraTailnetStoreFailure("busy")
        var stream: FileOutputStream? = null
        var fd: FileDescriptor? = null
        try {
            checkDirectory(base)
            try { Os.mkdir(root.path, PRIVATE_DIR) }
            catch (error: ErrnoException) { if (error.errno != OsConstants.EEXIST) throw error }
            checkDirectory(root)
            // Also on retry: an earlier mkdir may have succeeded while the parent
            // fsync failed. Do not admit identity state before its root is durable.
            syncDirectory(base)
            val path = File(root, "owner.lock")
            stat(path)?.let { checkFile(it) }
            fd = Os.open(path.path, OsConstants.O_RDWR or OsConstants.O_CREAT or
                OsConstants.O_NOFOLLOW, PRIVATE_FILE)
            stream = FileOutputStream(fd)
            reservation.stream = stream
            checkFile(Os.fstat(fd))
            val lock = try { stream.channel.tryLock() } catch (_: OverlappingFileLockException) { null }
            if (lock == null) throw AuroraTailnetStoreFailure("busy")
            return HeldLock(fd, stream, lock, root.path, reservation)
        } catch (error: Throwable) {
            // Do not reopen a descriptor whose cleanup has not completed.
            try { stream?.close() } finally {
                if (fd != null) Os.close(fd)
                owners.remove(root.path, reservation)
                reservation.stream = null
            }
            throw error
        }
    }

    fun readMetadata(): String? {
        if (stat(root) == null) return null
        checkDirectory(root)
        val info = stat(metadata) ?: return null
        checkFile(info)
        val fd = Os.open(metadata.path, OsConstants.O_RDONLY or OsConstants.O_NOFOLLOW, 0)
        try { return FileInputStream(fd).use { stream ->
            checkFile(Os.fstat(fd))
            val bytes = ByteArray(4097)
            var used = 0
            while (used < bytes.size) {
                val count = stream.read(bytes, used, bytes.size - used)
                if (count < 0) break
                used += count
            }
            if (used > 4096) invalid()
            Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes, 0, used)).toString()
        } } finally { Os.close(fd) }
    }

    fun validateLayout(node: String?, phase: String) {
        if (stat(root) == null) { if (node != null) invalid(); return }
        checkDirectory(root)
        val nodeName = node?.let { "node-$it" }
        for (entry in root.listFiles() ?: invalid()) {
            when (entry.name) {
                "owner.lock", "settings.json", "settings.next" -> checkFile(stat(entry) ?: invalid())
                nodeName -> checkDirectory(entry)
                else -> invalid()
            }
        }
        if (node != null && phase == "ready") checkDirectory(File(root, "node-$node"))
    }

    fun nodePath(node: String): String = File(root, "node-$node").path

    fun allocateNode(node: String) {
        val directory = File(nodePath(node))
        if (stat(directory) == null) {
            Os.mkdir(directory.path, PRIVATE_DIR)
            syncRoot()
        }
        checkDirectory(directory)
        if ((directory.listFiles() ?: invalid()).isNotEmpty()) invalid()
    }

    fun writeMetadata(text: String) {
        checkDirectory(root)
        // A leftover temporary file is uncommitted metadata, not a node. Only
        // remove this exact private regular file while holding the owner lock.
        stat(pending)?.let { checkFile(it); Os.remove(pending.path) }
        val fd = Os.open(pending.path, OsConstants.O_WRONLY or OsConstants.O_CREAT or
            OsConstants.O_EXCL or OsConstants.O_NOFOLLOW, PRIVATE_FILE)
        try { FileOutputStream(fd).use { stream ->
            checkFile(Os.fstat(fd))
            stream.write(text.toByteArray(Charsets.UTF_8))
            stream.fd.sync()
        } } finally { Os.close(fd) }
        Os.rename(pending.path, metadata.path)
        syncRoot()
    }

    fun removeNode(node: String) {
        val directory = File(nodePath(node))
        if (stat(directory) == null) return
        fun remove(entry: File) {
            val info = stat(entry) ?: invalid()
            if (OsConstants.S_ISDIR(info.st_mode)) {
                checkDirectory(entry)
                for (child in entry.listFiles() ?: invalid()) remove(child)
                Os.remove(entry.path)
            } else {
                checkFile(info)
                Os.remove(entry.path)
            }
        }
        remove(directory)
        syncRoot()
    }

    private fun syncRoot() = syncDirectory(root)
    private fun syncDirectory(directory: File) {
        val fd = Os.open(directory.path, OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or
            OsConstants.O_NOFOLLOW, 0)
        try { checkDirectoryInfo(Os.fstat(fd)); Os.fsync(fd) } finally { Os.close(fd) }
    }
    private fun stat(file: File): StructStat? = try { Os.lstat(file.path) }
        catch (error: ErrnoException) { if (error.errno == OsConstants.ENOENT) null else throw error }
    private fun checkDirectory(file: File) {
        checkDirectoryInfo(stat(file) ?: invalid())
    }
    private fun checkDirectoryInfo(info: StructStat) {
        if (!OsConstants.S_ISDIR(info.st_mode) || info.st_uid != Os.getuid() ||
            info.st_mode and 0xfff != PRIVATE_DIR) invalid()
    }
    private fun checkFile(info: StructStat) {
        if (!OsConstants.S_ISREG(info.st_mode) || info.st_uid != Os.getuid() ||
            info.st_mode and 0xfff != PRIVATE_FILE || info.st_nlink != 1L) invalid()
    }
    private fun invalid(): Nothing = throw AuroraTailnetStoreFailure("invalid-state")
    companion object {
        private const val PRIVATE_DIR = 448
        private const val PRIVATE_FILE = 384
        private val owners = ConcurrentHashMap<String, Reservation>()
    }
}
