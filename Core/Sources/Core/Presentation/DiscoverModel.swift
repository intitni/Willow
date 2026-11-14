import BreezePlugins
import CoreStorage
import Foundation
import Observation

@MainActor
@Observable
final class DiscoverViewModel {
    fileprivate(set) var selectedPluginID: String?
    fileprivate(set) var query = ""
    fileprivate(set) var sections: [HomeSection] = []
    fileprivate(set) var tabs: [PluginHomeTab] = []
    fileprivate(set) var results: [ComicSummary] = []
    fileprivate(set) var hasMore = false
    fileprivate(set) var loading = false
    fileprivate(set) var error: String?
    fileprivate var refreshID = 0
    fileprivate(set) var displayedRequest: DiscoverModel.Request?
}

@MainActor
final class DiscoverModel {
    struct Request: Hashable {
        let pluginID: String?
        let pluginVersion: String?
        let query: String
        let refreshID: Int
    }

    private static let selectedPluginKey = "discover.selectedPluginID"
    private let defaults: UserDefaults
    let viewModel = DiscoverViewModel()
    private var page = 1
    private var operation = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reloadSelection()
    }

    func reloadSelection() {
        viewModel.selectedPluginID = defaults.string(forKey: Self.selectedPluginKey)
    }

    func selectPlugin(_ id: String) {
        defaults.set(id, forKey: Self.selectedPluginKey)
        viewModel.selectedPluginID = id
    }

    func activePlugin(in plugins: [PluginRecord]) -> PluginRecord? {
        plugins.first { $0.uuid == viewModel.selectedPluginID } ?? plugins.first
    }

    func request(for plugin: PluginRecord?) -> Request {
        Request(pluginID: plugin?.uuid, pluginVersion: plugin?.version,
                query: viewModel.query, refreshID: viewModel.refreshID)
    }

    func submit(_ text: String) {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if viewModel.query == query {
            viewModel.refreshID += 1
        } else {
            viewModel.query = query
        }
    }

    func clearSearch() {
        viewModel.query = ""
    }

    func loadMoreOrRetry(plugin: PluginRecord, request: Request) {
        guard viewModel.displayedRequest == request else { return }
        if viewModel.results.isEmpty {
            viewModel.refreshID += 1
        } else {
            Task { await loadMore(plugin: plugin, request: request) }
        }
    }

    func loadInitial(plugin: PluginRecord?, request: Request) async {
        guard request == self.request(for: plugin), !Task.isCancelled else { return }
        let operation = beginOperation()
        viewModel.displayedRequest = request
        viewModel.sections = []
        viewModel.tabs = []
        viewModel.results = []
        viewModel.hasMore = false
        viewModel.error = nil
        page = 1
        guard let plugin else {
            viewModel.loading = false
            return
        }
        viewModel.loading = true
        defer { finishOperation(operation) }
        do {
            if request.query.isEmpty {
                let home = try await PluginService.shared.homeTabs(plugin: plugin)
                guard isCurrent(operation, request: request, plugin: plugin) else { return }
                viewModel.tabs = home
            } else {
                let result = try await PluginService.shared.search(plugin: plugin, query: request.query, page: 1)
                guard isCurrent(operation, request: request, plugin: plugin) else { return }
                viewModel.results = result.comics
                viewModel.hasMore = result.hasMore
            }
        } catch {
            if isCurrent(operation, request: request, plugin: plugin) {
                viewModel.error = error.localizedDescription
            }
        }
    }

    private func loadMore(plugin: PluginRecord, request: Request) async {
        guard !viewModel.loading, viewModel.hasMore, viewModel.displayedRequest == request,
              self.request(for: plugin) == request else { return }
        let operation = beginOperation()
        viewModel.loading = true
        viewModel.error = nil
        defer { finishOperation(operation) }
        do {
            let result = try await PluginService.shared.search(plugin: plugin, query: request.query, page: page + 1)
            guard isCurrent(operation, request: request, plugin: plugin) else { return }
            var identifiers = Set(viewModel.results.map(\.id))
            viewModel.results += result.comics.filter { identifiers.insert($0.id).inserted }
            viewModel.hasMore = result.hasMore
            page += 1
        } catch {
            if isCurrent(operation, request: request, plugin: plugin) {
                viewModel.error = error.localizedDescription
            }
        }
    }

    private func beginOperation() -> UUID {
        operation = UUID()
        return operation
    }

    private func finishOperation(_ operation: UUID) {
        if operation == self.operation { viewModel.loading = false }
    }

    private func isCurrent(_ operation: UUID, request: Request, plugin: PluginRecord) -> Bool {
        !Task.isCancelled && operation == self.operation && request == self.request(for: plugin)
    }
}
