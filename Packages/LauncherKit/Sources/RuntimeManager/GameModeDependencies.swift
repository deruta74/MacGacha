// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

/// Resolve only within an inspected tree, including relative symlinks. Files
/// map to their contained source; publication verifies each hard link's inode.
struct GameModeDependencyTree {
    enum Failure: Error { case missing, outside, invalid }
    let paths: Set<String>
    let directories: Set<String>
    let links: [String: String]
    let files: [String: SafeRelativePath]

    func resolve(_ components: [String]) throws -> [String] {
        var pending = Array(components.reversed()), resolved: [String] = [], followed = 0
        while let next = pending.popLast() {
            if next == "." || next.isEmpty { continue }
            if next == ".." {
                guard !resolved.isEmpty else { throw Failure.outside }
                resolved.removeLast(); continue
            }
            resolved.append(next)
            let key = resolved.joined(separator: "/")
            guard paths.contains(key) else { throw Failure.missing }
            if let target = links[key] {
                followed += 1
                guard followed <= 40, !target.hasPrefix("/") else { throw Failure.invalid }
                resolved.removeLast()
                pending.append(contentsOf: target.split(separator: "/", omittingEmptySubsequences: false).map(String.init).reversed())
            } else if !pending.isEmpty && !directories.contains(key) { throw Failure.missing }
        }
        return resolved
    }
}

struct GameModeDependencies {
    static let maximumSearchCandidates = 32768
    let runtime: GameModeDependencyTree
    let mirror: GameModeDependencyTree
    let sourceRoot: String
    let fs: ContainedFileSystem

    func validate(_ image: MachOLoadCommands.Image, originalParent: [String], helperParent: [String]) throws {
        // Parsing bounds do not bound the rpaths × dylibs expansion. Cap the
        // combined search work before allocating any candidate arrays.
        let searches = image.dylibs.reduce(0) { $0 + (($1 == "@rpath" || $1.hasPrefix("@rpath/")) ? image.rpaths.count : 1) }
        guard searches <= Self.maximumSearchCandidates else { throw LauncherError.io("Too many Game Mode dependency candidates") }
        for dylib in image.dylibs {
            let originalCandidates = candidates(dylib, rpaths: image.rpaths, parent: originalParent, helper: false)
            guard let original = try firstFile(originalCandidates, in: runtime) else { continue }
            let helperCandidates = candidates(dylib, rpaths: image.rpaths, parent: helperParent, helper: true)
            guard let target = try firstFile(helperCandidates, in: mirror),
                try fs.regularFileIdentity(at: original) == fs.regularFileIdentity(at: target) else {
                throw LauncherError.io("Game Mode dependency target changed")
            }
        }
    }

    /// nil marks an external search location, not a missing local candidate.
    /// Never assert that a later local match beats an uninspectable earlier one.
    private func firstFile(_ candidates: [[String]?], in tree: GameModeDependencyTree) throws -> SafeRelativePath? {
        var external = false
        for candidate in candidates {
            guard let candidate else { external = true; continue }
            let resolved: [String]
            do { resolved = try tree.resolve(candidate) }
            catch GameModeDependencyTree.Failure.missing { continue }
            catch GameModeDependencyTree.Failure.outside { external = true; continue }
            catch { throw LauncherError.io("Invalid Game Mode dependency link") }
            guard let file = tree.files[resolved.joined(separator: "/")] else { continue }
            guard !external else { throw LauncherError.io("Unverifiable Game Mode dependency search") }
            return file
        }
        return nil
    }

    private func candidates(_ path: String, rpaths: [String], parent: [String], helper: Bool) -> [[String]?] {
        if path == "@rpath" || path.hasPrefix("@rpath/") {
            let tail = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
            return rpaths.map { expand($0, parent: parent, helper: helper).map { $0 + tail } }
        }
        return [expand(path, parent: parent, helper: helper)]
    }

    private func expand(_ path: String, parent: [String], helper: Bool) -> [String]? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "@loader_path" { return parent + parts.dropFirst() }
        if parts.first == "@executable_path" {
            // The long-running process and its children use the Unix loader.
            return (helper ? ["Contents", "MacOS"] : ["lib", "wine", "x86_64-unix"]) + parts.dropFirst()
        }
        if path == sourceRoot || path.hasPrefix(sourceRoot + "/") {
            return (helper ? ["Contents"] : []) + path.dropFirst(sourceRoot.count).split(separator: "/").map(String.init)
        }
        return nil
    }
}
