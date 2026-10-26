package mangashelf.host

import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import java.security.MessageDigest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/** A fresh source-owned tree is inspected and changed only within its registry lease. */
class SourceFilterCodec(private val filters: FilterList) {
    private val editable = linkedMapOf<String, Filter<*>>()
    private var characters = 0
    private var count = 0
    private val rows = rows(filters, "", 0)
    private val shape = shape(rows)
    val schemaHash = MessageDigest.getInstance("SHA-256").digest(shape.toString().toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it.toInt() and 255) }

    fun snapshot(sourceId: String): JsonObject = buildJsonObject {
        put("sourceId", sourceId); put("schemaHash", schemaHash); put("rows", rows)
    }

    fun apply(request: JsonObject?): FilterList {
        if (request == null) return filters
        if (SourceCommands.string(request, "schemaHash", 64) != schemaHash) fail("source_filters_changed")
        val states = request["states"] as? JsonArray ?: fail("invalid_source_filters")
        if (states.size != editable.size) fail("invalid_source_filters")
        val seen = hashSetOf<String>()
        // Validate all values before mutating the fresh tree. Source objects never leave this method's lease.
        val changes = states.map { value ->
            val state = value as? JsonObject ?: fail("invalid_source_filters")
            val path = SourceCommands.string(state, "path", 64)
            val filter = editable[path] ?: fail("invalid_source_filters")
            if (!seen.add(path)) fail("invalid_source_filters")
            val raw = state["value"] as? JsonObject ?: fail("invalid_source_filters")
            filter to readValue(filter, raw)
        }
        changes.forEach { (filter, value) -> when (filter) {
            is Filter.CheckBox -> filter.state = value as Boolean
            is Filter.TriState -> filter.state = value as Int
            is Filter.Select<*> -> filter.state = value as Int
            is Filter.Text -> filter.state = value as String
            is Filter.Sort -> filter.state = value as Filter.Sort.Selection?
            else -> fail("invalid_source_filters")
        } }
        return filters
    }
    private fun readValue(filter: Filter<*>, raw: JsonObject): Any? {
        fun kind(expected: String) { if (SourceCommands.string(raw, "kind", 16) != expected) fail("invalid_source_filters") }
        return when (filter) {
            is Filter.CheckBox -> { kind("toggle"); bool(raw, "checked") }
            is Filter.Text -> { kind("text"); text(SourceCommands.string(raw, "text", 16384, true)) }
            is Filter.TriState -> { kind("index"); integer(raw, "index").takeIf { it in 0..2 } ?: fail("invalid_source_filters") }
            is Filter.Select<*> -> { kind("index"); integer(raw, "index").takeIf { it in filter.values.indices } ?: fail("invalid_source_filters") }
            is Filter.Sort -> {
                kind("sort")
                val ascending = bool(raw, "ascending")
                if (raw["index"] == JsonNull) null else Filter.Sort.Selection(integer(raw, "index").takeIf { it in filter.values.indices } ?: fail("invalid_source_filters"), ascending)
            }
            else -> fail("invalid_source_filters")
        }
    }
    private fun rows(items: List<*>, parent: String, depth: Int): JsonArray {
        if (depth > 8 || items.size > 512) fail("source_filter_limit")
        return JsonArray(items.mapIndexed { index, item ->
            if (++count > 512) fail("source_filter_limit")
            val filter = item as? Filter<*> ?: fail("unsupported_source_filter")
            val path = if (parent.isEmpty()) "$index" else "$parent.$index"
            buildJsonObject {
                put("path", path); put("name", text(filter.name))
                when (filter) {
                    is Filter.Header -> put("kind", "header")
                    is Filter.Separator -> put("kind", "separator")
                    is Filter.Group<*> -> { put("kind", "group"); put("children", rows(filter.state, path, depth + 1)) }
                    is Filter.CheckBox -> {
                        editable[path] = filter; put("kind", "checkbox")
                        put("state", buildJsonObject { put("kind", "toggle"); put("checked", filter.state) })
                    }
                    is Filter.TriState -> {
                        if (filter.state !in 0..2) fail("invalid_source_filter_default")
                        editable[path] = filter; put("kind", "tristate")
                        put("state", buildJsonObject { put("kind", "index"); put("index", filter.state) })
                    }
                    is Filter.Text -> {
                        editable[path] = filter; put("kind", "text")
                        put("state", buildJsonObject { put("kind", "text"); put("text", text(filter.state)) })
                    }
                    is Filter.Select<*> -> {
                        if (filter.state !in filter.values.indices) fail("invalid_source_filter_default")
                        editable[path] = filter; put("kind", "select"); put("choices", choices(filter.values))
                        put("state", buildJsonObject { put("kind", "index"); put("index", filter.state) })
                    }
                    is Filter.Sort -> {
                        if (filter.state?.index?.let { it !in filter.values.indices } == true) fail("invalid_source_filter_default")
                        editable[path] = filter; put("kind", "sort"); put("choices", choices(filter.values))
                        put("state", buildJsonObject { put("kind", "sort"); put("index", filter.state?.index?.let(::JsonPrimitive) ?: JsonNull); put("ascending", filter.state?.ascending ?: true) })
                    }
                }
            }
        })
    }
    private fun shape(rows: JsonArray): JsonArray = JsonArray(rows.map { value ->
        val row = value as JsonObject
        JsonObject(row.filterKeys { it != "state" }.mapValues { (key, item) -> if (key == "children") shape(item as JsonArray) else item })
    })
    private fun choices(values: Array<*>): JsonArray {
        if (values.isEmpty() || values.size > 2048) fail("source_filter_limit")
        return JsonArray(values.map { JsonPrimitive(text(it.toString())) })
    }
    private fun text(value: String): String {
        if (value.length > 16384 || value.toByteArray(Charsets.UTF_8).size > 16384) fail("source_filter_limit")
        var index = 0
        while (index < value.length) {
            val c = value[index++]
            if (c.isHighSurrogate()) { if (index >= value.length || !value[index++].isLowSurrogate()) fail("invalid_source_filters") }
            else if (c.isLowSurrogate()) fail("invalid_source_filters")
        }
        characters += value.length
        if (characters > 512 * 1024) fail("source_filter_limit")
        return value
    }
    private fun bool(value: JsonObject, key: String): Boolean = (value[key] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: fail("invalid_source_filters")
    private fun integer(value: JsonObject, key: String): Int = (value[key] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull ?: fail("invalid_source_filters")
    private fun fail(code: String): Nothing = throw SourceCommands.CommandException(code)
}
