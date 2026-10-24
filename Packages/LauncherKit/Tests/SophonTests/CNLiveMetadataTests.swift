// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
import LauncherCore
import Sophon

@Test(.enabled(if: ProcessInfo.processInfo.environment["MACGACHA_LIVE_CN"] == "1"), .timeLimit(.minutes(2)))
func cnLiveGameListAndBuildMetadataOnly() async throws {
    let region = Region.mainlandChina
    let http = DeliveryHostPolicy.makeHTTPClient(region: region)
    defer { http.invalidate() }
    let games = try await withThrowingTaskGroup(of: GamesEnvelope.self) { group in
        group.addTask {
            let (head, body) = try await http.get(region.hypAPIURL("getGames"), byteRangeFrom: nil)
            guard head.status == 200 else { throw LauncherError.io("CN metadata HTTP status") }
            var data = Data()
            for try await piece in body {
                guard piece.count <= (2 << 20) - data.count else { throw LauncherError.io("CN metadata size limit") }
                data.append(piece)
            }
            return try JSONDecoder().decode(GamesEnvelope.self, from: data)
        }
        group.addTask { try await Task.sleep(for: .seconds(45)); throw LauncherError.transport("CN metadata deadline") }
        defer { group.cancelAll() }
        return try #require(try await group.next())
    }
    #expect(games.retcode == 0)
    #expect(games.data.games.contains { $0.id == "1Z8W5NHUQb" && $0.biz == "hk4e_cn" })
    let api = DeliveryAPI(http: http, region: region)
    let branch = try await api.branch(biz: "hk4e_cn")
    let build = try await api.build(branch)
    #expect(build.tag == branch.tag)
    #expect(!build.categories.isEmpty)
    // No manifest or chunk is fetched. Selector passwords never leave memory.
    #expect(build.categories.allSatisfy { $0.region == .mainlandChina })
}

private struct GamesEnvelope: Decodable, Sendable {
    struct Payload: Decodable, Sendable {
        struct Game: Decodable, Sendable { let id: String; let biz: String }
        let games: [Game]
    }
    let retcode: Int
    let data: Payload
}
