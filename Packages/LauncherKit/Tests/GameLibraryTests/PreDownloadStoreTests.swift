// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Synchronization
import Testing
import LauncherCore
import DownloadEngine
import Sophon
import TestSupport
@testable import GameLibrary

@Suite struct PreDownloadStoreTests {
    @Test func descriptorIdentityIsCanonicalAndChangesWithSelectors() throws {
        let root = try TempDir(), fs = try ContainedFileSystem(root: root.url)
        let a = try cachePlan(fs: fs), b = try cachePlan(fs: fs, build: "promoted")
        let roundTrip = try JSONDecoder().decode(PreDownloadPlan.self, from: JSONEncoder().encode(a))
        try roundTrip.validate()
        #expect(try a.id == roundTrip.id)
        #expect(try a.digest != b.digest)
        #expect(a.containers.keys == b.containers.keys)
    }

    @Test func statePublicationReplacementAndDeletionAreContained() throws {
        let root = try TempDir(), fs = try ContainedFileSystem(root: root.url), plan = try cachePlan(fs: fs)
        let store = try PreDownloadStore(fs: fs)
        var state = try store.replace(plan)
        let object = try #require(plan.containers.values.first).object
        try fs.writeAtomically(Data("cache".utf8), to: store.part(object))
        state.verified.insert(object.id); state.completed = true; try store.save(state)
        #expect(try store.load() == state)
        let replacement = try cachePlan(fs: fs, build: "promoted")
        let next = try store.replace(replacement)
        #expect(next.verified == [object.id])
        #expect(try fs.readFile(at: store.part(object), maxBytes: 5) == Data("cache".utf8))
        try fs.writeAtomically(Data("user".utf8), to: SafeRelativePath("game.bin"))
        try store.remove()
        #expect(try store.load() == nil)
        #expect(try fs.readFile(at: SafeRelativePath("game.bin"), maxBytes: 4) == Data("user".utf8))
    }

    @Test func copiedStoreCannotBindToAnotherInstallation() throws {
        let a = try TempDir(), b = try TempDir(), fs = try ContainedFileSystem(root: a.url), other = try ContainedFileSystem(root: b.url)
        let store = try PreDownloadStore(fs: fs); _ = try store.replace(cachePlan(fs: fs))
        try other.writeAtomically(fs.readFile(at: PreDownloadStore.statePath, maxBytes: PreDownloadStore.maximumBytes), to: PreDownloadStore.statePath)
        #expect(throws: LauncherError.self) { try PreDownloadStore(fs: other).load() }
    }

    @Test func unsafeDescriptorAndOrphanReceiptAreRejected() throws {
        let root = try TempDir(), fs = try ContainedFileSystem(root: root.url), plan = try cachePlan(fs: fs)
        var data = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as? [String: Any])
        var containers = try #require(data["containers"] as? [String: [String: Any]])
        let id = try #require(containers.keys.first)
        var entry = try #require(containers[id]), object = try #require(entry["object"] as? [String: Any])
        object["urls"] = ["https://evil.test/container"]; entry["object"] = object; containers[id] = entry; data["containers"] = containers
        let bad = try JSONDecoder().decode(PreDownloadPlan.self, from: JSONSerialization.data(withJSONObject: data))
        #expect(throws: LauncherError.self) { try bad.validate() }
        var state = try PreDownloadState(plan: plan); state.verified.insert("orphan")
        #expect(throws: LauncherError.self) { try PreDownloadStore(fs: fs).save(state) }
    }

    @Test(arguments: [false, true]) func interruptedCleanupRetainsRecoverablePublication(deleting: Bool) throws {
        let root = try TempDir(), fault = CacheUnlinkFault(), fs = try ContainedFileSystem(root: root.url, fileOps: fault)
        let store = try PreDownloadStore(fs: fs), old = try cachePlan(fs: fs)
        _ = try store.replace(old)
        let object = try #require(old.containers.values.first).object
        try fs.writeAtomically(Data("cache".utf8), to: store.part(object))
        fault.armed.withLock { $0 = true }
        let next = try cachePlan(fs: fs, rawID: "replacement")
        #expect(throws: LauncherError.io("cache unlink interrupted")) {
            if deleting { try store.remove() } else { _ = try store.replace(next) }
        }
        if deleting { #expect(try store.load() == nil); try store.finishDeletion() }
        else {
            #expect(try store.load()?.plan == next)
            _ = try store.replace(next)
        }
        #expect(try fs.size(at: store.part(object)) == nil)
    }
}

func cacheDigest(_ data: Data) -> Digest { var h = StreamingHasher(.md5); h.update(data); return h.finalize() }
func cachePlan(fs: ContainedFileSystem, build: String = "future", target: String = "2.0", rawID: String = "raw") throws -> PreDownloadPlan {
    let digest = cacheDigest(Data("cache".utf8)), id = SophonPlanner.patchContainerIdentity(id: rawID, digest: digest)
    let object = ChunkObject(id: id, urls: [URL(string: "https://cdn.hoyoverse.com/raw")!], transferSize: 5,
        transferDigest: digest, decodedSize: 5, decodedDigest: digest)
    return try PreDownloadPlan(edition: "genshin", region: .global, installation: fs.rootIdentity(), sourceTag: "1.0", targetTag: target,
        buildID: build, patchID: "patch", categories: [PreDownloadCategory(id: "game", matchingField: "game", containers: [id])], voices: [],
        containers: [id: PreDownloadContainer(rawID: rawID, object: object)])
}

private final class CacheUnlinkFault: FileOps, Sendable {
    let armed = Mutex(false)
    let base = SystemFileOps()
    func write(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws -> Int { try base.write(descriptor, bytes: bytes) }
    func synchronize(_ descriptor: Int32, durable: Bool) throws { try base.synchronize(descriptor, durable: durable) }
    func rename(from source: String, in sourceDirectory: Int32, to destination: String, in destinationDirectory: Int32, exclusive: Bool) throws {
        try base.rename(from: source, in: sourceDirectory, to: destination, in: destinationDirectory, exclusive: exclusive)
    }
    func unlink(_ name: String, in directory: Int32, isDirectory: Bool) throws {
        if name.hasSuffix(".part"), armed.withLock({ value in let fail = value; value = false; return fail }) {
            throw LauncherError.io("cache unlink interrupted")
        }
        try base.unlink(name, in: directory, isDirectory: isDirectory)
    }
}
