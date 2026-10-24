package mangashelf.host

import android.app.Application
import com.sun.net.httpserver.HttpServer
import java.io.IOException
import java.net.InetSocketAddress
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import java.util.HexFormat
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import mangashelf.runtime.ExtensionArchiveVerifier

/** Only project-authored signed fixtures are executable inputs to this check. */
object LoaderCheck {
    private class HttpFixtureServer : AutoCloseable {
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        private val executor = Executors.newCachedThreadPool { Thread(it, "authored-source-server").apply { isDaemon = true } }
        private val server = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0)
        val url get() = "http://127.0.0.1:${server.address.port}"
        init {
            server.executor = executor
            server.createContext("/") { exchange ->
                try {
                    check(exchange.requestHeaders.getFirst("X-Fixture") == "verified")
                    if (exchange.requestURI.path == "/slow") {
                        entered.countDown()
                        check(release.await(10, TimeUnit.SECONDS))
                    }
                    val body = "العربية 📚".toByteArray(Charsets.UTF_8)
                    exchange.responseHeaders.add("Content-Type", "text/plain; charset=utf-8")
                    exchange.sendResponseHeaders(200, body.size.toLong())
                    exchange.responseBody.use { it.write(body) }
                } catch (_: IOException) { /* A cancelled client may close its socket. */ }
                finally { exchange.close() }
            }
            server.start()
        }
        override fun close() { release.countDown(); server.stop(0); executor.shutdownNow() }
    }
    private fun count() = System.getProperty("msl.fixture.constructs", "0").toInt()
    private fun lastLoader() = System.getProperties()["msl.fixture.loader"] as VerifiedExtensionClassLoader
    private suspend fun until(property: String) {
        withTimeout(5000) { while (System.getProperty(property) != "true") delay(5) }
    }
    private suspend fun fails(code: String, action: suspend () -> Unit) {
        try { action() }
        catch (error: Throwable) {
            val codes = generateSequence(error) { it.cause }.map {
                when (it) {
                    is ExtensionLoader.LoadException -> it.code
                    is SourceRegistry.RegistrationException -> it.code
                    is ExtensionArchiveVerifier.VerificationException -> it.code
                    else -> it.message
                }
            }.toList()
            check(code in codes) { "Expected $code, got $codes" }
            return
        }
        error("Expected failure $code")
    }

    @JvmStatic
    fun main(args: Array<String>) = runBlocking {
        val root = Path.of(args.single())
        val fixtures = Json.parseToJsonElement(Files.readString(root.resolve("fixtures.json"))).jsonObject
        val scratch = Files.createDirectory(root.resolve("loader-scratch"))
        val checks = linkedMapOf<String, Boolean>()
        fun request(label: String): ExtensionLoader.Request {
            val item = fixtures.getValue(label).jsonObject
            fun value(key: String) = item.getValue(key).jsonPrimitive.content
            return ExtensionLoader.Request(root.resolve(value("file")), value("sha256"), value("pin"),
                "fixture.extension", 106000UL, "1.6.0", value("mainClass"),
                listOf(SourceRegistry.ExpectedSource(-37, "ar"), SourceRegistry.ExpectedSource(42, "en")))
        }
        suspend fun case(name: String, body: suspend () -> Unit) {
            System.err.println("START $name")
            System.getProperties().keys.filter { it.toString().startsWith("msl.fixture.") }.toList()
                .forEach { System.getProperties().remove(it) }
            try { withTimeout(15000) { body() } }
            catch (error: Throwable) {
                System.err.println("FAIL $name: ${error.javaClass.name}: ${error.message}")
                throw error
            }
            Files.list(scratch).use { check(it.count() == 0L) { "Snapshot paths leaked" } }
            checks[name] = true
            System.err.println("PASS $name")
        }

        case("fixture_classes_are_absent_from_parent_classpath") {
            try { Class.forName("fixture.extension.Generated", false, javaClass.classLoader); error("Fixture on parent classpath") }
            catch (_: ClassNotFoundException) { }
        }
        case("verified_open_handle_survives_original_replacement_without_snapshot_paths") {
            val original = request("valid")
            val copy = Files.copy(original.archive, root.resolve("replaceable.jar"))
            ExtensionArchiveVerifier.openVerified(copy, original.archiveSha256, original.trustedCertificateSha256, scratch).use { archive ->
                Files.list(scratch).use { check(it.count() == 0L) }
                val before = checkNotNull(archive.read("fixture/extension/Generated.class")).bytes()
                Files.writeString(copy, "Replaced caller-owned path after verification")
                val after = checkNotNull(archive.read("fixture/extension/Generated.class")).bytes()
                check(before.contentEquals(after))
                VerifiedExtensionClassLoader.open(archive, javaClass.classLoader).use { loader ->
                    val type = loader.localEntrypoint(original.mainClass)
                    check(type.classLoader === loader && count() == 0)
                    val signers = checkNotNull(type.signers)
                    check(signers.isNotEmpty())
                    val source = type.protectionDomain.codeSource
                    check(source.location.protocol == "msl-jar" && source.location.host == original.archiveSha256)
                    val leaf = source.codeSigners.single().signerCertPath.certificates.first().encoded
                    val pin = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(leaf))
                    check(pin == original.trustedCertificateSha256)
                    val thread = Thread.currentThread()
                    val previous = thread.contextClassLoader
                    try {
                        thread.contextClassLoader = loader
                        check(type.getConstructor().newInstance() is eu.kanade.tachiyomi.source.SourceFactory)
                    } finally { thread.contextClassLoader = previous }
                    check(count() == 1)
                }
                check(archive.isClosed)
            }
        }
        case("signed_factory_registers_and_invokes_two_real_typed_fixture_sources") {
            val previous = Thread.currentThread().contextClassLoader
            val registry = SourceRegistry()
            val infos = ExtensionLoader(registry, scratch).install(request("valid"))
            check(infos.map { it.id } == listOf(-37L, 42L) && infos.map { it.language } == listOf("ar", "en"))
            check(count() == 1)
            for (info in infos) registry.withSource(info.id) { source ->
                check(source.javaClass.classLoader === lastLoader())
                val page = source.getPopularManga(2)
                check(page.mangas.single().title == "signed/base/${info.id}/2" && !page.hasNextPage)
                check(page.mangas.single().description == "verified resource العربية 📚\n")
            }
            val loader = lastLoader()
            check(!loader.isClosed)
            registry.remove("fixture.extension").await()
            check(loader.isClosed && registry.snapshot().isEmpty())
            check(Thread.currentThread().contextClassLoader === previous)
        }
        case("single_source_entrypoint_and_relative_manifest_class") {
            val registry = SourceRegistry()
            val single = request("single").copy(expectedSources = listOf(SourceRegistry.ExpectedSource(-37, "ar")))
            check(ExtensionLoader(registry, scratch).install(single).single().id == -37L)
            registry.close().forEach { it.await() }
            check(lastLoader().isClosed)
        }
        case("multi_release_class_selection_and_signed_package_sealing") {
            val registry = SourceRegistry()
            ExtensionLoader(registry, scratch).install(request("multi"))
            registry.withSource(42) { source ->
                check(source.getPopularManga(1).mangas.single().title == "signed/versioned/42/1")
                check(source.javaClass.`package`.isSealed)
                check(source.javaClass.`package`.implementationVersion == "authored-v1")
            }
            registry.close().forEach { it.await() }
        }
        case("unicode_resource_urls_enumeration_and_closed_handle_behavior") {
            val registry = SourceRegistry()
            ExtensionLoader(registry, scratch).install(request("valid"))
            val loader = lastLoader()
            val name = "assets/العربية 📚 #%.txt"
            val resource = checkNotNull(loader.getResource(name))
            check(resource.toExternalForm().contains("%23%25"))
            check(resource.openStream().use { it.readBytes().toString(Charsets.UTF_8) } == "verified resource العربية 📚\n")
            check(loader.getResources(name).toList() == listOf(resource))
            val retainedStream = resource.openStream()
            registry.close().forEach { it.await() }
            check(retainedStream.use { it.readBytes().toString(Charsets.UTF_8) } == "verified resource العربية 📚\n")
            fails("archive_closed") { resource.openStream() }
            check(loader.getResource(name) == null)
            try { loader.loadClass("fixture.extension.Late"); error("Defined new class after close") }
            catch (_: ClassNotFoundException) { }
        }
        case("digest_and_pin_rejection_precede_constructor_execution") {
            val registry = SourceRegistry()
            val loader = ExtensionLoader(registry, scratch)
            fails("digest_mismatch") { loader.install(request("valid").copy(archiveSha256 = "0".repeat(64))) }
            fails("signer_mismatch") { loader.install(request("valid").copy(trustedCertificateSha256 = "0".repeat(64))) }
            check(count() == 0 && registry.snapshot().isEmpty())
        }
        case("manifest_identity_and_api_rejection_precede_initialization") {
            val registry = SourceRegistry()
            val loader = ExtensionLoader(registry, scratch)
            val valid = request("valid")
            for (bad in listOf(valid.copy(packageName = "wrong.package"), valid.copy(versionCode = 7UL),
                valid.copy(versionName = "other"), valid.copy(mainClass = "fixture.extension.NotSource"))) {
                fails("manifest_mismatch") { loader.install(bad) }
            }
            fails("unsupported_source_api") { loader.install(request("old_api")) }
            check(count() == 0 && System.getProperty("msl.fixture.invalid_initialized") == null)
        }
        case("missing_manifest_and_entity_declarations_are_rejected") {
            val registry = SourceRegistry()
            val loader = ExtensionLoader(registry, scratch)
            fails("missing_extension_manifest") { loader.install(request("no_android")) }
            fails("invalid_extension_manifest") { loader.install(request("entity")) }
            check(count() == 0)
        }
        case("host_class_shadow_and_external_classpath_are_rejected_before_initialization") {
            val registry = SourceRegistry()
            val loader = ExtensionLoader(registry, scratch)
            for (label in listOf("shadow", "versioned_shadow")) fails("host_class_shadow") { loader.install(request(label)) }
            fails("external_class_path_unsupported") { loader.install(request("classpath")) }
            check(count() == 0)
        }
        case("unsupported_entrypoint_types_and_abstract_classes_do_not_initialize") {
            val registry = SourceRegistry()
            val loader = ExtensionLoader(registry, scratch)
            for (label in listOf("not_source", "abstract")) fails("unsupported_entrypoint") { loader.install(request(label)) }
            try { loader.install(request("private")); error("Private constructor accepted") }
            catch (_: NoSuchMethodException) { }
            check(System.getProperty("msl.fixture.invalid_initialized") == null)
        }
        case("entrypoint_must_resolve_from_verified_child_not_host_parent") {
            val registry = SourceRegistry()
            fails("entrypoint_not_local") { ExtensionLoader(registry, scratch).install(request("parent")) }
            check(count() == 0)
        }
        case("constructor_failure_closes_owned_loader_without_replay") {
            val registry = SourceRegistry()
            fails("Authored constructor failure") { ExtensionLoader(registry, scratch).install(request("throws")) }
            check(count() == 1 && lastLoader().isClosed && registry.snapshot().isEmpty())
        }
        case("registration_failure_closes_owned_loader_without_replay") {
            val registry = SourceRegistry()
            val bad = request("valid").copy(expectedSources = listOf(SourceRegistry.ExpectedSource(1, "en")))
            fails("metadata_mismatch") { ExtensionLoader(registry, scratch).install(bad) }
            check(count() == 1 && lastLoader().isClosed && registry.snapshot().isEmpty())
        }
        case("cancellation_after_constructor_prevents_publication_and_closes_handle") {
            val registry = SourceRegistry()
            coroutineScope {
                val task = launch { ExtensionLoader(registry, scratch).install(request("blocking")) }
                try {
                    until("msl.fixture.constructor_blocked")
                    task.cancel()
                } finally { System.setProperty("msl.fixture.constructor_release", "true") }
                task.join()
                check(task.isCancelled)
            }
            check(count() == 1 && lastLoader().isClosed && registry.snapshot().isEmpty())
        }
        case("removal_drains_cancelled_source_before_archive_release") {
            val registry = SourceRegistry()
            ExtensionLoader(registry, scratch).install(request("valid"))
            val loader = lastLoader()
            coroutineScope {
                val call = async { registry.withSource(42) { it.getPopularManga(99) } }
                try {
                    until("msl.fixture.blocked")
                    val released = registry.remove("fixture.extension")
                    check(registry.snapshot().isEmpty() && !released.isCompleted && !loader.isClosed)
                    fails("source_not_registered") { registry.withSource(42) { it.getPopularManga(1) } }
                    System.setProperty("msl.fixture.release", "true")
                    try { call.await(); error("Removed source call completed") } catch (_: CancellationException) { }
                    released.await()
                    check(loader.isClosed && System.getProperty("msl.fixture.cleaned") == "true")
                } finally {
                    System.setProperty("msl.fixture.release", "true")
                    call.cancelAndJoin()
                }
            }
        }
        case("signed_http_source_fetches_unicode_over_real_http_through_registry") {
            val registry = SourceRegistry()
            HttpFixtureServer().use { server ->
                HostServices.configure(Application(root.resolve("http-success"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
                try {
                    System.setProperty("msl.fixture.http_url", server.url)
                    val http = request("http").copy(expectedSources = listOf(SourceRegistry.ExpectedSource(987, "en")))
                    check(ExtensionLoader(registry, scratch).install(http).single().id == 987L)
                    check(System.getProperty("msl.fixture.injected_app_package") == "app.mangashelf.test")
                    val preferences = HostServices.current.context.getSharedPreferences("source_987", 0)
                    check(preferences.getInt("starts", 0) == 1)
                    registry.withSource(987) { source ->
                        check(source.javaClass.classLoader === lastLoader())
                        check(source.getPopularManga(1).mangas.single().title == "العربية 📚")
                    }
                    registry.remove("fixture.extension").await()
                    check(lastLoader().isClosed)
                    ExtensionLoader(registry, scratch).install(http)
                    check(preferences.getInt("starts", 0) == 2)
                    registry.withSource(987) { check(it.getPopularManga(2).mangas.single().title == "العربية 📚") }
                    registry.remove("fixture.extension").await()
                    check(lastLoader().isClosed)
                } finally { registry.close().forEach { it.await() }; HostServices.close() }
            }
        }
        case("signed_source_settings_validate_persist_drive_http_and_drain_before_archive_close") {
            val registry = SourceRegistry()
            HttpFixtureServer().use { server ->
                HostServices.configure(Application(root.resolve("signed-settings"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
                try {
                    System.setProperty("msl.fixture.http_url", server.url)
                    val http = request("http").copy(expectedSources = listOf(SourceRegistry.ExpectedSource(987, "en")))
                    ExtensionLoader(registry, scratch).install(http)
                    val loader = lastLoader()
                    val session = SourcePreferenceSession.open(registry, 987)
                    try {
                        check(session.snapshot().rows.map { it.title } == listOf("Quality", "Result prefix"))
                        check(!session.validateText(2, "bad\nvalue").allowed)
                        check(!session.change(2, SourcePreferenceSession.Value.Text("bad\nvalue")).accepted)
                        check(System.getProperty("msl.fixture.settings_changed") == null)
                        check(session.change(1, SourcePreferenceSession.Value.Text("small")).screen.rows[0].summary == "Small")
                        check(session.change(2, SourcePreferenceSession.Value.Text("إعداد 📚: ")).accepted)
                        check(System.getProperty("msl.fixture.settings_changed") == "true")
                        registry.withSource(987) { check(it.getPopularManga(1).mangas.single().title == "إعداد 📚: العربية 📚") }
                        System.setProperty("msl.fixture.settings_hold", "true")
                        val removed = registry.remove("fixture.extension")
                        until("msl.fixture.settings_cleanup_entered")
                        check(!removed.isCompleted && !loader.isClosed)
                        System.setProperty("msl.fixture.settings_release", "true")
                        removed.await(); session.closeAndJoin()
                        check(loader.isClosed && System.getProperty("msl.fixture.settings_cleanup_done") == "true")
                        ExtensionLoader(registry, scratch).install(http)
                        val reopened = SourcePreferenceSession.open(registry, 987)
                        try {
                            check(reopened.snapshot().rows[1].value == SourcePreferenceSession.Value.Text("إعداد 📚: "))
                            registry.withSource(987) { check(it.getPopularManga(2).mangas.single().title == "إعداد 📚: العربية 📚") }
                        } finally { reopened.closeAndJoin() }
                        registry.remove("fixture.extension").await()
                    } finally { System.setProperty("msl.fixture.settings_release", "true"); session.closeAndJoin() }
                } finally {
                    System.setProperty("msl.fixture.settings_release", "true")
                    registry.close().forEach { it.await() }; HostServices.close()
                }
            }
        }
        case("http_cancellation_retains_archive_until_asynchronous_interceptor_cleanup") {
            val registry = SourceRegistry()
            HttpFixtureServer().use { server ->
                HostServices.configure(Application(root.resolve("http-cancel"), "app.mangashelf.test"), "test", 7, "MangaShelf-Test/7")
                try {
                    System.setProperty("msl.fixture.http_url", server.url)
                    val http = request("http").copy(expectedSources = listOf(SourceRegistry.ExpectedSource(987, "en")))
                    ExtensionLoader(registry, scratch).install(http)
                    coroutineScope {
                        val call = async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
                            registry.withSource(987) { it.getPopularManga(99) }
                        }
                        try {
                            check(server.entered.await(5, TimeUnit.SECONDS))
                            val released = registry.remove("fixture.extension")
                            until("msl.fixture.http_cleanup_entered")
                            check(!released.isCompleted && !lastLoader().isClosed)
                            System.setProperty("msl.fixture.http_release", "true")
                            try { call.await(); error("Cancelled HTTP source returned data") } catch (_: CancellationException) { }
                            released.await()
                            check(lastLoader().isClosed && System.getProperty("msl.fixture.http_cleanup_done") == "true")
                        } finally {
                            System.setProperty("msl.fixture.http_release", "true")
                            server.release.countDown()
                            call.cancelAndJoin()
                        }
                    }
                } finally {
                    System.setProperty("msl.fixture.http_release", "true")
                    registry.close().forEach { it.await() }
                    HostServices.close()
                }
            }
        }
        case("manifest_parser_bounds_namespaces_duplicates_and_unsigned_version_range") {
            val manifest = Files.readString(root.resolve("manifest.xml"))
            val parsed = ExtensionManifest.parse(manifest.replace("xmlns:android", "xmlns:a").replace("android:", "a:").toByteArray())
            check(parsed.mainClass() == "fixture.extension.Generated")
            check(ExtensionManifest.parse(manifest.replace("106000", "18446744073709551615").toByteArray()).versionCode().toString() == "18446744073709551615")
            val invalid = listOf(
                manifest.replace("106000", "18446744073709551616"),
                manifest.replace("106000", "-1"),
                manifest.replace("http://schemas.android.com/apk/res/android", "https://wrong.invalid/android"),
                manifest.replace("<application>", "<application xmlns='urn:wrong'>"),
                manifest.replace("</application>", "<meta-data android:name='tachiyomi.extension.class' android:value='Other'/></application>"),
                manifest.replace("</manifest>", "<application/></manifest>"),
                manifest.replace("</application>", "<nested>".repeat(34) + "</nested>".repeat(34) + "</application>"),
                manifest.replace("</application>", "<item/>".repeat(4097) + "</application>"),
                manifest.replace("<application>", "<application " + (1..65).joinToString(" ") { "a$it='x'" } + ">"),
                manifest.replace("fixture.extension.Generated", "../Generated"),
                manifest + "\u0000",
            )
            for (text in invalid) fails("invalid_extension_manifest") { ExtensionManifest.parse(text.toByteArray()) }
            fails("invalid_extension_manifest") { ExtensionManifest.parse(ByteArray(256 * 1024 + 1) { 65 }) }
            fails("invalid_extension_manifest") { ExtensionManifest.parse(byteArrayOf(0xC0.toByte(), 0xAF.toByte())) }
        }
        case("static_runtime_close_drains_signed_source_http_before_archive_and_services") {
            HttpFixtureServer().use { server ->
                System.setProperty("msl.fixture.http_url", server.url)
                fun runtime(action: String, body: JsonObject): JsonObject =
                    Json.parseToJsonElement(SourceRuntime.dispatch(action, body.toString())).jsonObject
                val configured = runtime("configure", buildJsonObject {
                    put("dataDirectory", root.resolve("static-runtime").toString()); put("applicationId", "app.mangashelf.runtimefixture")
                    put("versionName", "test"); put("versionCode", 9); put("userAgent", "MangaShelf-Test/9"); put("platformRelease", "26.2")
                })
                check(configured["status"]?.jsonPrimitive?.content == "configured")
                try {
                    val http = request("http")
                    val loaded = runtime("load", buildJsonObject {
                        put("package", http.packageName); put("path", http.archive.toString()); put("archiveSha256", http.archiveSha256)
                        put("trustedCertificateSha256", http.trustedCertificateSha256); put("mainClass", http.mainClass)
                        put("versionCode", http.versionCode.toString()); put("versionName", http.versionName)
                        put("sources", kotlinx.serialization.json.JsonArray(listOf(buildJsonObject { put("id", "987"); put("language", "en") })))
                    })
                    check(loaded["status"]?.jsonPrimitive?.content == "loaded")
                    check(runtime("popular", buildJsonObject { put("sourceId", "987"); put("page", 88) })["error"]?.jsonPrimitive?.content == "source_timeout")
                    val httpFailure = runtime("popular", buildJsonObject { put("sourceId", "987"); put("page", 87) })
                    check(httpFailure["error"]?.jsonPrimitive?.content == "source_http_error" && httpFailure["httpStatus"]?.jsonPrimitive?.content == "429")
                    check(runtime("popular", buildJsonObject { put("sourceId", "987"); put("page", 86) })["error"]?.jsonPrimitive?.content == "source_browser_verification")
                    val tlsFailure = runtime("popular", buildJsonObject { put("sourceId", "987"); put("page", 85) })
                    check(tlsFailure.keys == setOf("error") && tlsFailure["error"]?.jsonPrimitive?.content == "source_tls_failed")
                    val loader = lastLoader()
                    coroutineScope {
                        val call = async(Dispatchers.IO) { runtime("popular", buildJsonObject { put("sourceId", "987"); put("page", 99) }) }
                        try {
                            check(server.entered.await(5, TimeUnit.SECONDS))
                            val closing = async(Dispatchers.IO) { runtime("close", buildJsonObject { }) }
                            until("msl.fixture.http_cleanup_entered")
                            check(!closing.isCompleted && !loader.isClosed)
                            System.setProperty("msl.fixture.http_release", "true")
                            check(call.await()["error"]?.jsonPrimitive?.content == "cancelled")
                            check(closing.await()["status"]?.jsonPrimitive?.content == "closed")
                            check(loader.isClosed && System.getProperty("msl.fixture.http_cleanup_done") == "true")
                            try { HostServices.current; error("Closed runtime retained its services") }
                            catch (expected: IllegalStateException) { check(expected.message == "source_host_not_configured") }
                        } finally {
                            System.setProperty("msl.fixture.http_release", "true"); server.release.countDown()
                            call.cancelAndJoin()
                        }
                    }
                } finally {
                    System.setProperty("msl.fixture.http_release", "true"); server.release.countDown()
                    check(runtime("close", buildJsonObject { })["status"]?.jsonPrimitive?.content == "closed")
                }
            }
        }
        System.getProperties().keys.filter { it.toString().startsWith("msl.fixture.") }.toList()
            .forEach { System.getProperties().remove(it) }
        println(buildJsonObject {
            put("passed", true)
            put("checks", JsonObject(checks.mapValues { Json.parseToJsonElement(it.value.toString()) }))
            put("scope", "Project-authored signed fixture JARs and loopback HTTP, typed registry and host JVM; no published extension, NativeNet or iOS execution")
        })
    }
}
