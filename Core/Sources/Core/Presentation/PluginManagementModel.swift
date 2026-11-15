import BreezePlugins
import CoreStorage
import Foundation
import Observation
import SwiftData

@MainActor
final class PluginManagementModel {
    @MainActor
    @Observable
    final class ViewModel {
        var address = ""
        var error: String?
        fileprivate(set) var working = false
    }

    let viewModel = ViewModel()

    func canAddDefaultSubscription(_ subscriptions: [SubscriptionRecord]) -> Bool {
        !subscriptions.contains { $0.url == PluginService.defaultSubscriptionURL.absoluteString }
    }

    func addDefaultSubscription(context: ModelContext) {
        perform {
            try await PluginService.shared.addSubscription(url: PluginService.defaultSubscriptionURL, context: context)
        }
    }

    func addSubscription(context: ModelContext) {
        submitAddress { url in
            try await PluginService.shared.addSubscription(url: url, context: context)
        }
    }

    func install(context: ModelContext) {
        submitAddress { url in
            try await PluginService.shared.install(url: url, context: context)
        }
    }

    func importPlugin(_ result: Result<URL, Error>, context: ModelContext) {
        perform {
            try await PluginService.shared.install(url: result.get(), context: context)
        }
    }

    func uninstall(_ plugin: PluginRecord, context: ModelContext) {
        perform {
            try await PluginService.shared.uninstall(plugin: plugin, context: context)
        }
    }

    func remove(_ subscription: SubscriptionRecord, context: ModelContext) {
        perform {
            context.delete(subscription)
            try context.save()
        }
    }

    private func submitAddress(_ operation: @escaping (URL) async throws -> Void) {
        let input = viewModel.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: input), url.scheme == "https", url.host != nil else {
            viewModel.error = L10n.text("PluginManagement.InvalidURL")
            return
        }
        perform { try await operation(url) }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !viewModel.working else { return }
        viewModel.working = true
        Task {
            defer { viewModel.working = false }
            do { try await operation() }
            catch { viewModel.error = error.localizedDescription }
        }
    }
}

@MainActor
final class InstalledPluginModel {
    struct Field: Identifiable {
        enum Kind {
            case toggle(Bool)
            case text(String)
            case password
            case unsupported
        }

        let id: String
        let title: String
        let kind: Kind

        init(_ setting: PluginSetting) {
            id = setting.id
            title = setting.title
            switch setting.kind {
            case "switch": kind = .toggle(setting.value == "true")
            case "text": kind = .text(setting.value)
            case "password": kind = .password
            default: kind = .unsupported
            }
        }
    }

    @MainActor
    @Observable
    final class ViewModel {
        private let plugin: PluginRecord

        var name: String { plugin.name }
        var version: String { plugin.version }
        var subscriptionURL: String? { plugin.subscriptionURL }
        var enabled: Bool { plugin.enabled }
        var error: String?
        fileprivate(set) var fields: [Field]?
        fileprivate(set) var canLogin = false
        fileprivate(set) var loading = false
        fileprivate(set) var working = false
        fileprivate(set) var showingLogin = false

        init(plugin: PluginRecord) { self.plugin = plugin }
    }

    private let plugin: PluginRecord
    private var settings: PluginSettings?
    private(set) var loginModel: PluginLoginModel?
    let viewModel: ViewModel

    init(plugin: PluginRecord) {
        self.plugin = plugin
        viewModel = ViewModel(plugin: plugin)
    }

    func setEnabled(_ enabled: Bool, context: ModelContext) {
        perform {
            try await PluginService.shared.setEnabled(enabled, plugin: self.plugin, context: context)
            if !enabled { self.closeLogin() }
        }
    }

    func setNSFW(_ isNSFW: Bool, context: ModelContext) {
        let id = plugin.uuid
        do {
            let rating = try context.fetch(FetchDescriptor<PluginContentRating>(
                predicate: #Predicate { $0.sourceID == id }
            )).first
            if let rating {
                guard rating.isNSFW != isNSFW else { return }
                rating.isNSFW = isNSFW
                rating.updatedAt = .now
            } else {
                context.insert(PluginContentRating(sourceID: id, isNSFW: isNSFW))
            }
            try context.save()
        } catch {
            context.rollback()
            viewModel.error = error.localizedDescription
        }
    }

    func saveSetting(id: String, value: String) {
        guard let setting = settings?.fields.first(where: { $0.id == id }) else { return }
        perform {
            try await PluginService.shared.saveSetting(plugin: self.plugin, setting: setting, value: value)
            await self.loadSettings()
        }
    }

    func saveToggle(id: String, enabled: Bool) {
        saveSetting(id: id, value: enabled ? "true" : "false")
    }

    func openLogin() {
        perform {
            let form = try await PluginService.shared.loginForm(plugin: self.plugin)
            guard self.plugin.enabled else { return }
            self.loginModel = PluginLoginModel(plugin: self.plugin, form: form)
            self.viewModel.showingLogin = true
        }
    }

    func closeLogin() {
        viewModel.showingLogin = false
        loginModel = nil
    }

