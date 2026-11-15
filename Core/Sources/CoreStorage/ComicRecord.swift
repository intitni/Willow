import Foundation
import SwiftData

@Model
package final class ComicRecord {
    package var id: String = ""
    package var sourceID: String = ""
    package var comicID: String = ""
    package var title: String = ""
    package var coverURL: String = ""
    package var author: String = ""
    package var summary: String = ""
    package var isFavorite: Bool = false
    // Retain the legacy field for existing SwiftData stores.
    package var collectionName: String = ""
    package var lastReadAt: Date?
    package var historyClearedAt: Date?
    package var chapterID: String?
    package var pageIndex: Int = 0
    package var detailJSON: Data?

    package init(
        sourceID: String,
        comicID: String,
        title: String,
        coverURL: String = "",
        author: String = "",
        summary: String = ""
    ) {
        self.id = Self.identifier(sourceID: sourceID, comicID: comicID)
        self.sourceID = sourceID
        self.comicID = comicID
        self.title = title
        self.coverURL = coverURL
        self.author = author
        self.summary = summary
    }

    var lastReadingEventAt: Date? {
        [lastReadAt, historyClearedAt].compactMap { $0 }.max()
    }

    package func clearHistory(at date: Date = .now) {
        lastReadAt = nil
        historyClearedAt = date
        chapterID = nil
        pageIndex = 0
    }

    package static func identifier(sourceID: String, comicID: String) -> String {
        "\(sourceID.utf8.count):\(sourceID)\(comicID)"
    }

    @MainActor
    package static func findOrCreate(
        in context: ModelContext,
        sourceID: String,
        comicID: String,
        title: String,
        coverURL: String = "",
        author: String = "",
        summary: String = ""
    ) throws -> ComicRecord {
        let key = identifier(sourceID: sourceID, comicID: comicID)
        let descriptor = FetchDescriptor<ComicRecord>(predicate: #Predicate { $0.id == key })
        let matches = try context.fetch(descriptor)
        if let existing = matches.max(by: {
            ($0.lastReadingEventAt ?? .distantPast) < ($1.lastReadingEventAt ?? .distantPast)
        }) {
            // Existing libraries may contain duplicate entries for the same comic.
            for duplicate in matches where duplicate !== existing {
                if duplicate.isFavorite && !existing.isFavorite {
                    existing.isFavorite = true
                    existing.collectionName = duplicate.collectionName
                }
                existing.detailJSON = existing.detailJSON ?? duplicate.detailJSON
                context.delete(duplicate)
            }
            if !title.isEmpty { existing.title = title }
            if !coverURL.isEmpty { existing.coverURL = coverURL }
            if !author.isEmpty { existing.author = author }
            if !summary.isEmpty { existing.summary = summary }
            return existing
        }
        let record = ComicRecord(
            sourceID: sourceID,
            comicID: comicID,
            title: title,
            coverURL: coverURL,
            author: author,
            summary: summary
        )
        context.insert(record)
        return record
    }
}
