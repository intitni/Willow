# Willow 项目协作约定

## 沟通与 Git

- 使用中文与用户沟通，自称「猫猫」。说明问题时使用完整句子；犯错时直接承认并修正。
- **Git commit message 的标题和正文一律使用英语。** 描述具体改动及其目的，例如 `Fix sync observation across multiple windows`。
- 用户本人开发的改动在交付时默认走 feature 分支和中文 PR。有本机配置的 Willow 所有者开发流程时，按该流程执行。其他 commit、amend 或 push 需要用户明确要求。不要覆盖、回退或顺手提交与当前任务无关的用户改动。
- 提交前检查暂存区和 `.gitignore`。个人签名配置、证书、私钥、provisioning profile、应用数据及构建产物不能进入版本库。
- 除非用户明确要求，否则不要使用 Computer Use。
- 对超出用户需求且涉及较大改动的方案先确认。日常修复和已授权范围内的工作直接完成。

## 项目结构

Willow 是兼容 Breeze 插件协议的原生漫画阅读器，使用 SwiftUI、SwiftData 和 Rust 运行时。

- `Willow/App/WillowApp.swift`：薄 App 入口，只整合场景、生命周期和系统后台任务。
- `Core/`：名为 **Core** 的本地 Swift package。功能代码、资源和测试优先放在这里，可按功能拆分 target。
- `Core/Sources/Core`：SwiftUI 页面、展示 Model / ViewModel、应用整合。
- `CoreStorage`：持久化、标签、下载、缓存及同步协调。
- `BreezeRuntime`：Swift 到 Rust 运行时的桥接、插件配置保护等。
- `BreezePlugins`：插件安装、订阅和功能协议适配。
- `CoreToast`：统一 Toast 展示。
- `Bridge/`：Rust 静态库和宿主适配，依赖版本由 `Cargo.lock` 固定。
- `Vendor/Breeze`：固定提交的上游 Git submodule。改动该目录前阅读其中的 `AGENTS.md`；不要顺手更新子模块或修改上游源码。
- `Licenses/`、`THIRD_PARTY_NOTICES.md`：第三方许可材料及维护说明。

在已有 package target 中新增文件不需要修改 `.xcodeproj`。新增 target 时维护 `Core/Package.swift`；只有宿主整合确有需要时才修改工程配置。`Scripts/generate-project.rb` 用于重建工程，不是日常添加功能文件的步骤。

## Swift 与界面

- 沿用现有代码风格，优先 SwiftUI、系统控件、TabView 和原生 toolbar；Liquid Glass 适用于界面控件，不要给阅读内容叠加无必要的装饰。
- 采用 **View → Model → ViewModel** 组织方式：Model 提供 `@MainActor @Observable` ViewModel，View 消费展示数据并将操作交给 Model。
- 展示状态留在 MainActor；数据库协调、文件 I/O、编解码等重工作使用独立 Actor。不要仅因为 Model 被 UI 使用就把所有业务工作标成 MainActor。
- 优先使用 Swift Concurrency、Actor 和 Task；不要首先选择 DispatchQueue 或 NSLock。不要让 SwiftData 的可变模型对象跨 Actor 传递，跨隔离边界使用 Sendable 快照或标识。
- 异步操作需要处理取消、重入和等待期间的数据变化。不能在检查并发冲突之前执行无法恢复的破坏性操作。
- 适配优先使用 size class 和系统布局信息；不要用固定像素宽度推测设备、折叠状态或双页模式。仅在系统确有公开能力时实现外屏展示。
- 阅读画面保持全屏，toolbar 显隐不得改变内容区域；竖屏不能错误启用双页布局。
- 页面错误使用已有 CoreToast / ErrorAlert 机制，避免新增零散提示实现。Toast 外边距约定为 18。
- 使用语义化本地化 Key，例如 `ButtonTitle.LoadMore`，维护对应 target 的 String Catalog 中英文翻译，通过该模块的资源 bundle 加载。语言跟随系统。
- 不主动引入 Material Design 主题、动态取色、字体设置、代理设置、墨水屏、左手优化或图片超分。插件需要的 OpenCC bridge 兼容不等于新增用户界面的简繁转换设置。

