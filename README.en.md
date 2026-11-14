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

### Use iCloud Drive sync

Sign in to the same iCloud account and enable iCloud Drive on each device. Check that the Files app can access the folder you plan to use. Sync is off by default, so select the sync method and folder separately on each device.

1. On the first device, choose **iCloud Drive** under **Settings → Sync Method**, pick a folder under iCloud Drive in the system picker, and tap **Create Encrypted Sync Folder**.
2. Back in Settings, tap **Copy Recovery Key** and save it somewhere safe. Willow encrypts sync records and plugin scripts before writing them for upload and stores the recovery key in this device’s Keychain.
3. On other devices, pick the same folder. Willow reads the verification file and checks the device’s Keychain. On the first connection, enter the recovery key and tap **Connect Existing Folder**. If the files are still arriving, allow iCloud Drive time to download them and try again. Builds signed with a free Apple Account can use the system picker to access iCloud Drive.
4. Once **Active Sync Method** shows **iCloud Drive**, tap **Sync Now**. Bookmark a title on one device, then open Willow and sync on the other device to check that the title appears in its library. The last-checked time indicates that Willow completed a local sync pass. File transfers also depend on iCloud Drive scheduling.

Sync files are stored in a `Willow Sync v1` subfolder inside the selected folder. Comic information, tags, reading records, and plugin scripts are encrypted. Keep this subfolder and its verification file intact so other devices can identify it and verify the recovery key.

Save a separate copy of your recovery key somewhere safe. Reinstalling Willow or changing its signing identity may require you to enter the key again. While copying the key, the button shows **Reading recovery key…**, followed by a confirmation when copying finishes.

After an upgrade, Willow verifies a legacy recovery key and saves it to the current device before deleting the old iCloud Keychain item. The deletion propagates to other devices. A device that hasn’t saved its own copy will need the recovery key again.

Switching methods keeps your local data and existing cloud copies. The first connection merges items unique to either side. Newly discovered local items are published as lower-priority versions, so existing Drive edits and deletions still apply when they arrive later. Reading progress and history deletions are ordered by the time of the actual action, so a later reread can move the bookmark to an earlier page. When Willow finds sync records still downloading, it waits for the next sync. iCloud may still be discovering files uploaded by other devices, and those files join the merge when they appear. Switching from iCloud Drive to None immediately stops Willow’s Drive sync tasks. The file provider can finish transfers that Willow has already submitted. For changes involving CloudKit, the previous method stays active until you quit and reopen Willow. Settings shows both the selected method and the method currently in effect.

### Enable CloudKit sync

CloudKit requires signing with the appropriate entitlements.

1. Use an Apple Developer team with permission to configure iCloud. Set your Team ID as described in the device signing instructions below.
2. In Xcode, open **Signing & Capabilities** for the Willow target. Enable **CloudKit** under **iCloud** and select a container your team can access. The project already includes the configuration CloudKit uses to receive silent background updates. [Apple setup guide](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
3. If your team cannot use the preset identifiers `com.intii.Willow` and `iCloud.intii.Willow`, use your team's own bundle ID and iCloud container. Update the build settings, `Willow/Willow.entitlements`, and `WillowPersistence.iCloudContainer` together. Devices that sync with each other must use the same container and CloudKit environment.
4. Install the signed build on iPhones or iPads signed in to the same iCloud account. Open Willow, select **CloudKit** under **Settings → Sync Method**, then quit and reopen it. **Active Sync Method** shows **CloudKit** once the storage container has initialized. To verify that data syncs, bookmark a title on one device and look for it in the library on another. If the active method still shows **None**, check the message below it and review the signing and container configuration.

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
