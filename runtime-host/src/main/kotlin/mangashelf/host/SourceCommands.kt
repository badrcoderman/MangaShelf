package mangashelf.host

import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.UpdateStrategy
import eu.kanade.tachiyomi.source.online.HttpSource
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.floatOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Converts Source 1.6 models inside a registry lease; only a host-owned JSON string leaves it. */
class SourceCommands(private val registry: SourceRegistry) {
    class CommandException(val code: String) : IllegalArgumentException(code)
    private data class UpdateKey(val source: Long, val url: String)
    private class UpdateGate { val mutex = Mutex(); var users = 0 }
    private val updateLock = Any()
    private val updates = mutableMapOf<UpdateKey, UpdateGate>()
    private val imageTransfers by lazy { ImageTransferStore(HostServices.current.context.cacheDir.toPath().resolve("image-transfers")) }

    // KeiSource rejects overlapping updates for one manga. Keep unrelated
    // titles concurrent and release idle gates, including cancelled waiters.
    private suspend fun <T> updating(source: Long, url: String, block: suspend () -> T): T {
        val key = UpdateKey(source, url)
        val gate = synchronized(updateLock) { updates.getOrPut(key, ::UpdateGate).also { it.users++ } }
        try { return gate.mutex.withLock { block() } }
        finally { synchronized(updateLock) { if (--gate.users == 0) updates.remove(key) } }
    }

