# Willow

[简体中文](README.md)

Willow is a native manga reader built with SwiftUI and SwiftData. It uses the [Breeze](https://github.com/breeze-project-org/Breeze) plugin runtime to support additional content sources.

Willow supports iPhone and iPad, adapts to changing window sizes on iPhone Duo, and follows native iOS design conventions. It requires iOS 26 or later.

## Use Willow

1. In Settings → Plugins & Subscriptions, add the Breeze plugin catalog or your own HTTPS subscription URL.
2. Install a source from a subscription, import a `.cjs` or `.cjs.br` file, or install from an HTTPS link.
3. Select a source in Discover to browse or search. If the source requires an account, use its sign-in form.
4. Bookmark manga to add them to your library, open a chapter to read, or download individual chapters from the details page. The toolbar also lets you download the entire work. The Downloads page lists downloads by chapter.
5. Assign local tags on a manga's details page and use them to filter your library and downloads.

Willow checks the latest GitHub release at launch and shows a red dot on the Settings tab when an update is available. Open Settings → Updates to see the release notes and release page; updates must still be downloaded and signed manually.

Third-party sources must be installed separately. Sync is off by default. Under **Settings → Sync Method**, choose iCloud Drive or CloudKit to sync bookmarks, reading history and progress, plugin scripts and metadata, subscriptions, tags, and tag assignments. Plugin login credentials, cookies, and tokens stay encrypted on the device, with their encryption key in Keychain. Manga images stay on the device and are excluded from backups.

Sync runs in response to local changes, arrivals from the cloud, foreground activity, and system background refresh.

### Sign and install the IPA

Download `Willow-<version>-unsigned.ipa` and use either tool below to sign and install it with your Apple Account. Trust the developer and enable Developer Mode when your device prompts you. [GitHub Releases](https://github.com/intitni/Willow/releases)

- **AltStore Classic.** Run AltServer on your computer, install AltStore Classic on your device, and save the IPA to the Files app. Connect to AltServer over USB or the same Wi-Fi network, then tap **+** in AltStore's **My Apps** tab to import the IPA. If you use a free account, tap **Refresh All** in **My Apps** before the seven-day signing period expires. [macOS setup](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) · [Windows setup](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) · [Refresh instructions](https://faq.altstore.io/altstore-classic/your-altstore)
- **iLoader.** Install iLoader on your computer and connect your iPhone or iPad over USB. Sign in to your Apple Account in iLoader, select your device, and import the IPA from your computer to sign and install it. [Official download](https://iloader.app/) · [Usage instructions](https://github.com/nab138/iloader#how-to-use)

### iCloud Drive sync

Sync is off by default. Sign in to the same iCloud account and enable iCloud Drive on each device.

1. On the first device, choose **iCloud Drive** under **Settings → Sync Method**, select a folder in iCloud Drive, and tap **Create Encrypted Sync Folder**.
2. Tap **Copy Recovery Key** and save it somewhere safe. Sync data is encrypted, and other devices need this key to read it.
3. On other devices, select the same folder, enter the recovery key, and tap **Connect Existing Folder**.

Willow syncs automatically when you open it. You can also tap **Sync Now**. If changes have not appeared yet, allow iCloud Drive time to transfer them and try again. The recovery key is stored only on your device, so you may need to enter it again after reinstalling Willow.

### Use CloudKit sync

We recommend using iCloud Drive sync. Follow the steps above to select a folder and save your recovery key.

If your build is signed to support CloudKit, you can also choose **CloudKit** under **Settings → Sync Method**. Sign in to the same iCloud account on each device.

When signing your own build for CloudKit, change the Bundle Identifier (`com.intii.Willow`) and iCloud Container Identifier (`iCloud.intii.Willow`) to identifiers available to your developer team, and update the project configuration accordingly.

After switching to or from CloudKit, quit and reopen Willow for the change to take effect.

## Open and build

The current build configuration targets Apple Silicon Macs with Xcode 27.1 and Rust 1.96.1. The app uses iOS 27 APIs where available and provides fallbacks on iOS 26. Build with the SDK included in Xcode 27.1.

Open `Willow.xcodeproj` and select the Willow scheme. Xcode builds the Rust static library during the build. Flutter is unnecessary.

Before your first build, initialize the submodules and install Rust with the iOS targets.

```sh
git submodule update --init --recursive
rustup toolchain install 1.96.1 --profile minimal --target aarch64-apple-ios --target aarch64-apple-ios-sim
```

To build for the simulator, run the following command.

```sh
xcodebuild -project Willow.xcodeproj -scheme Willow -sdk iphonesimulator \
  -configuration Debug -derivedDataPath /tmp/WillowDerivedData CODE_SIGNING_ALLOWED=NO build
```

Before running on a device, copy `Config/Signing.example.xcconfig` to `Config/Signing.local.xcconfig` and enter your Team ID in that Git-ignored file. For CloudKit, enable iCloud / CloudKit in Xcode and keep the selected container consistent with `Willow/Willow.entitlements` and `WillowPersistence.iCloudContainer`. The simulator uses a local database.

The host app target contains only `Willow/App/WillowApp.swift`. It creates `CoreAppModel`, displays `WillowRootView`, and forwards lifecycle events. The local Swift package `Core` contains the app's Swift feature code. SwiftPM automatically picks up new Swift files in existing targets under `Core/Sources`. When adding a feature target, update the target and its dependencies in `Core/Package.swift`.

Use `Scripts/generate-project.rb` to regenerate the host Xcode project. It requires the Ruby `xcodeproj` gem. Each Swift package target packages its own string catalog and loads translations from its resource bundle. The host app declares the supported languages.

## Verification

Use the provided scripts to run the storage and plugin tests in isolated environments.

```sh
Scripts/test-core.sh
Scripts/test-plugins.sh
```

## License

Willow's original source code is licensed under the [Mozilla Public License 2.0](LICENSE). See the [third-party notices](THIRD_PARTY_NOTICES.md) for the licenses and copyright notices for Breeze and other dependencies.
