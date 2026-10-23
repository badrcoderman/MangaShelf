package mangashelf.host

import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import eu.kanade.tachiyomi.source.model.FilterList
import eu.kanade.tachiyomi.source.model.MangasPage
import eu.kanade.tachiyomi.source.model.Page
import eu.kanade.tachiyomi.source.model.SChapter
import eu.kanade.tachiyomi.source.model.SManga
import eu.kanade.tachiyomi.source.model.SMangaUpdate
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

object RegistryCheck {
    private class FixtureSource(
        override val id: Long,
        override val lang: String = "en",
        private val beforePopular: suspend () -> Unit = {},
    ) : CatalogueSource {
        override val name = "Authored source $id"
        override val supportsLatest = true
        override suspend fun getPopularManga(page: Int): MangasPage {
            beforePopular()
            return MangasPage(listOf(SManga.create().apply {
                title = "Source $id page $page"
                url = "/owned/$id/$page"
            }), page < 2)
        }
        override suspend fun getLatestUpdates(page: Int) = getPopularManga(page)
        override suspend fun getSearchManga(page: Int, query: String, filters: FilterList) = getPopularManga(page)
        override suspend fun getMangaUpdate(manga: SManga, chapters: List<SChapter>, fetchDetails: Boolean, fetchChapters: Boolean) =
            SMangaUpdate(manga, chapters)
        override suspend fun getPageList(chapter: SChapter) = listOf(Page(0, chapter.url, "https://example.invalid/owned.png"))
    }

    private class Handle(private val onClose: () -> Unit = {}) : AutoCloseable {
        val closes = AtomicInteger()
        override fun close() {
            check(closes.incrementAndGet() == 1)
            onClose()
        }
    }

    private fun expected(vararg sources: FixtureSource) = sources.map { SourceRegistry.ExpectedSource(it.id, it.lang) }
    private fun factory(vararg sources: Source) = object : SourceFactory { override fun createSources() = sources.toList() }
    private suspend fun code(value: String, action: suspend () -> Unit) {
        try { action(); error("Expected registry failure $value") }
        catch (error: SourceRegistry.RegistrationException) { check(error.code == value) { "Expected $value, got ${error.code}" } }
    }

