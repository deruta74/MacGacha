// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import RuntimeManager

private struct ResolutionRegistration: GameModeRegistering { func register(_ app: URL) throws {} }

private func fatMachO(_ images: [Data]) -> Data {
    func big(_ n: UInt32) -> Data { withUnsafeBytes(of: n.bigEndian) { Data($0) } }
    var table = big(0xcafebabe) + big(UInt32(images.count)), offset = 8 + 20 * images.count
    for image in images {
        table += big(0x01000007) + big(3) + big(UInt32(offset)) + big(UInt32(image.count)) + big(0)
        offset += image.count
    }
    return table + images.reduce(Data(), +)
}

@Suite(.timeLimit(.minutes(1))) struct GameModeResolutionTests {
    @Test(arguments: [false, true], [false, true])
    func absentDependencyMustStayAbsent(weak: Bool, helperPresent: Bool) async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.store.paths.root)
        if helperPresent {
            try fs.writeAtomically(Data("optional library".utf8), to: SafeRelativePath("\(source)/bin/liboptional.dylib"))
        }
        let path = "@loader_path/../../bin/liboptional.dylib"
        try fs.writeAtomically(gameModeMachO(dylibs: weak ? [] : [path], weakDylibs: weak ? [path] : []),
            to: SafeRelativePath("\(source)/lib/wine/x86_64-unix/winebus.so"))
        #expect(try fs.itemType(at: SafeRelativePath("\(source)/lib/bin/liboptional.dylib")) == nil)
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: ResolutionRegistration())
        if helperPresent {
            await #expect(throws: (any Error).self) {
                try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue))
            }
        } else {
            let helper = try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue))
            try await manager.validate(helper, bundle: bundle)
        }
    }

    @Test func generatedResourceCannotCreateANewDependency() throws {
        let f = try BundleFixture(), fs = try ContainedFileSystem(root: f.store.paths.root)
        let runtime = GameModeDependencyTree(paths: [], directories: [], links: [:], files: [:])
        let mirror = GameModeDependencyTree(paths: ["Contents", "Contents/MacOS", "Contents/Resources", "Contents/Resources/Assets.car"],
            directories: ["Contents", "Contents/MacOS", "Contents/Resources"], links: [:], files: [:])
        let validator = GameModeDependencies(runtime: runtime, mirror: mirror, sourceRoot: f.store.paths.root.path, fs: fs)
        #expect(throws: (any Error).self) {
            try validator.validate(MachOLoadCommands.Image(dylibs: ["@loader_path/../Resources/Assets.car"]),
                originalParent: ["lib", "wine", "x86_64-unix"], helperParent: ["Contents", "MacOS"])
        }
    }

    @Test func dependencySearchWorkHasAFixedBound() throws {
        let f = try BundleFixture(), fs = try ContainedFileSystem(root: f.store.paths.root)
        let tree = GameModeDependencyTree(paths: [], directories: [], links: [:], files: [:])
        let validator = GameModeDependencies(runtime: tree, mirror: tree, sourceRoot: f.store.paths.root.path, fs: fs)
        let image = MachOLoadCommands.Image(rpaths: Array(repeating: "@loader_path/missing", count: 256),
            dylibs: Array(repeating: "@rpath/library.dylib", count: 256))
        #expect(throws: (any Error).self) { try validator.validate(image, originalParent: [], helperParent: []) }
    }

    @Test func orderedRpathSearchSkipsMissingCandidatesAndPreservesTarget() async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.store.paths.root)
        try fs.writeAtomically(gameModeMachO(rpaths: ["@loader_path/missing", "@loader_path/../.."], dylibs: ["@rpath/wine/x86_64-unix/driver.so"]),
            to: SafeRelativePath("\(source)/lib/wine/x86_64-unix/winebus.so"))
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: ResolutionRegistration())
        let helper = try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue))
        try await manager.validate(helper, bundle: bundle)
    }

    @Test(arguments: [false, true]) func rpathOrderCannotSkipAnExistingWrongTarget(wrongFirst: Bool) async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.store.paths.root)
        for parent in ["lib/bin", "bin", "lib/wine/x86_64-unix"] {
            try fs.writeAtomically(Data("same contents".utf8), to: SafeRelativePath("\(source)/\(parent)/libfoo.dylib"))
        }
        let rpaths = wrongFirst ? ["@loader_path/../../bin", "@loader_path"] : ["@loader_path", "@loader_path/../../bin"]
        try fs.writeAtomically(gameModeMachO(rpaths: rpaths, dylibs: ["@rpath/libfoo.dylib"]),
            to: SafeRelativePath("\(source)/lib/wine/x86_64-unix/winebus.so"))
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: ResolutionRegistration())
        if wrongFirst {
            await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue)) }
        } else {
            let helper = try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue))
            try await manager.validate(helper, bundle: bundle)
        }
    }

    @Test func differentPathsToTheSameHardLinkedDependencyAreAccepted() async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.store.paths.root)
        try fs.writeAtomically(Data("library".utf8), to: SafeRelativePath("\(source)/lib/bin/libfoo.dylib"))
        try fs.createHardLink(at: SafeRelativePath("\(source)/bin/libfoo.dylib"), to: SafeRelativePath("\(source)/lib/bin/libfoo.dylib"))
        try fs.writeAtomically(gameModeMachO(dylibs: ["@loader_path/../../bin/libfoo.dylib"]),
            to: SafeRelativePath("\(source)/lib/wine/x86_64-unix/winebus.so"))
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: ResolutionRegistration())
        let helper = try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue))
        try await manager.validate(helper, bundle: bundle)
    }

    @Test(arguments: [false, true]) func symlinkChainsCompareFinalInodes(sameTarget: Bool) async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.store.paths.root)
        for file in ["actual", "other"] {
            try fs.writeAtomically(Data("same contents".utf8), to: SafeRelativePath("\(source)/lib/shared/\(file).dylib"))
        }
        try fs.createSymbolicLink(at: SafeRelativePath("\(source)/lib/shared/alias.dylib"), target: "actual.dylib")
        try fs.createSymbolicLink(at: SafeRelativePath("\(source)/lib/bin/libfoo.dylib"), target: "../shared/alias.dylib")
        try fs.createSymbolicLink(at: SafeRelativePath("\(source)/bin/libfoo.dylib"), target: "../lib/shared/\(sameTarget ? "alias" : "other").dylib")
        try fs.writeAtomically(gameModeMachO(dylibs: ["@loader_path/../../bin/libfoo.dylib"]),
            to: SafeRelativePath("\(source)/lib/wine/x86_64-unix/winebus.so"))
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: ResolutionRegistration())
        if sameTarget {
            let helper = try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue))
            try await manager.validate(helper, bundle: bundle)
        } else {
            await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue)) }
        }
    }

    @Test func fatSlicesNeverShareTheirRpathLists() async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.store.paths.root)
        let slices = [gameModeMachO(rpaths: ["@loader_path"]),
            gameModeMachO(rpaths: ["@loader_path/.."], dylibs: ["@rpath/x86_64-unix/driver.so"])]
        let fat = fatMachO(slices), parsed = try MachOLoadCommands.images(in: fat)
        #expect(parsed.count == 2)
        #expect(parsed[0].rpaths == ["@loader_path"])
        #expect(parsed[1].rpaths == ["@loader_path/.."])
        try fs.writeAtomically(fat, to: SafeRelativePath("\(source)/lib/wine/x86_64-unix/winebus.so"))
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: ResolutionRegistration())
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue)) }
    }
}
