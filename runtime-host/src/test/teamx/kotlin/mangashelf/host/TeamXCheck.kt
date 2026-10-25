package mangashelf.host

import android.app.Application
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.online.HttpSource
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import okhttp3.CompressionInterceptor
import org.jsoup.Jsoup
import org.jsoup.nodes.Document

/** Only the reviewed source rebuild is accepted. No IPA specimen or published JAR executes here. */
object TeamXCheck {
    private const val ID = 4110737012647435874L
    @JvmStatic fun main(args: Array<String>) = runBlocking {
        val candidate = Path.of(args[0]); val data = Path.of(args[1]); val live = args.getOrNull(2) == "live"
        val checks = linkedMapOf<String, Boolean>(); val counts = linkedMapOf<String, Int>()
        val registry = SourceRegistry()
        HostServices.configure(Application(data.resolve("app"), "app.mangashelf.teamxcheck"), "test", 8, "MangaShelf-TeamXCheck/8", "26.2")
        suspend fun case(name: String, block: suspend () -> Unit) {
            System.err.println("START $name"); withTimeout(90000) { block() }
            checks[name] = true; System.err.println("PASS $name")
        }
        fun request(vararg fields: Pair<String, String>): JsonObject = buildJsonObject {
            put("sourceId", ID.toString()); fields.forEach { (key, value) -> put(key, value) }
        }
        suspend fun document(url: String): Document = registry.withSource(ID) { source ->
            val http = source as HttpSource
            http.client.newCall(GET(url, http.headers)).awaitSuccess().use { response ->
                val bytes = response.body.byteStream().readNBytes(4 * 1024 * 1024 + 1)
                check(bytes.size <= 4 * 1024 * 1024)
                Jsoup.parse(bytes.inputStream(), null, response.request.url.toString())
            }
        }
        fun chapterURLs(document: Document): List<String> = document.select("div.chapter-card")
            .filter { it.selectFirst("span.locked") == null }.map { element ->
                val uri = URI(checkNotNull(element.selectFirst("a")).absUrl("href"))
                (uri.rawPath ?: "") + (uri.rawQuery?.let { "?$it" } ?: "") + (uri.rawFragment?.let { "#$it" } ?: "")
            }
        try {
            case("reviewed_teamx_rebuild_installs_exact_source_identity") {
                val installed = ExtensionLoader(registry, Files.createDirectories(data.resolve("verified"))).install(ExtensionLoader.Request(
                    candidate.resolve("tachiyomi-ar.teamx-v1.6.33.jar"),
                    "9b8908c39e874bbebb09698e1b535f0b8260938992a4687ffbd82f8fbe388a4d",
                    "30253495a3d855599903d555afe2708a220b8a1ca2896f660161cf4b3df095f3",
                    "eu.kanade.tachiyomi.extension.ar.teamx", 106033UL, "1.6.33", "keiyoushi.source.Generated",
                    listOf(SourceRegistry.ExpectedSource(ID, "ar"))))
                check(installed.size == 1 && installed.single().id == ID)
            }
            case("actual_teamx_headers_and_compression_client_construct") {
                registry.withSource(ID) { source ->
                    check(source is HttpSource && source.name == "Team X" && source.lang == "ar")
                    check(source.javaClass.classLoader is VerifiedExtensionClassLoader)
                    check(source.headers["Referer"] == "https://olympustaff.com/" && source.headers["Origin"] == "https://olympustaff.com")
                    check(source.client.interceptors.any { it is CompressionInterceptor })
                }
            }
            if (live) {
                val commands = SourceCommands(registry)
                var selected = JsonObject(emptyMap()); var firstDocument: Document? = null; var lastPage = 1
                var update = JsonObject(emptyMap()); var page = JsonObject(emptyMap())
                case("live_teamx_catalogue_and_public_paginated_title_selection") {
                    val popular = Json.parseToJsonElement(commands.execute("popular", buildJsonObject { put("sourceId", ID.toString()); put("page", 1) })).jsonObject
                    val mangas = popular.getValue("mangas").jsonArray.map { it.jsonObject }
                    check(mangas.isNotEmpty()); counts["catalogue"] = mangas.size
                    for (item in mangas.take(5)) {
                        val url = registry.withSource(ID) { source -> (source as HttpSource).getMangaUrl(SManga.create().apply { this.url = item.getValue("url").jsonPrimitive.content }) }
                        val document = document(url)
                        val pages = document.select("ul.pagination a.page-link").mapNotNull { it.text().toIntOrNull() }.maxOrNull() ?: 1
                        if (chapterURLs(document).isNotEmpty() && pages <= 10 && (selected.isEmpty() || pages > 1)) {
                            selected = item; firstDocument = document; lastPage = pages
                            if (pages > 1) break
                        }
                    }
                    check(selected.isNotEmpty()) { "No usable public title among the five reviewed catalogue entries" }
                    counts["website_chapter_pages"] = lastPage
                }
                case("live_teamx_partial_details_and_all_unlocked_chapters_match_website_pages") {
                    update = Json.parseToJsonElement(commands.execute("update", request(
                        "url" to selected.getValue("url").jsonPrimitive.content,
                        "sourceMetadataJSON" to selected.getValue("sourceMetadataJSON").jsonPrimitive.content))).jsonObject
                    check(update.getValue("details").jsonObject["url"] == selected["url"])
                    val first = checkNotNull(firstDocument)
                    val expected = chapterURLs(first).toMutableList()
                    for (number in 2..lastPage) expected.addAll(chapterURLs(document(first.location() + "?page=$number")))
                    val chapters = update.getValue("chapters").jsonArray.map { it.jsonObject.getValue("url").jsonPrimitive.content }
                    check(chapters == expected) { "Source/website chapter count mismatch: ${chapters.size}/${expected.size}" }
                    check(chapters.isNotEmpty()); counts["chapters"] = chapters.size
                }
                case("live_teamx_chapter_pages_keep_source_image_metadata") {
                    val chapter = update.getValue("chapters").jsonArray.first().jsonObject
                    val pages = Json.parseToJsonElement(commands.execute("pages", request(
                        "url" to chapter.getValue("url").jsonPrimitive.content,
                        "sourceMetadataJSON" to chapter.getValue("sourceMetadataJSON").jsonPrimitive.content))).jsonArray
                    check(pages.isNotEmpty()); counts["images_in_chapter"] = pages.size
                    page = pages.first().jsonObject
                }
                case("live_teamx_image_download_uses_source_client_and_verified_binary_file") {
                    val image = Json.parseToJsonElement(commands.execute("image", request("sourceMetadataJSON" to page.getValue("sourceMetadataJSON").jsonPrimitive.content))).jsonObject
                    val name = image.getValue("fileName").jsonPrimitive.content
                    check(Regex("[0-9a-f-]{36}\\.bin").matches(name))
                    val path = HostServices.current.context.cacheDir.toPath().resolve("image-transfers").resolve(name)
                    try {
                        val bytes = Files.readAllBytes(path)
                        check(bytes.isNotEmpty() && bytes.size <= 32 * 1024 * 1024 && bytes.size.toLong() == image.getValue("bytes").jsonPrimitive.long)
                        check(MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) } == image.getValue("sha256").jsonPrimitive.content)
                        counts["image_bytes"] = bytes.size
                    } finally { Files.deleteIfExists(path) }
                }
            }
        } finally { registry.close().forEach { it.await() }; HostServices.close() }
        println(buildJsonObject {
            put("passed", true); put("checks", buildJsonObject { checks.forEach { (name, passed) -> put(name, passed) } })
            put("counts", buildJsonObject { counts.forEach { (name, count) -> put(name, count) } })
            put("scope", "Pinned public Team X source rebuild on a host JVM; no iPhone execution or image rendering")
        })
    }
}
