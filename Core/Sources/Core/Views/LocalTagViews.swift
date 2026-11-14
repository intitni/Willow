import CoreStorage
import SwiftData
import SwiftUI

struct LocalTagFilterMenu: View {
    let tags: [LocalTagSnapshot]
    let selected: Set<UUID>
    let select: (Set<UUID>) -> Void

    var body: some View {
        Menu {
            Button(L10n.text("Text.AllTags")) { select([]) }
            ForEach(tags) { tag in
                Toggle(tag.name, isOn: Binding(
                    get: { selected.contains(tag.id) },
                    set: { enabled in
                        var next = selected
                        if enabled { next.insert(tag.id) } else { next.remove(tag.id) }
                        select(next)
                    }
                ))
                .menuActionDismissBehavior(.disabled)
            }
            Text(L10n.text("Text.MatchAnySelectedTag"))
        } label: {
            Label(L10n.text("Text.FilterTags"), systemImage: selected.isEmpty ? "tag" : "tag.fill")
        }
        .accessibilityValue(selected.isEmpty ? L10n.text("Text.AllTags") : tags.filter { selected.contains($0.id) }.map(\.name).joined(separator: "、"))
    }
}

struct ComicLocalTagsSection: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \LocalTagRecord.name) private var tags: [LocalTagRecord]
    @State private var model: LocalTagsModel
    let edit: () -> Void
    let comicKey: String

    init(sourceID: String, comicID: String, edit: @escaping () -> Void) {
        self.edit = edit
        comicKey = ComicRecord.identifier(sourceID: sourceID, comicID: comicID)
        _model = State(initialValue: LocalTagsModel(comicKey: ComicRecord.identifier(sourceID: sourceID, comicID: comicID)))
    }

    var body: some View {
        Section(L10n.text("Text.LocalTags")) {
            Button(action: edit) {
                LabeledContent {
                    Text(model.viewModel.assignedNames.isEmpty ? L10n.text("Text.AddTag") : model.viewModel.assignedNames.joined(separator: "、"))
                        .multilineTextAlignment(.trailing)
                } label: { Label(L10n.text("Text.Tags"), systemImage: "tag").labelStyle(CompactActionLabelStyle()) }
            }
        }
        .onChange(of: tags.map(LocalTagSnapshot.init), initial: true) { _, tags in model.update(tags, context: context) }
    }
}

struct LocalTagEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \LocalTagRecord.name) private var tags: [LocalTagRecord]
    @State private var model: LocalTagsModel

    init(comicKey: String) { _model = State(initialValue: LocalTagsModel(comicKey: comicKey)) }

    var body: some View {
        @Bindable var state = model.viewModel
        NavigationStack {
            Form {
                Section(L10n.text("Text.NewTag")) {
                    TextField(L10n.text("Text.TagName"), text: $state.draft)
                        .submitLabel(.done)
                        .onSubmit { if state.canCreate { model.create() } }
                    Button(L10n.text("Text.CreateAndAdd"), systemImage: "plus", action: model.create)
                        .disabled(!state.canCreate)
                }
                Section {
                    ForEach(state.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { state.selected.contains(tag.id) }, set: { model.assign(tag.id, selected: $0) }))
                    }
                } header: { Text(L10n.text("Text.ExistingTags")) } footer: {
                    Text(L10n.text("Message.TagsSyncWithICloud"))
                }
            }
            .navigationTitle(L10n.text("Text.LocalTags"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Text.Done")) { dismiss() } } }
        }
        .onChange(of: tags.map(LocalTagSnapshot.init), initial: true) { _, tags in model.update(tags, context: context) }
        .modifier(ErrorAlert(error: $state.error))
    }
}