## 数据、同步与下载

- iCloud 云盘同步范围：书架、阅读历史/进度、插件脚本和元数据、订阅、标签及漫画的标签关联。
- 登录账号、Cookie、Token 等插件配置只保留在本机，保持现有加密和 Keychain 密钥保护。不要将这些内容加入同步记录、日志、测试产物或发布包。
- 漫画图片只保存在本地，并排除备份。应用锁使用设备支持的 Face ID / Touch ID。
- 同步由数据变化及明确事件触发，例如本地保存、同步文件到达、启动、回到前台和受保护数据恢复可用。**不要恢复固定间隔轮询。**
- 系统后台刷新是补充入口，运行时间由 iOS 调度；处理到期取消，不承诺固定执行间隔或无限后台运行。
- 合并连续事件，保留同步期间到来的变化；排除同步自身写入造成的通知循环。多窗口共享监听必须维持到最后一个使用者退出，旧任务清理不能破坏新监听。
- 插件恢复必须保持脚本与版本、元数据一致；卸载或更新冲突不能留下数据库记录存在而文件已被删除的状态。
- 下载以单章为单位，保留详情 toolbar 的整部下载入口。持久下载任务不依附页面生命周期；可见图片请求与离线下载使用已有排队、优先级和缓存机制。

## 验证

- 当前工具链：Apple Silicon Mac、Xcode 27.1、Rust 1.96.1；最低 iOS 26。新系统 API 必须有 availability 保护。
- 优先使用 Xcode 编译和测试；能直接通过 Xcode 验证的内容，不要另建 Script / Smoke 可执行程序。新增 Swift 单元测试使用 Swift Testing，放入 package 的 test target。
- 现有宿主存储和插件测试需要 Rust 链接及隔离环境时，使用 `Scripts/test-core.sh`、`Scripts/test-plugins.sh`。插件测试不得访问真实插件目录或真实登录配置。
- 按改动选择验证范围。同步改动覆盖更新、删除、文件延迟到达、并发修改、取消及多窗口生命周期；纯文档改动无需编译整个应用。
- 未签名设备编译可使用：

  ```sh
  xcodebuild -project Willow.xcodeproj -scheme Willow -configuration Debug \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath /private/tmp/willow-device-build CODE_SIGNING_ALLOWED=NO build
  ```

- 汇报时区分编译、离线数据交换测试、真机 iCloud 云盘同步和系统后台唤醒；不得用本地测试通过代替真机验证。

## 发布、许可证与签名

- Release tag 使用 **`version/X.Y.Z`**，不使用 `vX.Y.Z`。
- GitHub Actions 发布未签名 IPA、对应 Rust 组件源码包和校验和，不上传 Xcode archive、个人签名信息或开发环境文件。
- Team ID 等个人配置只放在被忽略的 `Config/Signing.local.xcconfig`。保留可提交的模板和共享配置；不要写回 `project.pbxproj`。
- Breeze 的 MPL 声明、对应版本源码和其他依赖的独立许可声明必须保留。引用上游代码不等于获得其商标或资产的额外使用权，也不要擅自为 Willow 原创代码选择许可证。
- 更改 Rust 依赖后运行 `python3 Scripts/package-licenses.py`，更新随 App 打包的许可目录。发布使用 `--check` 检查目录是否过期，并提供对应源码归档。
- 源码归档使用明确的文件范围；不得把整个工作区、Cargo 用户目录或 Keychain 导出到归档。
- 提交或发布涉及相关文件时运行 `python3 Scripts/check-release-safety.py`。保留 Cargo.lock、共享 Xcode scheme、源码资源和许可文件。
