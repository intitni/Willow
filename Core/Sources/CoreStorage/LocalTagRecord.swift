import Foundation
import SwiftData

/// Tags use stable comic identities; PreferenceSyncModel mirrors names and
/// memberships to CloudKit without relationships across stores.
@Model
package final class LocalTagRecord {
    @Attribute(.unique) package var id: UUID
    @Attribute(.unique) package var normalizedName: String
    package var name: String
    package var comicKeys: [String]

    package init(name: String) {
        id = UUID()
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        normalizedName = Self.normalize(name)
        comicKeys = []
    }

    package static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }
}

package struct LocalTagSnapshot: Identifiable, Equatable, Sendable {
    package let id: UUID
    package let name: String
    package let comicKeys: Set<String>

    package init(_ record: LocalTagRecord) {
        id = record.id; name = record.name; comicKeys = Set(record.comicKeys)
    }

    package static func matches(comicKey: String, selected: Set<UUID>, tags: [LocalTagSnapshot]) -> Bool {
        selected.isEmpty || tags.contains { selected.contains($0.id) && $0.comicKeys.contains(comicKey) }
    }
}

@MainActor
package enum LocalTagStore {
    @discardableResult
    package static func create(_ name: String, comicKey: String, context: ModelContext) throws -> LocalTagRecord {
        let normalized = LocalTagRecord.normalize(name)
        guard !normalized.isEmpty else { throw TagError.emptyName }
        let existing = try context.fetch(FetchDescriptor<LocalTagRecord>(predicate: #Predicate { $0.normalizedName == normalized })).first
        let tag = existing ?? LocalTagRecord(name: name)
        if existing == nil { context.insert(tag) }
        if !tag.comicKeys.contains(comicKey) { tag.comicKeys.append(comicKey) }
        do { try context.save() } catch { context.rollback(); throw error }
        return tag
    }

    package static func assign(_ id: UUID, to comicKey: String, selected: Bool, context: ModelContext) throws {
        guard let tag = try context.fetch(FetchDescriptor<LocalTagRecord>(predicate: #Predicate { $0.id == id })).first else { return }
        if selected {
            if !tag.comicKeys.contains(comicKey) { tag.comicKeys.append(comicKey) }
        } else { tag.comicKeys.removeAll { $0 == comicKey } }
        do { try context.save() } catch { context.rollback(); throw error }
    }

    private enum TagError: LocalizedError {
        case emptyName
        var errorDescription: String? { L10n.text("Message.EnterTagName") }
    }
}
