import CoreStorage
import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class SyncSettingsModel {
    private static let methodKey = "sync.method"
    private static let folderKey = "sync.driveFolder"

    private let container: ModelContainer
    private let didImportFollowing: @Sendable () async -> Void
    private let setup = DriveSyncSetup()

    private(set) var selection: WillowSyncMethod
    private(set) var activeMethod: WillowSyncMethod
    private(set) var folder: DriveSyncFolder?
    private(set) var worker: PreferenceSyncModel?
    private(set) var events = PreferenceSyncEvents()
    private(set) var isSwitching = false
    private(set) var isReconciling = false

    var error: String? { worker?.viewModel.error }

    init(container: ModelContainer, didImportFollowing: @escaping @Sendable () async -> Void) {
        self.container = container
        self.didImportFollowing = didImportFollowing
        selection = UserDefaults.standard.string(forKey: Self.methodKey).flatMap(WillowSyncMethod.init(rawValue:)) ?? .none
        folder = UserDefaults.standard.data(forKey: Self.folderKey).flatMap { try? JSONDecoder().decode(DriveSyncFolder.self, from: $0) }
        activeMethod = .none
        if selection == .drive, let folder {
            activeMethod = .drive
            worker = PreferenceSyncModel(container: container, folder: folder, didImportFollowing: didImportFollowing)
        }
    }

    func select(_ method: WillowSyncMethod) async {
        guard !isSwitching, method != .drive || folder != nil else { return }
        isSwitching = true
        defer { isSwitching = false }
        await changeSelection(method)
    }

    func inspect(_ url: URL) async throws -> DriveSyncSetup.FolderStatus {
        try Task.checkCancellation()
        guard !isSwitching else { throw CancellationError() }
        isSwitching = true
        defer { isSwitching = false }
        let status = try await setup.inspect(url)
        try Task.checkCancellation()
        if case .connected(let folder) = status {
            try await applyFolder(folder)
        }
        return status
    }

    func connect(to url: URL, recoveryKey: String?) async throws {
        guard !isSwitching else { return }
        isSwitching = true
        defer { isSwitching = false }
        let folder = try await setup.connect(to: url, recoveryKey: recoveryKey)
        try await applyFolder(folder)
    }

    private func applyFolder(_ folder: DriveSyncFolder) async throws {
        UserDefaults.standard.set(try JSONEncoder().encode(folder), forKey: Self.folderKey)
        self.folder = folder
        await changeSelection(.drive)
    }

    func reconcile() async {
        guard let worker, !isSwitching, !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }
        try? await worker.reconcile()
    }

    func recoveryKey() async throws -> String? {
        guard let folder else { return nil }
        return try await setup.recoveryKey(for: folder)
    }

    private func changeSelection(_ method: WillowSyncMethod) async {
        // Background refresh and other windows may still hold the old worker.
        await worker?.stop()
        worker = nil
        activeMethod = .none
        if method == .drive, let folder {
            worker = PreferenceSyncModel(container: container, folder: folder, didImportFollowing: didImportFollowing)
            activeMethod = .drive
        }
        events = PreferenceSyncEvents()

        selection = method
        UserDefaults.standard.set(method.rawValue, forKey: Self.methodKey)
    }
}
