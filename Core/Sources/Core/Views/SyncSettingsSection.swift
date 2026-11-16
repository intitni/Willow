import CoreStorage
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SyncSettingsSection: View {
    @Environment(SyncSettingsModel.self) private var model
    @State private var pickingFolder = false
    @State private var folder: SelectedFolder?
    @State private var recoveryFolder: DriveSyncFolder?
    @State private var isReadingRecoveryKey = false
    @Binding var didCopyKey: Bool
    @Binding var error: String?

    var body: some View {
        Section {
            Picker(L10n.text("SyncSettings.Method"), selection: Binding(get: { model.selection }, set: select)) {
                ForEach(WillowSyncMethod.allCases) { method in
                    Text(label(method)).tag(method)
                }
            }
            LabeledContent(L10n.text("SyncSettings.ActiveMethod"), value: label(model.activeMethod))
            if model.selection == .drive {
                if let folder = model.folder {
                    LabeledContent(L10n.text("SyncSettings.Folder"), value: folder.name)
                    Button(action: copyRecoveryKey) {
                        if isReadingRecoveryKey {
                            HStack {
                                ProgressView()
                                Text(L10n.text("SyncSettings.ReadingRecoveryKey"))
                            }
                        } else {
                            Text(L10n.text("SyncSettings.CopyKey"))
                        }
                    }
                    .disabled(isReadingRecoveryKey)
                    Button(L10n.text("SyncSettings.RestoreKey")) { recoveryFolder = folder }
                        .sheet(item: $recoveryFolder) { folder in
                            DriveKeyRecoveryView(folder: folder, model: model)
                                .modifier(AppLockShield())
                        }
                    if model.activeMethod == .drive {
                        Button(L10n.text("SyncSettings.SyncNow")) {
                            Task { await model.reconcile() }
                        }
                        .disabled(model.isReconciling)
                    }
                }
                Button(L10n.text("SyncSettings.ChooseFolder")) { pickingFolder = true }
            }
        } footer: {
            if let failure = model.error {
                Text(failure)
            } else if model.selection == .drive, model.folder == nil {
                Text(L10n.text("SyncSettings.FolderRequired"))
            } else if model.activeMethod == .drive, let date = model.worker?.viewModel.lastReconciledAt {
                Text(L10n.resource("SyncSettings.LastReconciled", defaultValue: "Last checked \(date.formatted())"))
            }
        }
        .disabled(model.isSwitching)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): folder = SelectedFolder(url: url)
            case .failure(let error): self.error = error.localizedDescription
            }
        }
        .sheet(item: $folder) { folder in
            DriveFolderSetupView(folder: folder.url, model: model)
                .modifier(AppLockShield())
        }
    }

    private func label(_ method: WillowSyncMethod) -> String {
        switch method {
        case .none: L10n.text("SyncSettings.None")
        case .drive: "iCloud Drive"
        }
    }

    private func select(_ method: WillowSyncMethod) {
        if method == .drive && model.folder == nil {
            pickingFolder = true
        } else {
            Task { await model.select(method) }
        }
    }

    private func copyRecoveryKey() {
        guard !isReadingRecoveryKey, let folder = model.folder else { return }
        isReadingRecoveryKey = true
        Task {
            defer { isReadingRecoveryKey = false }
            do {
                guard model.selection == .drive, model.folder == folder,
                      let key = try await model.recoveryKey(),
                      model.selection == .drive, model.folder == folder else { return }
                UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: key]], options: [
                    .localOnly: true, .expirationDate: Date.now.addingTimeInterval(120),
                ])
                didCopyKey = true
            } catch {
                guard model.selection == .drive, model.folder == folder else { return }
                self.error = error.localizedDescription
            }
        }
    }

    private struct SelectedFolder: Identifiable {
        let url: URL
        var id: URL { url }
    }
}

private struct DriveKeyRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?
    let folder: DriveSyncFolder
    let model: SyncSettingsModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(L10n.text("SyncSettings.RecoveryKey"), text: $key)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button(L10n.text("SyncSettings.RestoreKey"), action: restore)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: {
                    Text(folder.name)
                } footer: {
                    Text(L10n.text("SyncSettings.RestoreKeyDescription"))
                }
            }
            .navigationTitle(L10n.text("SyncSettings.RestoreKey"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Text.Cancel")) { dismiss() }
                }
            }
            .disabled(model.isSwitching)
            .interactiveDismissDisabled(model.isSwitching)
            .modifier(ErrorAlert(error: $error))
        }
    }

    private func restore() {
        Task {
            do {
                try await model.restoreRecoveryKey(key, for: folder)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct DriveFolderSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var status: DriveSyncSetup.FolderStatus?
    @State private var error: String?
    let folder: URL
    let model: SyncSettingsModel

    var body: some View {
        NavigationStack {
            Form {
                if status != nil {
                    Section {
                        SecureField(L10n.text("SyncSettings.RecoveryKey"), text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button(L10n.text("SyncSettings.JoinFolder")) { connect(key) }
                            .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } footer: {
                        Text(L10n.text("SyncSettings.JoinDescription"))
                    }
                }
                if case .empty = status {
                    Section {
                        Button(L10n.text("SyncSettings.CreateFolder")) { connect(nil) }
                    } footer: {
                        Text(L10n.text("SyncSettings.CreateDescription"))
                    }
                }
                if status == nil {
                    Button(L10n.text("Text.Retry")) { Task { await inspect() } }
                }
            }
            .navigationTitle(folder.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("Text.Cancel")) { dismiss() }
                }
            }
            .disabled(model.isSwitching)
            .interactiveDismissDisabled(model.isSwitching)
            .task { await inspect() }
            .modifier(ErrorAlert(error: $error))
        }
    }

    private func inspect() async {
        do {
            status = try await model.inspect(folder)
            if case .connected = status { dismiss() }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func connect(_ key: String?) {
        Task {
            do {
                try await model.connect(to: folder, recoveryKey: key)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
