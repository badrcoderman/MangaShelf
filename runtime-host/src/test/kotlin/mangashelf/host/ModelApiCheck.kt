@file:Suppress("DEPRECATION") // Exercise the public MangasPage compatibility methods.

package mangashelf.host

import android.net.Uri
import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import eu.kanade.tachiyomi.source.model.Filter
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import eu.kanade.tachiyomi.source.model.UpdateStrategy
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.supervisorScope
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.lang.reflect.InvocationTargetException

/** Calls only authored implementations. No extension archive or source loader is involved. */
object ModelApiCheck {
    @JvmStatic
    fun main(args: Array<String>) {
        val checks = linkedMapOf<String, Boolean>()
        var completed = false
        try {
            runBlocking {
                verify(checks, "manga_factories_and_fields") {
                    val first = SManga.create()
                    val second = SManga.create()
                    check(first !== second)
                    check(first.status == SManga.UNKNOWN)
                    check(!first.initialized && first.memo.isEmpty())
                    check(first.update_strategy == UpdateStrategy.ALWAYS_UPDATE)
                    check(first.thumbnail_url == null && first.description == null)
                    first.url = "/عنوان/漫画"
                    first.title = "عنوان 漫画 📚"
                    first.thumbnail_url = "https://covers.invalid/صورة.jpg"
                    first.artist = "Artist"
                    first.author = "Author"
                    first.status = SManga.ON_HIATUS
                    first.description = "Description\nوصف"
                    first.genre = "Action, Slice of Life"
                    first.update_strategy = UpdateStrategy.ONLY_FETCH_ONCE
                    first.initialized = true
                    first.memo = JsonObject(mapOf("source.token" to JsonPrimitive("preserve-📚")))
                    check(first.url == "/عنوان/漫画" && first.title == "عنوان 漫画 📚")
                    check(first.thumbnail_url == "https://covers.invalid/صورة.jpg")
                    check(first.artist == "Artist" && first.author == "Author")
                    check(first.description == "Description\nوصف" && first.genre == "Action, Slice of Life")
                    check(first.status == 6 && first.initialized)
                    check(first.update_strategy == UpdateStrategy.ONLY_FETCH_ONCE)
                    check(first.memo["source.token"] == JsonPrimitive("preserve-📚"))
                    check(second.memo.isEmpty() && !second.initialized)
                }

                verify(checks, "chapter_factories_and_millisecond_timestamp") {
                    val first = SChapter.create()
                    val second = SChapter.create()
                    check(first !== second)
                    check(first.chapter_number == -1f && first.date_upload == 0L)
                    check(first.scanlator == null && first.memo.isEmpty())
                    first.url = "/chapter/فصل-1"
                    first.name = "الفصل 1.5"
                    first.chapter_number = 1.5f
                    first.scanlator = "Group أ"
                    first.date_upload = MILLIS
                    first.memo = JsonObject(mapOf("source.revision" to JsonPrimitive(3)))
                    check(first.url == "/chapter/فصل-1" && first.name == "الفصل 1.5")
                    check(first.chapter_number == 1.5f && first.scanlator == "Group أ")
                    check(first.date_upload == 1_770_000_000_123L)
                    check(first.date_upload % 1000L == 123L)
                    check(first.memo["source.revision"] == JsonPrimitive(3))
                    check(second.memo.isEmpty() && second.date_upload == 0L)
                }

                verify(checks, "pagination_and_compatibility_copies") {
                    val empty = MangasPage(emptyList(), true)
                    check(empty.mangas.isEmpty() && empty.hasNextPage)
                    val title = manga("copy", "Copy")
                    val page = MangasPage(listOf(title), false)
                    val (mangas, hasNext) = page
                    check(mangas.single() === title && !hasNext)
                    val sameValues = page.copy()
                    check(sameValues !== page && sameValues.mangas === page.mangas)
                    check(!sameValues.hasNextPage)
                    val changed = page.copy(mangas = emptyList(), hasNextPage = true)
                    check(changed.mangas.isEmpty() && changed.hasNextPage)
                    check(page.mangas.single() === title && !page.hasNextPage)
                }

                verify(checks, "filter_defaults_and_mutable_states") {
                    val text = object : Filter.Text("Query") {}
                    val checkBox = object : Filter.CheckBox("Completed") {}
                    val select = object : Filter.Select<String>("Order", arrayOf("A", "B")) {}
                    val triState = object : Filter.TriState("Genre") {}
                    val group = object : Filter.Group<Filter<*>>("Group", listOf(text, checkBox)) {}
                    val sort = object : Filter.Sort("Sort", arrayOf("Title", "Date")) {}
                    check(text.state.isEmpty() && !checkBox.state && select.state == 0)
                    check(triState.isIgnored() && !triState.isIncluded() && !triState.isExcluded())
                    text.state = "بحث"
                    checkBox.state = true
                    select.state = 1
                    triState.state = Filter.TriState.STATE_INCLUDE
                    check(triState.isIncluded() && !triState.isIgnored() && !triState.isExcluded())
                    triState.state = Filter.TriState.STATE_EXCLUDE
                    check(triState.isExcluded() && !triState.isIgnored() && !triState.isIncluded())
                    check(text.state == "بحث" && checkBox.state && select.values[select.state] == "B")
                    check(group.state[0] === text && group.state[1] === checkBox)
                    check(sort.state == null)
                    sort.state = Filter.Sort.Selection(1, false)
                    val (index, ascending) = checkNotNull(sort.state)
                    check(index == 1 && !ascending)
                    check(sort.state!!.copy(ascending = true) == Filter.Sort.Selection(1, true))
                    check(Filter.Header("Header").state == 0 && Filter.Separator().name.isEmpty())
                    val list = FilterList(text, checkBox, select)
                    check(FilterList().isEmpty() && list.size == 3 && list[0] === text)
                    check(list.copy().list === list.list)
                    val replacement = list.copy(list = listOf(sort))
                    check(replacement.single() === sort && list.size == 3)
                }

                verify(checks, "readonly_sequenced_collection_compatibility_bridges") {
                    val names = setOf("addFirst", "addLast", "removeFirst", "removeLast")
                    val methods = FilterList::class.java.declaredMethods.filter { it.name in names }
                    check(methods.size == 8)
                    for (name in names) {
                        val overloads = methods.filter { it.name == name }
                        check(overloads.size == 2)
                        if (name.startsWith("add")) {
                            check(overloads.map { it.parameterTypes.single() }.toSet() ==
                                setOf(Filter::class.java, Any::class.java))
                            check(overloads.all { it.returnType == Void.TYPE })
                        } else {
                            check(overloads.all { it.parameterCount == 0 })
                            check(overloads.map { it.returnType }.toSet() ==
                                setOf(Filter::class.java, Any::class.java))
                        }
                    }
                    val filter = object : Filter.Text("Read only", "preserved") {}
                    val backing = mutableListOf<Filter<*>>(filter)
                    for (target in listOf(FilterList(), FilterList(backing))) {
                        val before = target.toList()
                        for (method in methods) {
                            val arguments = if (method.name.startsWith("add")) {
                                arrayOf<Any?>(filter)
                            } else {
                                emptyArray()
                            }
                            val failure = runCatching { method.invoke(target, *arguments) }.exceptionOrNull()
                            check(failure is InvocationTargetException &&
                                failure.cause is UnsupportedOperationException)
                            if (method.parameterTypes.contentEquals(arrayOf(Any::class.java))) {
                                for (invalid in listOf(null, "not a filter")) {
                                    val invalidFailure = runCatching {
                                        method.invoke(target, invalid)
                                    }.exceptionOrNull()
                                    check(invalidFailure is InvocationTargetException &&
                                        invalidFailure.cause is UnsupportedOperationException)
                                }
                            }
                            check(target.toList() == before)
                        }
                    }
                    check(backing.single() === filter && filter.state == "preserved")
                }

                verify(checks, "page_uri_descriptor_and_encoded_value") {
                    val constructor = Page::class.java.getConstructor(
                        Integer.TYPE,
                        String::class.java,
                        String::class.java,
                        Uri::class.java,
                    )
                    val encoded = "content://棚/ملف%20漫画?x=1+2#片"
                    val uri = Uri.parse(encoded)
                    val same = Uri.parse(encoded)
                    check(uri.toString() == encoded && uri == same && uri.hashCode() == same.hashCode())
                    check(uri.compareTo(same) == 0 && Uri.parse("") === Uri.EMPTY)
                    check(Uri.parse("%41") != Uri.parse("A"))
                    check(Uri.parse("a").compareTo(Uri.parse("b")) < 0)
                    val page = constructor.newInstance(7, "/viewer", null, uri)
                    check(page.index == 7 && page.url == "/viewer" && page.imageUrl == null)
                    check(page.uri === uri)
                    page.imageUrl = "https://pages.invalid/1.jpg"
                    page.uri = same
                    check(page.imageUrl == "https://pages.invalid/1.jpg" && page.uri === same)
                    val defaults = Page(0)
                    check(defaults.url.isEmpty() && defaults.imageUrl == null && defaults.uri == null)
                }

                val sources = AuthoredFactory().createSources()
                verify(checks, "authored_factory_61_distinct_ids_and_languages") {
                    check(sources.size == 61 && sources.toSet().size == 61)
                    check(sources.map { it.id }.toSet().size == 61)
                    check(sources.map { (it as CatalogueSource).lang }.toSet().size == 61)
                    check((sources[0] as CatalogueSource).lang == "ar")
                    check((sources[1] as CatalogueSource).lang == "en")
                }

                verify(checks, "61_source_suspend_popular_calls") {
                    val results = sources.map { source -> async { source.getPopularManga(1) } }.awaitAll()
                    check(results.size == 61)
                    results.forEachIndexed { index, page ->
                        val source = sources[index] as AuthoredSource
                        check(page.hasNextPage && source.popularCalls == 1)
                        check(page.mangas.single().url == "/${source.lang}/popular/1")
                        check(page.mangas.single().title == "Popular ${source.lang}")
                    }
                }

                val selected = sources[0] as AuthoredSource
                verify(checks, "source_defaults_and_related_unsupported") {
                    check(selected.getFilterList().isEmpty())
                    check(!selected.supportsRelatedMangas && !selected.disableRelatedMangas)
                    check(!selected.disableRelatedMangasBySearch && selected.supportsLatest)
                    val failure = runCatching { selected.fetchRelatedMangaList(manga("related", "Related")) }
                        .exceptionOrNull()
                    check(failure is UnsupportedOperationException)
                }

                verify(checks, "suspend_latest_and_search_objects") {
                    val latest = selected.getLatestUpdates(4)
                    check(latest.mangas.isEmpty() && !latest.hasNextPage)
                    val filter = object : Filter.Text("Keyword", "الحالة") {}
                    val results = selected.getSearchManga(2, "بحث 漫画", FilterList(filter))
                    check(!results.hasNextPage)
                    check(results.mangas.single().title == "بحث 漫画:الحالة")
                    check(results.mangas.single().url == "/ar/search/2")
                }

                verify(checks, "suspend_update_flags_and_model_values") {
                    val original = manga("/original", "Original")
                    val oldChapters = listOf(chapter("/old", "Old"))
                    val details = selected.getMangaUpdate(original, oldChapters, true, false)
                    check(details.manga !== original && details.manga.title == "Original updated")
                    check(details.manga.initialized && details.chapters === oldChapters)
                    check(original.title == "Original" && !original.initialized)
                    val chapters = selected.getMangaUpdate(original, oldChapters, false, true)
                    check(chapters.manga === original && chapters.chapters !== oldChapters)
                    check(chapters.chapters.single().url == "/ar/chapter/1")
                    check(chapters.chapters.single().date_upload == MILLIS)
                    check(oldChapters.single().url == "/old")
                }

                verify(checks, "suspend_page_list_preserves_returned_order") {
                    val pages = selected.getPageList(chapter("/pages", "Pages"))
                    check(pages.map { it.index } == listOf(9, 0, 3))
                    check(pages.map { it.url } == listOf("first", "second", "third"))
                    check(pages.map { it.imageUrl } == listOf(
                        "https://pages.invalid/first.jpg",
                        "https://pages.invalid/second.jpg",
                        "https://pages.invalid/third.jpg",
                    ))
                }

                verify(checks, "async_source_failure_propagates") {
                    supervisorScope {
                        val request = async { selected.getSearchManga(1, "controlled-failure", FilterList()) }
                        val failure = runCatching { request.await() }.exceptionOrNull()
                        check(failure is AuthoredFailure && failure.message == "Authored source failure")
                    }
                }

                verify(checks, "suspended_source_cancellation_propagates_and_cleans_up") {
                    supervisorScope {
                        val request = async { selected.getPageList(chapter("/cancel", "Cancellation")) }
                        withTimeout(5_000) { selected.cancellationEntered.await() }
                        request.cancel(CancellationException("Authored model API cancellation"))
                        val failure = runCatching { request.await() }.exceptionOrNull()
                        check(failure is CancellationException && request.isCancelled)
                        withTimeout(5_000) { selected.cancellationFinished.await() }
                    }
                }
            }
            completed = true
        } finally {
            println(buildJsonObject {
                put("scope", "Authored Source 1.6 interfaces/models and suspend calls on host only")
                put("passed", completed && checks.values.all { it })
                put("checks", JsonObject(checks.mapValues { JsonPrimitive(it.value) }))
                put("authored_factory_source_count", 61)
                put("extension_code_executed", false)
                put("registry_tested", false)
                put("network_tested", false)
                put("ios_execution", false)
            })
        }
    }

