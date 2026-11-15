import CoreStorage
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ContentPrivacy {
    @ObservationIgnored private let defaults: UserDefaults
    private static let greenTravelKey = "willow.greenTravelEnabled"
    private static let nsfwSourcesKey = "willow.nsfwSourceIDs"

    private(set) var greenTravelEnabled: Bool
    private(set) var allowsNSFW = false
    private(set) var requiresNSFWUnlock = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        greenTravelEnabled = defaults.bool(forKey: Self.greenTravelKey)
    }

    var hidesNSFWSources: Bool {
        greenTravelEnabled && !allowsNSFW
    }

    func lockNSFWAccess() {
        if allowsNSFW { requiresNSFWUnlock = true }
    }

    func unlockNSFWAccess() {
        requiresNSFWUnlock = false
    }

    func setGreenTravel(_ enabled: Bool) {
        greenTravelEnabled = enabled
        defaults.set(enabled, forKey: Self.greenTravelKey)
    }

    func toggleNSFWAccess() {
        allowsNSFW.toggle()
        if !allowsNSFW { requiresNSFWUnlock = false }
    }

    static func migrateSourceRatings(in context: ModelContext, defaults: UserDefaults = .standard) throws {
        guard let sourceIDs = defaults.stringArray(forKey: nsfwSourcesKey) else { return }
        let existing = Set(try context.fetch(FetchDescriptor<PluginContentRating>()).map(\.sourceID))
        for id in Set(sourceIDs).subtracting(existing) {
            context.insert(PluginContentRating(sourceID: id, isNSFW: true, updatedAt: nil))
        }
        try context.save()
        defaults.removeObject(forKey: nsfwSourcesKey)
    }
}