    @JvmStatic
    fun main(args: Array<String>) = runBlocking {
        val checks = linkedMapOf<String, Boolean>()
        suspend fun case(name: String, body: suspend () -> Unit) {
            withTimeout(8000) { body() }
            checks[name] = true
        }

        case("factory_registers_61_metadata_id_language_pairs_and_invokes_them") {
            val registry = SourceRegistry()
            val sources = (1L..61L).map { FixtureSource(it, "lang-$it") }
            val creates = AtomicInteger()
            val handle = Handle()
            val owner = object : SourceFactory {
                override fun createSources(): List<Source> { creates.incrementAndGet(); return sources }
            }
            val infos = registry.register("fixture.multiple", owner, sources.map { SourceRegistry.ExpectedSource(it.id, it.lang) }, handle)
            check(creates.get() == 1 && infos.size == 61 && registry.snapshot() == infos)
            coroutineScope {
                sources.map { source -> async {
                    val page = registry.withSource(source.id) { it.getPopularManga(2) }
                    check(page.mangas.single().title == "Source ${source.id} page 2" && !page.hasNextPage)
                } }.awaitAll()
            }
            registry.remove("fixture.multiple").await()
            check(registry.snapshot().isEmpty() && handle.closes.get() == 1)
        }

        case("single_source_entrypoint_keeps_signed_long_id_and_language") {
            val registry = SourceRegistry()
            val source = FixtureSource(-41, "ar")
            val handle = Handle()
            check(registry.register("fixture.single", source, expected(source), handle).single().language == "ar")
            check(registry.withSource(-41) { it.getLatestUpdates(1) }.mangas.single().url == "/owned/-41/1")
            registry.close().forEach { it.await() }
            check(handle.closes.get() == 1)
        }

        case("non_catalogue_source_preserves_metadata_language_without_inventing_a_getter") {
            val registry = SourceRegistry()
            val source = object : Source by FixtureSource(8, "ar") { }
            val info = registry.register("fixture.plain", source, listOf(SourceRegistry.ExpectedSource(8, "en"))).single()
            check(info.language == "en" && registry.withSource(8) { it.id } == 8L)
            registry.close().forEach { it.await() }
        }

        case("duplicate_metadata_rejected_before_factory_and_resource_closed") {
            val registry = SourceRegistry()
            val creates = AtomicInteger()
            val owner = object : SourceFactory {
                override fun createSources(): List<Source> { creates.incrementAndGet(); return listOf(FixtureSource(1)) }
            }
            val handle = Handle()
            code("duplicate_metadata_id") {
                registry.register("fixture.duplicates", owner, listOf(SourceRegistry.ExpectedSource(1, "en"), SourceRegistry.ExpectedSource(1, "ar")), handle)
            }
            check(creates.get() == 0 && handle.closes.get() == 1 && registry.snapshot().isEmpty())
        }

        case("duplicate_factory_ids_reject_entire_package") {
            val registry = SourceRegistry()
            val handle = Handle()
            code("duplicate_source_id") {
                registry.register("fixture.duplicates", factory(FixtureSource(5), FixtureSource(5)), expected(FixtureSource(5), FixtureSource(6)), handle)
            }
            check(registry.snapshot().isEmpty() && handle.closes.get() == 1)
        }

        case("metadata_id_and_language_mismatch_never_partially_register") {
            val registry = SourceRegistry()
            val existing = FixtureSource(1)
            registry.register("fixture.existing", existing, expected(existing))
            val idHandle = Handle()
            code("metadata_mismatch") { registry.register("fixture.wrongid", FixtureSource(5), expected(FixtureSource(6)), idHandle) }
            val languageHandle = Handle()
            code("language_mismatch") {
                registry.register("fixture.wronglang", factory(FixtureSource(10), FixtureSource(11, "ar")), expected(FixtureSource(10), FixtureSource(11, "en")), languageHandle)
            }
            check(registry.snapshot().map { it.id } == listOf(1L))
            check(idHandle.closes.get() == 1 && languageHandle.closes.get() == 1)
            registry.close().forEach { it.await() }
        }

        case("cross_package_conflict_is_atomic_and_preserves_existing_handle") {
            val registry = SourceRegistry()
            val first = Handle()
            registry.register("fixture.first", FixtureSource(1), expected(FixtureSource(1)), first)
            val second = Handle()
            code("source_id_conflict") {
                registry.register("fixture.second", factory(FixtureSource(1), FixtureSource(2)), expected(FixtureSource(1), FixtureSource(2)), second)
            }
            check(registry.snapshot().map { it.packageName } == listOf("fixture.first"))
            check(first.closes.get() == 0 && second.closes.get() == 1)
            registry.remove("fixture.first").await()
            check(first.closes.get() == 1)
        }

        case("package_duplicate_and_global_bounds_preserve_prior_registration") {
            val registry = SourceRegistry(2, 2)
            registry.register("fixture.first", FixtureSource(1), expected(FixtureSource(1)))
            val duplicate = Handle()
            code("package_already_registered") { registry.register("fixture.first", FixtureSource(2), expected(FixtureSource(2)), duplicate) }
            val excess = Handle()
            code("source_count_limit") {
                registry.register("fixture.excess", factory(FixtureSource(2), FixtureSource(3)), expected(FixtureSource(2), FixtureSource(3)), excess)
            }
            check(registry.snapshot().map { it.id } == listOf(1L))
            check(duplicate.closes.get() == 1 && excess.closes.get() == 1)
            registry.close().forEach { it.await() }
        }

        case("factory_exception_propagates_and_releases_uncommitted_resource") {
            val registry = SourceRegistry()
            val original = IllegalArgumentException("authored factory error")
            val handle = Handle()
            val owner = object : SourceFactory { override fun createSources(): List<Source> = throw original }
            try { registry.register("fixture.throwing", owner, expected(FixtureSource(1)), handle); error("Expected factory error") }
            catch (error: IllegalArgumentException) { check(error === original) }
            check(handle.closes.get() == 1 && registry.snapshot().isEmpty())
        }

        case("source_failure_does_not_cancel_sibling_or_package") {
            val registry = SourceRegistry()
            registry.register("fixture.failure", factory(FixtureSource(1), FixtureSource(2)), expected(FixtureSource(1), FixtureSource(2)))
            val original = IllegalStateException("authored source error")
            try { registry.withSource(1) { throw original }; error("Expected source error") }
            catch (error: IllegalStateException) { check(error === original) }
            check(registry.withSource(2) { it.getPopularManga(1) }.mangas.single().title == "Source 2 page 1")
            registry.close().forEach { it.await() }
        }

        case("caller_cancellation_reaches_source_and_keeps_package_available") {
            val registry = SourceRegistry()
            val started = CompletableDeferred<Unit>()
            val cleaned = AtomicBoolean()
            val source = FixtureSource(1) { started.complete(Unit); try { awaitCancellation() } finally { cleaned.set(true) } }
            val handle = Handle()
            registry.register("fixture.cancel", source, expected(source), handle)
            coroutineScope {
                val request = async { registry.withSource(1) { it.getPopularManga(1) } }
                started.await()
                request.cancelAndJoin()
            }
            check(cleaned.get() && handle.closes.get() == 0 && registry.withSource(1) { it.id } == 1L)
            registry.remove("fixture.cancel").await()
            check(handle.closes.get() == 1)
        }

        case("removal_cancels_live_call_then_releases_handle_after_cleanup") {
            val registry = SourceRegistry()
            val started = CompletableDeferred<Unit>()
            val gate = CompletableDeferred<Unit>()
            val cleaned = AtomicBoolean()
            val source = FixtureSource(1) {
                started.complete(Unit)
                try { awaitCancellation() }
                finally { withContext(NonCancellable) { gate.await(); cleaned.set(true) } }
            }
            val handle = Handle { check(cleaned.get()); registry.snapshot() }
            registry.register("fixture.active", source, expected(source), handle)
            coroutineScope {
                val request = async { registry.withSource(1) { it.getPopularManga(1) } }
                try {
                    started.await()
                    val released = registry.remove("fixture.active")
                    check(registry.snapshot().isEmpty() && !released.isCompleted && handle.closes.get() == 0)
                    code("source_not_registered") { registry.withSource(1) { it.getPopularManga(1) } }
                    val replacement = FixtureSource(1, "ar")
                    registry.register("fixture.active", replacement, expected(replacement))
                    check(registry.snapshot().single().language == "ar")
                    val closed = registry.close()
                    check(released in closed && registry.snapshot().isEmpty())
                    gate.complete(Unit)
                    closed.forEach { it.await() }
                    request.join()
                    check(request.isCancelled && cleaned.get() && handle.closes.get() == 1)
                } finally {
                    gate.complete(Unit)
                    registry.close().forEach { it.await() }
                }
            }
        }

        case("already_cancelled_caller_does_not_execute_source") {
            val registry = SourceRegistry()
            registry.register("fixture.precancel", FixtureSource(1), expected(FixtureSource(1)))
            val calls = AtomicInteger()
            coroutineScope {
                launch(start = CoroutineStart.UNDISPATCHED) {
                    coroutineContext.cancel()
                    try { registry.withSource(1) { calls.incrementAndGet() }; error("Expected cancellation") }
                    catch (_: CancellationException) { }
                }.join()
            }
            check(calls.get() == 0)
            registry.close().forEach { it.await() }
        }

        case("cancelled_factory_preparation_cannot_publish_sources") {
            val registry = SourceRegistry()
            val started = CompletableDeferred<Unit>()
            val gate = CountDownLatch(1)
            val handle = Handle()
            val owner = object : SourceFactory {
                override fun createSources(): List<Source> {
                    started.complete(Unit)
                    check(gate.await(3, TimeUnit.SECONDS))
                    return listOf(FixtureSource(1))
                }
            }
            coroutineScope {
                val registration = async { registry.register("fixture.preparation", owner, expected(FixtureSource(1)), handle) }
                try { started.await(); registration.cancel() }
                finally { gate.countDown() }
                registration.join()
            }
            check(registry.snapshot().isEmpty() && handle.closes.get() == 1)
        }

        case("concurrent_conflicting_installs_have_one_atomic_winner") {
            val registry = SourceRegistry()
            val handles = listOf(Handle(), Handle())
            val results = coroutineScope {
                handles.mapIndexed { index, handle -> async {
                    runCatching { registry.register("fixture.race$index", FixtureSource(9), expected(FixtureSource(9)), handle) }
                } }.awaitAll()
            }
            check(results.count { it.isSuccess } == 1)
            check((results.single { it.isFailure }.exceptionOrNull() as SourceRegistry.RegistrationException).code == "source_id_conflict")
            check(registry.snapshot().size == 1 && handles.sumOf { it.closes.get() } == 1)
            registry.close().forEach { it.await() }
            check(handles.all { it.closes.get() == 1 })
        }

        case("release_failure_is_reported_without_restoring_removed_source") {
            val registry = SourceRegistry()
            val original = IllegalStateException("authored release error")
            val handle = Handle { throw original }
            registry.register("fixture.release", FixtureSource(1), expected(FixtureSource(1)), handle)
            try { registry.remove("fixture.release").await(); error("Expected release error") }
            catch (error: IllegalStateException) { check(error === original) }
            check(registry.snapshot().isEmpty() && handle.closes.get() == 1)
        }

        case("closed_registry_rejects_registration_and_close_is_idempotent") {
            val registry = SourceRegistry()
            val first = Handle()
            registry.register("fixture.closed", FixtureSource(1), expected(FixtureSource(1)), first)
            registry.close().forEach { it.await() }
            val second = Handle()
            code("registry_closed") { registry.register("fixture.later", FixtureSource(2), expected(FixtureSource(2)), second) }
            check(first.closes.get() == 1 && second.closes.get() == 1 && registry.close().isEmpty())
        }

        case("mutating_returned_snapshot_cannot_mutate_registry") {
            val registry = SourceRegistry()
            registry.register("fixture.snapshot", FixtureSource(1), expected(FixtureSource(1)))
            @Suppress("UNCHECKED_CAST")
            val copy = registry.snapshot() as MutableList<SourceRegistry.SourceInfo>
            copy.clear()
            check(registry.snapshot().size == 1)
            registry.close().forEach { it.await() }
        }

        case("bounded_snapshot_rejects_factory_iterator_that_exceeds_declared_size") {
            val registry = SourceRegistry()
            val reads = AtomicInteger()
            val source = FixtureSource(1)
            val dishonest = object : AbstractList<Source>() {
                override val size = 1
                override fun get(index: Int): Source = source
                override fun iterator() = object : Iterator<Source> {
                    override fun hasNext() = true
                    override fun next(): Source { reads.incrementAndGet(); return source }
                }
            }
            val owner = object : SourceFactory { override fun createSources(): List<Source> = dishonest }
            val handle = Handle()
            code("metadata_mismatch") { registry.register("fixture.iterator", owner, expected(source), handle) }
            check(reads.get() == 2 && handle.closes.get() == 1 && registry.snapshot().isEmpty())
        }

        println(buildJsonObject {
            put("passed", true)
            put("scope", "Authored SourceFactory/Source registry and coroutine lifecycle on host only")
            put("checks", buildJsonObject { checks.forEach { (name, value) -> put(name, value) } })
            put("real_extension_executed", false)
            put("archive_loader_tested", false)
            put("network_tested", false)
            put("ios_execution", false)
        })
    }
}
