package mangashelf.host

import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** End-to-end authored filter tree -> wire -> fresh source tree -> real search callback. */
suspend fun checkSourceFilters(registry: SourceRegistry): Map<String, Boolean> {
    class Fixture : HttpSource() {
        override val id = 91L
        override val name = "Authored filter source"
        override val lang = "en"
        override val supportsLatest = true
        override val baseUrl = "https://filters.example.invalid"
        var revision = "Genre"
        var created = 0
        var searches = 0
        override fun getFilterList(): FilterList {
            created++
            return FilterList(Filter.Header("Header العربية"), Filter.Separator(),
                object : Filter.CheckBox("Completed") {}, object : Filter.TriState("Available") {},
                object : Filter.Text("Author", "default") {},
                object : Filter.Select<String>(revision, arrayOf("All", "Action", "Drama"), 1) {},
                object : Filter.Sort("Sort", arrayOf("Title", "Date")) {},
                object : Filter.Group<Filter<*>>("Group", listOf(object : Filter.Group<Filter<*>>("Nested", listOf(object : Filter.CheckBox("Inside", true) {})) {})) {})
        }
        override suspend fun getPopularManga(page: Int) = MangasPage(emptyList(), false)
        override suspend fun getLatestUpdates(page: Int) = MangasPage(emptyList(), false)
        override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
        override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
        override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) = SMangaUpdate(manga, emptyList())
        override suspend fun getPageList(chapter: SChapter): List<Page> = emptyList()
        override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
            searches++
            val nested = (((filters[7] as Filter.Group<*>).state[0] as Filter.Group<*>).state[0] as Filter.CheckBox).state
            val state = listOf((filters[2] as Filter.CheckBox).state, (filters[3] as Filter.TriState).state,
                (filters[4] as Filter.Text).state, (filters[5] as Filter.Select<*>).state,
                (filters[6] as Filter.Sort).state, nested).joinToString("|")
            return MangasPage(listOf(SManga.create().apply { url = "/$page"; title = "$query:$state" }), false)
        }
    }
    val checks = linkedMapOf<String, Boolean>()
    val source = Fixture()
    var released = false
    registry.register("authored.filters", source, listOf(SourceRegistry.ExpectedSource(91, "en")), AutoCloseable { released = true })
    val commands = SourceCommands(registry)
    fun request(extra: Map<String, JsonElement> = emptyMap()) = JsonObject(mapOf("sourceId" to JsonPrimitive("91"), "query" to JsonPrimitive("q"), "page" to JsonPrimitive(1)) + extra)
    suspend fun screen() = Json.parseToJsonElement(commands.execute("filters", request())).jsonObject
    fun states(rows: JsonArray): List<JsonObject> = rows.flatMap {
        val row = it.jsonObject
        if (row["state"] != null) listOf(buildJsonObject { put("path", row.getValue("path")); put("value", row.getValue("state")) })
        else row["children"]?.let { child -> states(child.jsonArray) } ?: emptyList()
    }
    val screen = screen()
    val defaults = states(screen.getValue("rows").jsonArray)
    fun selected(change: Map<String, JsonElement> = emptyMap(), hash: JsonElement = screen.getValue("schemaHash")) = buildJsonObject {
        put("schemaHash", hash)
        put("states", JsonArray(defaults.map { row ->
            val path = row.getValue("path").jsonPrimitive.content
            JsonObject(row + (change[path]?.let { mapOf("value" to it) } ?: emptyMap()))
        }))
    }
    suspend fun search(selection: JsonObject? = null): String {
        val reply = Json.parseToJsonElement(commands.execute("search", request(selection?.let { mapOf("filters" to it) } ?: emptyMap()))).jsonObject
        return reply.getValue("mangas").jsonArray.single().jsonObject.getValue("title").jsonPrimitive.content
    }
    suspend fun rejects(code: String, selection: JsonElement) {
        val before = source.searches
        try { commands.execute("search", request(mapOf("filters" to selection))); error("Invalid filters reached search") }
        catch (failure: SourceCommands.CommandException) { check(failure.code == code) { "${failure.code} != $code" } }
        check(source.searches == before)
    }
    try {
        check(defaults.size == 6 && defaults.last()["path"] == JsonPrimitive("7.0.0"))
        check(screen.getValue("rows").jsonArray[0].jsonObject["kind"] == JsonPrimitive("header"))
        check(screen.getValue("rows").jsonArray[1].jsonObject["kind"] == JsonPrimitive("separator"))
        check(search() == "q:false|0|default|1|null|true")
        checks["source_filters_cover_all_types_nested_paths_and_search_receives_defaults"] = true
        val values = mapOf("2" to buildJsonObject { put("kind", "toggle"); put("checked", true) },
            "3" to buildJsonObject { put("kind", "index"); put("index", 2) },
            "4" to buildJsonObject { put("kind", "text"); put("text", "مؤلف 📚") },
            "5" to buildJsonObject { put("kind", "index"); put("index", 2) },
            "6" to buildJsonObject { put("kind", "sort"); put("index", 1); put("ascending", false) },
            "7.0.0" to buildJsonObject { put("kind", "toggle"); put("checked", false) })
        check(search(selected(values)) == "q:true|2|مؤلف 📚|2|Selection(index=1, ascending=false)|false")
        check(search() == "q:false|0|default|1|null|true" && source.created == 4)
        checks["wire_overrides_reach_real_search_and_do_not_mutate_later_default_trees"] = true
        check(screen() == screen)
        checks["schema_and_defaults_are_repeatable_across_fresh_source_leases"] = true
        source.revision = "Changed"
        rejects("source_filters_changed", selected(values))
        source.revision = "Genre"
        checks["changed_source_shape_fails_before_search_instead_of_applying_wrong_options"] = true
        rejects("invalid_source_filters", selected(mapOf("3" to buildJsonObject { put("kind", "index"); put("index", 3) })))
        rejects("invalid_source_filters", selected(mapOf("5" to buildJsonObject { put("kind", "index"); put("index", -1) })))
        rejects("invalid_source_filters", selected(mapOf("6" to buildJsonObject { put("kind", "sort"); put("index", 2); put("ascending", true) })))
        rejects("invalid_source_filters", selected(mapOf("2" to buildJsonObject { put("kind", "toggle"); put("checked", "true") })))
        rejects("invalid_source_filters", selected(mapOf("3" to buildJsonObject { put("kind", "index"); put("index", "1") })))
        rejects("invalid_source_filters", selected(mapOf("2" to buildJsonObject { put("kind", "text"); put("text", "wrong") })))
        checks["tri_state_choice_sort_and_primitive_type_ranges_are_enforced"] = true
        val duplicate = JsonObject(selected() + ("states" to JsonArray(defaults.dropLast(1) + defaults.first())))
        rejects("invalid_source_filters", duplicate)
        rejects("invalid_source_filters", JsonObject(selected() + ("states" to JsonArray(defaults.dropLast(1)))))
        val unknown = defaults.toMutableList().also { it[0] = JsonObject(it[0] + ("path" to JsonPrimitive("99"))) }
        rejects("invalid_source_filters", JsonObject(selected() + ("states" to JsonArray(unknown))))
        rejects("invalid_source_filters", JsonNull)
        checks["duplicate_unknown_missing_paths_and_wrong_container_fail_before_search"] = true
        val nullSort = buildJsonObject { put("kind", "sort"); put("index", JsonNull); put("ascending", false) }
        check(search(selected(mapOf("6" to nullSort))) == "q:false|0|default|1|null|true")
        checks["sort_can_restore_no_explicit_selection"] = true
        rejects("invalid_request", selected(mapOf("4" to buildJsonObject { put("kind", "text"); put("text", "📚".repeat(5000)) })))
        rejects("invalid_source_filters", selected(mapOf("4" to buildJsonObject { put("kind", "text"); put("text", "\uD800") })))
        checks["filter_text_enforces_utf8_bytes_and_valid_unicode"] = true
        fun bounded(code: String, list: FilterList) {
            try { SourceFilterCodec(list); error("Unbounded filter tree accepted") }
            catch (failure: SourceCommands.CommandException) { check(failure.code == code) }
        }
        bounded("source_filter_limit", FilterList(List(513) { Filter.Header("h") }))
        bounded("source_filter_limit", FilterList(object : Filter.Select<String>("many", Array(2049) { "a" }) {}))
        bounded("invalid_source_filter_default", FilterList(object : Filter.Select<String>("bad", arrayOf("a"), 3) {}))
        bounded("source_filter_limit", FilterList(Filter.Header("📚".repeat(5000))))
        fun nested(depth: Int): Filter<*> = if (depth == 0) Filter.Header("end") else object : Filter.Group<Filter<*>>("g", listOf(nested(depth - 1))) {}
        bounded("source_filter_limit", FilterList(nested(10)))
        checks["source_supplied_tree_defaults_options_utf8_depth_and_count_are_bounded"] = true
    } finally { registry.remove("authored.filters").await() }
    check(released)
    checks["filter_requests_release_source_lease_before_package_removal"] = true
    return checks
}
