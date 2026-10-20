// swift-tools-version: 6.4
// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
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
        .systemLibrary(name: "CArchive"),
        .target(name: "RuntimeManager", dependencies: ["LauncherCore", "DownloadEngine", "CArchive"]),
        .target(name: "Diagnostics", dependencies: ["LauncherCore"]),
        .target(name: "TestSupport", dependencies: ["LauncherCore", "DownloadEngine"]),
        .executableTarget(name: "CrashHarness", dependencies: ["DownloadEngine", "TestSupport"], path: "Tests/CrashHarness"),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore", "TestSupport"]),
        .testTarget(name: "DownloadEngineTests", dependencies: ["DownloadEngine", "TestSupport", "CrashHarness"]),
        .testTarget(name: "RuntimeManagerTests", dependencies: ["RuntimeManager", "TestSupport"]),
        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics", "LauncherCore"]),
    ],
    swiftLanguageModes: [.v6]
)
