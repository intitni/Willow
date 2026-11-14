import CoreStorage
import SwiftUI

struct SettingsView: View {
    @Environment(AppLock.self) private var appLock
    let persistence: WillowPersistence
    let updates: UpdateModel

    var body: some View {
        SettingsForm(appLock: appLock, persistence: persistence, updates: updates)
    }
}

private struct SettingsForm: View {
    @Environment(PreferenceSyncViewModel.self) private var preferenceSync
    @State private var model: SettingsModel
    let updates: UpdateModel

    init(appLock: AppLock, persistence: WillowPersistence, updates: UpdateModel) {
        _model = State(initialValue: SettingsModel(appLock: appLock, persistence: persistence))
        self.updates = updates
    }

    var body: some View {
        @Bindable var viewModel = model.viewModel
        Form {
            Section(L10n.text("Text.Sources")) {
                NavigationLink {
                    PluginManagementView()
                } label: {
                    Label(L10n.text("PluginManagement.Title"), systemImage: "puzzlepiece.extension")
                }
            }

            Section(L10n.text("Downloads.Read")) {
                Picker(L10n.text("ReadingDirection.Title"), selection: Binding(get: { viewModel.mode }, set: model.setMode)) {
                    ForEach(ReaderMode.allCases) { value in Text(value.label).tag(value) }
                }
                Toggle(L10n.text("Settings.TwoPagesInWideWindows"), isOn: Binding(get: { viewModel.spreads }, set: model.setSpreads))
            }

            Section {
                Toggle(isOn: Binding(
                    get: { viewModel.lockEnabled },
                    set: model.setAppLock
                )) {
                    Label(L10n.text("Settings.AppLock"), systemImage: "lock")
                }
                .disabled(viewModel.updatingLock)
            } header: {
                Text(L10n.text("Settings.Privacy"))
            } footer: {
                Text(L10n.resource("Settings.BiometricUnlockDescription", defaultValue: "开启后，Willow 会在返回前台时使用 \(viewModel.biometryName) 解锁。"))
            }

            Section {
                LabeledContent(L10n.text("Settings.ICloudSync")) {
                    Text(viewModel.syncStatus)
                }
            } footer: {
                if let failure = viewModel.syncFailure ?? preferenceSync.error {
                    Text(failure)
                } else {
                    Text(L10n.text("Settings.ICloudSyncDescription"))
                }
            }

            Section {
                NavigationLink {
                    UpdatesView(model: updates)
                } label: {
                    HStack {
                        Label(L10n.text("About.Updates"), systemImage: "arrow.triangle.2.circlepath")
                        if updates.isUpdateAvailable == true {
                            Spacer()
                            Text(L10n.text("About.UpdateAvailable"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                NavigationLink {
                    AboutView()
                } label: {
                    Label(L10n.text("Settings.AboutAndLicenses"), systemImage: "info.circle")
                }
            }
        }
        .navigationTitle(L10n.text("Settings.Title"))
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)) { _ in
            model.reloadReaderPreferences()
        }
        .modifier(ErrorAlert(error: $viewModel.error))
    }
}

private struct UpdatesView: View {
    let model: UpdateModel
    var body: some View {
        List {
            Section {
                if let version = model.version {
                    LabeledContent(L10n.text("Text.Version"), value: version)
                }
            }

            Section(L10n.text("About.Updates")) {
                if model.isCheckingUpdates {
                    ProgressView(L10n.text("About.CheckingForUpdates"))
                } else if model.updateCheckFailed {
                    Text(L10n.text("About.UpdateCheckFailed"))
                        .foregroundStyle(.secondary)
                    Button(L10n.text("About.CheckAgain")) {
                        Task { await model.checkForUpdates() }
                    }
                } else if model.noPublishedRelease {
                    Text(L10n.text("About.NoPublishedReleaseYet"))
                        .foregroundStyle(.secondary)
                    Button(L10n.text("About.CheckAgain")) {
                        Task { await model.checkForUpdates() }
                    }
                } else if let release = model.latestRelease {
                    LabeledContent(L10n.text("About.LatestVersion"), value: release.version)
                    if let isUpdateAvailable = model.isUpdateAvailable {
                        if isUpdateAvailable {
                            Label(L10n.text("About.UpdateAvailable"), systemImage: "arrow.down.circle.fill")
                                .foregroundStyle(.tint)
                        } else {
                            Label(L10n.text("About.UpToDate"), systemImage: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Link(L10n.text("About.ViewRelease"), destination: release.url)
                    Button(L10n.text("About.CheckAgain")) {
                        Task { await model.checkForUpdates() }
                    }
                }
            }

            if let notes = model.latestRelease?.notes,
               !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section(L10n.text("About.ReleaseNotes")) {
                    Text(notes)
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle(L10n.text("About.Updates"))
    }
}

private struct AboutView: View {
    private let viewModel = AboutViewModel()

    var body: some View {
        List {
            Section(L10n.text("About.AppName")) {
                if let version = viewModel.version {
                    LabeledContent(L10n.text("Text.Version"), value: version)
                }
            }

            Section(L10n.text("Licenses.Title")) {
                Text(L10n.text("About.BreezeDescription"))
                Link(L10n.text("About.BreezeSourceCode"), destination: viewModel.upstream)
                Link(L10n.text("About.MozillaPublicLicense20"), destination: viewModel.license)
                NavigationLink {
                    ThirdPartyLicensesView()
                } label: {
                    Label(L10n.text("About.BundledLicenseNotices"), systemImage: "doc.text")
                }
                LabeledContent {
                    Text(viewModel.revision)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } label: {
                    Text(L10n.text("About.BreezeRevision"))
                }
            }
        }
        .navigationTitle(L10n.text("About.Title"))
    }
}
