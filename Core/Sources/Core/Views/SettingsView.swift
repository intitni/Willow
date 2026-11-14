import CoreStorage
import SwiftUI

struct SettingsView: View {
    @Environment(AppLock.self) private var appLock
    let persistence: WillowPersistence

    var body: some View {
        SettingsForm(appLock: appLock, persistence: persistence)
    }
}

private struct SettingsForm: View {
    @Environment(PreferenceSyncViewModel.self) private var preferenceSync
    @State private var model: SettingsModel

    init(appLock: AppLock, persistence: WillowPersistence) {
        _model = State(initialValue: SettingsModel(appLock: appLock, persistence: persistence))
    }

    var body: some View {
        @Bindable var viewModel = model.viewModel
        Form {
            Section(L10n.text("Text.Sources")) {
                NavigationLink {
                    PluginManagementView()
                } label: {
                    Label(L10n.text("Text.PluginsSubscriptions"), systemImage: "puzzlepiece.extension")
                }
            }

            Section(L10n.text("Text.Reading")) {
                Picker(L10n.text("Text.ReadingDirection"), selection: Binding(get: { viewModel.mode }, set: model.setMode)) {
                    ForEach(ReaderMode.allCases) { value in Text(value.label).tag(value) }
                }
                Toggle(L10n.text("Text.TwoPagesInWideWindows"), isOn: Binding(get: { viewModel.spreads }, set: model.setSpreads))
            }

            Section {
                Toggle(isOn: Binding(
                    get: { viewModel.lockEnabled },
                    set: model.setAppLock
                )) {
                    Label(L10n.text("Text.AppLock"), systemImage: "lock")
                }
                .disabled(viewModel.updatingLock)
            } header: {
                Text(L10n.text("Text.Privacy"))
            } footer: {
                Text(L10n.resource("Message.BiometricUnlock", defaultValue: "开启后，Willow 会在返回前台时使用 \(viewModel.biometryName) 解锁。"))
            }

            Section {
                LabeledContent(L10n.text("Text.ICloudSync")) {
                    Text(viewModel.syncStatus)
                }
            } footer: {
                if let failure = viewModel.syncFailure ?? preferenceSync.error {
                    Text(failure)
                } else {
                    Text(L10n.text("Message.ICloudSyncScope"))
                }
            }

            Section {
                NavigationLink {
                    AboutView()
                } label: {
                    Label(L10n.text("Text.AboutOpenSourceLicenses"), systemImage: "info.circle")
                }
            }
        }
        .navigationTitle(L10n.text("Text.Settings"))
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: UserDefaults.standard)) { _ in
            model.reloadReaderPreferences()
        }
        .modifier(ErrorAlert(error: $viewModel.error))
    }
}

private struct AboutView: View {
    private let viewModel = AboutViewModel()

    var body: some View {
        List {
            Section(L10n.text("Text.WillowNative")) {
                if let version = viewModel.version {
                    LabeledContent(L10n.text("Text.Version"), value: version)
                }
            }

            Section(L10n.text("Text.OpenSourceLicenses")) {
                Text(L10n.text("Text.WillowNativeUsesTheBreezePluginRuntime"))
                Link(L10n.text("Text.BreezeSourceCode"), destination: viewModel.upstream)
                Link(L10n.text("Text.MozillaPublicLicense20"), destination: viewModel.license)
                NavigationLink {
                    ThirdPartyLicensesView()
                } label: {
                    Label(L10n.text("Text.BundledLicenseNotices"), systemImage: "doc.text")
                }
                LabeledContent {
                    Text(viewModel.revision)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } label: {
                    Text(L10n.text("Text.BreezeRevision"))
                }
            }
        }
        .navigationTitle(L10n.text("Text.AboutWillow"))
    }
}
