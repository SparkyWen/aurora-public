package com.aurora.vpn.test

import com.aurora.vpn.AuroraTailnetStore
import com.aurora.vpn.AuroraTailnetStoreFailure
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import android.system.Os
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

private const val SESSION = "12345678-1234-1234-1234-123456789ABC"
private const val NODE = "ABCDEF12-1234-1234-1234-ABCDEF123456"

private fun privateFile(file: File, text: String) {
    file.writeText(text)
    Files.setPosixFilePermissions(file.toPath(), PosixFilePermissions.fromString("rw-------"))
}
private fun metadata(generation: String = "1", enabled: Boolean = true,
                     node: String? = NODE, phase: String = "ready") =
    "{\"schema\":1,\"settingsGeneration\":$generation,\"enabled\":$enabled,\"nodeGeneration\":${node?.let { "\"$it\"" } ?: "null"},\"phase\":\"$phase\"}\n"

private fun rejected(code: String, action: () -> Unit): Boolean = try {
    action(); false
} catch (error: AuroraTailnetStoreFailure) { error.code == code && error.message == code }

fun tailnetLockProbe(base: String) {
    try { AuroraTailnetStore(File(base)).prepareStart(1); println("ACQUIRED") }
    catch (error: AuroraTailnetStoreFailure) { println(if (error.code == "busy") "BUSY" else "OTHER_FAILURE") }
}

