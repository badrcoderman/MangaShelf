package eu.kanade.tachiyomi.source.online

import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import java.net.URI
import java.nio.ByteBuffer
import java.security.MessageDigest
import java.util.Locale
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import mangashelf.host.HostServices
import okhttp3.Headers
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.Request

/** Functional modern HTTP source base; concrete sources implement their suspended data methods. */
abstract class HttpSource : CatalogueSource {
    protected val network = HostServices.current.network
    abstract val baseUrl: String
    open fun getHomeUrl(): String = baseUrl
    open val versionId: Int = 1
    override val id: Long by lazy {
        val key = "${name.lowercase(Locale.ROOT)}/$lang/$versionId"
        ByteBuffer.wrap(MessageDigest.getInstance("MD5").digest(key.toByteArray(Charsets.UTF_8))).long and Long.MAX_VALUE
    }

    // The pinned KeiSource ABI replaces this field during construction. Keep it
    // writable: mutating an instance final field is restricted on newer JVMs.
    @Suppress("PropertyName")
    private var `headers$delegate`: Lazy<Headers> = lazy { headersBuilder().build() }
    val headers: Headers get() = `headers$delegate`.value
    open val client: OkHttpClient by lazy { network.client }
    protected open fun headersBuilder(): Headers.Builder = Headers.Builder().set("User-Agent", HostServices.userAgent)
    override fun toString(): String = name
    override fun getFilterList(): FilterList = FilterList()
    override val supportsRelatedMangas: Boolean get() = false
    override val disableRelatedMangas: Boolean get() = false
    override val disableRelatedMangasBySearch: Boolean get() = false
    override suspend fun fetchRelatedMangaList(manga: SManga): List<SManga> =
        super<CatalogueSource>.fetchRelatedMangaList(manga)

    // Page.imageUrl may be relative and Page.url may carry source-owned refresh
    // metadata. Let the source construct its request, including token refresh.
    // Some imageRequest overrides perform synchronous HTTP, so keep them off
    // the caller's dispatcher while the enclosing source lease remains active.
    open suspend fun getImageUrl(page: Page): String = withContext(Dispatchers.IO) {
        imageRequest(page).url.toString()
    }

    protected open fun imageRequest(page: Page): Request = Request.Builder()
        .url(page.imageUrl ?: throw UnsupportedOperationException("This source must implement getImageUrl for unresolved image pages"))
        .headers(headers).get().build()

    /** Keep source image headers, cookies, interceptors and token refresh intact. */
    internal fun imageCall(page: Page): Call = client.newCall(imageRequest(page))

    fun SChapter.setUrlWithoutDomain(url: String) { this.url = withoutDomain(url) }
    fun SManga.setUrlWithoutDomain(url: String) { this.url = withoutDomain(url) }
    private fun withoutDomain(url: String): String {
        val uri = URI(url)
        require(!uri.isOpaque) { "Expected a hierarchical source URL" }
        return buildString {
            append(uri.rawPath ?: "")
            uri.rawQuery?.let { append('?'); append(it) }
            uri.rawFragment?.let { append('#'); append(it) }
        }
    }
    abstract fun getMangaUrl(manga: SManga): String
    abstract fun getChapterUrl(chapter: SChapter): String
}
