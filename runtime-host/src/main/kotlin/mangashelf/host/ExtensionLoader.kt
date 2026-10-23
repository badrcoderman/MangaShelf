package mangashelf.host

import eu.kanade.tachiyomi.source.Source
import eu.kanade.tachiyomi.source.SourceFactory
import java.lang.reflect.Modifier
import java.nio.file.Path
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import mangashelf.runtime.ExtensionArchiveVerifier

/** Loads explicitly trusted Source 1.6 packages into the typed registry. No publisher trust bootstrap. */
class ExtensionLoader(private val registry: SourceRegistry, private val scratchDirectory: Path) {
    data class Request(
        val archive: Path,
        val archiveSha256: String,
        val trustedCertificateSha256: String,
        val packageName: String,
        val versionCode: ULong,
        val versionName: String?,
        val mainClass: String,
        val expectedSources: List<SourceRegistry.ExpectedSource>,
    )

    class LoadException(val code: String) : IllegalStateException(code)

    suspend fun install(request: Request): List<SourceRegistry.SourceInfo> {
        val expected = request.expectedSources.toList()
        var owned: VerifiedExtensionClassLoader? = null
        var transferred = false
        var failure: Throwable? = null
        try {
            val instance = withContext(Dispatchers.IO) {
                currentCoroutineContext().ensureActive()
                val archive = ExtensionArchiveVerifier.openVerified(
                    request.archive, request.archiveSha256, request.trustedCertificateSha256, scratchDirectory,
                )
                val loader = VerifiedExtensionClassLoader.open(archive, Source::class.java.classLoader)
                owned = loader
                currentCoroutineContext().ensureActive()
                val bytes = archive.read("AndroidManifest.xml")?.bytes() ?: fail("missing_extension_manifest")
                val metadata = ExtensionManifest.parse(bytes)
                if (metadata.packageName() != request.packageName ||
                    metadata.versionCode().toString() != request.versionCode.toString() ||
                    metadata.versionName() != request.versionName || metadata.mainClass() != request.mainClass
                ) fail("manifest_mismatch")
                if (metadata.libraryVersion() != "1.6") fail("unsupported_source_api")

                // Resolve and check type/constructor without running class initialization.
                val type = loader.localEntrypoint(request.mainClass)
                if ((!Source::class.java.isAssignableFrom(type) && !SourceFactory::class.java.isAssignableFrom(type)) ||
                    !Modifier.isPublic(type.modifiers) || Modifier.isAbstract(type.modifiers)
                ) fail("unsupported_entrypoint")
                val constructor = type.getConstructor()
                currentCoroutineContext().ensureActive()
                withContext(ExtensionExecutionContext(loader)) { constructor.newInstance() }
            }
            // Returning an owned resource directly from withContext could lose it to
            // prompt cancellation. The captured handle is closed in that case.
            currentCoroutineContext().ensureActive()
            val resource = checkNotNull(owned)
            transferred = true // register owns it on success AND failure.
            return registry.register(request.packageName, instance, expected, resource)
        } catch (error: Throwable) {
            failure = error
            throw error
        } finally {
            if (!transferred) {
                try { owned?.close() }
                catch (release: Throwable) {
                    val original = failure
                    if (original == null) throw release
                    if (original !== release) original.addSuppressed(release)
                }
            }
        }
    }

    private fun fail(code: String): Nothing = throw LoadException(code)
}
