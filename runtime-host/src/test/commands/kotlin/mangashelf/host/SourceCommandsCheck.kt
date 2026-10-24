package mangashelf.host

import android.app.Application
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.model.UpdateStrategy
import eu.kanade.tachiyomi.source.online.HttpSource
import java.nio.file.Path
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import okhttp3.Request

/** Authored source models with deliberately opaque state, dates and unordered indices. */
object SourceCommandsCheck {
    private class Fixture : HttpSource() {
        override val id = 73L
        override val name = "Authored wire source"
        override val lang = "en"
        override val supportsLatest = true
        override val baseUrl = "https://catalog.example.invalid"
        var mode = "normal"
        var called = ""
        val entered = CompletableDeferred<Unit>()
        val resume = CompletableDeferred<Unit>()
        val cleaned = CompletableDeferred<Unit>()
        private fun manga() = SManga.create().apply {
            url = "/title/one"; title = "العربية 📚"; author = "Author"; artist = "Artist"
            thumbnail_url = "https://images.example.invalid/cover.png"; genre = "Action, Comedy"
            description = "Description"; status = SManga.ON_HIATUS; initialized = true
            update_strategy = UpdateStrategy.ONLY_FETCH_ONCE
            memo = buildJsonObject { put("number", 9); put("nested", JsonArray(listOf(JsonPrimitive("a,b"), JsonPrimitive(false)))) }
        }
        override suspend fun getPopularManga(page: Int): MangasPage {
            called = "popular:$page"
            if (mode == "cancel") {
                entered.complete(Unit)
                try { resume.await() } finally { cleaned.complete(Unit) }
            }
            if (mode == "count") return MangasPage(List(1001) { manga() }, false)
            return MangasPage(listOf(manga().apply { if (mode == "oversized") title = "📚".repeat(3000) }), true)
        }
        override suspend fun getLatestUpdates(page: Int): MangasPage {
            val result = getPopularManga(page); called = "latest:$page"; return result
        }
        override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
            check(filters.isEmpty())
            val result = getPopularManga(page); called = "search:$page:$query"; return result
        }
        override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean): SMangaUpdate {
            check(manga.url == "/title/one" && manga.title == "العربية 📚" && manga.author == "Author" && manga.artist == "Artist")
            check(manga.thumbnail_url == "https://images.example.invalid/cover.png" && manga.genre == "Action, Comedy")
            check(manga.description == "Description" && manga.status == SManga.ON_HIATUS && manga.initialized)
            check(manga.update_strategy == UpdateStrategy.ONLY_FETCH_ONCE && manga.memo == this.manga().memo)
            check(chapters.isEmpty())
            called = "update:$fetchDetails:$fetchChapters"
            return SMangaUpdate(manga, if (fetchChapters) listOf(SChapter.create().apply {
                url = "/chapter/one"; name = "Chapter العربية"; chapter_number = 2.5f; date_upload = 1_700_000_000_123L
                scanlator = "Group"; memo = buildJsonObject { put("image-key", "secret,token") }
            }) else emptyList())
        }
        override suspend fun getPageList(chapter: SChapter): List<Page> {
            check(chapter.url == "/chapter/one" && chapter.name == "Chapter العربية" && chapter.chapter_number == 2.5f)
            check(chapter.date_upload == 1_700_000_000_123L && chapter.scanlator == "Group")
            check(chapter.memo["image-key"] == JsonPrimitive("secret,token"))
            return listOf(Page(9, "opaque,token,1", "/first.png"), Page(2, "opaque,token,2", "/second.png"), Page(9, "opaque,token,3", "/third.png"))
        }
        override fun imageRequest(page: Page): Request {
            check(page.url.startsWith("opaque,token,"))
            return Request.Builder().url("https://images.example.invalid" + page.imageUrl).header("X-Authored", "token").build()
        }
        override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
        override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
    }

    @JvmStatic
    fun main(args: Array<String>) = runBlocking {
        val checks = linkedMapOf<String, Boolean>()
        suspend fun case(name: String, body: suspend () -> Unit) {
            System.err.println("START $name")
            withTimeout(15000) { body() }
            checks[name] = true; System.err.println("PASS $name")
        }
        HostServices.configure(Application(Path.of(args.single()), "app.mangashelf.wirecheck"), "test", 9, "MangaShelf-Test/9", "26.2")
        val registry = SourceRegistry()
        val source = Fixture()
        var released = false
        registry.register("authored.wire", source, listOf(SourceRegistry.ExpectedSource(73, "en")), AutoCloseable { released = true })
        val commands = SourceCommands(registry)
        fun request(vararg fields: Pair<String, JsonPrimitive>): JsonObject = buildJsonObject {
            put("sourceId", "73"); fields.forEach { (key, value) -> put(key, value) }
        }
        suspend fun failure(code: String, action: String, request: JsonObject) {
            try { commands.execute(action, request); error("Accepted $code") }
            catch (error: SourceCommands.CommandException) { check(error.code == code) { "${error.code} != $code" } }
        }
        var manga = JsonObject(emptyMap()); var chapter = JsonObject(emptyMap())
        try {
            case("catalogue_latest_search_and_source_pagination_have_distinct_wire_commands") {
                val result = Json.parseToJsonElement(commands.execute("popular", request("page" to JsonPrimitive(4)))).jsonObject
                check(result["hasNextPage"] == JsonPrimitive(true) && source.called == "popular:4")
                manga = result.getValue("mangas").jsonArray.single().jsonObject
                check(manga.getValue("title").jsonPrimitive.content == "العربية 📚")
                commands.execute("latest", request("page" to JsonPrimitive(3))); check(source.called == "latest:3")
                commands.execute("search", request("page" to JsonPrimitive(2), "query" to JsonPrimitive("العربية 📚")))
                check(source.called == "search:2:العربية 📚")
            }
            case("manga_metadata_memo_flags_and_update_strategy_survive_the_wire") {
                val input = request("url" to manga.getValue("url").jsonPrimitive, "sourceMetadataJSON" to manga.getValue("sourceMetadataJSON").jsonPrimitive)
                val details = Json.parseToJsonElement(commands.execute("details", input)).jsonObject
                check(source.called == "update:true:false" && details["status"] == JsonPrimitive("hiatus"))
                check(details.getValue("genre").jsonArray == JsonArray(listOf(JsonPrimitive("Action"), JsonPrimitive("Comedy"))))
                val updated = Json.parseToJsonElement(commands.execute("update", input)).jsonObject
                check(source.called == "update:true:true")
                chapter = updated.getValue("chapters").jsonArray.single().jsonObject
                val chapters = Json.parseToJsonElement(commands.execute("chapters", input)).jsonArray
                check(source.called == "update:false:true" && chapters.single() == chapter)
            }
            case("chapter_dates_convert_to_seconds_without_losing_milliseconds_or_memo") {
                check(chapter.getValue("dateUpload").jsonPrimitive.long == 1_700_000_000L)
                val metadata = Json.parseToJsonElement(chapter.getValue("sourceMetadataJSON").jsonPrimitive.content).jsonObject
                check(metadata.getValue("fields").jsonObject.getValue("date_upload").jsonPrimitive.long == 1_700_000_000_123L)
            }
            case("pages_keep_returned_order_dense_indices_raw_fields_and_source_image_resolution") {
                val input = request("url" to chapter.getValue("url").jsonPrimitive, "sourceMetadataJSON" to chapter.getValue("sourceMetadataJSON").jsonPrimitive)
                val pages = Json.parseToJsonElement(commands.execute("pages", input)).jsonArray.map { it.jsonObject }
                check(pages.map { it.getValue("index").jsonPrimitive.int } == listOf(0, 1, 2))
                check(pages.map { it.getValue("sourceIndex").jsonPrimitive.int } == listOf(9, 2, 9))
                check(pages.map { it.getValue("imageURL").jsonPrimitive.content } == listOf("first", "second", "third").map { "https://images.example.invalid/$it.png" })
                val metadata = Json.parseToJsonElement(pages.first().getValue("sourceMetadataJSON").jsonPrimitive.content).jsonObject
                val fields = metadata.getValue("fields").jsonObject
                check(fields["url"] == JsonPrimitive("opaque,token,1") && fields["imageUrl"] == JsonPrimitive("/first.png"))
            }
            case("invalid_ids_pages_metadata_ownership_and_typed_fields_are_rejected") {
                failure("invalid_source_id", "popular", JsonObject(mapOf("sourceId" to JsonPrimitive("073"))))
                failure("invalid_page", "popular", request("page" to JsonPrimitive(0)))
                failure("invalid_page", "popular", request("page" to JsonPrimitive("1")))
                val raw = manga.getValue("sourceMetadataJSON").jsonPrimitive.content
                failure("metadata_mismatch", "details", request("url" to JsonPrimitive("/other"), "sourceMetadataJSON" to JsonPrimitive(raw)))
                failure("metadata_mismatch", "details", request("url" to JsonPrimitive("/title/one"), "sourceMetadataJSON" to JsonPrimitive(raw.replace("\"sourceId\":\"73\"", "\"sourceId\":\"74\""))))
                failure("invalid_request", "details", request("url" to JsonPrimitive("/title/one"), "sourceMetadataJSON" to JsonPrimitive(raw.replace("\"initialized\":true", "\"initialized\":\"true\""))))
            }
            case("source_output_limits_reject_counts_and_multibyte_strings") {
                source.mode = "count"; failure("response_limit", "popular", request("page" to JsonPrimitive(1)))
                source.mode = "oversized"; failure("response_limit", "popular", request("page" to JsonPrimitive(1)))
                source.mode = "normal"
            }
            case("removal_cancels_suspended_wire_work_and_waits_for_source_cleanup") {
                source.mode = "cancel"
                coroutineScope {
                    val task = async { commands.execute("popular", request("page" to JsonPrimitive(1))) }
                    source.entered.await()
                    registry.remove("authored.wire").await()
                    try { task.await(); error("Removed source returned data") } catch (_: CancellationException) { }
                    check(source.cleaned.isCompleted && released)
                }
            }
        } finally { registry.close().forEach { it.await() }; HostServices.close() }
        println(buildJsonObject {
            put("passed", true); put("checks", buildJsonObject { checks.forEach { (name, passed) -> put(name, passed) } })
            put("scope", "Authored source models and JSON command boundary on host JVM; no JNI, Swift or iOS execution")
        })
    }
}
