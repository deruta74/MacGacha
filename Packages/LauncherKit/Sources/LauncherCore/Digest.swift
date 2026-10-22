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
        // Manifests normally contain exact-length ASCII. Avoid Unicode case
        // conversion/trimming and generic range searches for every chunk.
        // Preserve the public whitespace contract on the uncommon slow path.
        var candidate = hex.utf8.count == algorithm.hexLength ? hex : hex.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.makeContiguousUTF8()
        guard candidate.utf8.count == algorithm.hexLength else { throw LauncherError.invalidDigest(hex) }
        let normalized = try candidate.utf8.withContiguousStorageIfAvailable { bytes in
            try String(unsafeUninitializedCapacity: bytes.count) { output in
                for index in bytes.indices {
                    let byte = bytes[index]
                    if byte >= 48 && byte <= 57 || byte >= 97 && byte <= 102 { output[index] = byte }
                    else if byte >= 65 && byte <= 70 { output[index] = byte + 32 }
                    else { throw LauncherError.invalidDigest(hex) }
                }
                return bytes.count
            }
        }!
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
        data.withUnsafeBytes { update(buffer: $0) }
    }

    /// Borrows a synchronous decoder write buffer without allocating Data.
    package mutating func update(buffer: UnsafeRawBufferPointer) {
        switch state {
        case .sha256(var hasher):
            hasher.update(bufferPointer: buffer)
            state = .sha256(hasher)
        case .md5(var hasher):
            hasher.update(bufferPointer: buffer)
            state = .md5(hasher)
        }
    }

    public func finalize() -> Digest {
        switch state {
        case .sha256(let hasher):
            Digest(algorithm: .sha256, validatedHex: Self.hex(hasher.finalize()))
        case .md5(let hasher):
            Digest(algorithm: .md5, validatedHex: Self.hex(hasher.finalize()))
        }
    }

    private static func hex(_ digest: some ContiguousBytes) -> String {
        digest.withUnsafeBytes { bytes in
            String(unsafeUninitializedCapacity: bytes.count * 2) { output in
                var index = 0
                for byte in bytes {
                    let high = byte >> 4, low = byte & 15
                    output[index] = high < 10 ? high + 48 : high + 87
                    output[index + 1] = low < 10 ? low + 48 : low + 87
                    index += 2
                }
                return index
            }
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
