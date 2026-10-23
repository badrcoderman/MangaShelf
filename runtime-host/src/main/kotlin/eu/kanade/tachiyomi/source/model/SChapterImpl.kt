package eu.kanade.tachiyomi.source.model

import kotlinx.serialization.json.JsonObject

/** Unknown chapter numbers remain -1 rather than becoming a numbered chapter. */
@Suppress("PropertyName")
class SChapterImpl : SChapter {
    override lateinit var url: String
    override lateinit var name: String
    override var chapter_number: Float = -1f
    override var scanlator: String? = null
    override var date_upload: Long = 0L
    override var memo: JsonObject = JsonObject(emptyMap())
}
