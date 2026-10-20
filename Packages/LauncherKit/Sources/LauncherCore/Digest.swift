// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import CryptoKit
import Foundation

public enum DigestAlgorithm: String, Codable, Sendable {
    case sha256, md5

    public var hexLength: Int {
        switch self {
        case .sha256: 64
        case .md5: 32
        }
    }
}

public struct Digest: Hashable, Codable, Sendable {
    public let algorithm: DigestAlgorithm
    public let hex: String

    public init(algorithm: DigestAlgorithm, hex: String) throws {
        let normalized = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.utf8.count == algorithm.hexLength,
              normalized.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else {
            throw LauncherError.invalidDigest(hex)
        }
        self.init(algorithm: algorithm, validatedHex: normalized)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            algorithm: container.decode(DigestAlgorithm.self, forKey: .algorithm),
            hex: container.decode(String.self, forKey: .hex)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case algorithm, hex
    }

    fileprivate init(algorithm: DigestAlgorithm, validatedHex: String) {
        self.algorithm = algorithm
        self.hex = validatedHex
    }
}

public struct StreamingHasher: Sendable {
    private enum State: Sendable {
        case sha256(SHA256)
        case md5(Insecure.MD5)
    }

    private var state: State

    public init(_ algorithm: DigestAlgorithm) {
        switch algorithm {
        case .sha256: state = .sha256(SHA256())
        case .md5: state = .md5(Insecure.MD5())
        }
    }

    public mutating func update(_ data: Data) {
        switch state {
        case .sha256(var hasher):
            hasher.update(data: data)
            state = .sha256(hasher)
        case .md5(var hasher):
            hasher.update(data: data)
            state = .md5(hasher)
        }
    }

    public func finalize() -> Digest {
        switch state {
        case .sha256(let hasher):
            Digest(algorithm: .sha256, validatedHex: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        case .md5(let hasher):
            Digest(algorithm: .md5, validatedHex: hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }
}

public enum FileHasher {
    @concurrent
    public static func digest(of url: URL, algorithm: DigestAlgorithm, bufferSize: Int = 1 << 20) async throws -> Digest {
        guard bufferSize > 0 else {
            throw LauncherError.io("FileHasher buffer size must be positive")
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = StreamingHasher(algorithm)
            while true {
                guard !Task.isCancelled else { throw LauncherError.cancelled }
                let data = try autoreleasepool { try handle.read(upToCount: bufferSize) }
                guard let data, !data.isEmpty else { break }
                hasher.update(data)
            }
            return hasher.finalize()
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError.io(error.localizedDescription)
        }
    }
}
