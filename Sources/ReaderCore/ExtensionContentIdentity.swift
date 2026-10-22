import Foundation
import CryptoKit

/// Storage identity is separate from the opaque URL used to call a source.
/// Tachiyomi's SManga/SChapter have URLs, not globally unique storage IDs.
public enum ExtensionContentIdentity {
    public static func seriesID(sourceID: String, url: String) -> String {
        digest(kind: "manga", components: [sourceID, url])
    }

    public static func chapterID(seriesID: String, url: String) -> String {
        digest(kind: "chapter", components: [seriesID, url])
    }

    private static func digest(kind: String, components: [String]) -> String {
        var hash = SHA256()
        for component in components {
            let bytes = Data(component.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: bytes)
        }
        return "extension-" + kind + "-" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension SourceMangaItem {
    public func librarySeries(sourceID: String, sourceLanguage: String? = nil,
                              saved: [SavedSeries] = []) -> MangaSeries {
        let canonical = ExtensionContentIdentity.seriesID(sourceID: sourceID, url: url)
        let matches = saved.filter { $0.series.sourceID == sourceID && $0.series.sourceURL == url }
        // Preserve existing IDs and therefore their progress, downloads and overrides.
        let existing = matches.first { $0.id == canonical } ?? matches.min { $0.id < $1.id }
        return MangaSeries(id: existing?.id ?? canonical, title: title, coverURL: coverURL,
                           sourceID: sourceID, sourceURL: url,
                           sourceLanguage: sourceLanguage ?? existing?.series.sourceLanguage)
    }
}

extension SourceChapterItem {
    public func libraryChapter(seriesID: String, language: String,
                               saved: [MangaChapter] = []) -> MangaChapter {
        let canonical = ExtensionContentIdentity.chapterID(seriesID: seriesID, url: url)
        let matches = saved.filter { $0.seriesID == seriesID && $0.sourceURL == url }
        let existing = matches.first { $0.id == canonical } ?? matches.min { $0.id < $1.id }
        return MangaChapter(id: existing?.id ?? canonical, seriesID: seriesID, title: name,
                            number: String(chapterNumber), language: language, group: scanlator ?? "",
                            publishedAt: Date(timeIntervalSince1970: TimeInterval(dateUpload)), sourceURL: url)
    }
}