    func loadSettings() async {
        guard plugin.enabled else { return }
        viewModel.loading = true
        defer { viewModel.loading = false }
        do {
            let settings = try await PluginService.shared.settings(plugin: plugin)
            guard !Task.isCancelled, plugin.enabled else { return }
            self.settings = settings
            viewModel.fields = settings.fields.map(Field.init)
            viewModel.canLogin = settings.canLogin
        } catch {
            if !Task.isCancelled {
                viewModel.fields = nil
                viewModel.canLogin = false
                viewModel.error = error.localizedDescription
            }
        }
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        guard !viewModel.working else { return }
        viewModel.working = true
        Task {
            defer { viewModel.working = false }
            do { try await operation() }
            catch { viewModel.error = error.localizedDescription }
        }
    }
}

@MainActor
final class PluginLoginModel {
    struct Field: Identifiable {
        let id: String
        let title: String
        let isPassword: Bool
    }

    @MainActor
    @Observable
    final class ViewModel {
        let title: String
        let submitTitle: String
        let fields: [Field]
        private var values: [String: String]
        var error: String?
        fileprivate(set) var submitting = false

        init(form: PluginLoginForm) {
            title = form.title.isEmpty ? L10n.text("PluginSettings.SignIn") : form.title
            submitTitle = form.submitTitle.isEmpty ? L10n.text("PluginSettings.SignIn") : form.submitTitle
            fields = form.fields.map {
                Field(id: $0.id, title: $0.title, isPassword: $0.kind == "password")
            }
            values = form.fields.reduce(into: [:]) { values, field in
                values[field.id] = field.kind == "password" ? "" : field.value
            }
        }

        subscript(field id: String) -> String {
            get { values[id, default: ""] }
            set { values[id] = newValue }
        }

        fileprivate var submittedValues: [String: String] { values }
    }

    private let plugin: PluginRecord
    let viewModel: ViewModel

    init(plugin: PluginRecord, form: PluginLoginForm) {
        self.plugin = plugin
        viewModel = ViewModel(form: form)
    }

    func submit() async -> Bool {
        guard !viewModel.submitting else { return false }
        viewModel.submitting = true
        defer { viewModel.submitting = false }
        do {
            try await PluginService.shared.submitLogin(plugin: plugin, values: viewModel.submittedValues)
            return true
        } catch {
            viewModel.error = error.localizedDescription
            return false
        }
    }
}

@MainActor
final class SubscriptionModel {
    struct Row: Identifiable, Equatable {
        enum Status: Equatable {
            case installed, install, update
        }

        let id: String
        let name: String
        let version: String
        let description: String
        let status: Status
        let canDownload: Bool

        init(candidate: PluginCandidate, installedVersion: String?) {
            id = candidate.id
            name = candidate.name
            version = candidate.version
            description = candidate.description
            canDownload = candidate.downloadURL != nil || !candidate.npmName.isEmpty
            if installedVersion == candidate.version {
                status = .installed
            } else {
                status = installedVersion == nil ? .install : .update
            }
        }
    }

    @MainActor
    @Observable
    final class ViewModel {
        private let subscription: SubscriptionRecord

        var name: String { subscription.name }
        var installError: String?
        fileprivate(set) var rows: [Row] = []
        fileprivate(set) var installing = Set<String>()
        fileprivate(set) var loading = true
        fileprivate(set) var loadError: String?

        init(subscription: SubscriptionRecord) { self.subscription = subscription }
    }

    private let subscription: SubscriptionRecord
    private var candidates: [PluginCandidate] = []
    private var versions: [String: String] = [:]
    private var reloading = false
    let viewModel: ViewModel

    init(subscription: SubscriptionRecord) {
        self.subscription = subscription
        viewModel = ViewModel(subscription: subscription)
    }

    func installedVersions(_ plugins: [PluginRecord]) -> [String: String] {
        Dictionary(plugins.map { ($0.uuid, $0.version) }, uniquingKeysWith: { first, _ in first })
    }

    func updateInstalledVersions(_ versions: [String: String]) {
        self.versions = versions
        updateRows()
    }

    func reload(refresh: Bool, context: ModelContext) async {
        guard !reloading else { return }
        reloading = true
        viewModel.loading = true
        viewModel.loadError = nil
        defer {
            reloading = false
            viewModel.loading = false
        }
        do {
            if refresh {
                try await PluginService.shared.refresh(subscription: subscription, context: context)
            }
            let candidates = try await PluginService.shared.subscriptionCandidates(subscription: subscription)
            guard !Task.isCancelled else { return }
            self.candidates = candidates
            updateRows()
        } catch {
            if !Task.isCancelled { viewModel.loadError = error.localizedDescription }
        }
    }

    func install(id: String, context: ModelContext) async {
        guard let candidate = candidates.first(where: { $0.id == id }),
              viewModel.installing.insert(id).inserted else { return }
        defer { viewModel.installing.remove(id) }
        do {
            try await PluginService.shared.install(candidate: candidate, context: context)
        } catch {
            viewModel.installError = error.localizedDescription
        }
    }

    private func updateRows() {
        viewModel.rows = candidates.map { Row(candidate: $0, installedVersion: versions[$0.id]) }
    }
}
