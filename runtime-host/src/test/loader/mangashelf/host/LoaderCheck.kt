package mangashelf.host

import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import java.util.HexFormat
import kotlinx.coroutines.CancellationException
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
            System.getProperties().keys.filter { it.toString().startsWith("msl.fixture.") }.toList()
                .forEach { System.getProperties().remove(it) }
            withTimeout(15000) { body() }
            Files.list(scratch).use { check(it.count() == 0L) { "Snapshot paths leaked" } }
            checks[name] = true
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
        System.getProperties().keys.filter { it.toString().startsWith("msl.fixture.") }.toList()
            .forEach { System.getProperties().remove(it) }
        println(buildJsonObject {
            put("passed", true)
            put("checks", JsonObject(checks.mapValues { Json.parseToJsonElement(it.value.toString()) }))
            put("scope", "Project-authored signed fixture JARs only, typed registry and host JVM; no published extension, network or iOS execution")
        })
    }
}
