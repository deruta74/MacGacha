// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public enum ComponentKind: String, Codable, Sendable, CaseIterable {
    case wine, dxmt, d3dmetal
}

public enum SourceMode: String, Codable, Sendable {
    case download, importFromGPTK = "import"
}

public enum ArchiveFormat: String, Codable, Sendable {
    case tarXZ = "tar.xz", tarGZ = "tar.gz", zip
}

public enum ConsentKind: String, Codable, Sendable {
    case appleGPTK
}

public struct ComponentLicense: Codable, Sendable {
    public let name: String
    public let url: URL
    public let redistributable: Bool
    public let termsRevision: String

    public init(name: String, url: URL, redistributable: Bool, termsRevision: String) throws {
        try validateRuntimeText(name, field: "license name")
        try validateRuntimeText(termsRevision, field: "terms revision")
        try validateRuntimeURL(url)
        self.name = name
        self.url = url
        self.redistributable = redistributable
        self.termsRevision = termsRevision
    }

    private enum CodingKeys: String, CodingKey { case name, url, redistributable, termsRevision }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: container.decode(String.self, forKey: .name), url: container.decode(URL.self, forKey: .url),
            redistributable: container.decode(Bool.self, forKey: .redistributable),
            termsRevision: container.decode(String.self, forKey: .termsRevision))
    }
}

public struct RuntimeComponent: Codable, Sendable, Identifiable {
    public let id: SafeIdentifier
    public let kind: ComponentKind
    public let version: SafeIdentifier
    public let sourceMode: SourceMode
    public let url: URL?
    public let size: Int64?
    public let installedSize: Int64?
    public let sha256: Digest?
    public let archive: ArchiveFormat?
    public let license: ComponentLicense
    public let consent: ConsentKind?
    public let rootPath: SafeRelativePath?
    public let wineBinary: SafeRelativePath?
    public let overlay: [RuntimeOverlay]

    public init(id: SafeIdentifier, kind: ComponentKind, version: SafeIdentifier, sourceMode: SourceMode,
        url: URL? = nil, size: Int64? = nil, installedSize: Int64? = nil, sha256: Digest? = nil,
        archive: ArchiveFormat? = nil, license: ComponentLicense, consent: ConsentKind? = nil,
        rootPath: SafeRelativePath? = nil, wineBinary: SafeRelativePath? = nil, overlay: [RuntimeOverlay] = []) throws {
        guard id.rawValue == "\(kind.rawValue)-\(version.rawValue)" else {
            throw LauncherError.io("Runtime component ID must be <kind>-<version>")
        }
        if let url { try validateRuntimeURL(url) }
        guard size.map({ $0 >= 0 }) ?? true, installedSize.map({ $0 >= 0 }) ?? true else {
            throw LauncherError.io("Runtime sizes must be nonnegative")
        }
        guard sha256.map({ $0.algorithm == .sha256 }) ?? true else {
            throw LauncherError.io("Runtime digest must use SHA-256")
        }
        if sourceMode == .download {
            guard url != nil, size != nil, installedSize != nil, sha256 != nil, archive != nil else {
                throw LauncherError.io("Download runtime is missing URL, sizes, SHA-256 or archive format")
            }
        }
        guard kind != .d3dmetal || consent == .appleGPTK else {
            throw LauncherError.consentRequired(kind.rawValue)
        }
        guard consent == nil || kind == .d3dmetal else {
            throw LauncherError.consentRequired(kind.rawValue)
        }
        guard license.redistributable || consent != nil else {
            throw LauncherError.consentRequired(kind.rawValue)
        }
        self.id = id
        self.kind = kind
        self.version = version
        self.sourceMode = sourceMode
        self.url = url
        self.size = size
        self.installedSize = installedSize
        self.sha256 = sha256
        self.archive = archive
        self.license = license
        guard overlay.count <= 16, kind == .dxmt || overlay.isEmpty, kind != .dxmt || wineBinary == nil else {
            throw LauncherError.io("Invalid runtime layout")
        }
        self.consent = consent
        if let rootPath { try ArchivePolicy.validateRoot(rootPath) }
        self.rootPath = rootPath; self.wineBinary = wineBinary; self.overlay = overlay
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, version, sourceMode, url, size, installedSize, sha256, archive, license, consent, rootPath, wineBinary, overlay
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(SafeIdentifier.self, forKey: .id), kind: c.decode(ComponentKind.self, forKey: .kind),
            version: c.decode(SafeIdentifier.self, forKey: .version), sourceMode: c.decode(SourceMode.self, forKey: .sourceMode),
            url: c.decodeIfPresent(URL.self, forKey: .url), size: c.decodeIfPresent(Int64.self, forKey: .size),
            installedSize: c.decodeIfPresent(Int64.self, forKey: .installedSize), sha256: c.decodeIfPresent(Digest.self, forKey: .sha256),
            archive: c.decodeIfPresent(ArchiveFormat.self, forKey: .archive), license: c.decode(ComponentLicense.self, forKey: .license),
            consent: c.decodeIfPresent(ConsentKind.self, forKey: .consent),
            rootPath: c.decodeIfPresent(SafeRelativePath.self, forKey: .rootPath),
            wineBinary: c.decodeIfPresent(SafeRelativePath.self, forKey: .wineBinary),
            overlay: c.decodeIfPresent([RuntimeOverlay].self, forKey: .overlay) ?? [])
    }
}

