import Foundation
import SwiftData

// 同步记录与现有本地表分离，升级时不搬移或删除用户的旧数据。
@Model
package final class PreferenceSyncRecord {
    package var revision: String = UUID().uuidString
    @Attribute(.allowsCloudEncryption) package var key: String = ""
    @Attribute(.allowsCloudEncryption) package var payload: Data?
    package var modifiedAt: Date = Date.distantPast
    package var deleted: Bool = false

    package init(key: String, payload: Data?, deleted: Bool = false, modifiedAt: Date = .now) {
        self.key = key
        self.payload = payload
        self.deleted = deleted
        self.modifiedAt = modifiedAt
    }
}

@Model
package final class PluginSyncAsset {
    package var digest: String = ""
    @Attribute(.externalStorage) package var data: Data?
    package init(digest: String, data: Data) { self.digest = digest; self.data = data }
}

@Model
package final class PreferenceSyncCheckpoint {
    @Attribute(.unique) package var key: String
    package var payload: Data?
    package var revision: String
    package var localBundlePath: String?
    package var modifiedAt: Date?
    package init(key: String, payload: Data?, revision: String) {
        self.key = key; self.payload = payload; self.revision = revision
    }
}

package enum PreferencePayload: Codable, Equatable, Sendable {
    case plugin(Plugin)
    case subscription(Subscription)
    case tag(Tag)
    case tagLink(TagLink)
    case favorite(Comic)
    case reading(Reading)

    package struct Comic: Codable, Equatable, Sendable {
        let sourceID: String
        let comicID: String
        let title: String
        let coverURL: String
        let author: String
        let summary: String

        init(_ record: ComicRecord) {
            sourceID = record.sourceID
            comicID = record.comicID
            title = record.title
            coverURL = record.coverURL
            author = record.author
            summary = record.summary
        }

        var id: String { ComicRecord.identifier(sourceID: sourceID, comicID: comicID) }
    }

    package struct Reading: Codable, Equatable, Sendable {
        let comic: Comic
        let lastReadAt: Date
        let chapterID: String?
        let pageIndex: Int
    }

    package struct Plugin: Codable, Equatable, Sendable {
        package let id: String
        package let name: String
        package let version: String
        package let subscriptionURL: String?
        package let enabled: Bool
        package let info: Data?
        package let digest: String
    }
    package struct Subscription: Codable, Equatable, Sendable {
        package let url: String
        package let name: String
    }
    package struct Tag: Codable, Equatable, Sendable {
        package let normalizedName: String
        package let name: String
    }
    package struct TagLink: Codable, Equatable, Sendable {
        package let normalizedName: String
        package let comicKey: String
    }

    package var key: String {
        switch self {
        case .plugin(let value): "plugin/" + value.id
        case .subscription(let value): "subscription/" + value.url
        case .tag(let value): "tag/" + value.normalizedName
        case .favorite(let comic): "favorite/" + comic.id
        case .reading(let reading): "reading/" + reading.comic.id
        case .tagLink(let value): "tag-link/" + Data(value.normalizedName.utf8).base64EncodedString() + "/" + Data(value.comicKey.utf8).base64EncodedString()
        }
    }
    package func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}
