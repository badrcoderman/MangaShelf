package mangashelf.host

import eu.kanade.tachiyomi.network.awaitSuccess
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.Path
import java.nio.file.StandardOpenOption.WRITE
import java.nio.file.StandardOpenOption.TRUNCATE_EXISTING
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Call

/** Bounded, app-owned handoff files. Swift verifies, consumes and deletes each file.
 * Old unclaimed responses are reclaimed, including a native allocation failure
 * after Java committed a response. No extension path is accepted by this store.
 */
class ImageTransferStore(directory: Path, private val maximumImageBytes: Long = 32L * 1024 * 1024,
                         private val maximumTotalBytes: Long = 128L * 1024 * 1024) {
    data class Transfer(val path: Path, val bytes: Long, val sha256: String)
    private val root = directory.toAbsolutePath().normalize()
    private val lock = Any()
    private val reserved = mutableSetOf<Path>()
    private val fileName = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\\.bin")

    init {
        require(maximumImageBytes in 1..32L * 1024 * 1024 && maximumTotalBytes in maximumImageBytes..128L * 1024 * 1024)
        storage { Files.createDirectories(root) }
        if (!Files.isDirectory(root, NOFOLLOW_LINKS)) fail("image_storage_failed")
    }

    private fun reserve(): Path = synchronized(lock) {
        var used = 0L
        var count = 0
        storage {
            Files.newDirectoryStream(root).use { files ->
                for (path in files) {
                    if (++count > 128 || !fileName.matches(path.fileName.toString()) || !Files.isRegularFile(path, NOFOLLOW_LINKS)) fail("image_storage_failed")
                    if (path !in reserved && System.currentTimeMillis() - Files.getLastModifiedTime(path, NOFOLLOW_LINKS).toMillis() > 300_000) {
                        Files.delete(path)
                    } else { used += if (path in reserved) maximumImageBytes else Files.size(path) }
                }
            }
        }
        if (used > maximumTotalBytes - maximumImageBytes) fail("image_transfer_limit")
        val path = root.resolve(UUID.randomUUID().toString() + ".bin")
        storage { Files.createFile(path) }
        reserved.add(path)
        path
    }

    suspend fun fetch(call: Call): Transfer = withContext(Dispatchers.IO) {
        val path = reserve()
        var complete = false
        try {
            val transfer = coroutineScope {
                // Response headers may arrive before the body. Keep cancellation
                // wired to the Call until the body has closed, not just enqueue.
                val bodyFinished = AtomicBoolean()
                val cancellation = launch(start = CoroutineStart.UNDISPATCHED) {
                    try { awaitCancellation() } finally { if (!bodyFinished.get()) call.cancel() }
                }
                try {
                    val downloaded = call.awaitSuccess().use { response ->
                        if (response.body.contentLength() > maximumImageBytes) fail("response_limit")
                        val digest = MessageDigest.getInstance("SHA-256")
                        var size = 0L
                        response.body.byteStream().use { input ->
                            storage { Files.newOutputStream(path, WRITE, TRUNCATE_EXISTING) }.use { output ->
                                val buffer = ByteArray(16 * 1024)
                                while (true) {
                                    currentCoroutineContext().ensureActive()
                                    val read = input.read(buffer)
                                    if (read < 0) break
                                    if (read == 0) continue
                                    if (read.toLong() > maximumImageBytes - size) fail("response_limit")
                                    storage { output.write(buffer, 0, read) }
                                    digest.update(buffer, 0, read); size += read
                                }
                            }
                        }
                        if (size == 0L) fail("invalid_response")
                        currentCoroutineContext().ensureActive()
                        Transfer(path, size, digest.digest().joinToString("") { "%02x".format(it) })
                    }
                    bodyFinished.set(true)
                    downloaded
                } finally { withContext(NonCancellable) { cancellation.cancelAndJoin() } }
            }
            complete = true
            transfer
        } catch (error: IOException) {
            currentCoroutineContext().ensureActive()
            throw error
        } finally {
            synchronized(lock) {
                reserved.remove(path)
                if (!complete) try { Files.deleteIfExists(path) } catch (_: IOException) { }
            }
        }
    }

    fun discard(transfer: Transfer) {
        require(transfer.path.parent == root && fileName.matches(transfer.path.fileName.toString()))
        synchronized(lock) { storage { Files.deleteIfExists(transfer.path) } }
    }

    private inline fun <T> storage(block: () -> T): T = try { block() }
        catch (_: IOException) { fail("image_storage_failed") }
    private fun fail(code: String): Nothing = throw SourceCommands.CommandException(code)
}
