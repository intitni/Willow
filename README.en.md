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

Third-party sources must be installed separately. CloudKit can sync plugin scripts, subscriptions, tags, and the tags assigned to each manga. Plugin settings such as login credentials, cookies, and tokens are encrypted on the device, with the encryption key stored in Keychain. Manga images stay on the device and are excluded from backups.

SwiftData stores bookmarks, reading history, and reading progress. These records can sync through CloudKit on devices configured with the required capabilities. Plugin and tag sync runs in response to data changes, cloud imports, the app returning to the foreground, and system background refresh.

### Sign and install the IPA

Download `Willow-<version>-unsigned.ipa` and use either tool below to sign and install it with your Apple Account. Trust the developer and enable Developer Mode when your device prompts you. [GitHub Releases](https://github.com/intitni/Willow/releases)

- **AltStore Classic.** Run AltServer on your computer, install AltStore Classic on your device, and save the IPA to the Files app. Connect to AltServer over USB or the same Wi-Fi network, then tap **+** in AltStore's **My Apps** tab to import the IPA. If you use a free account, tap **Refresh All** in **My Apps** before the seven-day signing period expires. [macOS setup](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) · [Windows setup](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) · [Refresh instructions](https://faq.altstore.io/altstore-classic/your-altstore)
- **iLoader.** Install iLoader on your computer and connect your iPhone or iPad over USB. Sign in to your Apple Account in iLoader, select your device, and import the IPA from your computer to sign and install it. [Official download](https://iloader.app/) · [Usage instructions](https://github.com/nab138/iloader#how-to-use)

### Enable CloudKit sync

Willow configures CloudKit at launch based on its signing entitlements. **Settings → iCloud Sync** shows the configuration status. An IPA signed with a free Apple Account typically uses local storage only.

1. Use an Apple Developer team with permission to configure iCloud. Set your Team ID as described in the device signing instructions below.
2. In Xcode, open **Signing & Capabilities** for the Willow target. Enable **CloudKit** under **iCloud** and select a container your team can access. The project already includes the configuration CloudKit uses to receive silent background updates. [Apple setup guide](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
3. If your team cannot use the preset identifiers `com.intii.Willow` and `iCloud.intii.Willow`, use your team's own bundle ID and iCloud container. Update the build settings, `Willow/Willow.entitlements`, and `WillowPersistence.iCloudContainer` together. Devices that sync with each other must use the same container and CloudKit environment.
4. Install the signed build on iPhones or iPads signed in to the same iCloud account. Open Willow and check that **Settings → iCloud Sync** shows **Configured**. This status confirms the storage container initialized successfully. To verify that data syncs, bookmark a title on one device and look for it in the library on another. If the status shows **On This Device**, check the message below it and review the signing and container configuration.

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

Before running on a device, copy `Config/Signing.example.xcconfig` to `Config/Signing.local.xcconfig` and enter your Team ID in that Git-ignored file. Follow the CloudKit instructions above to configure the required entitlements and container. The simulator uses a local database.

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
