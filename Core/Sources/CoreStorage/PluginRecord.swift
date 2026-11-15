import Foundation
import SwiftData

@Model
package final class PluginRecord {
    @Attribute(.unique) package var uuid: String
    package var name: String
    package var version: String
    package var bundlePath: String
    package var subscriptionURL: String?
    package var enabled: Bool
    package var infoJSON: Data?

    package init(
        uuid: String,
        name: String,
        version: String,
        bundlePath: String,
        subscriptionURL: String? = nil,
        enabled: Bool = true,
        infoJSON: Data? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.version = version
        self.bundlePath = bundlePath
        self.subscriptionURL = subscriptionURL
        self.enabled = enabled
        self.infoJSON = infoJSON
    }
}

@Model
package final class PluginContentRating {
    @Attribute(.unique) package var sourceID: String
    package var isNSFW: Bool
    package var updatedAt: Date?

    package init(sourceID: String, isNSFW: Bool, updatedAt: Date? = .now) {
        self.sourceID = sourceID
        self.isNSFW = isNSFW
        self.updatedAt = updatedAt
    }
}

@Model
package final class SubscriptionRecord {
    @Attribute(.unique) package var url: String
    package var name: String
    package var updatedAt: Date

    package init(url: String, name: String, updatedAt: Date = .now) {
        self.url = url
        self.name = name
        self.updatedAt = updatedAt
    }
}
