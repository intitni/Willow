import Foundation
import SwiftData

@Model
package final class ComicRecord {
    @Attribute(.allowsCloudEncryption) package var id: String = ""
    @Attribute(.allowsCloudEncryption) package var sourceID: String = ""
    @Attribute(.allowsCloudEncryption) package var comicID: String = ""
    @Attribute(.allowsCloudEncryption) package var title: String = ""
    @Attribute(.allowsCloudEncryption) package var coverURL: String = ""
    @Attribute(.allowsCloudEncryption) package var author: String = ""
    @Attribute(.allowsCloudEncryption) package var summary: String = ""
    @Attribute(.allowsCloudEncryption) package var isFavorite: Bool = false
    @Attribute(.allowsCloudEncryption) package var collectionName: String = ""
    @Attribute(.allowsCloudEncryption) package var lastReadAt: Date?
    @Attribute(.allowsCloudEncryption) package var chapterID: String?
    @Attribute(.allowsCloudEncryption) package var pageIndex: Int = 0
    @Attribute(.allowsCloudEncryption) package var detailJSON: Data?

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
            ($0.lastReadAt ?? .distantPast) < ($1.lastReadAt ?? .distantPast)
        }) {
            // CloudKit allows simultaneous inserts for the same comic on different devices.
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
