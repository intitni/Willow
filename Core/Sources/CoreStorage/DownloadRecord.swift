import Foundation
import SwiftData

package enum DownloadStatus: String, Sendable {
    case queued
    case downloading
    case paused
    case completed
    case failed
}

@Model
package final class DownloadRecord {
    @Attribute(.unique) package var id: String
    package var sourceID: String
    package var comicID: String
    package var chapterID: String
    package var title: String
    package var pageURLs: [URL]
    package var requestHeaders: [[String: String]]?
    package var completedPageCount: Int
    package var errorMessage: String?
    package var createdAt: Date
    package var updatedAt: Date
    var rawStatus: String

    package var status: DownloadStatus {
        get { DownloadStatus(rawValue: rawStatus) ?? .paused }
        set { rawStatus = newValue.rawValue }
    }

    package static var unfinishedDownloads: FetchDescriptor<DownloadRecord> {
        let completed = DownloadStatus.completed.rawValue
        return FetchDescriptor(
            predicate: #Predicate { $0.rawStatus != completed },
            sortBy: [SortDescriptor(\.createdAt)]
        )
    }

    package static var completedDownloads: FetchDescriptor<DownloadRecord> {
        let completed = DownloadStatus.completed.rawValue
        return FetchDescriptor(
            predicate: #Predicate { $0.rawStatus == completed },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
    }

    package init(
        sourceID: String,
        comicID: String,
        chapterID: String,
        title: String,
        pageURLs: [URL],
        requestHeaders: [[String: String]]? = nil
    ) {
        self.id = Self.identifier(sourceID: sourceID, comicID: comicID, chapterID: chapterID)
        self.sourceID = sourceID
        self.comicID = comicID
        self.chapterID = chapterID
        self.title = title
        self.pageURLs = pageURLs
        self.requestHeaders = requestHeaders
        self.completedPageCount = 0
        self.createdAt = .now
        self.updatedAt = .now
        self.rawStatus = DownloadStatus.queued.rawValue
    }

    static func identifier(sourceID: String, comicID: String, chapterID: String) -> String {
        "\(sourceID.utf8.count):\(sourceID)\(comicID.utf8.count):\(comicID)\(chapterID)"
    }
}
