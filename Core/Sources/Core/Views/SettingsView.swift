import CoreStorage
import SwiftUI

struct SettingsView: View {
    @Environment(AppLock.self) private var appLock
    @Environment(ContentPrivacy.self) private var privacy
    let updates: UpdateModel

    var body: some View {
        SettingsForm(appLock: appLock, privacy: privacy, updates: updates)
    }
}

private struct SettingsForm: View {
    @State private var model: SettingsModel
    let updates: UpdateModel

    init(appLock: AppLock, privacy: ContentPrivacy, updates: UpdateModel) {
        _model = State(initialValue: SettingsModel(appLock: appLock))
        self.privacy = privacy
        self.updates = updates
    }

    private let privacy: ContentPrivacy

    var body: some View {
        @Bindable var viewModel = model.viewModel
        Form {
            UpdateSettingsSection(model: updates)

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
                Toggle(isOn: Binding(get: { privacy.greenTravelEnabled }, set: privacy.setGreenTravel)) {
                    Label(L10n.text("Settings.GreenTravel"), systemImage: "leaf")
                }
            } header: {
                Text(L10n.text("Settings.Privacy"))
            } footer: {
                Text(L10n.resource("Settings.BiometricUnlockDescription", defaultValue: "开启后，Willow 会在返回前台时使用 \(viewModel.biometryName) 解锁。"))
            }

            SyncSettingsSection()

            Section {
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

private struct UpdateSettingsSection: View {
    let model: UpdateModel

    var body: some View {
        Section {
            NavigationLink {
                UpdatesView(model: model)
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.resource("About.Updates"))
                        if let status {
                            Text(status)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
            }

            Link(destination: URL(string: "https://github.com/intitni/Willow")!) {
                Label {
                    Text(verbatim: "GitHub")
                } icon: {
                    Image(systemName: "arrow.up.right.square")
                }
            }
        }
    }

    private var status: LocalizedStringResource? {
        if model.isUpdateAvailable == true { return L10n.resource("About.UpdateAvailable") }
        if model.isCheckingUpdates { return L10n.resource("About.CheckingForUpdates") }
        if model.updateCheckFailed { return L10n.resource("About.UpdateCheckFailed") }
        if model.noPublishedRelease { return L10n.resource("About.NoPublishedReleaseYet") }
        if model.isUpdateAvailable == false { return L10n.resource("About.UpToDate") }
        return nil
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

            Section(L10n.text("About.ReleaseNotes")) {
                if let notes = model.latestRelease?.notes,
                   !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let markdown = try? AttributedString(
                        markdown: notes,
                        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                    )
                    Text(markdown ?? AttributedString(notes))
                        .textSelection(.enabled)
                } else {
                    Text(L10n.resource("About.NoReleaseNotes"))
                        .foregroundStyle(.secondary)
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