fun tailnetStoreTests() {
    fun case(name: String, body: (File, AuroraTailnetStore) -> Unit) {
        val base = Files.createTempDirectory("aurora-tailnet-test-").toFile()
        try {
            body(base, AuroraTailnetStore(base))
        } catch (error: Throwable) {
            expect(false, "$name: ${error.javaClass.simpleName}")
        } finally { base.deleteRecursively() }
    }
    fun root(base: File): File = File(base, "aurora-tailnet")
    fun enabled(store: AuroraTailnetStore) = store.setEnabled(0, true) { true }
    fun prepared(store: AuroraTailnetStore): AuroraTailnetStore.Prepared {
        enabled(store)
        return store.prepareStart(1)!!
    }
    fun seed(base: File, text: String, directory: Boolean = true) {
        val folder = root(base); folder.mkdir()
        Files.setPosixFilePermissions(folder.toPath(), PosixFilePermissions.fromString("rwx------"))
        privateFile(File(folder, "settings.json"), text)
        if (directory) {
            val node = File(folder, "node-$NODE"); node.mkdir()
            Files.setPosixFilePermissions(node.toPath(), PosixFilePermissions.fromString("rwx------"))
        }
    }
    case("disabled does not create a node") { base, store ->
        expect(store.readSettings() == AuroraTailnetStore.Settings(0, false, null), "fresh settings disabled")
        expect(store.prepareStart(0) == null, "disabled prepare has no context")
        expect(root(base).listFiles().orEmpty().none { it.name.startsWith("node-") }, "disabled prepare creates no identity")
    }
    case("path resolution failure does not expose filesystem details") { base, _ ->
        val inaccessible = object : File(base.path) {
            override fun getCanonicalFile(): File = throw IOException("private fixture path")
        }
        expect(rejected("storage") { AuroraTailnetStore(inaccessible) }, "native path failure is a fixed category")
    }
    case("Os descriptor owners close every read write and lease path") { _, store ->
        // Android's public FileInput/OutputStream(fd) are non-owning; host JDK
        // closes on use(). Track the required Os ownership boundary explicitly.
        val before = Os.ownedDescriptorCount()
        val context = prepared(store)
        repeat(4) { store.readSettings() }
        val lease = store.acquireSessionLease(context, SESSION)
        expect(Os.ownedDescriptorCount() == before + 1, "only the active lock descriptor remains owned")
        lease.close()
        expect(Os.ownedDescriptorCount() == before, "lease close explicitly closes owned Os descriptor")
        Os.failNextRename = true
        expect(rejected("storage") { store.setEnabled(1, false) { true } }, "metadata error remains safe")
        expect(Os.ownedDescriptorCount() == before, "failed atomic write releases its Os descriptors")
    }
    case("root directory durability failure prevents identity admission") { base, store ->
        Os.failingSyncPath = base.canonicalPath
        try {
            expect(rejected("storage") { store.setEnabled(0, true) { true } }, "unconfirmed root durability refuses settings commit")
            expect(rejected("storage") { store.prepareStart(0) }, "retry cannot bypass unconfirmed root durability")
            expect(root(base).listFiles().orEmpty().none { it.name.startsWith("node-") }, "failed parent durability creates no node")
        } finally { Os.failingSyncPath = null }
    }
    case("identity survives reopening") { base, store ->
        val context = prepared(store)
        privateFile(File(context.stateDirectory, "tailscaled.state"), "fixture-node-key")
        val reopened = AuroraTailnetStore(base).prepareStart(1)!!
        expect(reopened == context, "reopening preserves node directory and identity")
        expect(File(context.stateDirectory, "tailscaled.state").readText() == "fixture-node-key", "reopen preserves core state")
        expect(context.hostname.startsWith("aurora-"), "hostname is native derived")
    }
    case("settings generation admission") { _, store ->
        val settings = enabled(store)
        expect(settings.settingsGeneration == 1L, "successful change increments generation")
        expect(store.setEnabled(1, true) { true } == settings, "idempotent setting does not invalidate queued context")
        expect(rejected("stale") { store.setEnabled(0, false) { true } }, "stale setter rejected")
        expect(rejected("invalid-state") { store.prepareStart(-1) }, "negative generation rejected")
        expect(rejected("busy") { store.setEnabled(1, false) { false } }, "running guard rejects setting")
    }
    case("lease blocks mutation and old close cannot release new lease") { base, store ->
        val context = prepared(store)
        val first = store.acquireSessionLease(context, SESSION)
        try {
            expect(AuroraTailnetStore(base).readSettings().nodeGeneration == context.nodeGeneration, "active settings remain readable")
            expect(rejected("busy") { AuroraTailnetStore(base).setEnabled(1, false) { true } }, "live lease beats stopped status")
            expect(store.forget(context.nodeGeneration) { true } == "busy", "live lease prevents forget")
            expect(rejected("busy") { store.acquireSessionLease(context, SESSION) }, "second owner rejected")
        } finally { first.close() }
        val second = store.acquireSessionLease(context, SESSION)
        try {
            first.close()
            expect(store.forget(context.nodeGeneration) { true } == "busy", "late old release cannot unlock replacement")
        } finally { second.close() }
        expect(store.forget(context.nodeGeneration) { true } == "forgotten", "actual release allows forget")
        expect(store.readSettings() == AuroraTailnetStore.Settings(2, false, null), "forget disables and advances generation")
    }
    case("stale or forged queued contexts rejected") { _, store ->
        val context = prepared(store)
        expect(rejected("invalid-state") { store.acquireSessionLease(context, "1-1-1-1-1") }, "short UUID rejected")
        expect(rejected("stale") { store.acquireSessionLease(context.copy(stateDirectory = "/tmp/foreign"), SESSION) }, "caller cannot replace native directory")
        store.setEnabled(1, false) { true }
        expect(rejected("stale") { store.acquireSessionLease(context, SESSION) }, "changed settings invalidate queued start")
    }
    case("uppercase persisted UUID stays intact") { base, store ->
        seed(base, metadata())
        val context = store.prepareStart(1)!!
        expect(context.nodeGeneration == NODE, "UUID case preserved")
        store.acquireSessionLease(context, SESSION).close()
        expect(store.forget(NODE.lowercase()) { true } == "stale", "different identity string cannot forget node")
    }
    for (text in listOf(metadata().replace("\"schema\":1", "\"schema\":2"),
            metadata(generation = "-1"), metadata(generation = "9223372036854775808"),
            metadata().replace("\"phase\"", "\"unknown\""), metadata(node = "1-1-1-1-1"))) {
        case("invalid metadata fails closed") { base, store ->
            seed(base, text)
            expect(rejected("invalid-state") { store.prepareStart(1) }, "invalid metadata cannot become new identity")
            expect(File(root(base), "settings.json").readText() == text, "invalid metadata is preserved")
        }
    }
    case("generation overflow cannot wrap") { base, store ->
        seed(base, metadata(generation = "9223372036854775807"))
        expect(store.readSettings().settingsGeneration == Long.MAX_VALUE, "int64 maximum readable")
        expect(rejected("invalid-state") { store.setEnabled(Long.MAX_VALUE, false) { true } }, "generation overflow rejected")
    }
    case("orphan state cannot be adopted") { base, store ->
        seed(base, metadata()); File(root(base), "settings.json").delete()
        expect(rejected("invalid-state") { store.prepareStart(0) }, "missing metadata with state fails closed")
    }
    case("lost ready directory cannot be recreated") { base, store ->
        seed(base, metadata(), directory = false)
        expect(rejected("invalid-state") { store.prepareStart(1) }, "lost state does not regenerate under old UUID")
    }
    case("allocated phase resumes only an empty directory") { base, store ->
        seed(base, metadata(phase = "allocated"), directory = false)
        expect(store.prepareStart(1)!!.nodeGeneration == NODE, "interrupted allocation resumes same UUID")
    }
    case("allocated phase never adopts unknown core bytes") { base, store ->
        seed(base, metadata(phase = "allocated"))
        privateFile(File(root(base), "node-$NODE/tailscaled.state"), "fixture-orphan")
        expect(rejected("invalid-state") { store.prepareStart(1) }, "interrupted allocation with core state refused")
    }
    case("symlink directory refused") { base, store ->
        val outside = Files.createTempDirectory("aurora-outside-")
        try {
            Files.createSymbolicLink(root(base).toPath(), outside)
            expect(rejected("invalid-state") { store.prepareStart(0) }, "root symlink refused")
        } finally { Files.delete(outside) }
    }
    case("public metadata refused") { base, store ->
        seed(base, metadata())
        Files.setPosixFilePermissions(File(root(base), "settings.json").toPath(), PosixFilePermissions.fromString("rw-r--r--"))
        expect(rejected("invalid-state") { store.prepareStart(1) }, "unexpected permissions refused")
    }
    case("failed forget retains tombstone and cannot start") { base, store ->
        val context = prepared(store)
        val outside = Files.createTempFile("aurora-outside-state-", ".fixture")
        try {
            Files.createSymbolicLink(File(context.stateDirectory, "unsafe-link").toPath(), outside)
            expect(rejected("invalid-state") { store.forget(context.nodeGeneration) { true } }, "forget refuses foreign symlink")
            expect(rejected("invalid-state") { store.prepareStart(2) }, "partial forget cannot restart")
            expect(rejected("invalid-state") { store.setEnabled(2, true) { true } }, "partial forget cannot enable")
            expect(Files.exists(outside), "forget never follows symlink")
            Files.delete(File(context.stateDirectory, "unsafe-link").toPath())
            expect(store.forget(context.nodeGeneration) { true } == "forgotten", "retry resumes same tombstone")
            expect(!File(context.stateDirectory).exists(), "forget removes only known node")
        } finally { Files.deleteIfExists(outside) }
    }
    case("native stopped admission is rechecked while locked") { _, store ->
        val context = prepared(store)
        expect(store.forget(context.nodeGeneration) { false } == "busy", "false stopped gate preserves node")
        expect(store.readSettings().nodeGeneration == context.nodeGeneration, "busy forget leaves metadata unchanged")
    }
    case("atomic write failure leaves last committed settings usable") { base, store ->
        enabled(store)
        Os.failNextRename = true
        expect(rejected("storage") { store.setEnabled(1, false) { true } }, "failed rename returns safe storage category")
        expect(AuroraTailnetStore(base).readSettings() == AuroraTailnetStore.Settings(1, true, null), "failed write does not replace successful metadata")
        expect(store.setEnabled(1, false) { true }.settingsGeneration == 2L, "retry can discard only own uncommitted metadata")
    }
    case("failed tombstone write never deletes core bytes") { _, store ->
        val context = prepared(store)
        val state = File(context.stateDirectory, "tailscaled.state")
        privateFile(state, "fixture-node-key")
        Os.failNextRename = true
        expect(rejected("storage") { store.forget(context.nodeGeneration) { true } }, "forget refuses mutation if marker cannot commit")
        expect(state.readText() == "fixture-node-key", "failed tombstone preserves node")
        expect(store.prepareStart(1) == context, "uncommitted forget cannot replace identity")
    }
    case("hardlinked metadata refused") { base, store ->
        seed(base, metadata())
        Files.createLink(File(base, "metadata-alias").toPath(), File(root(base), "settings.json").toPath())
        expect(rejected("invalid-state") { store.prepareStart(1) }, "hardlinked metadata cannot be rewritten")
    }
    case("special directory permissions refused") { base, store ->
        seed(base, metadata())
        Files.setAttribute(root(base).toPath(), "unix:mode", 0x4000 or 0x400 or 448)
        expect(rejected("invalid-state") { store.prepareStart(1) }, "setgid root is not an ordinary private directory")
    }
    for (target in listOf("settings.json", "owner.lock", "node-$NODE")) {
        case("owned entry symlink refused") { base, store ->
            seed(base, metadata())
            val entry = File(root(base), target)
            entry.deleteRecursively()
            Files.createSymbolicLink(entry.toPath(), base.toPath())
            expect(rejected("invalid-state") { store.prepareStart(1) }, "owned symlink $target refused")
        }
    }
    case("independent owners cannot both acquire directory") { base, store ->
        val context = prepared(store)
        val start = CountDownLatch(1)
        val attempted = CountDownLatch(2)
        val release = CountDownLatch(1)
        val acquired = AtomicInteger()
        val busy = AtomicInteger()
        val unexpected = AtomicInteger()
        val threads = (1..2).map {
            Thread {
                start.await()
                try {
                    val lease = AuroraTailnetStore(base).acquireSessionLease(context, SESSION)
                    acquired.incrementAndGet(); attempted.countDown()
                    try { release.await(2, TimeUnit.SECONDS) } finally { lease.close() }
                } catch (error: AuroraTailnetStoreFailure) {
                    if (error.code == "busy") busy.incrementAndGet() else unexpected.incrementAndGet()
                    attempted.countDown()
                } catch (_: Throwable) { unexpected.incrementAndGet(); attempted.countDown() }
            }.apply { start() }
        }
        start.countDown()
        val returned = attempted.await(2, TimeUnit.SECONDS)
        release.countDown()
        threads.forEach { it.join(2500) }
        expect(returned && threads.none { it.isAlive }, "competing lock acquisition is nonblocking")
        expect(acquired.get() == 1 && busy.get() == 1 && unexpected.get() == 0, "one real file lock admits exactly one owner")
    }
    case("failed local contender preserves kernel lock against another process") { base, store ->
        val context = prepared(store)
        store.acquireSessionLease(context, SESSION).use {
            expect(rejected("busy") { AuroraTailnetStore(base).acquireSessionLease(context, SESSION) }, "local contender is refused")
            val java = File(System.getProperty("java.home"), "bin/java").path
            val process = ProcessBuilder(java, "-cp", System.getProperty("java.class.path"),
                "com.aurora.vpn.test.MainKt", "tailnet-lock-probe", base.path).redirectErrorStream(true).start()
            val ended = process.waitFor(5, TimeUnit.SECONDS)
            if (!ended) process.destroyForcibly().waitFor(2, TimeUnit.SECONDS)
            expect(ended && process.exitValue() == 0 && process.inputStream.bufferedReader().readText().trim() == "BUSY",
                "closing a refused contender must not release the active process kernel lock")
        }
    }
}
