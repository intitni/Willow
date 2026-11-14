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

应用不预装第三方图源。插件脚本、订阅、标签及漫画的标签关联参与 CloudKit 同步；登录账号、Cookie、Token 等插件配置加密保存在本机，密钥存放在 Keychain。漫画图片仅保存在本地并排除备份。书架、历史和阅读进度通过 SwiftData 持久化，在具备相应权限的真机上配置 CloudKit 同步。插件和标签的同步由数据变化、云端导入、前台恢复及系统后台刷新触发，不使用定时轮询。

### 自签安装 IPA

从发布页下载 `Willow-<版本>-unsigned.ipa`，任选一种工具用自己的 Apple 账户签名安装。首次安装时，请按设备提示信任开发者并开启开发者模式。[GitHub Releases](https://github.com/intitni/Willow/releases)

- **AltStore Classic**。在电脑上运行 AltServer，将 AltStore Classic 安装到设备，再把 IPA 保存到设备的「文件」App。通过 USB 或同一 Wi-Fi 网络连接 AltServer，在 AltStore 的「My Apps」中点按「+」导入 IPA。免费账户的签名有效期为 7 天，到期前可在「My Apps」中点按「Refresh All」。[macOS 安装步骤](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos) · [Windows 安装步骤](https://faq.altstore.io/altstore-classic/how-to-install-altstore-windows) · [续签说明](https://faq.altstore.io/altstore-classic/your-altstore)
- **iLoader**。在电脑上安装 iLoader，通过 USB 连接 iPhone 或 iPad。在 iLoader 中登录 Apple 账户、选择设备，再导入电脑上的 IPA 进行签名和安装。[官方下载](https://iloader.app/) · [使用说明](https://github.com/nab138/iloader#how-to-use)

### 开启 CloudKit 同步

Willow 会在启动时根据签名权限自动配置 CloudKit。App 内的「设置 → iCloud 同步」显示配置状态。使用免费 Apple 账户自签 IPA 时，通常只能使用本地存储。

1. 使用具备 iCloud 配置权限的 Apple Developer 团队，按下文的真机签名步骤填写自己的 Team ID。
2. 在 Xcode 的 Willow target 中打开 **Signing & Capabilities**，启用 iCloud 下的 CloudKit，并选中团队有权访问的容器。项目已有 CloudKit 接收数据变更所需的静默后台通知配置。[Apple 配置指南](https://developer.apple.com/documentation/swiftdata/syncing-model-data-across-a-persons-devices)
3. 如果团队无法使用项目预设的 `com.intii.Willow` 和 `iCloud.intii.Willow`，请使用自己团队的 Bundle ID 和 iCloud 容器，并同步修改构建设置、`Willow/Willow.entitlements` 和 `WillowPersistence.iCloudContainer`。需要互相同步的设备应使用相同的容器及 CloudKit 环境。
4. 将签名后的 Willow 安装到已登录同一个 iCloud 账户的 iPhone 或 iPad。打开 Willow，在「设置 → iCloud 同步」确认显示「已配置」。该状态表示存储容器已初始化。可在一台设备收藏一部作品，再到另一台设备查看书架，确认数据实际同步。若显示「仅本机」，请查看状态下方的错误提示并检查签名和容器配置。

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

真机运行前，将 `Config/Signing.example.xcconfig` 复制为 `Config/Signing.local.xcconfig`，并在该 Git 忽略的本地文件中填写自己的 Team ID。CloudKit 权限和容器的配置见上文。模拟器使用本地数据库。

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