public struct RuntimeManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let components: [RuntimeComponent]
    public let bundles: [RuntimeBundle]

    public init(schemaVersion: Int = 2, components: [RuntimeComponent], bundles: [RuntimeBundle] = []) throws {
        guard schemaVersion == 2 else { throw LauncherError.io("Unsupported runtime manifest schema") }
        guard components.count <= 256 else { throw LauncherError.io("Too many runtime components") }
        guard Set(components.map(\.id)).count == components.count else { throw LauncherError.io("Duplicate runtime component ID") }
        let destinations = components.map { $0.kind.rawValue + "/" + $0.version.rawValue.lowercased() }
        guard Set(destinations).count == components.count else { throw LauncherError.io("Colliding runtime install destinations") }
        guard bundles.count <= 64, Set(bundles.map { $0.id.rawValue.lowercased() }).count == bundles.count else {
            throw LauncherError.io("Invalid runtime bundles")
        }
        for bundle in bundles { try bundle.validate(components: components) }
        self.bundles = bundles
        self.schemaVersion = schemaVersion
        self.components = components
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, components, bundles }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(Int.self, forKey: .schemaVersion)
        guard schema == 2 else { throw LauncherError.io("Unsupported runtime manifest schema") }
        var array = try c.nestedUnkeyedContainer(forKey: .components)
        var components: [RuntimeComponent] = []
        while !array.isAtEnd {
            guard components.count < 256 else { throw LauncherError.io("Too many runtime components") }
            components.append(try array.decode(RuntimeComponent.self))
        }
        try self.init(schemaVersion: schema, components: components, bundles: c.decodeIfPresent([RuntimeBundle].self, forKey: .bundles) ?? [])
    }

    public static func load(from url: URL) throws -> RuntimeManifest {
        guard let data = try RuntimeJSONFile.read(url, limit: 1 << 20) else {
            throw LauncherError.io("Runtime manifest is missing")
        }
        return try JSONDecoder().decode(RuntimeManifest.self, from: data)
    }
}

func validateRuntimeText(_ value: String, field: String) throws {
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 1024 else {
        throw LauncherError.io("Invalid \(field)")
    }
}

private func validateRuntimeURL(_ url: URL) throws {
    guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
          url.absoluteString.utf8.count <= 8192, url.user == nil, url.password == nil else {
        throw LauncherError.io("Runtime URLs must be absolute HTTP(S) URLs without credentials")
    }
}
