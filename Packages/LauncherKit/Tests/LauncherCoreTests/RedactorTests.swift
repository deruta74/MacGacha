import Foundation
import Testing
import LauncherCore

@Test(arguments: [
    ("token=\"secret with spaces", "token=<redacted>"),
    ("token='secret with spaces\nnext line", "token=<redacted>\nnext line"),
    (#"password=\"secret\"&lang=en"#, "password=<redacted>&lang=en"),
    (#"password=\"secret with spaces"#, "password=<redacted>"),
    ("password=ab'cd&lang=en", "password=<redacted>&lang=en"),
    ("password=ab\"cd&lang=en", "password=<redacted>&lang=en"),
    (#"token="secret \"with\" spaces"&lang=en"#, "token=<redacted>&lang=en"),
])
func redactsMalformedAndEscapedQuotedValues(input: String, expected: String) {
    #expect(Redactor.redact(input) == expected)
}

@Test
func redactsStringifiedJSONAndBalancedCompositeValues() throws {
    let stringified = #"{"message":"{\"\\u0074oken\":\"planted-secret\"}"}"#
    #expect(!Redactor.redact(stringified).contains("planted-secret"))
    for value in [#"{"id":1,"secret":"xyz"}"#, #"[{"id":1},"xyz",[1,2]]"#,
        #"{"nested":[{"value":"a}b\"c"}],"secret":"xyz"}"#] {
        let input = "failed: {\"session\":\(value),\"lang\":\"en\"} trailing text"
        let result = Redactor.redact(input)
        #expect(result == "failed: {\"session\":\"<redacted>\",\"lang\":\"en\"} trailing text")
        #expect(!result.contains("xyz"))
    }
}

@Test
func redactsMixedMultilinePayloadsWithoutLosingTrailingNewlines() {
    let input = "request failed\n{\n  \"token\":\n    \"planted-secret\",\n  \"lang\": \"en\"\n}\n\n"
    let result = Redactor.redact(input)
    #expect(!result.contains("planted-secret"))
    #expect(result.contains("\"lang\": \"en\""))
    #expect(result.hasSuffix("\n\n"))
}

@Test
func redactsKnownSecrets() throws {
    #expect(Redactor.redact("GET /x?authkey=abc123&lang=en") == "GET /x?authkey=<redacted>&lang=en")
    #expect(Redactor.redact("Authorization: Bearer xyz") == "Authorization: <redacted>")
    #expect(Redactor.redact("Cookie: session=abc; lang=en\r\nSet-Cookie: ticket=def")
        == "Cookie: <redacted>\r\nSet-Cookie: <redacted>")
    #expect(Redactor.redact("{\"stoken\":\"q\"}") == "{\"stoken\":\"<redacted>\"}")
    for key in ["token", "authkey", "auth_key", "stoken", "ltoken", "cookie_token", "password", "session", "ticket"] {
        #expect(Redactor.redact("\(key.uppercased())=secret&lang=en") == "\(key.uppercased())=<redacted>&lang=en")
    }
    #expect(Redactor.redact("A plain sentence with Unicode: café 日本語") == "A plain sentence with Unicode: café 日本語")
    #expect(Redactor.redact("token=\"secret with spaces\" lang=en") == "token=<redacted> lang=en")
}

@Test
func redactsMetadataByKeyRegardlessOfValue() {
    let metadata = ["TOKEN": "opaque text", "Authorization": "Basic opaque", "cookie_token": "12345",
        "password": "contains no key syntax", "uid": "123456789", "version": "1.2.3", "detail": "ticket=secret"]
    let result = Redactor.redact(metadata: metadata)
    for key in ["TOKEN", "Authorization", "cookie_token", "password", "uid"] {
        #expect(result[key] == "<redacted>")
    }
    #expect(result["version"] == "1.2.3")
    #expect(result["detail"] == "ticket=<redacted>")
}

@Test
func redactsNestedJSONAndFreeTextErrors() throws {
    let input = #"{"metadata":{"ToKeN":"opaque","session":{"nested":"secret"}},"message":"failed: password=\"space secret\"","items":[{"ticket":123}],"lang":"en"}"#
    let output = Redactor.redact(input)
    #expect(!output.contains("opaque"))
    #expect(!output.contains("secret"))
    let object = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    #expect(object["lang"] as? String == "en")
    #expect(Redactor.redact(Redactor.redact(input)) == output)
}

@Test(arguments: ["ltoken_v2", "cookie_token_v2", "stoken_v2", "ltuid_v2", "ltmid_v2",
    "account_mid_v2", "game_token", "combo_token", "login_ticket", "e_hk4e_token",
    "app-passwd-v2", "client_secret", "account_id_v2", "rpc-auth-key-v2", "session_v2"])
func redactsSensitiveKeySubstringsEverywhere(key: String) throws {
    #expect(Redactor.redact(metadata: [key: "planted-secret"])[key] == "<redacted>")
    #expect(Redactor.redact("{\"\(key)\":\"planted-secret\"}") == "{\"\(key)\":\"<redacted>\"}")
    #expect(Redactor.redact("failed: {\"\(key)\":\"planted-secret\"}") == "failed: {\"\(key)\":\"<redacted>\"}")
    #expect(Redactor.redact("\(key)=planted-secret&lang=en") == "\(key)=<redacted>&lang=en")
}

@Test
func redactsColonAssignmentsAndWholeHeaderLines() {
    #expect(Redactor.redact(#"LoginResponse(token: "abc", id: 1)"#) == "LoginResponse(token: <redacted>, id: 1)")
    #expect(Redactor.redact("LoginResponse(game_token: abc, id: 1)") == "LoginResponse(game_token: <redacted>, id: 1)")
    #expect(Redactor.redact("x-rpc-combo_token: abc extra credentials; private\r\nlang: en")
        == "x-rpc-combo_token: <redacted>\r\nlang: en")
}

@Test(arguments: ["Authorization", "Cookie", "Set-Cookie"])
func redactsEqualsHeaderValuesThroughEndOfLine(key: String) {
    #expect(Redactor.redact("\(key)=Bearer abc; extra private\nnext") == "\(key)=<redacted>\nnext")
}

@Test(arguments: ["%3D", "%3d"])
func redactsPercentEncodedAssignments(separator: String) {
    let url = "https://example.test/?redirect=https%3A%2F%2Fexample.test%2F%3Fauthkey\(separator)abc%26lang%3Den"
    #expect(!Redactor.redact(url).contains("abc"))
    #expect(Redactor.redact(url).contains("authkey\(separator)<redacted>"))
}

@Test
func metadataRedactionPreservesCollidingKeys() {
    let result = Redactor.redact(metadata: ["token=one": "first", "token=two": "second", "token=three": "third"])
    #expect(result.count == 3)
    for key in ["token=<redacted>", "token=<redacted>#2", "token=<redacted>#3"] {
        #expect(result[key] == "<redacted>")
    }
}
