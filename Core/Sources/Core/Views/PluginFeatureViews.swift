import BreezePlugins
import BreezeRuntime
import CoreStorage
import SwiftUI

struct PluginCloudFavoritesView: View {
    let plugin: PluginRecord
    @State private var model: PluginComicListModel
    @State private var showingFilters = false

    init(plugin: PluginRecord) {
        self.plugin = plugin
        _model = State(initialValue: PluginComicListModel(plugin: plugin))
    }

    var body: some View {
        let state = model.viewModel
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 112, maximum: 192), spacing: 14)], spacing: 18) {
                ForEach(state.comics) { comic in
                    NavigationLink {
                        ComicDetailView(sourceID: plugin.uuid, summary: comic)
                    } label: {
                        DiscoverComicTile(comic: comic)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
            if state.isLoading {
                ProgressView().padding()
            } else if let error = state.error {
                RetryView(title: L10n.text("Text.LoadFailed"), message: error) { Task { await model.retry() } }
            } else if state.hasMore {
                PaginationTrigger(itemCount: state.comics.count) { Task { await model.loadNextPage() } }
            } else if state.loaded && state.tabs.isEmpty {
                ContentUnavailableView(L10n.text("CloudFavorites.NoFolders"), systemImage: "star")
            } else if state.searched && state.comics.isEmpty {
                ContentUnavailableView(L10n.text("Text.NoComics"), systemImage: "books.vertical")
            }
        }
        .navigationTitle(L10n.text("CloudFavorites.SourceTitle"))
        .toolbar {
            if state.tabs.count > 1 {
                Menu(L10n.text("CloudFavorites.FavoriteFolders"), systemImage: "folder") {
                    Picker(L10n.text("CloudFavorites.FavoriteFolders"), selection: Binding(get: { state.selectedTab }, set: { value in
                        Task { await model.selectTab(value) }
                    })) {
                        ForEach(state.tabs) { tab in Text(tab.title).tag(Optional(tab.id)) }
                    }
                }
                .disabled(state.isLoading)
            }
            if !state.fields.isEmpty {
                Button(L10n.text("Text.SortAndFilter"), systemImage: "arrow.up.arrow.down") { showingFilters = true }
                    .disabled(state.isLoading)
            }
        }
        .sheet(isPresented: $showingFilters) {
            FavoriteFiltersSheet(fields: state.fields, values: state.values) { values in
                showingFilters = false
                Task { await model.applyFavoriteFilters(values) }
            }
            .modifier(AppLockShield())
        }
        .task { if !state.loaded { await model.loadFavorites() } }
        .refreshable { await model.loadFavorites() }
    }
}

struct FavoriteFiltersSheet: View {
    let fields: [PluginFeatureField]
    @State private var values: [String: JSONValue]
    let apply: ([String: JSONValue]) -> Void
    @Environment(\.dismiss) private var dismiss

