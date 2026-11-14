# Willow

清风拂柳。Willow 是一个基于 [Breeze](https://github.com/breeze-project-org/Breeze) 插件运行时的原生漫画阅读器，使用 SwiftUI 和 SwiftData 构建。

支持 iPhone、iPad，以及 iPhone Duo 的动态窗口尺寸以及原生的设计风格。最低支持 iOS 26。

本项目将专注于原生漫画阅读体验，充分利用 iOS 平台的特性，同时通过 Breeze 插件运行时实现灵活的内容扩展。

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

真机运行先将 `Config/Signing.example.xcconfig` 复制为 `Config/Signing.local.xcconfig`，填写自己的 Team ID。该本地文件被 Git 忽略，不要将个人 Team 写回 `project.pbxproj`。为 `com.intii.Willow` 配置 iCloud/CloudKit 和 Push Notifications。容器 ID 为 `iCloud.intii.Willow`；如果更换标识，需要同时修改 entitlement、构建设置和 `WillowPersistence.iCloudContainer`。这些应用与容器标识不是证书或私钥。模拟器明确使用本地数据库。界面中的「已配置」仅表示存储容器配置成功，不代表所有数据已完成上传。

主 App target 只有 `Willow/App/WillowApp.swift`，只负责创建 `CoreAppModel`、显示 `WillowRootView` 和转发生命周期。所有 Swift 功能代码都在本地 Swift Package `Core`。在 `Core/Sources` 的现有 target 中新增 Swift 文件会由 SwiftPM 自动发现，无需修改 Xcode 工程。新增功能 target 时只需维护 `Core/Package.swift` 的依赖关系。

`Scripts/generate-project.rb` 只用于重建宿主工程配置（需要 Ruby `xcodeproj` gem），不是日常新增功能文件的步骤。本地化目录由对应的 Swift package target 打包，使用其资源 bundle 查找翻译；宿主仅声明支持语言。

## 使用

1. 在「设置 → 插件与订阅」添加 Breeze 插件目录或自己的 HTTPS 订阅地址。
2. 从订阅安装图源，也可以导入 `.cjs`、`.cjs.br`，或从 HTTPS 链接安装。
3. 在「发现」选择图源，浏览、搜索，按源提供的登录表单登录。
4. 收藏漫画到书架，打开章节阅读，或在详情页按章下载；toolbar 也提供整部下载。下载列表按章节管理。
5. 在漫画详情中设置本地标签，并在书架和下载页按标签筛选。

应用不预装第三方图源。插件脚本、订阅、标签及漫画的标签关联参与 CloudKit 同步；登录账号、Cookie、Token 等插件配置加密保存在本机，密钥存放在 Keychain。漫画图片仅保存在本地并排除备份。书架、历史和阅读进度通过 SwiftData 持久化，在具备相应权限的真机上配置 CloudKit 同步。插件和标签的同步由数据变化、云端导入、前台恢复及系统后台刷新触发，不使用定时轮询。

## 验证

存储和插件测试目前需要脚本提供隔离环境：

```sh
Scripts/test-core.sh
Scripts/test-plugins.sh
```
