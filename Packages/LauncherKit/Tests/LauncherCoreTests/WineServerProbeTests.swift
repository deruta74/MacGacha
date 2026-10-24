// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Darwin
import Foundation
import Testing
import TestSupport
@testable import LauncherCore

@Suite(.timeLimit(.minutes(1))) struct WineServerProbeTests {
    @Test func identityComesFromPinnedPrefixAfterPathReplacement() async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            try fs.createDirectory(at: SafeRelativePath("prefix"))
            let original = try fs.pinDirectoryIfPresent(at: SafeRelativePath("prefix"))
            let pinned = try #require(original)
            let name = try WineServerProbe.directoryName(for: pinned)
            _ = try fs.publishDirectory(at: SafeRelativePath("prefix"), to: SafeRelativePath("old-prefix"))
            try fs.createDirectory(at: SafeRelativePath("prefix"))
            let replacement = try fs.pinDirectoryIfPresent(at: SafeRelativePath("prefix"))
            let current = try #require(replacement)
            #expect(try WineServerProbe.directoryName(for: pinned) == name)
            #expect(try WineServerProbe.directoryName(for: current) != name)
        }
    }

    @Test(arguments: ["root-mode", "server-mode", "root-link", "server-link", "lock-link", "socket-link", "lock-unreadable"])
    func unsafeServerNamespaceIsUncertain(attack: String) async throws {
        try await BlockingIO.run {
            let temp = try TempDir(), fs = try ContainedFileSystem(root: temp.url)
            try fs.createDirectory(at: SafeRelativePath("prefix"))
            let pinned = try fs.pinDirectoryIfPresent(at: SafeRelativePath("prefix"))
            let prefix = try #require(pinned)
            let name = try WineServerProbe.directoryName(for: prefix)
            try fs.createDirectory(at: SafeRelativePath("servers/\(name)"))
            try fs.writeAtomically(Data("untouched".utf8), to: SafeRelativePath("target"))
            let root = temp.url.appendingPathComponent("servers")
            let server = root.appendingPathComponent(name.description)
            switch attack {
            case "root-mode": try #require(chmod(root.path, 0o755) == 0)
            case "server-mode": try #require(chmod(server.path, 0o755) == 0)
            case "root-link":
                _ = try fs.publishDirectory(at: SafeRelativePath("servers"), to: SafeRelativePath("saved-servers"))
                try fs.createSymbolicLink(at: SafeRelativePath("servers"), target: "saved-servers")
            case "server-link":
                try fs.removeItem(at: SafeRelativePath("servers/\(name)"))
                try fs.createSymbolicLink(at: SafeRelativePath("servers/\(name)"), target: "../prefix")
            case "lock-link", "socket-link":
                let leaf = attack == "lock-link" ? "lock" : "socket"
                try fs.createSymbolicLink(at: SafeRelativePath("servers/\(name)/\(leaf)"), target: "../../target")
            default:
                try fs.writeAtomically(Data(), to: SafeRelativePath("servers/\(name)/lock"))
                try #require(chmod(server.appendingPathComponent("lock").path, 0) == 0)
            }
            defer { if attack == "lock-unreadable" { chmod(server.appendingPathComponent("lock").path, 0o600) } }
            #expect(throws: LauncherError.self) { try WineServerProbe(root: root).isIdle(prefix: prefix) }
            #expect(try fs.readFile(at: SafeRelativePath("target"), maxBytes: 100) == Data("untouched".utf8))
        }
    }

    @Test func acceptingSocketIsBusyAndStaleSocketIsIdleWithoutLock() async throws {
        try await BlockingIO.run {
            // sockaddr_un has a short pathname limit; use a private short root.
            let parent = try ContainedFileSystem(root: URL(fileURLWithPath: "/private/tmp"))
            let workspace = try SafeRelativePath("mg-" + UUID().uuidString)
            try parent.createDirectory(at: workspace)
            let root = workspace.resolved(against: URL(fileURLWithPath: "/private/tmp")), fs = try ContainedFileSystem(root: root)
            defer { try? parent.removeItem(at: workspace) }
            try fs.createDirectory(at: SafeRelativePath("prefix"))
            let pinned = try fs.pinDirectoryIfPresent(at: SafeRelativePath("prefix"))
            let prefix = try #require(pinned), name = try WineServerProbe.directoryName(for: prefix)
            try fs.createDirectory(at: name)
            let socketURL = root.appendingPathComponent(name.description).appendingPathComponent("socket")
            var address = sockaddr_un()
            let bytes = Array(socketURL.path.utf8) + [UInt8(0)]
            try #require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path))
            address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            var listener = socket(AF_UNIX, SOCK_STREAM, 0)
            try #require(listener >= 0)
            defer {
                if listener >= 0 { close(listener) }
                try? fs.withRootDirectoryDescriptor { _ = unlinkat($0, name.description + "/socket", 0) }
            }
            try #require(fcntl(listener, F_SETFD, FD_CLOEXEC) == 0)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            try #require(bound == 0)
            try #require(listen(listener, 1) == 0)
            #expect(try !WineServerProbe(root: root).isIdle(prefix: prefix))
            close(listener); listener = -1
            #expect(try WineServerProbe(root: root).isIdle(prefix: prefix))
        }
    }
}
