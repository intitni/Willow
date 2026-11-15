import CoreToast
import CoreStorage
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct PluginManagementView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.hiddenNSFWSources) private var hiddenSources
    @Query(sort: \PluginRecord.name) private var plugins: [PluginRecord]
    @Query(sort: \SubscriptionRecord.name) private var subscriptions: [SubscriptionRecord]
    @State private var model = PluginManagementModel()
    @State private var showingSubscriptionPrompt = false
    @State private var showingInstallPrompt = false
    @State private var showingImporter = false
    @State private var uninstalling: PluginRecord?
    @State private var removingSubscription: SubscriptionRecord?
    @State private var progressToast: Toast.ID?
    @State private var toastScope = UUID()

    var body: some View {
        @Bindable var viewModel = model.viewModel
        let visiblePlugins = plugins.filter { !hiddenSources.contains($0.uuid) }
        List {
            Section(L10n.text("PluginManagement.Installed")) {
                if visiblePlugins.isEmpty {
                    Text(L10n.text("PluginManagement.EmptyPlugins")).foregroundStyle(.secondary)
                }
                ForEach(visiblePlugins, id: \.uuid) { plugin in
                    NavigationLink {
                        InstalledPluginView(plugin: plugin)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(plugin.name)
                            HStack {
                                Text(plugin.version)
                                if !plugin.enabled { Text(L10n.text("PluginManagement.Disabled")) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(L10n.text("PluginManagement.Uninstall"), systemImage: "trash", role: .destructive) {
                            uninstalling = plugin
                        }
                    }
                }
            }

            Section(L10n.text("PluginManagement.Subscriptions")) {
                if subscriptions.isEmpty {
                    Text(L10n.text("PluginManagement.EmptySubscriptions")).foregroundStyle(.secondary)
                }
                ForEach(subscriptions, id: \.url) { subscription in
                    NavigationLink {
                        SubscriptionView(subscription: subscription)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(subscription.name)
                            Text(subscription.url).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button(L10n.text("Text.Remove"), systemImage: "trash", role: .destructive) {
                            removingSubscription = subscription
                        }
                    }
                }
            }
        }
        .navigationTitle(L10n.text("PluginManagement.Title"))
        .toolbar {
            Menu(L10n.text("Text.Add"), systemImage: "plus") {
                if model.canAddDefaultSubscription(subscriptions) {
                    Button(L10n.text("PluginManagement.AddBreezePluginDirectory"), systemImage: "list.bullet.rectangle") {
                        model.addDefaultSubscription(context: context)
                    }
                }
                Button(L10n.text("PluginManagement.AddSubscription"), systemImage: "list.bullet") {
                    viewModel.address = ""
                    showingSubscriptionPrompt = true
                }
                Button(L10n.text("PluginManagement.InstallFromLink"), systemImage: "link") {
                    viewModel.address = ""
                    showingInstallPrompt = true
                }
                Button(L10n.text("PluginManagement.ImportPluginFile"), systemImage: "doc.badge.plus") {
                    showingImporter = true
                }
            }
            .disabled(viewModel.working)
        }
        .overlay(alignment: .top) { ToastHost(scope: toastScope) }
        .task(id: viewModel.working) {
            let working = viewModel.working
            await Task.yield()
            guard !Task.isCancelled else { return }
            if let progressToast { Toast.hide(progressToast); self.progressToast = nil }
            if working { progressToast = Toast.info(L10n.text("PluginManagement.Working"), duration: nil, scope: toastScope) }
        }
        .onDisappear {
            if let progressToast { Toast.hide(progressToast); self.progressToast = nil }
        }
        .alert(L10n.text("PluginManagement.AddSubscription"), isPresented: $showingSubscriptionPrompt) {
            PluginAddressField(address: $viewModel.address)
            Button(L10n.text("Text.Add")) { model.addSubscription(context: context) }
            Button(L10n.text("Text.Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("PluginManagement.SubscriptionURLPrompt"))
        }
        .alert(L10n.text("PluginManagement.InstallFromLink"), isPresented: $showingInstallPrompt) {
            PluginAddressField(address: $viewModel.address)
            Button(L10n.text("PluginManagement.Install")) { model.install(context: context) }
            Button(L10n.text("Text.Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("PluginManagement.InstallURLPrompt"))
        }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [
            UTType(filenameExtension: "cjs") ?? .data,
            UTType(filenameExtension: "br") ?? .data,
            UTType(filenameExtension: "js") ?? .data
        ]) { result in
            model.importPlugin(result, context: context)
        }
        .alert(L10n.text("PluginManagement.UninstallTitle"), isPresented: Binding(
            get: { uninstalling != nil },
            set: { if !$0 { uninstalling = nil } }
        ), presenting: uninstalling) { plugin in
            Button(L10n.text("PluginManagement.UninstallNamedPlugin", defaultValue: "卸载 \(plugin.name)"), role: .destructive) {
                model.uninstall(plugin, context: context)
            }
            Button(L10n.text("Text.Cancel"), role: .cancel) {}
        }
        .confirmationDialog(L10n.text("PluginManagement.RemoveSubscriptionTitle"), isPresented: Binding(
            get: { removingSubscription != nil },
            set: { if !$0 { removingSubscription = nil } }
        ), titleVisibility: .visible, presenting: removingSubscription) { subscription in
            Button(L10n.text("PluginManagement.RemoveNamedSubscription", defaultValue: "移除 \(subscription.name)"), role: .destructive) {
                model.remove(subscription, context: context)
            }
        }
        .modifier(ErrorAlert(error: $viewModel.error))
    }
}

private struct PluginAddressField: View {
    @Binding var address: String

    var body: some View {
        TextField(L10n.text("PluginManagement.URLPlaceholder"), text: $address)
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
    }
}

private struct InstalledPluginView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.hiddenNSFWSources) private var hiddenSources
    @Environment(\.dismiss) private var dismiss
    @Query private var ratings: [PluginContentRating]
    @State private var model: InstalledPluginModel
    private let sourceID: String
    @State private var editingField: InstalledPluginModel.Field?
    @State private var editedValue = ""

    init(plugin: PluginRecord) {
        _model = State(initialValue: InstalledPluginModel(plugin: plugin))
        let id = plugin.uuid
        sourceID = id
        _ratings = Query(filter: #Predicate<PluginContentRating> { $0.sourceID == id })
    }

    var body: some View {
        let hidden = hiddenSources.contains(sourceID)
        Group {
            if !hidden { settings }
        }
        .onChange(of: hidden) { _, hidden in
            if hidden { dismiss() }
        }
    }

    @ViewBuilder private var settings: some View {
        @Bindable var viewModel = model.viewModel
        Form {
            Section(L10n.text("PluginSettings.Information")) {
                LabeledContent(L10n.text("Text.Version"), value: viewModel.version)
                if let subscriptionURL = viewModel.subscriptionURL {
                    LabeledContent(L10n.text("PluginManagement.Subscriptions"), value: subscriptionURL)
                }
                Toggle(L10n.text("PluginSettings.Enable"), isOn: Binding(
                    get: { viewModel.enabled },
                    set: { model.setEnabled($0, context: context) }
                ))
                Toggle(L10n.text("PluginSettings.NSFW"), isOn: Binding(
                    get: { ratings.first?.isNSFW ?? false },
                    set: { model.setNSFW($0, context: context) }
                ))
            }

            if viewModel.enabled {
                Section(L10n.text("PluginSettings.Title")) {
                    if viewModel.loading {
                        ProgressView(L10n.text("PluginSettings.Loading"))
                    } else if let fields = viewModel.fields {
                        if fields.isEmpty && !viewModel.canLogin {
                            Text(L10n.text("PluginSettings.NoEditableSettings")).foregroundStyle(.secondary)
                        }
                        ForEach(fields) { field in
                            settingRow(field)
                        }
                        if viewModel.canLogin {
                            Button(L10n.text("PluginSettings.SignIn"), systemImage: "person.crop.circle", action: model.openLogin)
                                .disabled(viewModel.working)
                        }
                    } else {
                        Button(L10n.text("PluginSettings.RetryLoading")) { Task { await model.loadSettings() } }
                    }
                }
            }
        }
        .navigationTitle(viewModel.name)
        .task(id: viewModel.enabled) {
            await model.loadSettings()
        }
        .alert(editingField?.title ?? L10n.text("PluginSettings.EditSetting"), isPresented: Binding(
            get: { editingField != nil },
            set: { if !$0 { editingField = nil } }
        ), presenting: editingField) { field in
            if case .password = field.kind {
                SecureField(L10n.text("PluginSettings.Password"), text: $editedValue)
            } else {
                TextField(L10n.text("Text.Value"), text: $editedValue)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Button(L10n.text("Text.Save")) { model.saveSetting(id: field.id, value: editedValue) }
            Button(L10n.text("Text.Cancel"), role: .cancel) {}
        }
        .sheet(isPresented: Binding(
            get: { viewModel.showingLogin },
            set: { if !$0 { model.closeLogin() } }
        ), onDismiss: {
            Task { await model.loadSettings() }
        }) {
            if let loginModel = model.loginModel {
                PluginLoginView(model: loginModel)
                    .modifier(AppLockShield())
            }
        }
        .modifier(ErrorAlert(error: $viewModel.error))
    }

    @ViewBuilder private func settingRow(_ field: InstalledPluginModel.Field) -> some View {
        switch field.kind {
        case .toggle(let enabled):
            Toggle(field.title, isOn: Binding(
                get: { enabled },
                set: { model.saveToggle(id: field.id, enabled: $0) }
            ))
            .disabled(model.viewModel.working)
        case .text(let value):
            editButton(field, value: value)
        case .password:
            editButton(field, value: "")
        case .unsupported:
            LabeledContent(field.title) { Text(L10n.text("PluginSettings.UnsupportedSetting")) }
        }
    }

    private func editButton(_ field: InstalledPluginModel.Field, value: String) -> some View {
        Button {
            editedValue = value
            editingField = field
        } label: {
            LabeledContent(field.title, value: value)
        }
        .disabled(model.viewModel.working)
    }
}

private struct PluginLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let model: PluginLoginModel

    var body: some View {
        @Bindable var viewModel = model.viewModel
        NavigationStack {
            Form {
                ForEach(viewModel.fields) { field in
                    if field.isPassword {
                        SecureField(field.title, text: $viewModel[field: field.id])
                            .textContentType(.password)
                    } else {
                        TextField(field.title, text: $viewModel[field: field.id])
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                if viewModel.submitting { ProgressView() }
            }
            .navigationTitle(viewModel.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Text.Cancel")) { dismiss() }
                        .disabled(viewModel.submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.submitTitle) {
                        Task {
                            if await model.submit() { dismiss() }
                        }
                    }
                    .disabled(viewModel.submitting)
                }
            }
        }
        .interactiveDismissDisabled(viewModel.submitting)
        .modifier(ErrorAlert(error: $viewModel.error))
    }
}

private struct SubscriptionView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.hiddenNSFWSources) private var hiddenSources
    @Query private var installedPlugins: [PluginRecord]
    @State private var model: SubscriptionModel

    init(subscription: SubscriptionRecord) {
        _model = State(initialValue: SubscriptionModel(subscription: subscription))
    }

    var body: some View {
        @Bindable var viewModel = model.viewModel
        let rows = viewModel.rows.filter { !hiddenSources.contains($0.id) }
        Group {
            if viewModel.loading && rows.isEmpty {
                ProgressView(L10n.text("Subscription.Loading"))
            } else if let error = viewModel.loadError, rows.isEmpty {
                RetryView(title: L10n.text("Subscription.LoadFailed"), message: error) {
                    Task { await model.reload(refresh: true, context: context) }
                }
            } else if rows.isEmpty {
                ContentUnavailableView(L10n.text("Subscription.EmptyTitle"), systemImage: "puzzlepiece.extension")
            } else {
                List {
                    if let error = viewModel.loadError {
                        Section { Text(error).foregroundStyle(.secondary) }
                    }
                    ForEach(rows) { row in
                        SubscriptionPluginRow(row: row, installing: viewModel.installing.contains(row.id)) {
                            Task { await model.install(id: row.id, context: context) }
                        }
                    }
                }
            }
        }
        .navigationTitle(viewModel.name)
        .toolbar {
            Button(L10n.text("Subscription.Refresh"), systemImage: "arrow.clockwise") {
                Task { await model.reload(refresh: true, context: context) }
            }
            .disabled(viewModel.loading)
        }
        .onChange(of: model.installedVersions(installedPlugins), initial: true) { _, versions in
            model.updateInstalledVersions(versions)
        }
        .task { await model.reload(refresh: false, context: context) }
        .refreshable { await model.reload(refresh: true, context: context) }
        .modifier(ErrorAlert(error: $viewModel.installError))
    }
}

private struct SubscriptionPluginRow: View {
    let row: SubscriptionModel.Row
    let installing: Bool
    let install: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(row.name).font(.headline)
            Text(row.version).font(.caption).foregroundStyle(.secondary)
            if !row.description.isEmpty {
                Text(row.description).font(.subheadline)
            }
            if installing {
                ProgressView(L10n.text("Subscription.Installing"))
            } else if row.status == .installed {
                Label(L10n.text("PluginManagement.Installed"), systemImage: "checkmark.circle").font(.caption)
            } else {
                Button(row.status == .install ? L10n.text("PluginManagement.Install") : L10n.text("Subscription.Update"), action: install)
                    .buttonStyle(.glass)
                    .disabled(!row.canDownload)
            }
        }
        .padding(.vertical, 4)
    }
}
