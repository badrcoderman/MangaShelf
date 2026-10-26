package mangashelf.host

import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put

/** Bounded wire handles retain the existing source lease, never extension rows or callbacks. */
class SourcePreferenceCommands(private val registry: SourceRegistry) {
    private data class Entry(val sourceId: Long, val session: SourcePreferenceSession)
    private val lock = Mutex()
    private val sessions = linkedMapOf<String, Entry>()

    suspend fun execute(action: String, request: JsonObject): String {
        if (action == "preferences.open") {
            val token = text(request, "sessionId", 36)
            if (!runCatching { UUID.fromString(token).toString() == token }.getOrDefault(false)) fail("invalid_request")
            val raw = text(request, "sourceId", 32)
            val sourceId = raw.toLongOrNull()?.takeIf { it.toString() == raw } ?: fail("invalid_source_id")
            return lock.withLock {
                sessions.entries.removeAll { it.value.session.isClosed }
                sessions[token]?.let { if (it.sourceId != sourceId) fail("invalid_request") else return@withLock bounded(response(token, it.session.snapshot()).toString()) }
                if (sessions.size >= 4) fail("preference_session_limit")
                val session = SourcePreferenceSession.open(registry, sourceId)
                try {
                    val screen = session.snapshot()
                    sessions[token] = Entry(sourceId, session)
                    bounded(response(token, screen).toString())
                } catch (error: Throwable) {
                    if (sessions[token]?.session === session) sessions.remove(token)
                    session.closeAndJoin(); throw error
                }
            }
        }
        val token = text(request, "sessionId", 36)
        if (!runCatching { UUID.fromString(token).toString() == token }.getOrDefault(false)) fail("invalid_request")
        if (action == "preferences.close") {
            val entry = lock.withLock { sessions.remove(token) }
            entry?.session?.closeAndJoin()
            return buildJsonObject { put("status", "preferences_closed") }.toString()
        }
        val entry = lock.withLock { sessions[token] } ?: fail("source_preferences_closed")
        val row = if (action == "preferences.snapshot") 0 else
            (request["rowId"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull?.takeIf { it in 1..512 }
                ?: fail("invalid_request")
        try {
            return when (action) {
                "preferences.snapshot" -> response(token, entry.session.snapshot())
                "preferences.change" -> {
                    val value = request["value"] as? JsonObject ?: fail("invalid_preference_value")
                    val parsed = when (text(value, "kind", 16)) {
                        "toggle" -> SourcePreferenceSession.Value.Toggle((value["checked"] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: fail("invalid_preference_value"))
                        "text" -> SourcePreferenceSession.Value.Text(text(value, "text", 900_000, true))
                        "multiple" -> {
                            val values = value["values"] as? JsonArray ?: fail("invalid_preference_value")
                            if (values.size > 4096) fail("preference_input_limit")
                            SourcePreferenceSession.Value.Multiple(values.map {
                                (it as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("invalid_preference_value")
                            }.toSet())
                        }
                        else -> fail("invalid_preference_value")
                    }
                    val change = entry.session.change(row, parsed)
                    response(token, change.screen, change.accepted)
                }
                "preferences.validate" -> {
                    val validation = entry.session.validateText(row, text(request, "text", 900_000, true))
                    buildJsonObject {
                        put("sessionId", token); put("screen", screen(validation.screen)); put("allowed", validation.allowed)
                        put("error", nullable(validation.error)); put("text", nullable(validation.text))
                    }
                }
                "preferences.click" -> {
                    val change = entry.session.click(row)
                    response(token, change.screen, change.accepted)
                }
                else -> fail("unknown_action")
            }.toString().let(::bounded)
        } finally {
            if (entry.session.isClosed) lock.withLock { if (sessions[token] === entry) sessions.remove(token) }
        }
    }

    suspend fun closeSources(ids: Set<Long>) {
        val released = lock.withLock {
            val found = sessions.filterValues { it.sourceId in ids }
            found.keys.forEach(sessions::remove)
            found.values.toList()
        }
        released.forEach { it.session.closeAndJoin() }
    }
    suspend fun closeAll() {
        val released = lock.withLock { sessions.values.toList().also { sessions.clear() } }
        released.forEach { it.session.closeAndJoin() }
    }
    private fun response(token: String, snapshot: SourcePreferenceSession.Snapshot, accepted: Boolean? = null) = buildJsonObject {
        put("sessionId", token); put("screen", screen(snapshot)); accepted?.let { put("accepted", it) }
    }
    private fun screen(snapshot: SourcePreferenceSession.Snapshot) = buildJsonObject {
        put("sourceId", snapshot.sourceId.toString())
        put("rows", JsonArray(snapshot.rows.map { row -> buildJsonObject {
            put("id", row.id); put("key", nullable(row.key)); put("kind", row.kind.name.lowercase())
            put("title", nullable(row.title)); put("summary", nullable(row.summary))
            put("enabled", row.enabled); put("visible", row.visible)
            put("dialogTitle", nullable(row.dialogTitle)); put("dialogMessage", nullable(row.dialogMessage))
            put("choices", JsonArray(row.choices.map { choice -> buildJsonObject { put("label", choice.label); put("value", choice.value) } }))
            put("value", when (val value = row.value) {
                is SourcePreferenceSession.Value.Toggle -> buildJsonObject { put("kind", "toggle"); put("checked", value.checked) }
                is SourcePreferenceSession.Value.Text -> buildJsonObject { put("kind", "text"); put("text", value.text) }
                is SourcePreferenceSession.Value.Multiple -> buildJsonObject { put("kind", "multiple"); put("values", JsonArray(value.values.sorted().map(::JsonPrimitive))) }
                null -> JsonNull
            })
        } }))
    }
    private fun nullable(value: String?): JsonElement = value?.let(::JsonPrimitive) ?: JsonNull
    private fun bounded(value: String): String {
        if (value.toByteArray(Charsets.UTF_8).size > 16 * 1024 * 1024) fail("response_limit")
        return value
    }
    private fun text(request: JsonObject, key: String, max: Int, empty: Boolean = false) = SourceCommands.string(request, key, max, empty)
    private fun fail(code: String): Nothing = throw SourceCommands.CommandException(code)
}
