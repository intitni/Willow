import CoreStorage
import Foundation
import Observation
import SwiftData

@MainActor
final class LocalTagsModel {
    @MainActor @Observable
    final class ViewModel {
        var tags: [LocalTagSnapshot] = []
        var selected: Set<UUID> = []
        var assignedNames: [String] = []
        var draft = ""
        var error: String?
        var canCreate: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    let viewModel = ViewModel()
    private let comicKey: String
    private var context: ModelContext?

    init(comicKey: String) { self.comicKey = comicKey }

    func update(_ tags: [LocalTagSnapshot], context: ModelContext) {
        self.context = context
        viewModel.tags = tags
        let assigned = tags.filter { $0.comicKeys.contains(comicKey) }
        viewModel.selected = Set(assigned.map(\.id))
        viewModel.assignedNames = assigned.map(\.name)
    }

    func create() {
        guard let context else { return }
        do {
            try LocalTagStore.create(viewModel.draft, comicKey: comicKey, context: context)
            viewModel.draft = ""
            try reload(context)
        } catch { viewModel.error = error.localizedDescription }
    }

    func assign(_ id: UUID, selected: Bool) {
        guard let context else { return }
        do {
            try LocalTagStore.assign(id, to: comicKey, selected: selected, context: context)
            try reload(context)
        } catch { viewModel.error = error.localizedDescription }
    }

    private func reload(_ context: ModelContext) throws {
        update(try context.fetch(FetchDescriptor<LocalTagRecord>(sortBy: [SortDescriptor(\.name)])).map(LocalTagSnapshot.init), context: context)
    }
}
