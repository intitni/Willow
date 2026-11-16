import Foundation
import SwiftData

@Model
package final class FollowedComicRecord {
    @Attribute(.unique) package private(set) var id: String
    package private(set) var sourceID: String
    package private(set) var comicID: String
    package private(set) var title: String
    package private(set) var coverURL: String
    package private(set) var author: String
    package private(set) var summary: String
    package private(set) var isFollowing: Bool
    package private(set) var hasUnreadUpdate: Bool
    package private(set) var updatedAt: Date
    fileprivate var followingChangedAt: Date
    fileprivate var revision: UUID
    fileprivate var knownChapterIDs: [String]?
    fileprivate var updateChapterID: String?
    fileprivate var updateChapterTitle: String?
    fileprivate var notifiedChapterID: String?

    fileprivate init(_ value: FollowedComicSnapshot) {
        id = value.id
        sourceID = value.sourceID
        comicID = value.comicID
        title = value.title
        coverURL = value.coverURL
        author = value.author
        summary = value.summary
        isFollowing = value.isFollowing
        hasUnreadUpdate = value.hasUnreadUpdate
        updatedAt = value.updatedAt
        followingChangedAt = value.followingChangedAt
        revision = value.revision
        knownChapterIDs = value.knownChapterIDs
        updateChapterID = value.updateChapter?.id
        updateChapterTitle = value.updateChapter?.title
    }

    fileprivate func apply(_ value: FollowedComicSnapshot) {
        title = value.title
        coverURL = value.coverURL
        author = value.author
        summary = value.summary
        isFollowing = value.isFollowing
        hasUnreadUpdate = value.hasUnreadUpdate
        updatedAt = value.updatedAt
        followingChangedAt = value.followingChangedAt
        revision = value.revision
        knownChapterIDs = value.knownChapterIDs
        updateChapterID = value.updateChapter?.id
        updateChapterTitle = value.updateChapter?.title
    }

    fileprivate var snapshot: FollowedComicSnapshot {
        FollowedComicSnapshot(sourceID: sourceID, comicID: comicID, title: title, coverURL: coverURL,
                              author: author, summary: summary, isFollowing: isFollowing,
                              knownChapterIDs: knownChapterIDs,
                              updateChapter: updateChapterID.map { .init(id: $0, title: updateChapterTitle ?? "") },
                              hasUnreadUpdate: hasUnreadUpdate, updatedAt: updatedAt,
                              followingChangedAt: followingChangedAt, revision: revision)
    }
}