    suspend fun execute(action: String, request: JsonObject): String {
        val sourceId = string(request, "sourceId", 32)
        val id = sourceId.toLongOrNull()?.takeIf { it.toString() == sourceId } ?: fail("invalid_source_id")
        val budget = Budget()
        return registry.withSource(id) { source ->
            var transfer: ImageTransferStore.Transfer? = null
            try {
            val result: JsonElement = when (action) {
                "popular", "latest", "search" -> {
                    val page = (request["page"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull
                        ?.takeIf { it in 1..10_000 } ?: fail("invalid_page")
                    val returned = when (action) {
                        "popular" -> source.getPopularManga(page)
                        "latest" -> source.getLatestUpdates(page)
                        else -> source.getSearchManga(page, string(request, "query", 4096, allowEmpty = true), FilterList())
                    }
                    if (returned.mangas.size > 1000) fail("response_limit")
                    val mangas = returned.mangas.map { manga ->
                        currentCoroutineContext().ensureActive()
                        budget.manga(sourceId, manga, details = false)
                    }
                    buildJsonObject { put("mangas", JsonArray(mangas)); put("hasNextPage", returned.hasNextPage) }
                }
                "details", "chapters", "update" -> {
                    val manga = readManga(sourceId, request)
                    val lookupURL = manga.url
                    val originalTitle = try { manga.title } catch (_: UninitializedPropertyAccessException) { null }
                    updating(id, lookupURL) {
                        val update = source.getMangaUpdate(manga, emptyList(), action != "chapters", action != "details")
                        if (update.chapters.size > 30_000) fail("response_limit")
                        when (action) {
                            "details" -> budget.manga(sourceId, update.manga, details = true, lookupURL = lookupURL, originalTitle = originalTitle)
                            "chapters" -> JsonArray(update.chapters.map {
                                currentCoroutineContext().ensureActive(); budget.chapter(sourceId, it)
                            })
                            else -> buildJsonObject {
                                put("details", budget.manga(sourceId, update.manga, details = true, lookupURL = lookupURL, originalTitle = originalTitle))
                                put("chapters", JsonArray(update.chapters.map {
                                    currentCoroutineContext().ensureActive(); budget.chapter(sourceId, it)
                                }))
                            }
                        }
                    }
                }
                "pages" -> {
                    val pages = source.getPageList(readChapter(sourceId, request))
                    if (pages.isEmpty() || pages.size > 4096) fail("response_limit")
                    JsonArray(pages.mapIndexed { position, page ->
                        currentCoroutineContext().ensureActive()
                        val resolved = if (source is HttpSource) source.getImageUrl(page) else page.imageUrl
                        val image = resolved?.toHttpUrlOrNull()?.toString() ?: fail("unresolved_image")
                        val fields = buildJsonObject {
                            put("index", page.index); put("url", budget.text(page.url, 32_768))
                            put("imageUrl", budget.optional(page.imageUrl, 8192))
                        }
                        buildJsonObject {
                            // The source's returned order is authoritative, even for duplicate/sparse indices.
                            put("index", position); put("sourceIndex", page.index)
                            put("url", fields.getValue("url")); put("imageURL", budget.text(image, 8192))
                            put("sourceMetadataJSON", budget.metadata(sourceId, "page", fields))
                        }
                    })
                }
                "image" -> {
                    if (source !is HttpSource) fail("unsupported_image_source")
                    val page = readPage(sourceId, request)
                    if (page.imageUrl == null) page.imageUrl = source.getImageUrl(page)
                    val image = imageTransfers.fetch(source.imageCall(page))
                    transfer = image
                    buildJsonObject {
                        put("fileName", image.path.fileName.toString()); put("bytes", image.bytes); put("sha256", image.sha256)
                    }
                }
                else -> fail("unknown_action")
            }
            currentCoroutineContext().ensureActive()
            val encoded = result.toString()
            if (encoded.toByteArray(Charsets.UTF_8).size > 16 * 1024 * 1024) fail("response_limit")
            currentCoroutineContext().ensureActive()
            transfer = null // Ownership passes to the app; failed encoding/cancellation removes the file below.
            encoded
            } finally { transfer?.let { imageTransfers.discard(it) } }
        }
    }

    private class Budget {
        private var remaining = 8 * 1024 * 1024
        fun text(value: String, maximum: Int): String {
            if (value.length > maximum) fail("response_limit")
            val size = value.toByteArray(Charsets.UTF_8).size
            val encodedSize = size + 2 + value.sumOf { char ->
                when { char.code < 32 -> 5; char == '"' || char == '\\' -> 1; else -> 0 }
            }
            if (size > maximum || encodedSize > remaining) fail("response_limit")
            remaining -= encodedSize
            return value
        }
        fun optional(value: String?, maximum: Int): JsonElement = value?.let { JsonPrimitive(text(it, maximum)) } ?: JsonNull
        fun metadata(sourceId: String, kind: String, fields: JsonObject): String {
            val value = text(buildJsonObject {
                put("version", 1); put("sourceId", sourceId); put("kind", kind); put("fields", fields)
            }.toString(), 256 * 1024)
            boundedObject(value) // Enforce the same nesting bound on both sides of a round trip.
            return value
        }

        fun manga(sourceId: String, manga: SManga, details: Boolean, lookupURL: String? = null, originalTitle: String? = null): JsonObject {
            // Details are a partial metadata update. Team X and other sources
            // legitimately leave url/title uninitialized. Preserve the lookup
            // identity, as the title's existing library record does in Mihon.
            val url = lookupURL ?: manga.url
            val title = (try { manga.title } catch (_: UninitializedPropertyAccessException) { null })
                ?.takeUnless(String::isBlank) ?: originalTitle
            if (url.isEmpty() || title.isNullOrBlank()) fail("invalid_response")
            val fields = buildJsonObject {
                put("url", text(url, 8192)); put("title", text(title, 8192))
                put("thumbnail_url", optional(manga.thumbnail_url, 8192))
                put("author", optional(manga.author, 8192)); put("artist", optional(manga.artist, 8192))
                put("description", optional(manga.description, 256 * 1024)); put("genre", optional(manga.genre, 32_768))
                put("status", manga.status); put("initialized", manga.initialized)
                put("update_strategy", manga.update_strategy.name)
                put("memo", checkedMemo(manga.memo))
            }
            return buildJsonObject {
                put("id", fields.getValue("url")); put("url", fields.getValue("url")); put("title", fields.getValue("title"))
                put("coverURL", fields.getValue("thumbnail_url"))
                if (details) {
                    put("author", fields.getValue("author")); put("artist", fields.getValue("artist"))
                    put("description", fields.getValue("description"))
                    put("genre", JsonArray(manga.genre?.split(',')?.map(String::trim)?.filter(String::isNotEmpty)?.map(::JsonPrimitive) ?: emptyList()))
                    put("status", when (manga.status) {
                        SManga.ONGOING -> "ongoing"
                        SManga.COMPLETED -> "completed"
                        SManga.LICENSED -> "licensed"
                        SManga.PUBLISHING_FINISHED -> "publishing_finished"
                        SManga.CANCELLED -> "cancelled"
                        SManga.ON_HIATUS -> "hiatus"
                        else -> "unknown"
                    })
                }
                put("sourceMetadataJSON", metadata(sourceId, "manga", fields))
            }
        }

        fun chapter(sourceId: String, chapter: SChapter): JsonObject {
            if (chapter.url.isEmpty() || !chapter.chapter_number.isFinite()) fail("invalid_response")
            val fields = buildJsonObject {
                put("url", text(chapter.url, 8192)); put("name", text(chapter.name, 8192))
                put("chapter_number", chapter.chapter_number); put("date_upload", chapter.date_upload)
                put("scanlator", optional(chapter.scanlator, 8192)); put("memo", checkedMemo(chapter.memo))
            }
            return buildJsonObject {
                put("id", fields.getValue("url")); put("url", fields.getValue("url")); put("name", fields.getValue("name"))
                put("chapterNumber", chapter.chapter_number)
                // ReaderCore's dateUpload is epoch seconds. Keep exact milliseconds in metadata.
                put("dateUpload", Math.floorDiv(chapter.date_upload, 1000L)); put("scanlator", fields.getValue("scanlator"))
                put("sourceMetadataJSON", metadata(sourceId, "chapter", fields))
            }
        }
        private fun checkedMemo(memo: JsonObject): JsonObject {
            val encoded = text(memo.toString(), 128 * 1024)
            return boundedObject(encoded)
        }
    }

    private fun fields(sourceId: String, kind: String, request: JsonObject, compareURL: Boolean = true): JsonObject? {
        val raw = request["sourceMetadataJSON"] ?: return null
        if (raw == JsonNull) return null
        val metadata = boundedObject(string(request, "sourceMetadataJSON", 256 * 1024))
        if ((metadata["version"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull != 1 ||
            string(metadata, "sourceId", 32) != sourceId || string(metadata, "kind", 16) != kind
        ) fail("metadata_mismatch")
        val fields = metadata["fields"] as? JsonObject ?: fail("invalid_request")
        if (compareURL && string(fields, "url", 8192) != string(request, "url", 8192)) fail("metadata_mismatch")
        return fields
    }

    private fun readPage(sourceId: String, request: JsonObject): Page {
        val fields = fields(sourceId, "page", request, compareURL = false) ?: fail("invalid_request")
        val index = (fields["index"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull ?: fail("invalid_request")
        return Page(index, string(fields, "url", 32_768, allowEmpty = true), optional(fields, "imageUrl", 8192))
    }

    private fun readManga(sourceId: String, request: JsonObject): SManga {
        val fields = fields(sourceId, "manga", request)
        return SManga.create().apply {
            url = string(request, "url", 8192)
            if (fields != null) {
                title = string(fields, "title", 8192)
                thumbnail_url = optional(fields, "thumbnail_url", 8192)
                author = optional(fields, "author", 8192); artist = optional(fields, "artist", 8192)
                description = optional(fields, "description", 256 * 1024); genre = optional(fields, "genre", 32_768)
                status = (fields["status"] as? JsonPrimitive)?.takeUnless { it.isString }?.intOrNull ?: fail("invalid_request")
                initialized = (fields["initialized"] as? JsonPrimitive)?.takeUnless { it.isString }?.booleanOrNull ?: fail("invalid_request")
                update_strategy = try { UpdateStrategy.valueOf(string(fields, "update_strategy", 32)) }
                    catch (_: IllegalArgumentException) { fail("invalid_request") }
                memo = fields["memo"] as? JsonObject ?: fail("invalid_request")
            }
        }
    }

    private fun readChapter(sourceId: String, request: JsonObject): SChapter {
        val fields = fields(sourceId, "chapter", request)
        return SChapter.create().apply {
            url = string(request, "url", 8192)
            if (fields != null) {
                name = string(fields, "name", 8192, allowEmpty = true)
                chapter_number = (fields["chapter_number"] as? JsonPrimitive)?.takeUnless { it.isString }?.floatOrNull
                    ?.takeIf(Float::isFinite) ?: fail("invalid_request")
                date_upload = (fields["date_upload"] as? JsonPrimitive)?.takeUnless { it.isString }?.longOrNull ?: fail("invalid_request")
                scanlator = optional(fields, "scanlator", 8192)
                memo = fields["memo"] as? JsonObject ?: fail("invalid_request")
            }
        }
    }

    companion object {
        private fun fail(code: String): Nothing = throw CommandException(code)
        internal fun string(value: JsonObject, key: String, maximum: Int, allowEmpty: Boolean = false): String {
            val text = (value[key] as? JsonPrimitive)?.takeIf { it.isString }?.content ?: fail("invalid_request")
            if ((!allowEmpty && text.isEmpty()) || text.length > maximum || text.toByteArray(Charsets.UTF_8).size > maximum) fail("invalid_request")
            return text
        }
        private fun optional(value: JsonObject, key: String, maximum: Int): String? =
            if (value[key] == null || value[key] == JsonNull) null else string(value, key, maximum, allowEmpty = true)

        internal fun boundedObject(text: String): JsonObject {
            if (text.length > 1024 * 1024 || text.toByteArray(Charsets.UTF_8).size > 1024 * 1024) fail("request_limit")
            var depth = 0; var quoted = false; var escaped = false
            for (char in text) {
                if (quoted) {
                    if (escaped) escaped = false else if (char == '\\') escaped = true else if (char == '"') quoted = false
                } else when (char) {
                    '"' -> quoted = true
                    '[', '{' -> if (++depth > 32) fail("request_limit")
                    ']', '}' -> depth--
                }
            }
            return try { Json.parseToJsonElement(text) as? JsonObject ?: fail("invalid_request") }
            catch (error: CommandException) { throw error }
            catch (_: IllegalArgumentException) { fail("invalid_request") }
        }
    }
}
