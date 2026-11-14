import Foundation
import BreezeRuntime

package struct ComicSummary: Identifiable, Hashable, Codable, Sendable {
    package var id: String
    package var title: String
    package var coverURL: URL?
    package var author: String
    package var summary: String

    package init(id: String, title: String, coverURL: URL?, author: String, summary: String) {
        self.id = id
        self.title = title
        self.coverURL = coverURL
        self.author = author
        self.summary = summary
    }
}

package struct ComicChapter: Identifiable, Hashable, Codable, Sendable {
    package var id: String
    package var title: String

    package init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

package struct ComicDetail: Hashable, Codable, Sendable {
    package var comic: ComicSummary
    package var chapters: [ComicChapter]
    package var sourceActions: PluginComicActionState?
    package var metadata: [ComicMetadata]?

    package init(comic: ComicSummary, chapters: [ComicChapter], sourceActions: PluginComicActionState? = nil, metadata: [ComicMetadata] = []) {
        self.comic = comic
        self.chapters = chapters
        self.sourceActions = sourceActions
        self.metadata = metadata
    }
}

package struct HomeSection: Identifiable, Hashable, Sendable {
    package var id: String
    package var title: String
    package var comics: [ComicSummary]

    package init(id: String, title: String, comics: [ComicSummary]) {
        self.id = id
        self.title = title
        self.comics = comics
    }
}

package struct SearchResult: Hashable, Sendable {
    package var comics: [ComicSummary]
    package var hasMore: Bool

    package init(comics: [ComicSummary], hasMore: Bool) {
        self.comics = comics
        self.hasMore = hasMore
    }
}

package struct PluginCandidate: Identifiable, Hashable, Codable, Sendable {
    package var id: String
    package var name: String
    package var version: String
    package var description: String
    package var downloadURL: URL?
    package var subscriptionURL: String
    package var npmName: String

    package init(
        id: String,
        name: String,
        version: String,
        description: String,
        downloadURL: URL?,
        subscriptionURL: String,
        npmName: String = ""
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.downloadURL = downloadURL
        self.subscriptionURL = subscriptionURL
        self.npmName = npmName
    }
}

package struct PluginSetting: Identifiable, Hashable, Sendable {
    package var id: String
    package var title: String
    package var kind: String
    package var value: String
    package var function: String

    package init(id: String, title: String, kind: String, value: String, function: String) {
        self.id = id
        self.title = title
        self.kind = kind
        self.value = value
        self.function = function
    }
}

package struct PluginSettings: Sendable {
    package var fields: [PluginSetting]
    package var canLogin: Bool

    package init(fields: [PluginSetting], canLogin: Bool) {
        self.fields = fields
        self.canLogin = canLogin
    }
}

package struct PluginLoginForm: Sendable {
    package var title: String
    package var fields: [PluginSetting]
    package var submitTitle: String

    package init(title: String, fields: [PluginSetting], submitTitle: String) {
        self.title = title
        self.fields = fields
        self.submitTitle = submitTitle
    }
}

package struct ComicMetadata: Identifiable, Hashable, Codable, Sendable {
    package let id: String
    package let title: String
    package let values: [String]
    package let actions: [String: JSONValue]?

    package init(id: String, title: String, values: [String], actions: [String: JSONValue]? = nil) {
        self.id = id
        self.title = title
        self.values = values
        self.actions = actions
    }
}
