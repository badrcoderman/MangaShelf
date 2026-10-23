package eu.kanade.tachiyomi.source.model

import android.net.Uri

/**
 * Source-facing page record. The legacy Uri descriptor is retained for binary
 * compatibility; this class neither downloads images nor implements Android I/O.
 */
class Page(
    val index: Int,
    val url: String = "",
    var imageUrl: String? = null,
    var uri: Uri? = null,
)
