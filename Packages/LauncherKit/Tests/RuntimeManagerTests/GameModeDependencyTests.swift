// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
@testable import RuntimeManager

private struct DependencyRegistration: GameModeRegistering { func register(_ app: URL) throws {} }

// Real load-command structure, without executable code or platform tools.
func gameModeMachO(rpaths: [String] = [], dylibs: [String] = []) -> Data {
    func word(_ n: UInt32) -> Data { withUnsafeBytes(of: n.littleEndian) { Data($0) } }
    var commands = Data()
    for (kind, paths) in [(UInt32(0x8000001c), rpaths), (UInt32(0xc), dylibs)] {
        for path in paths {
            let offset = kind == 0xc ? 24 : 12
            let size = (offset + path.utf8.count + 1 + 7) & ~7
            var command = word(kind) + word(UInt32(size)) + word(UInt32(offset))
            command.append(Data(repeating: 0, count: offset - command.count))
            command.append(Data(path.utf8)); command.append(Data(repeating: 0, count: size - command.count))
            commands.append(command)
        }
    }
    return word(0xfeedfacf) + word(0x01000007) + word(3) + word(6) + word(UInt32(rpaths.count + dylibs.count)) + word(UInt32(commands.count)) + word(0) + word(0) + commands
}

@Suite(.timeLimit(.minutes(1))) struct GameModeDependencyTests {
    @Test func readsThinAndEveryFatSliceAndRejectsBrokenCommands() throws {
        let paths = ["@loader_path/../..", "@loader_path/../../GStreamer.framework"]
        let thin = gameModeMachO(rpaths: paths, dylibs: ["@loader_path/library.dylib"])
        #expect(try MachOLoadCommands.loaderPaths(in: thin) == paths + ["@loader_path/library.dylib"])
        func big(_ n: UInt32) -> Data { withUnsafeBytes(of: n.bigEndian) { Data($0) } }
        let second = gameModeMachO(rpaths: ["@loader_path/second"])
        var fat = big(0xcafebabe) + big(2)
        for (offset, size) in [(48, thin.count), (48 + thin.count, second.count)] {
            fat += big(0x01000007) + big(3) + big(UInt32(offset)) + big(UInt32(size)) + big(0)
        }
        fat += thin + second
        #expect(try MachOLoadCommands.loaderPaths(in: fat) == paths + ["@loader_path/library.dylib", "@loader_path/second"])
        func little(_ n: UInt32) -> Data { withUnsafeBytes(of: n.littleEndian) { Data($0) } }
        func little64(_ n: UInt64) -> Data { withUnsafeBytes(of: n.littleEndian) { Data($0) } }
        let fat64 = little(0xcafebabf) + little(1) + little(0x01000007) + little(3)
            + little64(40) + little64(UInt64(thin.count)) + little(0) + little(0) + thin
        #expect(try MachOLoadCommands.loaderPaths(in: fat64) == paths + ["@loader_path/library.dylib"])
        // Byte-swapped 32-bit thin header, with no commands.
        let swapped = big(0xfeedface) + big(7) + big(3) + big(6) + big(0) + big(0) + big(0)
        #expect(try MachOLoadCommands.loaderPaths(in: swapped).isEmpty)
        var broken = thin; broken[36] = 0
        #expect(throws: (any Error).self) { try MachOLoadCommands.loaderPaths(in: broken) }
        for length in [4, 20, thin.count - 1] {
            #expect(throws: (any Error).self) { try MachOLoadCommands.loaderPaths(in: Data(thin.prefix(length))) }
        }
        var badOffset = thin; badOffset[40] = 255
        #expect(throws: (any Error).self) { try MachOLoadCommands.loaderPaths(in: badOffset) }
        var badFat = fat; badFat[16] = 255
        #expect(throws: (any Error).self) { try MachOLoadCommands.loaderPaths(in: badFat) }
        #expect(try MachOLoadCommands.loaderPaths(in: Data("#!/bin/sh".utf8)).isEmpty)
    }

    @Test func unixModuleRpathsKeepLibraryAndFrameworkTargets() async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.store.paths.root)
        try fs.writeAtomically(Data("framework".utf8), to: SafeRelativePath("\(source)/lib/GStreamer.framework/Versions/1.0/GStreamer"))
        try fs.writeAtomically(Data("library".utf8), to: SafeRelativePath("\(source)/lib/libsupport.dylib"))
        try fs.createSymbolicLink(at: SafeRelativePath("\(source)/lib/GStreamer.framework/Versions/Current"), target: "1.0")
        let module = gameModeMachO(rpaths: ["@loader_path/../..", "@loader_path/../../GStreamer.framework/Versions/Current", "@executable_path/../../GStreamer.framework/Versions/Current", bundle.root.path + "/lib/GStreamer.framework/Versions/Current"], dylibs: ["@loader_path/../../libsupport.dylib"])
        try fs.writeAtomically(module, to: SafeRelativePath("\(source)/lib/wine/x86_64-unix/winegstreamer.so"))
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: DependencyRegistration())
        let helper = try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue))
        let app = try RuntimeJSONFile.relativePath(helper.root.deletingLastPathComponent(), root: f.store.paths.root)
        let links = Dictionary(uniqueKeysWithValues: try fs.inspectTree(at: app, allowingExternalHardLinks: true).compactMap { entry in entry.linkTarget.map { (entry.path.description, $0) } })
        for name in ["wine", "GStreamer.framework", "libsupport.dylib"] { #expect(links[name] == "Contents/lib/\(name)") }
        #expect(links["lib"] == "Contents/lib")
        try await manager.validate(helper, bundle: bundle)
        try fs.moveItem(at: SafeRelativePath("\(app)/GStreamer.framework"), to: SafeRelativePath("removed-framework-link"), allowingNonRegularSource: true)
        await #expect(throws: (any Error).self) { try await manager.validate(helper, bundle: bundle) }
    }

    @Test(arguments: ["@loader_path", "@executable_path"])
    func unresolvableRelocatedDependencyRefusesHelper(token: String) async throws {
        let f = try BundleFixture(), bundle = try await gameModeTestBundle(f)
        let fs = try ContainedFileSystem(root: f.store.paths.root)
        let source = try RuntimeJSONFile.relativePath(bundle.root, root: f.store.paths.root)
        // A source-root dependency has no corresponding relocated parent in the app.
        try fs.createDirectory(at: SafeRelativePath("\(source)/policy-dir"))
        try fs.writeAtomically(gameModeMachO(rpaths: ["\(token)/../../../policy-dir"]), to: SafeRelativePath("\(source)/lib/wine/x86_64-unix/winebus.so"))
        let manager = GameModeHelper(paths: f.store.paths, icons: try FixedGameModeIcon(), registration: DependencyRegistration())
        await #expect(throws: (any Error).self) { try await manager.prepare(bundle: bundle, game: GameDefinition.all[0], componentIDs: f.bundle.components.map(\.rawValue)) }
    }
}
