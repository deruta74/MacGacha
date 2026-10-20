import Foundation
import LauncherCore

public struct ConsentRecord: Codable, Sendable, Equatable {
    public let kind: ConsentKind
    public let componentVersion: String
    public let noticeDigest: Digest
    public let termsRevision: String
    public let acceptedAt: Date

    public init(kind: ConsentKind, componentVersion: String, noticeDigest: Digest, termsRevision: String, acceptedAt: Date) throws {
        _ = try SafeIdentifier(componentVersion)
        try validateRuntimeText(termsRevision, field: "terms revision")
        guard noticeDigest.algorithm == .sha256, acceptedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw LauncherError.io("Invalid consent digest or acceptance date")
        }
        self.kind = kind
        self.componentVersion = componentVersion
        self.noticeDigest = noticeDigest
        self.termsRevision = termsRevision
        self.acceptedAt = acceptedAt
    }

    private enum CodingKeys: String, CodingKey { case kind, componentVersion, noticeDigest, termsRevision, acceptedAt }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(kind: c.decode(ConsentKind.self, forKey: .kind), componentVersion: c.decode(String.self, forKey: .componentVersion),
            noticeDigest: c.decode(Digest.self, forKey: .noticeDigest), termsRevision: c.decode(String.self, forKey: .termsRevision),
            acceptedAt: c.decode(Date.self, forKey: .acceptedAt))
    }
}

public actor ConsentStore {
    private let url: URL
    private let clock: @Sendable () -> Date

    public init(url: URL, clock: @escaping @Sendable () -> Date = Date.init) {
        self.url = url
        self.clock = clock
    }

    public func isAccepted(_ kind: ConsentKind, version: String, termsRevision: String) -> Bool {
        guard let records = try? load() else { return false }
        return records.contains { $0.kind == kind && $0.componentVersion == version
            && $0.noticeDigest == AppleNotice.bodyDigest && $0.termsRevision == termsRevision }
    }

    public func accept(_ kind: ConsentKind, version: String, termsRevision: String) throws {
        let record = try ConsentRecord(kind: kind, componentVersion: version, noticeDigest: AppleNotice.bodyDigest,
            termsRevision: termsRevision, acceptedAt: clock())
        var records = try load()
        records.removeAll { $0.kind == kind }
        records.append(record)
        try RuntimeJSONFile.write(records, to: url, limit: 65_536)
    }

    public func revoke(_ kind: ConsentKind) throws {
        var records = try load()
        records.removeAll { $0.kind == kind }
        try RuntimeJSONFile.write(records, to: url, limit: 65_536)
    }

    private func load() throws -> [ConsentRecord] {
        guard let data = try RuntimeJSONFile.read(url, limit: 65_536) else { return [] }
        let records = try JSONDecoder().decode([ConsentRecord].self, from: data)
        guard records.count <= 64, Set(records.map { $0.kind.rawValue }).count == records.count else {
            throw LauncherError.io("Duplicate or excessive consent records")
        }
        return records
    }
}
