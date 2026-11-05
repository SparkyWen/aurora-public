package android.system

// JVM boundary for API21 Os calls. Policy, files, content and FileChannel locks
// are production code on real temp files; directory fsync needs device validation.
import java.io.File
import java.io.FileDescriptor
import java.io.RandomAccessFile
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.attribute.PosixFilePermission
import java.util.IdentityHashMap

class ErrnoException(function: String, val errno: Int) : Exception(function)
class StructStat(val st_mode: Int, val st_uid: Int, val st_nlink: Long)
object OsConstants {
    const val IFF_UP=1; const val IFF_RUNNING=2; const val IFF_LOOPBACK=4; const val IFF_POINTOPOINT=8; const val IFF_MULTICAST=16
    const val ENOENT = 2; const val EEXIST = 17
    const val O_RDONLY = 0; const val O_WRONLY = 1; const val O_RDWR = 2
    const val O_CREAT = 64; const val O_EXCL = 128; const val O_NOFOLLOW = 131072
    const val O_NONBLOCK = 2048
    fun S_ISDIR(mode: Int) = mode and 0xf000 == 0x4000
    fun S_ISREG(mode: Int) = mode and 0xf000 == 0x8000
}
object Os {
    private data class Opened(val file: File, val raf: RandomAccessFile?)
    private val descriptors = IdentityHashMap<FileDescriptor, Opened>()
    @Synchronized fun ownedDescriptorCount() = descriptors.size
    var failNextRename = false
    var failingSyncPath: String? = null
    private fun permissions(mode: Int): Set<PosixFilePermission> {
        val values = listOf(PosixFilePermission.OWNER_READ, PosixFilePermission.OWNER_WRITE, PosixFilePermission.OWNER_EXECUTE,
            PosixFilePermission.GROUP_READ, PosixFilePermission.GROUP_WRITE, PosixFilePermission.GROUP_EXECUTE,
            PosixFilePermission.OTHERS_READ, PosixFilePermission.OTHERS_WRITE, PosixFilePermission.OTHERS_EXECUTE)
        return values.filterIndexed { index, _ -> mode and (1 shl (8 - index)) != 0 }.toSet()
    }
    // The owner of a file this process creates is its effective uid. The owner
    // of java.io.tmpdir is not: on Linux runners /tmp belongs to root while
    // the test directories belong to the runner user.
    private val uid: Int by lazy {
        val probe = Files.createTempFile("aurora-uid-", null)
        try { Files.getAttribute(probe, "unix:uid") as Int } finally { Files.delete(probe) }
    }
    fun getuid() = uid
    fun lstat(path: String): StructStat {
        val p = File(path).toPath()
        if (!Files.exists(p, NOFOLLOW_LINKS)) throw ErrnoException("lstat", OsConstants.ENOENT)
        return StructStat(Files.getAttribute(p, "unix:mode", NOFOLLOW_LINKS) as Int,
            Files.getAttribute(p, "unix:uid", NOFOLLOW_LINKS) as Int,
            (Files.getAttribute(p, "unix:nlink", NOFOLLOW_LINKS) as Number).toLong())
    }
    fun mkdir(path: String, mode: Int) {
        try { Files.createDirectory(File(path).toPath(), java.nio.file.attribute.PosixFilePermissions.asFileAttribute(permissions(mode))) }
        catch (_: java.nio.file.FileAlreadyExistsException) { throw ErrnoException("mkdir", OsConstants.EEXIST) }
    }
    @Synchronized fun open(path: String, flags: Int, mode: Int): FileDescriptor {
        val file = File(path)
        val p = file.toPath()
        if (flags and OsConstants.O_NOFOLLOW != 0 && Files.isSymbolicLink(p)) throw ErrnoException("open", 40)
        if (file.isDirectory) {
            if (flags and 3 != 0) throw ErrnoException("open", 21)
            return FileDescriptor().also { descriptors[it] = Opened(file, null) }
        }
        if (flags and OsConstants.O_CREAT != 0) {
            try { Files.createFile(p, java.nio.file.attribute.PosixFilePermissions.asFileAttribute(permissions(mode))) }
            catch (_: java.nio.file.FileAlreadyExistsException) {
                if (flags and OsConstants.O_EXCL != 0) throw ErrnoException("open", OsConstants.EEXIST)
            }
        }
        val raf = RandomAccessFile(file, if (flags and 3 == 0) "r" else "rw")
        return raf.fd.also { descriptors[it] = Opened(file, raf) }
    }
    @Synchronized fun fstat(fd: FileDescriptor) = lstat(descriptors[fd]!!.file.path)
    @Synchronized fun close(fd: FileDescriptor) {
        // Host JDK streams already close this descriptor. Android's fd-based
        // streams do not; require the production owner to release it explicitly.
        val opened = descriptors.remove(fd) ?: error("Descriptor closed twice")
        opened.raf?.close()
    }
    @Synchronized fun fsync(fd: FileDescriptor) {
        val opened = descriptors[fd] ?: error("Unknown descriptor")
        if (opened.file.canonicalPath == failingSyncPath) throw ErrnoException("fsync", 5)
        opened.raf?.fd?.sync()
    }
    fun remove(path: String) { Files.delete(File(path).toPath()) }
    fun rename(from: String, to: String) {
        if (failNextRename) { failNextRename = false; throw ErrnoException("rename", 5) }
        Files.move(File(from).toPath(), File(to).toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
    }
}