package struct FollowedComicSnapshot: Codable, Equatable, Sendable {
    package struct Chapter: Codable, Equatable, Sendable {
        package let id: String
        package let title: String

        package init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    package let sourceID: String
    package let comicID: String
    package let title: String
    package let coverURL: String
    package let author: String
    package let summary: String
    package var isFollowing: Bool
    var knownChapterIDs: [String]?
    package var updateChapter: Chapter?
    package var hasUnreadUpdate: Bool
    package var updatedAt: Date
    var followingChangedAt: Date
    package var revision: UUID

    package var id: String { ComicRecord.identifier(sourceID: sourceID, comicID: comicID) }

    package init(sourceID: String, comicID: String, title: String, coverURL: String,
                 author: String, summary: String, isFollowing: Bool = true, knownChapterIDs: [String]? = nil,
                 updateChapter: Chapter? = nil, hasUnreadUpdate: Bool = false,
                 updatedAt: Date = .now, followingChangedAt: Date? = nil, revision: UUID = UUID()) {
        self.sourceID = sourceID
        self.comicID = comicID
        self.title = title
        self.coverURL = coverURL
        self.author = author
        self.summary = summary
        self.isFollowing = isFollowing
        self.knownChapterIDs = knownChapterIDs
        self.updateChapter = updateChapter
        self.hasUnreadUpdate = hasUnreadUpdate
        self.updatedAt = updatedAt
        self.followingChangedAt = followingChangedAt ?? updatedAt
        self.revision = revision
    }

    // A chapter check or a read on an offline device cannot reverse a follow toggle.
    var version: (Date, Date, String) { (followingChangedAt, updatedAt, revision.uuidString) }

    mutating func advance(after date: Date) {
        updatedAt = max(.now, date.addingTimeInterval(0.001))
        revision = UUID()
    }
}

package actor FollowedComicStore {
    package static let shared = FollowedComicStore()
    static let didEdit = Notification.Name("Willow.FollowedComicStore.didEdit")

    private init() {}

    package func records(in container: ModelContainer, followingOnly: Bool = true) throws -> [FollowedComicSnapshot] {
        let context = ModelContext(container)
        return try fetch(in: context, followingOnly: followingOnly).map(\.snapshot)
    }

    package func setFollowing(_ proposed: FollowedComicSnapshot, in container: ModelContainer) throws {
        try Task.checkCancellation()
        let context = ModelContext(container)
        let record = try find(proposed.id, in: context)
        guard (record?.isFollowing ?? false) != proposed.isFollowing else { return }
        var value = proposed
        value.advance(after: record?.updatedAt ?? .distantPast)
        value.followingChangedAt = value.updatedAt
        if let record { record.apply(value) }
        else { context.insert(FollowedComicRecord(value)) }
        try saveEdit(in: context)
    }

    @discardableResult
    package func markOpened(_ id: String, in container: ModelContainer) throws -> UUID? {
        try Task.checkCancellation()
        let context = ModelContext(container)
        guard let record = try find(id, in: context), record.isFollowing else { return nil }
        guard record.hasUnreadUpdate else { return record.revision }
        var value = record.snapshot
        value.hasUnreadUpdate = false
        value.advance(after: record.updatedAt)
        record.apply(value)
        try saveEdit(in: context)
        return value.revision
    }

    @discardableResult
    package func observe(_ chapters: [FollowedComicSnapshot.Chapter], for id: String, expectedRevision: UUID?,
                         opened: Bool = false, in container: ModelContainer) throws -> Bool {
        try Task.checkCancellation()
        let context = ModelContext(container)
        guard let record = try find(id, in: context), record.isFollowing else { return false }
        // A detail load can be in progress when the comic is first followed.
        let needsBaseline = opened && expectedRevision == nil && record.knownChapterIDs == nil
        guard record.revision == expectedRevision || needsBaseline else { return false }
        var value = record.snapshot
        let known = Set(value.knownChapterIDs ?? [])
        let newChapters = chapters.filter { !known.contains($0.id) }
        guard value.knownChapterIDs == nil || !newChapters.isEmpty else { return false }
        // Keep the IDs of chapters that temporarily disappear from the source.
        value.knownChapterIDs = known.union(newChapters.map(\.id)).sorted()
        if record.knownChapterIDs != nil, let latest = newChapters.last {
            value.updateChapter = latest
            value.hasUnreadUpdate = !opened
        }
        value.advance(after: record.updatedAt)
        record.apply(value)
        try saveEdit(in: context)
        return true
    }

    func merge(_ incoming: [FollowedComicSnapshot], in container: ModelContainer) throws -> Bool {
        try Task.checkCancellation()
        let context = ModelContext(container)
        for value in incoming {
            try Task.checkCancellation()
            if let current = try find(value.id, in: context) {
                if current.snapshot.version < value.version { current.apply(value) }
            } else {
                context.insert(FollowedComicRecord(value))
            }
        }
        guard context.hasChanges else { return false }
        try context.save()
        return true
    }

    package func pendingNotifications(in container: ModelContainer) throws -> [FollowedComicSnapshot] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<FollowedComicRecord>(predicate: #Predicate { $0.isFollowing && $0.hasUnreadUpdate })
        return try context.fetch(descriptor).compactMap { record in
            guard let chapter = record.updateChapterID, record.notifiedChapterID != chapter else { return nil }
            return record.snapshot
        }
    }

    package func noteNotification(for id: String, chapterID: String, in container: ModelContainer) throws -> Bool {
        let context = ModelContext(container)
        guard let record = try find(id, in: context), record.isFollowing, record.hasUnreadUpdate,
              record.updateChapterID == chapterID else { return false }
        record.notifiedChapterID = chapterID
        try context.save()
        return true
    }

    private func fetch(in context: ModelContext, followingOnly: Bool) throws -> [FollowedComicRecord] {
        let descriptor = followingOnly
            ? FetchDescriptor<FollowedComicRecord>(predicate: #Predicate { $0.isFollowing })
            : FetchDescriptor<FollowedComicRecord>()
        return try context.fetch(descriptor)
    }

    private func find(_ id: String, in context: ModelContext) throws -> FollowedComicRecord? {
        var descriptor = FetchDescriptor<FollowedComicRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    private func saveEdit(in context: ModelContext) throws {
        try context.save()
        NotificationCenter.default.post(name: Self.didEdit, object: context.container)
    }
}
