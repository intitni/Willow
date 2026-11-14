// swift-tools-version: 6.2
import PackageDescription
import Foundation

let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let testLinker: [LinkerSetting] = [
    .unsafeFlags(["-L", repository.appendingPathComponent("Bridge/target/debug").path]),
    .linkedLibrary("willow_bridge"),
]

// Host-side integration tests do not build the iOS-only SwiftUI entry point.
// The regular Xcode app graph is unchanged when this flag is absent.
let testsOnly = ProcessInfo.processInfo.environment["WILLOW_PACKAGE_TESTS_ONLY"] == "1"

let package = Package(
    name: "Core",
    defaultLocalization: "en",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: testsOnly ? [] : [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "CoreToast"),
        .testTarget(name: "CoreToastTests", dependencies: ["CoreToast"]),
        .target(name: "BreezeBridge", publicHeadersPath: "include"),
        .target(
            name: "BreezeRuntime",
            dependencies: ["BreezeBridge"],
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("z"),
                             .linkedFramework("Security"), .linkedFramework("SystemConfiguration")]
        ),
        .target(name: "CoreStorage", dependencies: ["BreezeRuntime"], resources: [.process("Resources")]),
        .target(name: "BreezePlugins", dependencies: ["BreezeRuntime", "CoreStorage"], resources: [.process("Resources")]),
        .testTarget(name: "CoreStorageTests", dependencies: ["CoreStorage", "BreezeRuntime"], linkerSettings: testLinker),
        .testTarget(name: "BreezePluginsTests", dependencies: ["CoreStorage", "BreezeRuntime", "BreezePlugins"],
                    resources: [.copy("Fixtures")], linkerSettings: testLinker),
    ] + (testsOnly ? [] : [
        .target(
            name: "Core",
            dependencies: ["CoreStorage", "BreezeRuntime", "BreezePlugins", "CoreToast"],
            resources: [.process("Resources")]
        ),
        .testTarget(name: "CoreTests", dependencies: ["Core"], linkerSettings: testLinker)
    ])
)
