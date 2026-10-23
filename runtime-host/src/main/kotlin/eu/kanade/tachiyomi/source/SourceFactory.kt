package eu.kanade.tachiyomi.source

/** An entry point may create independent source instances for multiple languages. */
interface SourceFactory {
    fun createSources(): List<Source>
}
