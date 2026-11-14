import Foundation
#if os(macOS)
import Security
#endif
import SwiftData

@MainActor
package struct WillowPersistence {
    package enum SyncStatus: Equatable, Sendable {
        case iCloud
        case localOnly
        case inMemory
    }

    static let iCloudContainer = "iCloud.intii.Willow"

    package let container: ModelContainer
    package let syncStatus: SyncStatus
    package let syncFailure: String?

    package static func make(inMemory: Bool = false) throws -> WillowPersistence {
        let library = Schema([ComicRecord.self, PreferenceSyncRecord.self, PluginSyncAsset.self])
        let local = Schema([PluginRecord.self, SubscriptionRecord.self, DownloadRecord.self, LocalTagRecord.self, PreferenceSyncCheckpoint.self])
        let schema = Schema([ComicRecord.self, PreferenceSyncRecord.self, PluginSyncAsset.self, PluginRecord.self, SubscriptionRecord.self, DownloadRecord.self, LocalTagRecord.self, PreferenceSyncCheckpoint.self])
        let localConfiguration = ModelConfiguration(
            "WillowDevice",
            schema: local,
            isStoredInMemoryOnly: inMemory,
            cloudKitDatabase: .none
        )

        func configuration(cloudDatabase: ModelConfiguration.CloudKitDatabase) -> ModelConfiguration {
            ModelConfiguration(
                "WillowLibrary",
                schema: library,
                isStoredInMemoryOnly: inMemory,
                cloudKitDatabase: cloudDatabase
            )
        }

        func makeContainer(libraryConfiguration: ModelConfiguration) throws -> ModelContainer {
            try ModelContainer(for: schema, configurations: libraryConfiguration, localConfiguration)
        }

        let localLibrary = configuration(cloudDatabase: .none)
        if inMemory {
            return WillowPersistence(
                container: try makeContainer(libraryConfiguration: localLibrary),
                syncStatus: .inMemory,
                syncFailure: nil
            )
        }

        let cloudLibrary = configuration(cloudDatabase: cloudDatabase)
        guard cloudLibrary.cloudKitContainerIdentifier == iCloudContainer else {
            return WillowPersistence(
                container: try makeContainer(libraryConfiguration: localLibrary),
                syncStatus: .localOnly,
                syncFailure: localOnlyReason
            )
        }

        do {
            return WillowPersistence(
                container: try makeContainer(libraryConfiguration: cloudLibrary),
                syncStatus: .iCloud,
                syncFailure: nil
            )
        } catch {
            return WillowPersistence(
                container: try makeContainer(libraryConfiguration: localLibrary),
                syncStatus: .localOnly,
                syncFailure: error.localizedDescription
            )
        }
    }

    private static var localOnlyReason: String {
        #if targetEnvironment(simulator)
        L10n.text("Message.SimulatorLocalStorage")
        #else
        L10n.text("Message.CloudContainerUnavailable")
        #endif
    }

    private static var cloudDatabase: ModelConfiguration.CloudKitDatabase {
        #if targetEnvironment(simulator)
        return .none
        #elseif os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-services" as CFString, nil
              ) as? [String],
              let containers = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
              ) as? [String] else {
            return .none
        }
        return services.contains("CloudKit") && containers.contains(iCloudContainer) ? .private(iCloudContainer) : .none
        #else
        // SwiftData resolves .automatic from the app's signed CloudKit container entitlements.
        return .automatic
        #endif
    }
}