    init(fields: [PluginFeatureField], values: [String: JSONValue], apply: @escaping ([String: JSONValue]) -> Void) {
        self.fields = fields
        _values = State(initialValue: values)
        self.apply = apply
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(fields) { field in
                    PluginFeatureFieldView(field: field, values: $values)
                }
            }
            .navigationTitle(L10n.text("Text.SortAndFilter"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Text.Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Text.Apply")) { apply(values) }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct PluginAdvancedSearchView: View {
    let plugin: PluginRecord
    @State private var model: PluginComicListModel

    init(plugin: PluginRecord, keyword: String) {
        self.plugin = plugin
        _model = State(initialValue: PluginComicListModel(plugin: plugin, keyword: keyword))
    }

    var body: some View {
        @Bindable var state = model.viewModel
        Form {
            if state.loaded {
                Section(L10n.text("AdvancedSearch.Filters")) {
                    TextField(L10n.text("AdvancedSearch.Keyword"), text: $state.keyword)
                    ForEach(state.fields) { field in
                        PluginFeatureFieldView(field: field, values: $state.values)
                    }
                    Button(L10n.text("AdvancedSearch.Search"), systemImage: "magnifyingglass") { Task { await model.search() } }
                }
                .disabled(state.isLoading)
            }
            if !state.loaded || state.matchesSubmittedSearch {
                PluginFeatureResults(model: model, pluginID: plugin.uuid)
            }
        }
        .navigationTitle(L10n.text("AdvancedSearch.Title"))
        .task { if !state.loaded { await model.load() } }
    }
}

private struct PluginFeatureResults: View {
    let model: PluginComicListModel
    let pluginID: String

    var body: some View {
        let state = model.viewModel
        ForEach(state.comics) { comic in
            NavigationLink {
                ComicDetailView(sourceID: pluginID, summary: comic)
            } label: {
                HStack(spacing: 12) {
                    ComicCover(url: comic.coverURL).frame(width: 42)
                    VStack(alignment: .leading) {
                        Text(comic.title)
                        if !comic.author.isEmpty { Text(comic.author).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        if state.isLoading {
            ProgressView().frame(maxWidth: .infinity)
        } else if let error = state.error {
            RetryView(title: L10n.text("Text.LoadFailed"), message: error) {
                Task { await model.retry() }
            }
        } else if state.hasMore {
            Button(L10n.text("Pagination.LoadMore")) { Task { await model.fetch() } }
        } else if state.searched && state.comics.isEmpty {
            ContentUnavailableView(L10n.text("Text.NoComics"), systemImage: "books.vertical")
        }
    }
}

struct PluginComicActionsView: View {
    let plugin: PluginRecord
    let comicID: String
    let state: PluginComicActionState?
    @State private var model: PluginComicActionsModel
    @State private var shownPrompt: PluginFavoritePrompt?
    @State private var promptAnswer: JSONValue?
    @State private var showingComments = false

    init(plugin: PluginRecord, comicID: String, state: PluginComicActionState? = nil) {
        self.plugin = plugin
        self.comicID = comicID
        self.state = state
        _model = State(initialValue: PluginComicActionsModel(plugin: plugin, comicID: comicID, state: state))
    }

    var body: some View {
        @Bindable var viewModel = model.viewModel
        HStack(spacing: 0) {
            if let state = viewModel.state {
                if state.allowCollected {
                    Button {
                        Task { await model.favorite() }
                    } label: {
                        VStack(spacing: 4) {
                            Label(state.favorited ? L10n.text("Text.Bookmarked") : L10n.text("Text.Bookmark"),
                                  systemImage: state.favorited ? "star.fill" : "star")
                            Text(L10n.text("Text.Separator")).font(.caption).hidden().accessibilityHidden(true)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(viewModel.isWorking)
                }
                if state.allowCollected && (state.allowLike || state.allowComments) { Divider().frame(height: 28) }
                if state.allowLike {
                    Button {
                        Task { await model.like() }
                    } label: {
                        VStack(spacing: 4) {
                            Label(state.liked ? L10n.text("ComicActions.Liked") : L10n.text("ComicActions.Like"),
                                  systemImage: state.liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            Text(state.totalLikes.map { $0.formatted() } ?? "—")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .disabled(viewModel.isWorking)
                }
                if state.allowLike && state.allowComments { Divider().frame(height: 28) }
                if state.allowComments {
                    Button { showingComments = true } label: {
                        VStack(spacing: 4) {
                            Label(L10n.text("ComicActions.Comments"), systemImage: "bubble")
                            Text(state.totalComments.map { $0.formatted() } ?? "—")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                }
            } else if let error = viewModel.error {
                RetryView(title: L10n.text("ComicActions.LoadFailed"), message: error) { Task { await model.load() } }
            }
        }
        .labelStyle(CompactActionLabelStyle())
        .buttonStyle(.borderless)
        .sheet(isPresented: $showingComments) {
            NavigationStack {
                PluginCommentsView(plugin: plugin, comicID: comicID)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.text("Text.Done")) { showingComments = false } } }
            }
            .modifier(AppLockShield())
        }
        .task { await model.load() }
        .onChange(of: state) { _, state in model.updateSourceState(state) }
        .onChange(of: viewModel.prompt?.id) { _, _ in shownPrompt = viewModel.prompt }
        .sheet(item: $shownPrompt, onDismiss: {
            if let prompt = viewModel.prompt {
                let answer = promptAnswer ?? .object(["cancelled": .bool(true)])
                promptAnswer = nil
                Task { await model.answer(prompt, input: answer) }
            }
        }) { prompt in
            PluginFavoritePromptView(prompt: prompt) { input in
                promptAnswer = input
                shownPrompt = nil
            }
            .interactiveDismissDisabled()
            .modifier(AppLockShield())
        }
        .modifier(ErrorAlert(error: Binding(
            get: { viewModel.state != nil ? viewModel.error : nil },
            set: { viewModel.error = $0 }
        )))
    }
}

struct PluginCommentsView: View {
    @State private var model: PluginCommentsModel

    init(plugin: PluginRecord, comicID: String, parent: PluginComment? = nil, embedded: Bool = false, canReply: Bool = false) {
        _model = State(initialValue: PluginCommentsModel(plugin: plugin, comicID: comicID,
                                                        parent: parent, embedded: embedded, canReply: canReply))
    }

    var body: some View {
        @Bindable var state = model.viewModel
        List {
            if state.canPost {
                Section {
                    TextField(L10n.text("Comments.WritePrompt"), text: $state.draft, axis: .vertical)
                        .lineLimit(2...5)
                    Button(L10n.text("Comments.Post"), systemImage: "paperplane") { Task { await model.post() } }
                        .disabled(!state.canSend)
                }
            }
            if let parent = model.parent {
                Section { comment(parent) }
            }
            ForEach(state.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    comment(item)
                    if model.parent == nil && (item.replyCount > 0 || !item.replies.isEmpty || state.canReply) {
                        NavigationLink {
                            PluginCommentsView(plugin: model.plugin, comicID: model.comicID, parent: item,
                                               embedded: state.embedsReplies, canReply: state.canReply)
                        } label: {
                            if item.replyCount > 0 { Text(L10n.resource("Comments.ReplyCount", defaultValue: "\(item.replyCount) 条回复")) }
                            else { Text(L10n.text("Comments.Reply")) }
                        }
                    }
                }
            }
            if state.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error = state.error {
                RetryView(title: L10n.text("Comments.ActionFailed"), message: error) {
                    Task { await model.fetch(reset: true) }
                }
            } else if state.hasMore {
                Button(L10n.text("Comments.LoadMore")) { Task { await model.fetch() } }
            } else if state.items.isEmpty {
                ContentUnavailableView(L10n.text("Comments.EmptyTitle"), systemImage: "bubble")
            }
        }
        .navigationTitle(model.parent == nil ? L10n.text("Comments.Title") : L10n.text("Comments.Reply"))
        .task { if state.items.isEmpty { await model.fetch() } }
        .refreshable { await model.fetch(reset: true) }
    }

    private func comment(_ item: PluginComment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.author.isEmpty ? L10n.text("Comments.Anonymous") : item.author).font(.headline)
            Text(item.content)
            if !item.createdAt.isEmpty { Text(item.createdAt).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct PluginFeatureFieldView: View {
    let field: PluginFeatureField
    @Binding var values: [String: JSONValue]

    var body: some View {
        switch field.kind {
        case "switch", "confirm":
            Toggle(field.label, isOn: Binding(
                get: { values[field.id]?.bool ?? false },
                set: { values[field.id] = .bool($0) }
            ))
        case "multiChoice":
            Section(field.label) {
                ForEach(field.options) { option in
                    Toggle(option.label, isOn: Binding(
                        get: { selection.contains(option.id) },
                        set: { selected in
                            var next = selection.filter { $0 != option.id }
                            if selected { next.append(option.id) }
                            values[field.id] = .array(next)
                        }
                    ))
                }
            }
        case "choice", "select":
            Picker(field.label, selection: Binding(
                get: { values[field.id] ?? .null },
                set: { values[field.id] = $0 }
            )) {
                Text(L10n.text("PluginField.SelectOption")).tag(JSONValue.null)
                ForEach(field.options) { option in Text(option.label).tag(option.id) }
            }
        case "password":
            SecureField(field.label, text: text)
        case "number":
            TextField(field.label, text: text).keyboardType(.decimalPad)
        default:
            TextField(field.label, text: text)
        }
    }

    private var text: Binding<String> {
        Binding(
            get: { values[field.id]?.string ?? "" },
            set: { values[field.id] = .string($0) }
        )
    }

    private var selection: [JSONValue] {
        guard let value = values[field.id] else { return [] }
        if case .object(let map) = value {
            return map.filter { $0.value.bool }.keys.sorted().map(JSONValue.string)
        }
        return value.array
    }
}

private struct PluginFavoritePromptView: View {
    let prompt: PluginFavoritePrompt
    let submit: (JSONValue) -> Void
    @State private var values: [String: JSONValue] = [:]
    @State private var created = ""

    private var type: String { prompt.payload["type"].string }
    private var fields: [PluginFeatureField] {
        if type == "form" {
            return prompt.payload["fields"].array.map { PluginFeatureField($0, kindKey: "type") }
        }
        let kind = type == "select" ? (prompt.payload["selection"].string == "multiple" ? "multiChoice" : "choice") : "text"
        return [PluginFeatureField(id: "value", label: prompt.payload["key"].string.isEmpty ? L10n.text("Text.Value") : prompt.payload["key"].string,
                                   kind: kind, options: prompt.payload["options"].array.map(PluginChoice.init),
                                   required: prompt.payload["required"] != .bool(false))]
    }

    var body: some View {
        NavigationStack {
            Form {
                let description = prompt.payload["description"].string
                if !description.isEmpty { Text(description) }
                if type != "confirm" {
                    ForEach(fields) { field in
                        PluginFeatureFieldView(field: field, values: $values)
                    }
                }
                if prompt.payload["allowCreate"].bool {
                    let label = prompt.payload["createField"]["label"].string
                    TextField(label.isEmpty ? L10n.text("CloudFavorites.NewFolderName") : label, text: $created)
                }
            }
            .navigationTitle(prompt.payload["title"].string.isEmpty ? L10n.text("CloudFavorites.PromptTitle") : prompt.payload["title"].string)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Text.Cancel")) { submit(.object(["cancelled": .bool(true)])) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.text("Text.Confirm")) { submit(response) }
                        .disabled(type != "confirm" && !fields.allSatisfy(isValid))
                }
            }
            .onAppear {
                for field in fields where !field.defaultValue.isNull { values[field.id] = field.defaultValue }
                let selection = prompt.payload["options"].array.filter { $0["selected"].bool }.map { PluginChoice($0).id }
                if let first = selection.first {
                    values["value"] = fields.first?.kind == "multiChoice" ? .array(selection) : first
                }
            }
        }
    }

    private func isValid(_ field: PluginFeatureField) -> Bool {
        guard field.required else { return true }
        if type == "select" && !created.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        let value = values[field.id] ?? .null
        switch value {
        case .null: return false
        case .string(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .array(let items): return !items.isEmpty
        case .bool(let flag): return flag
        default: return true
        }
    }

    private var response: JSONValue {
        if type == "form" { return .object(["values": .object(values)]) }
        var input: [String: JSONValue] = ["value": type == "confirm" ? .bool(true) : (values["value"] ?? .null)]
        let key = prompt.payload["key"].string
        if !key.isEmpty { input["key"] = .string(key) }
        let name = created.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { input["created"] = .string(name) }
        return .object(input)
    }
}
