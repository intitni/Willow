import Foundation
import SwiftData

/// Local copy of the most recent time the reader opened each chapter.
@Model
package final class ReadChapterRecord {
    #Unique<ReadChapterRecord>([\.comicKey, \.chapterID])

    package var comicKey: String
    package var chapterID: String
    package var readAt: Date

    private init(comicKey: String, chapterID: String, readAt: Date) {
        self.comicKey = comicKey
        self.chapterID = chapterID
        self.readAt = readAt
    }

    fileprivate static func markRead(comicKey: String, chapterID: String, at date: Date, in context: ModelContext) throws {
        var descriptor = FetchDescriptor<ReadChapterRecord>(predicate: #Predicate {
            $0.comicKey == comicKey && $0.chapterID == chapterID
        })
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            if date > record.readAt { record.readAt = date }
        } else {
            context.insert(ReadChapterRecord(comicKey: comicKey, chapterID: chapterID, readAt: date))
        }
    }
}

package actor ReadChapterStore {
    package static let shared = ReadChapterStore()
    static let didRecordOpen = Notification.Name("Willow.ReadChapterStore.didRecordOpen")

    private init() {}

    package func recordOpen(comicKey: String, chapterID: String, at date: Date, in container: ModelContainer) throws {
        let context = ModelContext(container)
        try ReadChapterRecord.markRead(comicKey: comicKey, chapterID: chapterID, at: date, in: context)
        guard context.hasChanges else { return }
        try context.save()
        NotificationCenter.default.post(name: Self.didRecordOpen, object: container)
    }

    // Import and reader writes each compare and save in one turn of this actor.
    func merge(_ chapters: [PreferencePayload.ReadChapter], in container: ModelContainer) throws {
        try Task.checkCancellation()
        let context = ModelContext(container)
        for chapter in chapters {
            try Task.checkCancellation()
            try ReadChapterRecord.markRead(comicKey: chapter.comicKey, chapterID: chapter.chapterID,
                                           at: chapter.readAt, in: context)
        }
        if context.hasChanges { try context.save() }
    }
}
