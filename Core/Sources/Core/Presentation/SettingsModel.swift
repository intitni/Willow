import CoreStorage
import Foundation
import Observation

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

struct AboutViewModel {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    let revision = "d4888c8d4eaa866a526bd29b90564f6c60b86be3"
    private let repository = URL(string: "https://github.com/breeze-project-org/Breeze")!
    var upstream: URL { repository.appending(path: "tree/\(revision)") }

    var license: URL { repository.appending(path: "blob/\(revision)/LICENSE") }
}
