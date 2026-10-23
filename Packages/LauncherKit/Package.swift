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
        .library(name: "HoYoPlayAPI", targets: ["HoYoPlayAPI"]),
        .library(name: "Sophon", targets: ["Sophon"]),
        .library(name: "GameLibrary", targets: ["GameLibrary"]),
        .library(name: "Launch", targets: ["Launch"]),
    ],
    targets: [
        .target(name: "LauncherCore"),
        // Decompression only; CZstd.h is the public umbrella over unchanged upstream headers.
        .target(name: "CZstd", exclude: ["LICENSE", "VENDOR.txt"], publicHeadersPath: "include", cSettings: [
            .define("ZSTD_DISABLE_ASM", to: "1"), .define("ZSTD_LEGACY_SUPPORT", to: "0"),
            .unsafeFlags(["-Wno-everything"]),
        ]),
        .target(name: "DownloadEngine", dependencies: ["LauncherCore", "CZstd"]),
        .systemLibrary(name: "CArchive"),
        .target(name: "RuntimeManager", dependencies: ["LauncherCore", "DownloadEngine", "CArchive"]),
        .target(name: "Diagnostics", dependencies: ["LauncherCore"]),
        .target(name: "HoYoPlayAPI", dependencies: ["LauncherCore", "DownloadEngine"]),
        .target(name: "Sophon", dependencies: ["LauncherCore", "DownloadEngine"]),
        .target(name: "GameLibrary", dependencies: ["LauncherCore", "DownloadEngine", "Sophon"]),
        .target(name: "Launch", dependencies: ["LauncherCore", "RuntimeManager", "GameLibrary"]),
        .target(name: "TestSupport", dependencies: ["LauncherCore", "DownloadEngine"]),
        .executableTarget(name: "CrashHarness", dependencies: ["DownloadEngine", "GameLibrary", "Sophon", "TestSupport"], path: "Tests/CrashHarness"),
        .executableTarget(name: "ThroughputBenchmark", dependencies: ["LauncherCore", "DownloadEngine"], path: "Benchmarks/ThroughputBenchmark", exclude: ["README.md"]),
        .testTarget(name: "LauncherCoreTests", dependencies: ["LauncherCore", "TestSupport", "CrashHarness"]),
        .testTarget(name: "DownloadEngineTests", dependencies: ["DownloadEngine", "TestSupport", "CrashHarness"],
            resources: [.copy("Resources/zstd")]),
        .testTarget(name: "RuntimeManagerTests", dependencies: ["RuntimeManager", "TestSupport"]),
        .testTarget(name: "DiagnosticsTests", dependencies: ["Diagnostics", "LauncherCore"]),
        .testTarget(name: "HoYoPlayAPITests", dependencies: ["HoYoPlayAPI", "TestSupport"]),
        .testTarget(name: "SophonTests", dependencies: ["Sophon", "TestSupport"]),
        .testTarget(name: "GameLibraryTests", dependencies: ["GameLibrary", "TestSupport", "CrashHarness"]),
        .testTarget(name: "LaunchTests", dependencies: ["Launch", "TestSupport"]),
    ],
    swiftLanguageModes: [.v6]
)