    private suspend fun verify(
        checks: MutableMap<String, Boolean>,
        name: String,
        body: suspend () -> Unit,
    ) {
        try {
            body()
            checks[name] = true
        } catch (failure: Throwable) {
            checks[name] = false
            throw failure
        }
    }

    private const val MILLIS = 1_770_000_000_123L

    private fun manga(url: String, title: String): SManga = SManga.create().apply {
        this.url = url
        this.title = title
    }

    private fun chapter(url: String, name: String): SChapter = SChapter.create().apply {
        this.url = url
        this.name = name
    }

    private class AuthoredFactory : SourceFactory {
        override fun createSources(): List<Source> =
            languages.mapIndexed { index, language -> AuthoredSource(index, language) }

        private val languages = (
            "ar en ja es fr de it pt ru zh ko tr vi id th pl uk nl sv no da fi cs sk hu ro bg el he fa ur " +
                "hi bn ta te ml kn mr gu pa ne si my km lo ms tl sw af sq am az be bs ca et eu gl hr hy is"
            ).split(' ')
    }

    private class AuthoredSource(index: Int, override val lang: String) : CatalogueSource {
        override val id: Long = 4_000_000_000_000_000L + index
        override val name: String = "Authored source $lang"
        override val supportsLatest: Boolean = true
        var popularCalls = 0
            private set
        val cancellationEntered = CompletableDeferred<Unit>()
        val cancellationFinished = CompletableDeferred<Unit>()

