// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
@testable import RuntimeManager

@Suite struct StarRailFrameRateTests {
    @Test(arguments: [false, true]) func rewritePreservesOtherKeysAndTerminator(terminated: Bool) throws {
        var input = Data(#"{"FPS":60,"EnableVSync":false,"RenderScale":1.0,"Other":{"values":[1,"keep",null]}}"#.utf8)
        if terminated { input.append(0) }
        let output = try #require(StarRailFrameRate.rewrite(input, fps: 120))
        #expect((output.last == 0) == terminated)
        let decoded = try #require(JSONSerialization.jsonObject(with: terminated ? output.dropLast() : output) as? [String: Any])
        var before = try #require(JSONSerialization.jsonObject(with: terminated ? input.dropLast() : input) as? [String: Any])
        before["FPS"] = 120
        #expect(NSDictionary(dictionary: decoded).isEqual(to: before))
    }
    @Test func malformedValueIsReportedAndUntouched() {
        for text in ["not json", #"{"EnableVSync":false}"#, #"{"FPS":false}"#, #"{"FPS":"60"}"#, #"{"FPS":null}"#, "[]"] {
            let input = Data(text.utf8)
            #expect(StarRailFrameRate.rewrite(input, fps: 120) == nil)
            #expect(input == Data(text.utf8))
        }
    }
    @Test func parseQueryFindsAllModelValues() {
        let output = """
        HKEY_CURRENT_USER\\Software\\Cognosphere\\Star Rail
            GraphicsSettings_Model_h1234    REG_BINARY    7b22465053223a36307d00
            Unrelated    REG_BINARY    DEADBEEF
            GraphicsSettings_Model_h5678    REG_BINARY    7B22465053223A3132307D
            GraphicsSettings_Model_h9999    REG_SZ    not binary
        """
        let values = StarRailFrameRate.parseQuery(output)
        #expect(values.map(\.name) == ["GraphicsSettings_Model_h1234", "GraphicsSettings_Model_h5678"])
        #expect(values.map(\.hex) == ["7b22465053223a36307d00", "7B22465053223A3132307D"])
    }
}
