// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import LauncherCore

public struct DisplayChoice: Codable, Equatable, Sendable, Hashable {
    public var id: String
    public var name: String

    public init(id: String, name: String) { self.id = id; self.name = name }

    private enum CodingKeys: CodingKey { case id, name }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        try validate()
    }

    func validate() throws {
        guard UUID(uuidString: id) != nil, name.utf8.count <= 256,
            !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LauncherError.io("Invalid display choice")
        }
    }
}
