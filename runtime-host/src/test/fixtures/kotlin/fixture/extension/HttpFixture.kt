package fixture.extension

import android.app.Application
import android.content.Context
import eu.kanade.tachiyomi.network.NetworkHelper
import eu.kanade.tachiyomi.network.GET
import eu.kanade.tachiyomi.network.awaitSuccess
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.online.HttpSource
import okhttp3.Headers
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

/** Authored executable fixture, never a published extension or production data. */
class HttpFixture : HttpSource() {
    override val id = 987L
    override val name = "Authored signed HTTP source"
    override val lang = "en"
    override val supportsLatest = true
    override val baseUrl: String get() = checkNotNull(System.getProperty("msl.fixture.http_url"))
    private val application: Application = Injekt.get()
    init {
        check(Injekt.get<NetworkHelper>() === network)
        check(Injekt.get<Context>() === application && application.applicationContext === application)
        val preferences = application.getSharedPreferences("source_$id", Context.MODE_PRIVATE)
        check(preferences.edit().putInt("starts", preferences.getInt("starts", 0) + 1).commit())
        System.setProperty("msl.fixture.injected_app_package", application.packageName)
        System.getProperties()["msl.fixture.loader"] = javaClass.classLoader
    }

    private fun resource(): String {
        check(Thread.currentThread().contextClassLoader === javaClass.classLoader)
        return checkNotNull(Thread.currentThread().contextClassLoader.getResourceAsStream("assets/العربية 📚 #%.txt"))
            .use { it.readBytes().toString(Charsets.UTF_8) }
    }

    override val client by lazy {
        super.client.newBuilder().addInterceptor { chain ->
            check(Thread.currentThread().contextClassLoader === javaClass.classLoader)
            try { chain.proceed(chain.request()) }
            finally {
                if (chain.request().url.encodedPath == "/slow") {
                    System.setProperty("msl.fixture.http_cleanup_entered", "true")
                    val deadline = System.nanoTime() + 8_000_000_000L
                    while (System.getProperty("msl.fixture.http_release") != "true") {
                        check(System.nanoTime() < deadline) { "Authored HTTP cleanup gate timed out" }
                        Thread.sleep(5)
                    }
                    check(resource() == "verified resource العربية 📚\n")
                    System.setProperty("msl.fixture.http_cleanup_done", "true")
                }
            }
        }.build()
    }
    override fun headersBuilder(): Headers.Builder = super.headersBuilder().add("X-Fixture", resource().take(8))
    override suspend fun getPopularManga(page: Int): MangasPage {
        val endpoint = if (page == 99) "slow" else "utf8"
        return client.newCall(GET("$baseUrl/$endpoint", headers)).awaitSuccess().use { response ->
            MangasPage(listOf(SManga.create().apply { title = response.body.string(); url = "/owned/$page" }), false)
        }
    }
    override suspend fun getLatestUpdates(page: Int) = getPopularManga(page)
    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList) = getPopularManga(page)
    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
        SMangaUpdate(manga, chapters)
    override suspend fun getPageList(chapter: SChapter) = listOf(Page(0, chapter.url, "$baseUrl/image"))
    override fun getMangaUrl(manga: SManga) = baseUrl + manga.url
    override fun getChapterUrl(chapter: SChapter) = baseUrl + chapter.url
}
