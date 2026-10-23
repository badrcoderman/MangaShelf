package mangashelf.host

import com.squareup.zstd.ZSTD_e_end
import com.squareup.zstd.ZstdCompressor
import com.squareup.zstd.ZstdDecompressor
import com.squareup.zstd.getErrorName
import com.squareup.zstd.okio.zstdCompress
import com.squareup.zstd.okio.zstdDecompress
import com.squareup.zstd.zstdCompressor
import com.squareup.zstd.zstdDecompressor
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Modifier
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import kotlin.concurrent.thread
import kotlin.random.Random
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okio.Buffer
import okio.Sink
import okio.Source
import okio.Timeout
import okio.buffer

/** Authored format vectors/data and fault injection; never a published extension. */
object ZstdCheck {
    private val rawFrame = byteArrayOf(0x28, 0xb5.toByte(), 0x2f, 0xfd.toByte(), 0x20, 3, 0x19, 0, 0, 97, 98, 99)
    private inline fun <reified T : Throwable> fails(body: () -> Unit) {
        try { body() } catch (error: Throwable) { if (error is T) return else throw error }
        error("Expected ${T::class.java.name}")
    }
    private fun native(instance: Any, name: String, vararg arguments: Any?): Any? {
        val method = instance.javaClass.declaredMethods.single { it.name == name && Modifier.isNative(it.modifiers) }
        method.isAccessible = true
        try { return method.invoke(instance, *arguments) }
        catch (error: InvocationTargetException) { throw checkNotNull(error.cause) }
    }
    private fun handle(instance: Any, name: String) = instance.javaClass.getField(name).getLong(instance)
    private fun compress(data: ByteArray, compressor: ZstdCompressor, chunk: Int = 37): ByteArray {
        val input = byteArrayOf(11, 22, 33) + data + byteArrayOf(44)
        val original = input.copyOf(); var position = 3; val end = data.size + 3
        val result = ByteArrayOutputStream(); var steps = 0
        do {
            val output = ByteArray(chunk + 5) { 0x55 }
            val code = compressor.compressStream2(output, chunk + 2, 2, input, end, position, ZSTD_e_end)
            check(getErrorName(code) == null)
            check(compressor.inputBytesProcessed in 0..(end - position) && compressor.outputBytesProcessed in 0..chunk)
            check(output.take(2).all { it == 0x55.toByte() } && output.takeLast(3).all { it == 0x55.toByte() })
            result.write(output, 2, compressor.outputBytesProcessed); position += compressor.inputBytesProcessed
            if (code == 0L) { check(position == end && input.contentEquals(original)); return result.toByteArray() }
            check(compressor.inputBytesProcessed > 0 || compressor.outputBytesProcessed > 0)
            check(++steps < 100000)
        } while (true)
    }
    private fun decompress(data: ByteArray, decompressor: ZstdDecompressor, chunk: Int = 19): ByteArray {
        val input = byteArrayOf(11, 22, 33) + data + byteArrayOf(44)
        var position = 3; val end = data.size + 3; var steps = 0
        val result = ByteArrayOutputStream()
        do {
            val output = ByteArray(chunk + 5) { 0x55 }
            val code = decompressor.decompressStream(output, chunk + 2, 2, input, end, position)
            check(getErrorName(code) == null)
            check(decompressor.inputBytesProcessed in 0..(end - position) && decompressor.outputBytesProcessed in 0..chunk)
            check(output.take(2).all { it == 0x55.toByte() } && output.takeLast(3).all { it == 0x55.toByte() })
            result.write(output, 2, decompressor.outputBytesProcessed); position += decompressor.inputBytesProcessed
            if (code == 0L && position == end) return result.toByteArray()
            check(decompressor.inputBytesProcessed > 0 || decompressor.outputBytesProcessed > 0)
            check(++steps < 100000)
        } while (true)
    }
    private fun encode(data: ByteArray): ByteArray {
        val output = Buffer()
        output.zstdCompress().buffer().use { it.write(data) }
        return output.readByteArray()
    }
    private fun decode(data: ByteArray): ByteArray = Buffer().write(data).zstdDecompress().buffer().use { it.readByteArray() }
    private fun waitForGate() {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!ZstdNativeTestHooks.gateEntered()) { check(System.nanoTime() < deadline) { "Native gate not reached" }; Thread.sleep(1) }
    }

    @JvmStatic
    fun main(args: Array<String>) {
        val mode = args.single()
        val originalOS = System.getProperty("os.name")
        // Exercise the new loader with the exact OS name from the iPhone report.
        // Restore the host property immediately; this is not an iOS runtime test.
        try { System.setProperty("os.name", "Darwin"); check(getErrorName(0) == null) }
        finally { System.setProperty("os.name", originalOS) }
        val checks = linkedMapOf<String, Boolean>()
        fun case(name: String, body: () -> Unit) {
            System.err.println("START $name")
            try { body(); check(ZstdNativeTestHooks.activeContexts() == 0) { "Native contexts leaked" } }
            catch (error: Throwable) { System.err.println("FAIL $name: ${error.javaClass.name}: ${error.message}"); throw error }
            checks[name] = true; System.err.println("PASS $name")
        }
        case("darwin_named_loader_uses_the_requested_native_loading_mode") {
            check(mode in setOf("builtin", "dynamic"))
            check(ZstdNativeTestHooks.loadKind() == if (mode == "builtin") 2 else 1)
            check(ZstdNativeTestHooks.globalReferences() == 2)
        }
        case("independent_raw_and_rle_format_vectors_decode") {
            check(decode(rawFrame).contentEquals("abc".toByteArray()))
            val rle = byteArrayOf(0x28, 0xb5.toByte(), 0x2f, 0xfd.toByte(), 0x20, 29, 0xeb.toByte(), 0, 0, 65)
            check(decode(rle).contentEquals(ByteArray(29) { 65 }))
        }
        case("okio_empty_binary_and_unicode_roundtrips") {
            val data = Random(99).nextBytes(1024 * 1024) + "العربية 📚\u0000".repeat(700).toByteArray()
            check(decode(encode(byteArrayOf())).isEmpty())
            check(decode(encode(data)).contentEquals(data))
        }
        case("tiny_output_buffers_offsets_and_byte_counters_preserve_unrelated_bytes") {
            val data = Random(71).nextBytes(6000)
            val compressed = zstdCompressor().use { compress(data, it) }
            check(zstdDecompressor().use { decompress(compressed, it) }.contentEquals(data))
        }
        case("flush_and_concatenated_frames_preserve_all_data") {
            val output = Buffer()
            output.zstdCompress().buffer().use { sink -> sink.writeUtf8("first"); sink.flush(); sink.writeUtf8(" second") }
            val encoded = output.readByteArray()
            check(decode(encoded + rawFrame).contentEquals("first secondabc".toByteArray()))
        }
        case("truncated_and_checksum_corrupt_frames_fail_without_leaking_contexts") {
            fails<IOException> { decode(rawFrame.copyOf(rawFrame.size - 1)) }
            val encoded = zstdCompressor().use { compressor ->
                check(getErrorName(compressor.setParameter(201, 1)) == null)
                compress("checksummed 📚".toByteArray(), compressor)
            }
            encoded[encoded.lastIndex] = (encoded.last().toInt() xor 1).toByte()
            fails<IOException> { decode(encoded) }
        }
        case("oversized_decoder_window_is_rejected") {
            val frame = byteArrayOf(0x28, 0xb5.toByte(), 0x2f, 0xfd.toByte(), 0, 0xf8.toByte(), 1, 0, 0)
            fails<IOException> { decode(frame) }
        }
        case("parameters_return_codec_errors_with_safe_error_names") {
            zstdCompressor().use { compressor ->
                check(getErrorName(compressor.setParameter(100, 1)) == null)
                check(getErrorName(compressor.setParameter(-1, 0))?.isNotEmpty() == true)
            }
        }
        case("close_is_idempotent_and_operations_after_close_fail_safely") {
            val compressor = zstdCompressor(); compressor.close(); compressor.close()
            fails<IllegalStateException> { compressor.setParameter(100, 1) }
            val decompressor = zstdDecompressor(); decompressor.close(); decompressor.close()
            fails<IllegalStateException> { decompress(rawFrame, decompressor) }
        }
        case("bounds_null_and_alias_checks_precede_native_memory_access") {
            zstdCompressor().use { compressor ->
                fails<IndexOutOfBoundsException> { compressor.compressStream2(ByteArray(4), 5, 0, ByteArray(4), 4, 0, 2) }
                fails<IndexOutOfBoundsException> { compressor.compressStream2(ByteArray(4), 4, -1, ByteArray(4), 4, 0, 2) }
                val shared = ByteArray(64)
                fails<IllegalArgumentException> { compressor.compressStream2(shared, 64, 0, shared, 4, 0, 2) }
                val pointer = handle(compressor, "cctxPointer")
                fails<NullPointerException> { native(compressor, "compressStream2", 0x4d534c5aL, pointer, null, 4, 0, ByteArray(1), 1, 0, 2) }
                fails<IllegalArgumentException> { compressor.compressStream2(ByteArray(16), 16, 0, ByteArray(1), 1, 0, 99) }
                shared[0] = 97; shared[1] = 98; shared[2] = 99
                check(compressor.compressStream2(shared, 64, 16, shared, 3, 0, 2) == 0L)
                check(decode(shared.copyOfRange(16, 16 + compressor.outputBytesProcessed)).contentEquals("abc".toByteArray()))
                check(shared.take(3) == listOf(97.toByte(), 98.toByte(), 99.toByte()))
            }
        }
        case("forged_metadata_handle_and_wrong_context_kind_are_rejected") {
            zstdCompressor().use { compressor -> zstdDecompressor().use { decompressor ->
                val comp = handle(compressor, "cctxPointer"); val decomp = handle(decompressor, "dctxPointer")
                fails<IllegalStateException> { native(compressor, "setParameter", Long.MAX_VALUE, 100, 1) }
                fails<IllegalStateException> { native(compressor, "setParameter", decomp, 100, 1) }
                fails<IllegalStateException> { native(compressor, "compressStream2", 0L, comp, ByteArray(16), 16, 0, ByteArray(1), 1, 0, 2) }
                native(compressor, "close", decomp)
                check(decompress(rawFrame, decompressor).contentEquals("abc".toByteArray()))
            } }
        }
        case("injected_array_allocation_failures_release_acquisitions_and_leave_stream_reusable") {
            for (stage in 2..3) {
                zstdCompressor().use { compressor ->
                    ZstdNativeTestHooks.faultNext(stage)
                    fails<OutOfMemoryError> { compress("retry".toByteArray(), compressor) }
                    check(compressor.inputBytesProcessed == 0 && compressor.outputBytesProcessed == 0)
                    check(decode(compress("retry".toByteArray(), compressor)).contentEquals("retry".toByteArray()))
                }
                zstdDecompressor().use { decompressor ->
                    ZstdNativeTestHooks.faultNext(stage)
                    fails<OutOfMemoryError> { decompress(rawFrame, decompressor) }
                    check(decompress(rawFrame, decompressor).contentEquals("abc".toByteArray()))
                }
            }
        }
        case("context_and_metadata_failures_preserve_pending_exceptions_and_release_global_references") {
            ZstdNativeTestHooks.faultNext(1)
            fails<OutOfMemoryError> { zstdCompressor() }
            for (stage in 4..6) {
                check(ZstdNativeTestHooks.shutdown() == 0 && ZstdNativeTestHooks.globalReferences() == 0)
                ZstdNativeTestHooks.faultNext(stage)
                if (stage == 6) fails<NoSuchFieldError> { zstdCompressor() } else fails<OutOfMemoryError> { zstdCompressor() }
                check(ZstdNativeTestHooks.globalReferences() == 0 && ZstdNativeTestHooks.activeContexts() == 0)
                zstdCompressor().use { check(getErrorName(it.setParameter(100, 1)) == null) }
                check(ZstdNativeTestHooks.globalReferences() == 2)
            }
        }
        case("concurrent_close_retains_active_call_siblings_work_and_busy_shutdown_is_rejected") {
            val compressor = zstdCompressor(); val result = AtomicReference<ByteArray>(); val failure = AtomicReference<Throwable>()
            ZstdNativeTestHooks.armGate()
            val worker = thread(isDaemon = true) {
                try { result.set(compress("running".toByteArray(), compressor, 64)) }
                catch (error: Throwable) { failure.set(error) }
            }
            try {
                waitForGate(); compressor.close()
                check(ZstdNativeTestHooks.activeContexts() == 1 && ZstdNativeTestHooks.shutdown() == -1)
                check(decode(encode("sibling".toByteArray())).contentEquals("sibling".toByteArray()))
                ZstdNativeTestHooks.releaseGate(); worker.join(5000)
                check(!worker.isAlive && failure.get() == null)
                check(decode(result.get()).contentEquals("running".toByteArray()))
            } finally { ZstdNativeTestHooks.releaseGate(); worker.join(5000); compressor.close() }
        }
        case("shutdown_closes_idle_contexts_drops_refs_and_new_ids_do_not_alias_stale_objects") {
            val stale = zstdCompressor(); val staleDecoder = zstdDecompressor()
            val old = handle(stale, "cctxPointer")
            check(ZstdNativeTestHooks.shutdown() == 0 && ZstdNativeTestHooks.globalReferences() == 0)
            zstdCompressor().use { fresh ->
                check(handle(fresh, "cctxPointer") != old)
                fails<IllegalStateException> { stale.setParameter(100, 1) }
                stale.close(); staleDecoder.close()
                check(decode(compress("new lifetime".toByteArray(), fresh)).contentEquals("new lifetime".toByteArray()))
            }
        }
        case("parallel_streams_keep_independent_contexts_and_bytes") {
            val executor = Executors.newFixedThreadPool(4)
            try {
                val results = (1..8).map { index -> executor.submit<Boolean> {
                    val data = Random(index).nextBytes(24000) + "المصدر $index 📚".toByteArray()
                    decode(encode(data)).contentEquals(data)
                } }
                check(results.all { it.get(10, TimeUnit.SECONDS) })
            } finally { executor.shutdownNow(); check(executor.awaitTermination(5, TimeUnit.SECONDS)) }
        }
        case("upstream_io_failures_close_codec_contexts") {
            val badSource = object : Source {
                override fun read(sink: Buffer, byteCount: Long): Long = throw IOException("authored input failure")
                override fun timeout() = Timeout.NONE
                override fun close() { }
            }
            fails<IOException> { badSource.zstdDecompress().buffer().use { it.readByteArray() } }
            val badSink = object : Sink {
                override fun write(source: Buffer, byteCount: Long) { throw IOException("authored output failure") }
                override fun timeout() = Timeout.NONE
                override fun flush() { }
                override fun close() { }
            }
            fails<IOException> { badSink.zstdCompress().buffer().use { it.writeUtf8("write failure") } }
        }
        check(ZstdNativeTestHooks.globalReferences() == 2)
        println(buildJsonObject {
            put("passed", true); put("loading", mode)
            put("checks", buildJsonObject { checks.forEach { (name, value) -> put(name, value) } })
            put("scope", "Source-built codec, authored host JNI/streaming/fault fixtures and simulated Darwin loader property; no iOS execution or published extension")
        })
    }
}
