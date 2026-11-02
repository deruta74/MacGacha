// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore
import DownloadEngine
import Sophon

struct PreDownloadCategory: Codable, Sendable, Hashable {
    let id: String
    let matchingField: String
    let containers: [String]
}
struct PreDownloadContainer: Codable, Sendable, Hashable {
    let rawID: String
    let object: ChunkObject
}

/// Immutable transfer descriptors. No game-file recipes or installed-build state.
struct PreDownloadPlan: Codable, Sendable, Equatable {
    let edition: String
    let region: Region
    let installation: FileSystemIdentity
    let sourceTag: String
    let targetTag: String
    let buildID: String
    let patchID: String
    let categories: [PreDownloadCategory]
    let voices: [String]
    let containers: [String: PreDownloadContainer]

    init(edition: String, region: Region, installation: FileSystemIdentity, sourceTag: String, targetTag: String,
        buildID: String, patchID: String, categories: [PreDownloadCategory], voices: Set<String>, containers: [String: PreDownloadContainer]) throws {
        self.edition = edition; self.region = region; self.installation = installation
        self.sourceTag = sourceTag; self.targetTag = targetTag; self.buildID = buildID; self.patchID = patchID
        self.categories = categories.map { PreDownloadCategory(id: $0.id, matchingField: $0.matchingField, containers: $0.containers.sorted()) }.sorted { $0.id < $1.id }
        self.voices = voices.sorted(); self.containers = containers
        try validate()
    }
    var digest: Digest { get throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var hash = StreamingHasher(.sha256); hash.update(try encoder.encode(self)); return hash.finalize()
    } }
    var id: SafeIdentifier { get throws { try SafeIdentifier("predownload-" + digest.hex) } }
    var bytes: Int64 { get throws { try containers.values.reduce(0) { try SpaceBudget.adding($0, $1.object.transferSize) } } }

    func validate() throws {
        guard GameDefinition.find(edition)?.region == region,
            [sourceTag, targetTag, buildID, patchID].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }),
            sourceTag != targetTag, categories.count <= 256, voices.count <= 32,
            voices == voices.sorted(), Set(voices).count == voices.count,
            categories.map(\.id) == categories.map(\.id).sorted(), Set(categories.map(\.id)).count == categories.count,
            containers.count <= InstallPlan.maximumObjects else { throw LauncherError.io("invalid pre-download plan") }
        var referenced = Set<String>()
        for category in categories {
            guard !category.id.isEmpty, category.id.utf8.count <= 256, !category.matchingField.isEmpty,
                category.matchingField.utf8.count <= 256, category.containers == category.containers.sorted(),
                Set(category.containers).count == category.containers.count else { throw LauncherError.io("invalid pre-download category") }
            referenced.formUnion(category.containers)
        }
        guard referenced == Set(containers.keys) else { throw LauncherError.io("orphan pre-download container") }
        for (id, container) in containers {
            let object = container.object, name = try SafeRelativePath(container.rawID)
            guard name.components.count == 1, container.rawID.utf8.count <= ChunkObject.maximumIDBytes,
                id == object.id, id == SophonPlanner.patchContainerIdentity(id: container.rawID, digest: object.decodedDigest),
                object.codec == .identity, object.transferSize > 0, object.transferSize == object.decodedSize,
                object.decodedDigest.algorithm == .md5, object.transferDigest == object.decodedDigest,
                !object.urls.isEmpty, object.urls.count <= InstallPlan.maximumURLsPerObject,
                object.urls.allSatisfy({ DeliveryHostPolicy.allows($0, region: region) }) else {
                throw LauncherError.io("invalid pre-download container")
            }
        }
        _ = try bytes
    }
}

struct PreDownloadState: Codable, Sendable, Equatable {
    let plan: PreDownloadPlan
    let planDigest: Digest
    var verified: Set<String> = []
    var completed = false
    var withdrawn = false
    init(plan: PreDownloadPlan) throws { self.plan = plan; planDigest = try plan.digest }
    func validate() throws {
        try plan.validate()
        guard planDigest == (try plan.digest), verified.isSubset(of: Set(plan.containers.keys)),
            !completed || verified == Set(plan.containers.keys) else { throw LauncherError.journalCorrupt("invalid pre-download state") }
    }
}
