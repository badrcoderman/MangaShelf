package mangashelf.host

import android.app.Application
import eu.kanade.tachiyomi.network.BrowserVerificationRequiredException
import eu.kanade.tachiyomi.network.HttpException
import java.io.IOException
import java.net.SocketTimeoutException
import javax.net.ssl.SSLException
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import mangashelf.runtime.ExtensionArchiveVerifier

/** App-owned JNI (String,String)->String entrypoint for verified Source 1.6 packages.
 * Calls block their native worker; callers must keep them off the UI thread.
 * Closing cancels and drains owned work before releasing shared application services.
 */
object SourceRuntime {
    private class State(val application: Application) {
        val job = SupervisorJob()
        val scope = CoroutineScope(Dispatchers.IO + job)
        val registry = SourceRegistry()
        val commands = SourceCommands(registry)
        val mutation = Mutex()
        val loader = ExtensionLoader(registry, Files.createDirectories(application.cacheDir.toPath().resolve("verified-extensions")))
        var closing = false
        var active = 0
    }
    private val lock = Any()
    private var state: State? = null

    @JvmStatic
    fun dispatch(action: String, payload: String): String {
        return try {
            val request = SourceCommands.boundedObject(payload)
            when (action) {
                "ping" -> buildJsonObject {
                    put("status", "ok"); put("engine", "MangaShelf Source 1.6"); put("schemaVersion", 1)
                    put("configured", synchronized(lock) { state?.closing == false })
                }.toString()
                "configure" -> configure(request)
                "close" -> close()
                else -> {
                    val task = synchronized(lock) {
                        val host = state?.takeUnless { it.closing } ?: fail("source_host_not_configured")
                        if (host.active >= 16) fail("request_limit")
                        host.active++
                        host.scope.async { withTimeout(90_000) { execute(host, action, request) } }.also { pending ->
                            pending.invokeOnCompletion { synchronized(lock) { host.active-- } }
                        }
                    }
                    runBlocking {
                        try { task.await() }
                        finally { withContext(NonCancellable) { task.join() } }
                    }
                }
            }
        } catch (error: SourceCommands.CommandException) { errorJson(error.code) }
        catch (error: ExtensionLoader.LoadException) { errorJson(error.code) }
        catch (error: SourceRegistry.RegistrationException) { errorJson(error.code) }
        catch (error: ExtensionArchiveVerifier.VerificationException) { errorJson(error.code) }
        catch (_: TimeoutCancellationException) { errorJson("source_timeout") }
        catch (_: CancellationException) { errorJson("cancelled") }
        catch (error: HttpException) { errorJson("source_http_error", error.code.takeIf { it in 100..599 }) }
        catch (_: BrowserVerificationRequiredException) { errorJson("source_browser_verification") }
        catch (_: SSLException) { errorJson("source_tls_failed") }
        catch (_: SocketTimeoutException) { errorJson("source_timeout") }
        catch (_: IOException) { errorJson("source_network_failed") }
        catch (_: LinkageError) { errorJson("source_dependency_failed") }
        catch (_: Exception) { errorJson("source_failed") }
    }

    private fun configure(request: JsonObject): String = synchronized(lock) {
        if (state != null) fail("source_host_already_configured")
        val directory = Path.of(text(request, "dataDirectory", 8192))
        if (!directory.isAbsolute) fail("invalid_request")
        val versionCode = (request["versionCode"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
            ?.takeIf { it >= 0 } ?: fail("invalid_request")
        val app = Application(directory, text(request, "applicationId", 512))
        try {
            HostServices.configure(app, text(request, "versionName", 128), versionCode,
                text(request, "userAgent", 512), text(request, "platformRelease", 128))
            try { state = State(app) }
            catch (failure: Throwable) {
                try { HostServices.close() } catch (release: Throwable) { if (release !== failure) failure.addSuppressed(release) }
                throw failure
            }
        } catch (failure: Throwable) {
            try { app.close() } catch (release: Throwable) { if (release !== failure) failure.addSuppressed(release) }
            throw failure
        }
        acknowledgment("configured")
    }

    private suspend fun execute(host: State, action: String, request: JsonObject): String = when (action) {
        "load" -> host.mutation.withLock {
            val sources = request["sources"] as? JsonArray ?: fail("invalid_request")
            if (sources.isEmpty() || sources.size > 4096) fail("invalid_request")
            val expected = sources.map { value ->
                val item = value as? JsonObject ?: fail("invalid_request")
                val id = text(item, "id", 32)
                SourceRegistry.ExpectedSource(id.toLongOrNull()?.takeIf { it.toString() == id } ?: fail("invalid_source_id"),
                    text(item, "language", 32))
            }
            val version = (request["versionCode"] as? JsonPrimitive)?.content ?: fail("invalid_request")
            val versionCode = version.toULongOrNull()?.takeIf { it.toString() == version } ?: fail("invalid_request")
            val packageName = text(request, "package", 512)
            val installed = host.loader.install(ExtensionLoader.Request(
                Path.of(text(request, "path", 8192)), text(request, "archiveSha256", 64),
                text(request, "trustedCertificateSha256", 64), packageName, versionCode,
                if (request["versionName"] == null || request["versionName"] == JsonNull) null else text(request, "versionName", 128),
                text(request, "mainClass", 512), expected,
            ))
            buildJsonObject {
                put("status", "loaded"); put("package", packageName); put("sources", sourceInfos(installed))
            }.toString()
        }
        "unload" -> host.mutation.withLock {
            val packageName = text(request, "package", 512)
            host.registry.remove(packageName).await()
            acknowledgment("unloaded", packageName)
        }
        "sources" -> buildJsonObject { put("sources", sourceInfos(host.registry.snapshot())) }.toString()
        else -> host.commands.execute(action, request)
    }

    private fun close(): String {
        val host = synchronized(lock) {
            val current = state ?: return acknowledgment("closed")
            if (current.closing) fail("source_host_closing")
            current.closing = true
            current
        }
        try {
            runBlocking(Dispatchers.IO) {
                host.job.cancel(); host.job.join()
                var failure: Throwable? = null
                for (ticket in host.registry.close()) {
                    try { ticket.await() }
                    catch (release: Throwable) { if (failure == null) failure = release else if (failure !== release) failure.addSuppressed(release) }
                }
                try { HostServices.close() }
                catch (release: Throwable) { if (failure == null) failure = release else if (failure !== release) failure.addSuppressed(release) }
                failure?.let { throw it }
            }
        } finally { synchronized(lock) { if (state === host) state = null } }
        return acknowledgment("closed")
    }

    private fun sourceInfos(values: List<SourceRegistry.SourceInfo>) = JsonArray(values.map { source ->
        buildJsonObject { put("id", source.id.toString()); put("package", source.packageName); put("name", source.name); put("language", source.language) }
    })
    private fun acknowledgment(status: String, packageName: String? = null) = buildJsonObject {
        put("status", status); packageName?.let { put("package", it) }
    }.toString()
    private fun errorJson(code: String, httpStatus: Int? = null) = buildJsonObject {
        put("error", code); httpStatus?.let { put("httpStatus", it) }
    }.toString()
    private fun fail(code: String): Nothing = throw SourceCommands.CommandException(code)
    private fun text(request: JsonObject, key: String, maximum: Int) = SourceCommands.string(request, key, maximum)
}
