package eu.kanade.tachiyomi.source.model

import kotlinx.serialization.json.JsonObject

/** Mutable extension-facing title metadata with the public Source 1.6 ABI. */
@Suppress("PropertyName")
interface SManga {
    var url: String
    var title: String
    var thumbnail_url: String?
    var artist: String?
    var author: String?
    var status: Int
    var description: String?
    var genre: String?
    var update_strategy: UpdateStrategy
    var memo: JsonObject
    var initialized: Boolean

    companion object {
        const val UNKNOWN = 0
        const val ONGOING = 1
        const val COMPLETED = 2
        const val LICENSED = 3
        const val PUBLISHING_FINISHED = 4
        const val CANCELLED = 5
        const val ON_HIATUS = 6

        fun create(): SManga = SMangaImpl()
    }
}
