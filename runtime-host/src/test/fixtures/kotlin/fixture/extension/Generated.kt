package fixture.extension

import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext

private fun constructed(owner: Any) {
    check(Thread.currentThread().contextClassLoader === owner.javaClass.classLoader)
    val properties = System.getProperties()
    synchronized(properties) {
        val count = properties.getProperty("msl.fixture.constructs", "0").toInt()
        properties.setProperty("msl.fixture.constructs", (count + 1).toString())
        properties["msl.fixture.loader"] = owner.javaClass.classLoader
    }
}

class Generated : SourceFactory {
    init { constructed(this) }
    override fun createSources(): List<Source> {
        check(Thread.currentThread().contextClassLoader === javaClass.classLoader)
        return listOf(ExampleSource(-37, "ar"), ExampleSource(42, "en"))
    }
}

open class ExampleSource(override val id: Long, override val lang: String) : CatalogueSource {
    override val name = "Signed authored source $id"
    override val supportsLatest = true
    private fun resource(): String = checkNotNull(Thread.currentThread().contextClassLoader.getResourceAsStream("assets/العربية 📚 #%.txt"))
        .use { it.readBytes().toString(Charsets.UTF_8) }

    override suspend fun getPopularManga(page: Int): MangasPage {
        check(Thread.currentThread().contextClassLoader === javaClass.classLoader)
        delay(1)
        check(Thread.currentThread().contextClassLoader === javaClass.classLoader)
        if (page == 99) {
            try {
                System.setProperty("msl.fixture.blocked", "true")
                awaitCancellation()
            } finally {
                withContext(NonCancellable) {
                    while (System.getProperty("msl.fixture.release") != "true") delay(5)
                    check(resource() == "verified resource العربية 📚\n")
                    System.setProperty("msl.fixture.cleaned", "true")
                }
            }
        }
        return MangasPage(listOf(SManga.create().apply {
            title = "signed/${Versioned.value()}/$id/$page"
            url = "/authored/$id/$page"
            description = resource()
        }), page < 2)
    }
    override suspend fun getLatestUpdates(page: Int) = getPopularManga(page)
    override suspend fun getSearchManga(page: Int, query: String, filters: FilterList) = getPopularManga(page)
    override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
        SMangaUpdate(manga, chapters)
    override suspend fun getPageList(chapter: SChapter) = listOf(Page(0, chapter.url, "https://example.invalid/owned.png"))
}

class Single : ExampleSource(-37, "ar") { init { constructed(this) } }
class NotSource {
    companion object { init { System.setProperty("msl.fixture.invalid_initialized", "true") } }
}
class PrivateEntry private constructor() : SourceFactory {
    companion object { init { System.setProperty("msl.fixture.invalid_initialized", "true") } }
    override fun createSources(): List<Source> = emptyList()
}
abstract class AbstractEntry : SourceFactory {
    companion object { init { System.setProperty("msl.fixture.invalid_initialized", "true") } }
}
class ThrowingEntry : SourceFactory {
    init { constructed(this); error("Authored constructor failure") }
    override fun createSources(): List<Source> = emptyList()
}
class BlockingEntry : SourceFactory {
    init {
        constructed(this)
        System.setProperty("msl.fixture.constructor_blocked", "true")
        while (System.getProperty("msl.fixture.constructor_release") != "true") Thread.sleep(5)
    }
    override fun createSources(): List<Source> = listOf(ExampleSource(-37, "ar"), ExampleSource(42, "en"))
}
class Late { fun value() = "late" }
