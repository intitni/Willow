import SwiftData

package enum WillowSyncMethod: String, CaseIterable, Identifiable, Sendable {
    case none, drive
    package var id: Self { self }
}

@MainActor
package struct WillowPersistence {
    package let container: ModelContainer

    package static func make(inMemory: Bool = false) throws -> WillowPersistence {
        // Keep the existing store names so upgrades open the same local data.
        let library = Schema([ComicRecord.self])
        let local = Schema([PluginRecord.self, PluginContentRating.self, SubscriptionRecord.self, DownloadRecord.self,
                            LocalTagRecord.self, PreferenceSyncCheckpoint.self, ReadChapterRecord.self, FollowedComicRecord.self])
        let schema = Schema([ComicRecord.self, PluginRecord.self, PluginContentRating.self, SubscriptionRecord.self,
                             DownloadRecord.self, LocalTagRecord.self, PreferenceSyncCheckpoint.self, ReadChapterRecord.self, FollowedComicRecord.self])
        let localConfiguration = ModelConfiguration(
            "WillowDevice",
            schema: local,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        let libraryConfiguration = ModelConfiguration(
            "WillowLibrary",
            schema: library,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: libraryConfiguration, localConfiguration)
        return WillowPersistence(container: container)
    }
}
