import CoreStorage
import Foundation
import Observation

struct WillowRelease: Decodable, Sendable {
    let tagName: String
    let notes: String?
    let url: URL

    var version: String { String(tagName.dropFirst("version/".count)) }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case notes = "body"
        case url = "html_url"
    }
}

@MainActor
final class SettingsModel {
    private static let readerModeKey = "reader.mode"
    private static let readerSpreadsKey = "reader.spreads"

    @MainActor
    @Observable
    final class ViewModel {
        private let appLock: AppLock
        let syncStatus: LocalizedStringResource
        let syncFailure: String?
        var lockEnabled: Bool { appLock.isEnabled }
        var biometryName: String { appLock.biometryName }

        fileprivate(set) var mode = ReaderMode.vertical
        fileprivate(set) var spreads = true
        fileprivate(set) var updatingLock = false
        var error: String?
        init(appLock: AppLock, persistence: WillowPersistence) {
            self.appLock = appLock
            syncFailure = persistence.syncFailure
            syncStatus = switch persistence.syncStatus {
            case .iCloud: L10n.resource("ICloudSync.Configured")
            case .localOnly: L10n.resource("ICloudSync.OnThisDevice")
            case .inMemory: L10n.resource("ICloudSync.TemporaryStorage")
            }
        }
    }

    private let appLock: AppLock
    let viewModel: ViewModel

    init(appLock: AppLock, persistence: WillowPersistence) {
        self.appLock = appLock
        viewModel = ViewModel(appLock: appLock, persistence: persistence)
        reloadReaderPreferences()
    }

    func reloadReaderPreferences() {
        let defaults = UserDefaults.standard
        viewModel.mode = defaults.string(forKey: Self.readerModeKey).flatMap(ReaderMode.init(rawValue:)) ?? .vertical
        viewModel.spreads = defaults.object(forKey: Self.readerSpreadsKey) as? Bool ?? true
    }

    func setMode(_ mode: ReaderMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.readerModeKey)
        viewModel.mode = mode
    }

    func setSpreads(_ spreads: Bool) {
        UserDefaults.standard.set(spreads, forKey: Self.readerSpreadsKey)
        viewModel.spreads = spreads
    }

    func setAppLock(_ enabled: Bool) {
        guard !viewModel.updatingLock else { return }
        viewModel.updatingLock = true
        Task {
            defer { viewModel.updatingLock = false }
            await appLock.setEnabled(enabled)
            viewModel.error = appLock.errorMessage
        }
    }
}

@MainActor
@Observable
final class UpdateModel {
    let version: String?
    private let fetchRelease: @Sendable () async throws -> WillowRelease?
    private var initialCheckTask: Task<Void, Never>?

    private(set) var latestRelease: WillowRelease?
    private(set) var isCheckingUpdates = false
    private(set) var updateCheckFailed = false
    private(set) var noPublishedRelease = false

    init(
        version: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        fetchRelease: @escaping @Sendable () async throws -> WillowRelease? = UpdateModel.fetchLatestRelease
    ) {
        self.version = version
        self.fetchRelease = fetchRelease
    }

    @discardableResult
    func startInitialCheck() -> Task<Void, Never> {
        if let initialCheckTask { return initialCheckTask }
        let task = Task { await checkForUpdates() }
        initialCheckTask = task
        return task
    }

    var isUpdateAvailable: Bool? {
        guard let latestRelease,
              let currentVersion = version,
              let latest = Self.versionComponents(latestRelease.version),
              let current = Self.versionComponents(currentVersion) else { return nil }
        for (latestPart, currentPart) in zip(latest, current) where latestPart != currentPart {
            return latestPart > currentPart
        }
        return false
    }

    func checkForUpdates() async {
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        updateCheckFailed = false
        defer { isCheckingUpdates = false }

        do {
            let release = try await fetchRelease()
            try Task.checkCancellation()
            if let release {
                guard release.tagName.hasPrefix("version/"),
                      Self.versionComponents(release.tagName) != nil else {
                    throw URLError(.cannotParseResponse)
                }
            }
            latestRelease = release
            noPublishedRelease = release == nil
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled {
                updateCheckFailed = true
            }
        }
    }

    private nonisolated static func fetchLatestRelease() async throws -> WillowRelease? {
        let endpoint = URL(string: "https://api.github.com/repos/intitni/Willow/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Willow iOS App", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(WillowRelease.self, from: data)
    }

    private static func versionComponents(_ version: String) -> [Int]? {
        let value = version.hasPrefix("version/") ? String(version.dropFirst("version/".count)) : version
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts.allSatisfy({ part in part.allSatisfy { $0 >= "0" && $0 <= "9" } }) else { return nil }
        let components = parts.compactMap { Int($0) }
        return components.count == 3 ? components : nil
    }
}

struct AboutViewModel {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let revision = "d4888c8d4eaa866a526bd29b90564f6c60b86be3"
    private let repository = URL(string: "https://github.com/breeze-project-org/Breeze")!
    var upstream: URL { repository.appending(path: "tree/\(revision)") }
    var license: URL { repository.appending(path: "blob/\(revision)/LICENSE") }
}
