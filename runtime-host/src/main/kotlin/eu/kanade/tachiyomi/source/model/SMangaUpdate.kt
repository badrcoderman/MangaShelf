package eu.kanade.tachiyomi.source.model

/** A source may update metadata and chapters together in one suspend operation. */
class SMangaUpdate(val manga: SManga, val chapters: List<SChapter>)
