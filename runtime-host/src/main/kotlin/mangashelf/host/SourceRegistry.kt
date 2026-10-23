package mangashelf.host

import eu.kanade.tachiyomi.source.CatalogueSource
import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import java.util.LinkedHashMap
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext

/**
 * Registers already trusted/instantiated source objects. Archive verification,
 * class loading and Android/network bootstrap belong to the caller.
 *
 * Registration takes ownership of its resource on success and failure. Removal
 * cancels calls, then releases it only after those calls finish. A source that
 * ignores cancellation may delay release; this does not force JVM class unload.
 */
class SourceRegistry(
    private val maximumSources: Int = 10_000,
    private val maximumSourcesPerPackage: Int = 4096,
) {
    data class ExpectedSource(val id: Long, val language: String)
    data class SourceInfo(val packageName: String, val id: Long, val name: String, val language: String)
    class RegistrationException(val code: String) : IllegalStateException(code)

    private class Lease(val resource: AutoCloseable?, loader: ClassLoader) {
        private val job = SupervisorJob()
        val scope = CoroutineScope(Dispatchers.IO + job + ExtensionExecutionContext(loader))
        val released = CompletableDeferred<Unit>()

        init {
            job.invokeOnCompletion {
                try {
                    resource?.close()
                    released.complete(Unit)
                } catch (error: Throwable) {
                    released.completeExceptionally(error)
                }
            }
        }

        fun stop() { job.cancel(CancellationException("Source package removed")) }
    }

    private data class Prepared(val source: Source, val info: SourceInfo)
    private data class Entry(val source: Source, val info: SourceInfo, val lease: Lease)
    private data class Package(val lease: Lease, val ids: Set<Long>)
    private val lock = Any()
    private var packages: Map<String, Package> = emptyMap()
    private var sources: Map<Long, Entry> = emptyMap()
    private val retiring = LinkedHashSet<Lease>()
    private var closed = false

    init {
        require(maximumSources > 0 && maximumSourcesPerPackage > 0)
        require(maximumSourcesPerPackage <= maximumSources)
    }

    /** No source getters, factory callbacks or resource release run under the registry lock. */
    suspend fun register(
        packageName: String,
        instance: Any,
        expected: List<ExpectedSource>,
        resource: AutoCloseable? = null,
    ): List<SourceInfo> {
        var lease: Lease? = null
        try {
            if (packageName.length > 512 || !PACKAGE_NAME.matches(packageName)) fail("invalid_package")
            if (expected.isEmpty() || expected.size > maximumSourcesPerPackage) fail("source_count_limit")
            val expectedById = LinkedHashMap<Long, ExpectedSource>()
            for (item in expected) {
                if (!validLanguage(item.language)) fail("invalid_metadata")
                if (expectedById.put(item.id, item) != null) fail("duplicate_metadata_id")
            }

            // Return to the caller context before publication. Cancellation of this
            // preparation prevents registration and closes the uncommitted handle.
            val loader = instance.javaClass.classLoader ?: Source::class.java.classLoader
            val prepared = withContext(Dispatchers.IO + ExtensionExecutionContext(loader)) {
                val returned: List<*> = when (instance) {
                    is SourceFactory -> instance.createSources()
                    is Source -> listOf(instance)
                    else -> fail("unsupported_entrypoint")
                }
                if (returned.size != expectedById.size || returned.size > maximumSourcesPerPackage) {
                    fail("metadata_mismatch")
                }
                val found = ArrayList<Any?>(expectedById.size)
                for (source in returned) {
                    if (found.size >= expectedById.size) fail("metadata_mismatch")
                    found.add(source)
                }
                if (found.size != expectedById.size) fail("metadata_mismatch")
                val seen = HashSet<Long>()
                found.map { value ->
                    val source = value as? Source ?: fail("invalid_source")
                    val id = source.id
                    if (!seen.add(id)) fail("duplicate_source_id")
                    val metadata = expectedById[id] ?: fail("metadata_mismatch")
                    val language = if (source is CatalogueSource) source.lang else metadata.language
                    if (language != metadata.language || !validLanguage(language)) fail("language_mismatch")
                    val name = source.name
                    if (name.isEmpty() || name.length > 512 || name.any(Char::isISOControl)) fail("invalid_source_name")
                    Prepared(source, SourceInfo(packageName, id, name, language))
                }
            }
            val callerContext = currentCoroutineContext()
            callerContext.ensureActive()
            val infos = prepared.map { it.info }
            val installed = Lease(resource, loader)
            lease = installed
            val entries = prepared.map { Entry(it.source, it.info, installed) }
            synchronized(lock) {
                if (closed) fail("registry_closed")
                callerContext.ensureActive()
                if (packageName in packages) fail("package_already_registered")
                if (sources.size > maximumSources - entries.size) fail("source_count_limit")
                if (entries.any { it.info.id in sources }) fail("source_id_conflict")
                // Allocate complete successor maps before publishing either one.
                val nextSources = LinkedHashMap(sources)
                for (entry in entries) nextSources[entry.info.id] = entry
                val nextPackages = LinkedHashMap(packages)
                nextPackages[packageName] = Package(installed, entries.map { it.info.id }.toSet())
                sources = nextSources
                packages = nextPackages
            }
            return infos
        } catch (error: Throwable) {
            val owned = lease
            if (owned != null) {
                owned.stop()
            } else {
                try { resource?.close() }
                catch (releaseError: Throwable) { if (releaseError !== error) error.addSuppressed(releaseError) }
            }
            throw error
        }
    }

    fun snapshot(): List<SourceInfo> = synchronized(lock) { sources.values.map { it.info } }

    /**
     * Caller cancellation and package removal both cancel the source coroutine.
     * A cancelled caller waits for its source coroutine's cleanup to finish.
     * Convert plugin models inside operation; do not retain source/plugin objects
     * after this lease ends or its package may release the archive handle.
     */
    suspend fun <T> withSource(id: Long, operation: suspend (Source) -> T): T {
        currentCoroutineContext().ensureActive()
        val entry = synchronized(lock) { sources[id] ?: fail("source_not_registered") }
        val task = entry.lease.scope.async { operation(entry.source) }
        try { return task.await() }
        finally {
            if (!task.isCompleted) {
                task.cancel()
                withContext(NonCancellable) { task.join() }
            }
        }
    }

    /** Starts cancellation without blocking on potentially noncooperative plugin code. */
    fun remove(packageName: String): Deferred<Unit> {
        val removed = synchronized(lock) {
            val value = packages[packageName] ?: fail("package_not_registered")
            val nextSources = LinkedHashMap(sources)
            for (id in value.ids) nextSources.remove(id)
            val nextPackages = LinkedHashMap(packages)
            nextPackages.remove(packageName)
            sources = nextSources
            packages = nextPackages
            retiring.add(value.lease)
            value
        }
        watchRelease(removed.lease)
        removed.lease.stop()
        return removed.lease.released
    }

    /** Closes registration and removes every source before calling cancellation callbacks. */
    fun close(): List<Deferred<Unit>> {
        val removed = synchronized(lock) {
            closed = true
            val newlyRemoved = packages.values.map { it.lease }
            retiring.addAll(newlyRemoved)
            val pending = retiring.toList()
            packages = emptyMap()
            sources = emptyMap()
            Pair(newlyRemoved, pending)
        }
        removed.first.forEach(::watchRelease)
        removed.second.forEach { it.stop() }
        return removed.second.map { it.released }
    }

    private fun watchRelease(lease: Lease) {
        lease.released.invokeOnCompletion { synchronized(lock) { retiring.remove(lease) } }
    }

    private companion object {
        val PACKAGE_NAME = Regex("[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*)*")
        fun fail(code: String): Nothing = throw RegistrationException(code)
        fun validLanguage(value: String): Boolean = value.isNotEmpty() && value.length <= 32 &&
            value.none(Char::isISOControl) && value.toByteArray(Charsets.UTF_8).size <= 32
    }
}
