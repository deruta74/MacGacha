// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public enum RuntimeBackend: String, Codable, Sendable { case dxmt, d3dmetal }

public struct RuntimeOverlay: Codable, Sendable {
    public let source: SafeRelativePath
    public let destination: SafeRelativePath
    public init(source: SafeRelativePath, destination: SafeRelativePath) {
        self.source = source; self.destination = destination
    }
}

public struct RuntimeBundle: Codable, Sendable, Identifiable, Equatable {
    public let id: SafeIdentifier
    public let displayName: String
    /// One line for the Runtimes panel, e.g. "Wine 11.0 with game patches · DXMT 0.80".
    public let summary: String?
    public let backend: RuntimeBackend
    public let components: [SafeIdentifier]
    public let environment: [String: String]

    public init(id: SafeIdentifier, displayName: String, summary: String? = nil, backend: RuntimeBackend,
        components: [SafeIdentifier], environment: [String: String] = [:]) throws {
        try validateRuntimeText(displayName, field: "bundle name")
        if let summary { try validateRuntimeText(summary, field: "bundle summary") }
        guard !components.isEmpty, components.count <= 16, Set(components).count == components.count,
            environment.count <= 32, environment.allSatisfy({ key, value in
                !key.isEmpty && key.utf8.allSatisfy { (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }
                    && value.utf8.count <= 4096 && !value.utf8.contains(0)
            }) else { throw LauncherError.io("Invalid runtime bundle") }
        self.id = id; self.displayName = displayName; self.summary = summary; self.backend = backend
        self.components = components; self.environment = environment
    }

    private enum CodingKeys: CodingKey { case id, displayName, summary, backend, components, environment }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(SafeIdentifier.self, forKey: .id), displayName: c.decode(String.self, forKey: .displayName),
            summary: c.decodeIfPresent(String.self, forKey: .summary), backend: c.decode(RuntimeBackend.self, forKey: .backend), components: c.decode([SafeIdentifier].self, forKey: .components),
            environment: c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:])
    }

    func validate(components available: [RuntimeComponent]) throws {
        let selected = components.compactMap { id in available.first { $0.id == id } }
        guard selected.count == components.count, selected.allSatisfy({ $0.rootPath != nil }) else {
            throw LauncherError.io("Bundle component or rootPath is missing")
        }
        switch backend {
        case .dxmt:
            guard selected.count == 2, selected.filter({ $0.kind == .wine && $0.wineBinary != nil }).count == 1,
                selected.filter({ $0.kind == .dxmt && !$0.overlay.isEmpty }).count == 1,
                selected.allSatisfy({ $0.consent == nil }) else { throw LauncherError.io("Invalid DXMT bundle") }
        case .d3dmetal:
            guard selected.count == 1, let c = selected.first, c.kind == .d3dmetal,
                c.wineBinary != nil, c.consent == .appleGPTK else { throw LauncherError.io("Invalid D3DMetal bundle") }
        }
        for component in selected {
            var destinations = Set<String>()
            for overlay in component.overlay {
                guard overlay.destination.components.starts(with: ["lib", "wine"]),
                    overlay.destination.components.count == 3,
                    destinations.insert(overlay.destination.description.lowercased()).inserted else {
                    throw LauncherError.io("Invalid runtime overlay destination")
                }
            }
        }
    }
}
