// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import DownloadEngine
import Sophon
import TestSupport
@testable import GameLibrary

@Suite struct SandboxFilesTests {
    @Test func detectsOnlyReadableRegularListAndPreservesConfigLines() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            let list = try SafeRelativePath("beyond_pkg_version")
            #expect(try SandboxFiles.detect(in: fs, listPath: list) == nil)
            try fs.writeAtomically(Data(), to: list)
            #expect(try SandboxFiles.detect(in: fs, listPath: list)?.version == nil)
            let config = try SafeRelativePath("config.ini")
            let original = "[General]\r\ngame_version=7.2\r\nwpf_version=7.1\r\nother=x\r\n"
            try fs.writeAtomically(Data(original.utf8), to: config)
            #expect(try SandboxFiles.detect(in: fs, listPath: list)?.version == "7.1")
            try SandboxFiles.writeConfigVersion("7.2", in: fs)
            #expect(String(decoding: try fs.readFile(at: config, maxBytes: 1024), as: UTF8.self) == original.replacingOccurrences(of: "wpf_version=7.1", with: "wpf_version=7.2"))
            try SandboxFiles.writeConfigVersion(nil, in: fs)
            #expect(String(decoding: try fs.readFile(at: config, maxBytes: 1024), as: UTF8.self) == "[General]\r\ngame_version=7.2\r\nother=x\r\n")
            try fs.removeFile(at: config)
            try SandboxFiles.writeConfigVersion("7.2", in: fs)
            #expect(try fs.itemType(at: config) == nil)
        }
    }
    @Test func quickChecksSizeWhileFullChecksDigestAndRejectsEscapingList() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            let file = try SafeRelativePath("BeyondAssets/a.bin"), list = try SafeRelativePath("beyond_pkg_version")
            try fs.writeAtomically(Data("good".utf8), to: file)
            var hash = StreamingHasher(.md5); hash.update(Data("good".utf8))
            let line = "{\"remoteName\":\"BeyondAssets/a.bin\",\"md5\":\"\(hash.finalize().hex)\",\"fileSize\":4}\n"
            try fs.writeAtomically(Data(line.utf8), to: list)
            #expect(try SandboxFiles.verify(in: fs, listPath: list, mode: .full))
            try fs.writeAtomically(Data("evil".utf8), to: file)
            #expect(try SandboxFiles.verify(in: fs, listPath: list, mode: .quick))
            #expect(try !SandboxFiles.verify(in: fs, listPath: list, mode: .full))
            try fs.writeAtomically(Data(line.replacingOccurrences(of: "BeyondAssets/a.bin", with: "../other").utf8), to: list)
            #expect(throws: LauncherError.self) { try SandboxFiles.verify(in: fs, listPath: list, mode: .full) }
        }
    }
    @Test func legacyRecordDecodesWithoutSandbox() throws {
        let record = GameRecord(installPath: URL(fileURLWithPath: "/synthetic/game"), ownership: .adopted,
            executable: try SafeRelativePath("Game.exe"), installIdentity: FileSystemIdentity(volumeUUID: nil, device: 1, inode: 2))
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(GameRecord.self, from: data).sandbox == nil)
    }
}
