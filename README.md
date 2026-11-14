# Willow

[English](README.en.md)

清风拂柳。Willow 是一个基于 [Breeze](https://github.com/breeze-project-org/Breeze) 插件运行时的原生漫画阅读器，使用 SwiftUI 和 SwiftData 构建。

支持 iPhone、iPad，以及 iPhone Duo 的动态窗口尺寸以及原生的设计风格。最低支持 iOS 26。

本项目将专注于原生漫画阅读体验，充分利用 iOS 平台的特性，同时通过 Breeze 插件运行时实现灵活的内容扩展。

## 使用

1. 在「设置 → 插件与订阅」添加 Breeze 插件目录或自己的 HTTPS 订阅地址。
2. 从订阅安装图源，也可以导入 `.cjs`、`.cjs.br`，或从 HTTPS 链接安装。
3. 在「发现」选择图源，浏览、搜索，按源提供的登录表单登录。
4. 收藏漫画到书架，打开章节阅读，或在详情页按章下载；toolbar 也提供整部下载。下载列表按章节管理。
5. 在漫画详情中设置本地标签，并在书架和下载页按标签筛选。

Willow 每次启动时检查 GitHub 的最新发布版本；有更新时「设置」标签显示红点。在「设置 → 更新」可查看更新日志和发布页，更新仍需自行下载并签名安装。

### 自签安装 IPA

从发布页下载 `Willow-<版本>-unsigned.ipa`，任选一种工具用自己的 Apple 账户签名安装。首次安装时，请按设备提示信任开发者并开启开发者模式。[GitHub Releases](https://github.com/intitni/Willow/releases)

- **AltStore Classic**。在电脑上运行 AltServer，将 AltStore Classic 安装到设备，再把 IPA 保存到设备的「文件」App。通过 USB 或同一 Wi-Fi 网络连接 AltServer，在 AltStore 的「My Apps」中点按「+」导入 IPA。免费账户的签名有效期为 7 天，到期前可在「My Apps」中点按「Refresh All」。[macOS 安装步骤](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) · [Windows 安装步骤](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) · [续签说明](https://faq.altstore.io/altstore-classic/your-altstore)
- **iLoader**。在电脑上安装 iLoader，通过 USB 连接 iPhone 或 iPad。在 iLoader 中登录 Apple 账户、选择设备，再导入电脑上的 IPA 进行签名和安装。[官方下载](https://iloader.app/) · [使用说明](https://github.com/nab138/iloader#how-to-use)

### iCloud Drive 同步

Willow 默认不同步。使用 iCloud Drive 同步前，请在各设备上登录同一个 iCloud 账户并开启 iCloud 云盘。

1. 在第一台设备的「设置 → 同步方式」选择 **iCloud Drive**，选择云盘中的文件夹，点按「创建加密同步文件夹」。
2. 点按「复制恢复密钥」并妥善保存。同步内容经过加密，其他设备需要这份密钥才能读取。
3. 在其他设备上选择同一个文件夹，输入恢复密钥，点按「连接已有同步文件夹」。

之后打开 Willow 即可自动同步，也可以点按「立即同步」。如果数据暂未出现，请等待 iCloud 云盘完成传输后再试。恢复密钥仅保存在本机，重新安装后可能需要再次输入。

### 使用 CloudKit 同步

建议直接使用 iCloud Drive 同步，按上文选择文件夹并保存恢复密钥即可。

如果你使用的是支持 CloudKit 的签名版本，也可以在「设置 → 同步方式」选择 **CloudKit**。各设备需登录同一个 iCloud 账户。

自行签名使用 CloudKit 时，需要将 Bundle Identifier（`com.intii.Willow`）和 iCloud Container Identifier（`iCloud.intii.Willow`）调整为自己开发者团队可用的标识，并同步更新工程配置。

切换到或离开 CloudKit 后，请完全退出并重新打开 Willow，使选择生效。

## 打开与构建

当前构建配置面向 Apple Silicon Mac，使用 Xcode 27.1 和 Rust 1.96.1。最低运行系统 iOS 26 不等于最低构建 SDK；代码包含 iOS 27 API，并在较旧系统上使用兼容实现。

打开 `Willow.xcodeproj`，选择 Willow scheme。项目会在构建阶段编译 Rust 静态库，不需要 Flutter。

首次构建前安装 Rust 及 iOS targets：

```sh
git submodule update --init --recursive
rustup toolchain install 1.96.1 --profile minimal --target aarch64-apple-ios --target aarch64-apple-ios-sim
```

模拟器构建：

```sh
xcodebuild -project Willow.xcodeproj -scheme Willow -sdk iphonesimulator \
  -configuration Debug -derivedDataPath /tmp/WillowDerivedData CODE_SIGNING_ALLOWED=NO build
```

真机运行前，将 `Config/Signing.example.xcconfig` 复制为 `Config/Signing.local.xcconfig`，并在该 Git 忽略的本地文件中填写自己的 Team ID。使用 CloudKit 时，请在 Xcode 中启用 iCloud / CloudKit，并将所选容器与 `Willow/Willow.entitlements`、`WillowPersistence.iCloudContainer` 保持一致。模拟器使用本地数据库。

主 App target 只有 `Willow/App/WillowApp.swift`，只负责创建 `CoreAppModel`、显示 `WillowRootView` 和转发生命周期。所有 Swift 功能代码都在本地 Swift Package `Core`。在 `Core/Sources` 的现有 target 中新增 Swift 文件会由 SwiftPM 自动发现，无需修改 Xcode 工程。新增功能 target 时只需维护 `Core/Package.swift` 的依赖关系。

`Scripts/generate-project.rb` 只用于重建宿主工程配置（需要 Ruby `xcodeproj` gem），不是日常新增功能文件的步骤。本地化目录由对应的 Swift package target 打包，使用其资源 bundle 查找翻译；宿主仅声明支持语言。

## 验证

存储和插件测试目前需要脚本提供隔离环境：

```sh
Scripts/test-core.sh
Scripts/test-plugins.sh
```

## 许可证

Willow 原创代码采用 [Mozilla Public License 2.0](LICENSE)。Breeze 和其他第三方组件的许可及版权声明见 [第三方许可声明](THIRD_PARTY_NOTICES.md)。
