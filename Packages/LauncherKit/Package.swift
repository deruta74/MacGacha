// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "LauncherKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "LauncherCore", targets: ["LauncherCore"]),
        .library(name: "DownloadEngine", targets: ["DownloadEngine"]),
        .library(name: "RuntimeManager", targets: ["RuntimeManager"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
    ],
    targets: [
        .target(name: "LauncherCore"),
        .target(name: "DownloadEngine", dependencies: ["LauncherCore"]),
        .target(name: "RuntimeManager", dependencies: ["LauncherCore", "DownloadEngine"]),
        .target(name: "Diagnostics", dependencies: ["LauncherCore"]),
        .target(name: "TestSupport", dependencies: ["LauncherCore", "DownloadEngine"]),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore", "TestSupport"]),
        .testTarget(name: "DownloadEngineTests", dependencies: ["DownloadEngine", "TestSupport"]),
        .testTarget(name: "RuntimeManagerTests", dependencies: ["RuntimeManager", "TestSupport"]),
        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics", "LauncherCore"]),
    ],
    swiftLanguageModes: [.v6]
)
