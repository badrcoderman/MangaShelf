package mangashelf.host

import android.app.Application
import eu.kanade.tachiyomi.source.ConfigurableSource
import eu.kanade.tachiyomi.source.online.HttpSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import java.nio.file.Files
import java.nio.file.Path
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrl

/** Executes only the explicitly pinned public source rebuild, never an IPA specimen. */
object MangaDexCheck {
    @JvmStatic
    fun main(args: Array<String>) = runBlocking {
        val candidate = Path.of(args[0]); val data = Path.of(args[1])
        val live = args.getOrNull(2) == "live"
        val liveCounts = linkedMapOf<String, Int>()
        val metadata = Json.parseToJsonElement(Files.readString(candidate.resolve("source-build.json"))).jsonObject
        check(metadata.getValue("commit").jsonPrimitive.content == "1d3d7c4b3e876fb0c26ae3ade8113fb329af15fa")
        val sources = metadata.getValue("sources").jsonArray.map { value ->
            val item = value.jsonObject
            SourceRegistry.ExpectedSource(item.getValue("id").jsonPrimitive.content.toLong(), item.getValue("lang").jsonPrimitive.content)
        }
        check(sources.size == 61)
        val english = sources.single { it.language == "en" }.id
        val registry = SourceRegistry(); val checks = linkedMapOf<String, Boolean>()
        HostServices.configure(Application(data.resolve("app"), "app.mangashelf.sourcecheck"), "source-check", 8,
            "MangaShelf-SourceCheck/8", "26.2") // Explicit simulated release; this runs on a host JVM.
        suspend fun case(name: String, body: suspend () -> Unit) {
            System.err.println("START $name")
            try { withTimeout(90000) { body() } }
            catch (error: Throwable) { System.err.println("FAIL $name: ${error.javaClass.name}: ${error.message}"); throw error }
            checks[name] = true; System.err.println("PASS $name")
        }
        try {
            val scratch = Files.createDirectories(data.resolve("scratch"))
            val request = ExtensionLoader.Request(candidate.resolve("tachiyomi-all.mangadex-v1.6.0.jar"),
                "23321c50804ace0b0327117d4a453728b10a65e9383eaa4b962d83aac4afa070",
                "a5086c0c2f8e442846a0ea6df55af9cfc70baba17382029e7903de84731bbe7a",
                "eu.kanade.tachiyomi.extension.all.mangadex", 106000UL, "1.6.0", "keiyoushi.source.Generated", sources)
            case("verified_public_source_rebuild_installs_all_61_metadata_ids_and_languages") {
                val registered = ExtensionLoader(registry, scratch).install(request)
                check(registered.size == 61 && registered.map { it.id }.toSet() == sources.map { it.id }.toSet())
            }
            case("actual_source_headers_and_compression_client_construct_with_host_services") {
                registry.withSource(english) { source ->
                    check(source is ConfigurableSource && source is HttpSource)
                    check(source.name == "MangaDex" && source.lang == "en")
                    check(source.javaClass.classLoader is VerifiedExtensionClassLoader)
                    check(Thread.currentThread().contextClassLoader === source.javaClass.classLoader)
                    check(source.headers["User-Agent"] == "Tachiyomi MangaShelf-SourceCheck/8")
                    check(source.headers["Extra"]?.contains("Android/26.2") == true)
                    check(source.client.interceptors.any { it is okhttp3.CompressionInterceptor })
                }
            }
            case("actual_source_exposes_twelve_settings_with_validation_callbacks") {
                val session = SourcePreferenceSession.open(registry, english)
                try {
                    val snapshot = session.snapshot()
                    check(snapshot.rows.size == 12) { "Unexpected settings: ${snapshot.rows.map { it.key }}" }
                    val text = snapshot.rows.first { it.kind == SourcePreferenceSession.Kind.TEXT }
                    check(!session.validateText(text.id, "invalid-uuid").allowed)
                    check(session.validateText(text.id, "35d3f9dd-344b-40a6-b690-92c5def28f52").allowed)
                } finally { session.closeAndJoin() }
            }
            if (live) {
                // Keep every source model in the same lease until the flow ends.
                registry.withSource(english) { source ->
                    var selected: SManga? = null
                    var chapters = emptyList<SChapter>()
                    case("live_popular_catalogue_from_actual_source") {
                        val page = source.getPopularManga(1)
                        check(page.mangas.isNotEmpty() && page.mangas.all { it.title.isNotBlank() && it.url.isNotBlank() })
                        selected = page.mangas.first()
                        liveCounts["popular"] = page.mangas.size
                    }
                    case("live_search_details_and_chapters_from_actual_source") {
                        val manga = checkNotNull(selected)
                        val search = source.getSearchManga(1, manga.title, FilterList())
                        check(search.mangas.isNotEmpty())
                        liveCounts["search"] = search.mangas.size
                        val update = source.getMangaUpdate(manga, emptyList(), true, true)
                        check(update.manga.title.isNotBlank() && update.chapters.isNotEmpty())
                        selected = update.manga; chapters = update.chapters
                        liveCounts["chapters"] = chapters.size
                    }
                    case("live_page_urls_and_expired_token_refresh_from_actual_source_request_builder") {
                        check(source is HttpSource)
                        val chapter = chapters.first()
                        val pages = source.getPageList(chapter)
                        check(pages.isNotEmpty())
                        for (page in pages) {
                            val raw = page.imageUrl
                            val metadata = page.url
                            val url = source.getImageUrl(page).toHttpUrl()
                            check(url.isHttps && url.encodedPath.endsWith(checkNotNull(raw)))
                            check(page.imageUrl == raw && page.url == metadata)
                        }
                        val first = pages.first()
                        val expired = Page(first.index, first.url.substringBeforeLast(',') + ",0", first.imageUrl)
                        val refreshed = source.getImageUrl(expired).toHttpUrl()
                        check(refreshed.isHttps && refreshed.encodedPath.endsWith(checkNotNull(first.imageUrl)))
                        liveCounts["pages"] = pages.size
                        liveCounts["expired_token_refreshes"] = 1
                    }
                }

            }
            case("removal_drains_source_settings_and_releases_verified_archive") {
                val loader = registry.withSource(english) { it.javaClass.classLoader as VerifiedExtensionClassLoader }
                registry.remove(request.packageName).await()
                check(registry.snapshot().isEmpty() && loader.isClosed)
            }
        } finally { registry.close().forEach { it.await() }; HostServices.close() }

        fun runtime(action: String, request: kotlinx.serialization.json.JsonObject): kotlinx.serialization.json.JsonElement {
            val result = Json.parseToJsonElement(SourceRuntime.dispatch(action, request.toString()))
            check(result !is kotlinx.serialization.json.JsonObject || result["error"] == null) { result.toString() }
            return result
        }
        case("static_runtime_verifies_source_metadata_and_manages_all_61_sources") {
            try {
                runtime("configure", buildJsonObject {
                    put("dataDirectory", data.resolve("runtime").toString()); put("applicationId", "app.mangashelf.runtimecheck")
                    put("versionName", "source-check"); put("versionCode", 8); put("userAgent", "MangaShelf-SourceCheck/8")
                    put("platformRelease", "26.2")
                })
                val rejected = Json.parseToJsonElement(SourceRuntime.dispatch("load", "{}")).jsonObject
                check(rejected["error"]?.jsonPrimitive?.content == "invalid_request")
                val loaded = runtime("load", buildJsonObject {
                    put("package", "eu.kanade.tachiyomi.extension.all.mangadex")
                    put("path", candidate.resolve("tachiyomi-all.mangadex-v1.6.0.jar").toString())
                    put("archiveSha256", "23321c50804ace0b0327117d4a453728b10a65e9383eaa4b962d83aac4afa070")
                    put("trustedCertificateSha256", "a5086c0c2f8e442846a0ea6df55af9cfc70baba17382029e7903de84731bbe7a")
                    put("versionCode", "106000"); put("versionName", "1.6.0"); put("mainClass", "keiyoushi.source.Generated")
                    put("sources", kotlinx.serialization.json.JsonArray(sources.map { source -> buildJsonObject {
                        put("id", source.id.toString()); put("language", source.language)
                    } }))
                }).jsonObject
                check(loaded["status"] == kotlinx.serialization.json.JsonPrimitive("loaded"))
                check(loaded.getValue("sources").jsonArray.size == 61)
                check(runtime("sources", buildJsonObject { }).jsonObject.getValue("sources").jsonArray.size == 61)
                if (live) {
                case("live_json_commands_roundtrip_actual_manga_chapter_and_page_metadata") {
                    fun request(url: String? = null, metadata: String? = null) = buildJsonObject {
                        put("sourceId", english.toString()); put("page", 1)
                        url?.let { put("url", it) }; metadata?.let { put("sourceMetadataJSON", it) }
                    }
                    val catalogue = runtime("popular", request()).jsonObject
                    val manga = catalogue.getValue("mangas").jsonArray.first().jsonObject
                    val update = runtime("update", request(
                        manga.getValue("url").jsonPrimitive.content,
                        manga.getValue("sourceMetadataJSON").jsonPrimitive.content,
                    )).jsonObject
                    check(update.getValue("details").jsonObject.getValue("title").jsonPrimitive.content.isNotBlank())
                    val chapters = update.getValue("chapters").jsonArray
                    val chapter = chapters.first().jsonObject
                    val pages = runtime("pages", request(
                        chapter.getValue("url").jsonPrimitive.content,
                        chapter.getValue("sourceMetadataJSON").jsonPrimitive.content,
                    )).jsonArray.map { it.jsonObject }
                    check(pages.isNotEmpty() && pages.map { it.getValue("index").jsonPrimitive.int } == pages.indices.toList())
                    check(pages.all { it.getValue("imageURL").jsonPrimitive.content.toHttpUrl().isHttps })
                    liveCounts["wire_chapters"] = chapters.size; liveCounts["wire_pages"] = pages.size
                }
                }
                runtime("unload", buildJsonObject { put("package", "eu.kanade.tachiyomi.extension.all.mangadex") })
                check(runtime("sources", buildJsonObject { }).jsonObject.getValue("sources").jsonArray.isEmpty())
            } finally {
                val closed = Json.parseToJsonElement(SourceRuntime.dispatch("close", "{}")).jsonObject
                check(closed["status"] == kotlinx.serialization.json.JsonPrimitive("closed")) { closed.toString() }
            }
        }
        println(buildJsonObject {
            put("passed", true); put("checks", buildJsonObject { checks.forEach { (name, value) -> put(name, value) } })
            put("candidate", "Pinned public source rebuild, debug certificate; not publisher trust bootstrap")
            put("source_rebuild_executed", true); put("live_api_tested", live); put("ios_execution", false)
            put("live_counts", buildJsonObject { liveCounts.forEach { (name, value) -> put(name, value) } })
        })
    }
}