        override suspend fun getPopularManga(page: Int): MangasPage {
            delay(1)
            popularCalls += 1
            return MangasPage(listOf(manga("/$lang/popular/$page", "Popular $lang")), page == 1)
        }

        override suspend fun getLatestUpdates(page: Int): MangasPage {
            delay(1)
            check(page > 0)
            return MangasPage(emptyList(), false)
        }

        override suspend fun getSearchManga(page: Int, query: String, filters: FilterList): MangasPage {
            delay(1)
            if (query == "controlled-failure") throw AuthoredFailure()
            val filterValue = (filters.firstOrNull() as? Filter.Text)?.state.orEmpty()
            return MangasPage(listOf(manga("/$lang/search/$page", "$query:$filterValue")), false)
        }

        override suspend fun getMangaUpdate(
            manga: SManga,
            chapters: List<SChapter>,
            fetchDetails: Boolean,
            fetchChapters: Boolean,
        ): SMangaUpdate {
            delay(1)
            val updated = if (fetchDetails) {
                manga(manga.url, manga.title + " updated").apply { initialized = true }
            } else {
                manga
            }
            val fetched = if (fetchChapters) {
                listOf(chapter("/$lang/chapter/1", "New chapter").apply { date_upload = MILLIS })
            } else {
                chapters
            }
            return SMangaUpdate(updated, fetched)
        }

        override suspend fun getPageList(chapter: SChapter): List<Page> {
            if (chapter.url == "/cancel") {
                try {
                    cancellationEntered.complete(Unit)
                    delay(Long.MAX_VALUE)
                    error("Cancelled source unexpectedly resumed")
                } finally {
                    cancellationFinished.complete(Unit)
                }
            }
            delay(1)
            return listOf(
                Page(9, "first", "https://pages.invalid/first.jpg"),
                Page(0, "second", "https://pages.invalid/second.jpg"),
                Page(3, "third", "https://pages.invalid/third.jpg"),
            )
        }
    }

    private class AuthoredFailure : IllegalStateException("Authored source failure")
}
