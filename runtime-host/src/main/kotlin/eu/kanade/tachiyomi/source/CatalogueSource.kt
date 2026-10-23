package eu.kanade.tachiyomi.source

import eu.kanade.tachiyomi.source.model.SManga

/** Source language belongs to the selected source, independently of the UI locale. */
interface CatalogueSource : Source {
    val lang: String
    val supportsRelatedMangas: Boolean get() = false
    val disableRelatedMangasBySearch: Boolean get() = false
    val disableRelatedMangas: Boolean get() = false

    suspend fun fetchRelatedMangaList(manga: SManga): List<SManga> =
        throw UnsupportedOperationException("This source does not support related manga.")
}
