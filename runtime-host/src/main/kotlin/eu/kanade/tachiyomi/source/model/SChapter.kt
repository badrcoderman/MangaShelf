package eu.kanade.tachiyomi.source.model

import kotlinx.serialization.json.JsonObject

/** Source timestamps use Unix epoch milliseconds; conversion belongs at the host boundary. */
@Suppress("PropertyName")
interface SChapter {
    var url: String
    var name: String
    var chapter_number: Float
    var scanlator: String?
    var date_upload: Long
    var memo: JsonObject

    companion object {
        fun create(): SChapter = SChapterImpl()
    }
}
