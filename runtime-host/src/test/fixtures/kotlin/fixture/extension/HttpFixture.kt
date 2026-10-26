package fixture.extension

import android.app.Application
import android.content.Context
import android.text.Editable
import android.text.TextWatcher
import android.widget.Button
import androidx.preference.EditTextPreference
import androidx.preference.ListPreference
import androidx.preference.PreferenceScreen
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
import eu.kanade.tachiyomi.source.ConfigurableSource
import okhttp3.Headers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.withTimeout
import uy.kohesive.injekt.Injekt
import uy.kohesive.injekt.api.get

/** Authored executable fixture, never a published extension or production data. */
class HttpFixture : HttpSource(), ConfigurableSource {
    override val id = 987L
    override val name = "Authored signed HTTP source"
    override val lang = "en"
    override val supportsLatest = true
    override val baseUrl: String get() = checkNotNull(System.getProperty("msl.fixture.http_url"))
    private val application: Application = Injekt.get()
    private val preferences by lazy { application.getSharedPreferences("source_$id", Context.MODE_PRIVATE) }
    init {
        check(Injekt.get<NetworkHelper>() === network)
        check(Injekt.get<Context>() === application && application.applicationContext === application)
        check(preferences.edit().putInt("starts", preferences.getInt("starts", 0) + 1).commit())
        System.setProperty("msl.fixture.injected_app_package", application.packageName)
        System.getProperties()["msl.fixture.loader"] = javaClass.classLoader
    }

    private fun resource(): String {
        check(Thread.currentThread().contextClassLoader === javaClass.classLoader)
        return checkNotNull(Thread.currentThread().contextClassLoader.getResourceAsStream("assets/العربية 📚 #%.txt"))
            .use { it.readBytes().toString(Charsets.UTF_8) }
    }

    override fun setupPreferenceScreen(screen: PreferenceScreen) {
        check(resource() == "verified resource العربية 📚\n")
        screen.addPreference(ListPreference(screen.context).apply {
            key = "quality"; title = "Quality"; summary = "%s"
            entries = arrayOf("Full", "Small"); entryValues = arrayOf("full", "small"); setDefaultValue("full")
            setOnPreferenceChangeListener { _, value ->
                resource(); preferences.edit().putString("quality", value as String).commit()
            }
        })
        screen.addPreference(object : EditTextPreference(screen.context) {
            init {
                key = "caption"; title = "Result prefix"; setDefaultValue("")
                setOnBindEditTextListener { editor ->
                    resource()
                    editor.addTextChangedListener(object : TextWatcher {
                        override fun beforeTextChanged(text: CharSequence, start: Int, count: Int, after: Int) { }
                        override fun onTextChanged(text: CharSequence, start: Int, before: Int, count: Int) { }
                        override fun afterTextChanged(text: Editable) {
                            resource()
                            editor.error = if ('\n' in text) "One line only" else null
                            editor.rootView.findViewById<Button>(android.R.id.button1)?.isEnabled = editor.error == null
                        }
                    })
                }
                setOnPreferenceChangeListener { _, value ->
                    resource(); System.setProperty("msl.fixture.settings_changed", "true")
                    preferences.edit().putString("caption", value as String).commit()
                }
            }
            override fun onDetached() {
                super.onDetached(); resource()
                if (System.getProperty("msl.fixture.settings_hold") == "true") {
                    System.setProperty("msl.fixture.settings_cleanup_entered", "true")
                    val deadline = System.nanoTime() + 8_000_000_000L
                    while (System.getProperty("msl.fixture.settings_release") != "true") {
                        check(System.nanoTime() < deadline) { "Authored settings cleanup gate timed out" }
                        Thread.sleep(5)
                    }
                }
                resource(); System.setProperty("msl.fixture.settings_cleanup_done", "true")
            }
        })
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
        if (page == 88) withTimeout(1) { awaitCancellation() }
        if (page == 87) throw eu.kanade.tachiyomi.network.HttpException(429, 45.0)
        if (page == 86) throw eu.kanade.tachiyomi.network.BrowserVerificationRequiredException()
        if (page == 85) throw javax.net.ssl.SSLException("https://private.invalid/token=must-not-leak")
        val endpoint = if (page == 99) "slow" else "utf8"
        return client.newCall(GET("$baseUrl/$endpoint", headers)).awaitSuccess().use { response ->
            MangasPage(listOf(SManga.create().apply { title = preferences.getString("caption", "") + response.body.string(); url = "/owned/$page" }), false)
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
