// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
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
        #expect(Redactor.redact("?\(key.uppercased())=secret&lang=en") == "?\(key.uppercased())=<redacted>&lang=en")
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
    "app-passwd-v2", "client_secret", "account_id_v2", "rpc-auth-key-v2", "session_v2", "2token"])
func redactsSensitiveKeySubstringsEverywhere(key: String) throws {
    #expect(Redactor.redact(metadata: [key: "planted-secret"])[key] == "<redacted>")
    #expect(Redactor.redact("{\"\(key)\":\"planted-secret\"}") == "{\"\(key)\":\"<redacted>\"}")
    #expect(Redactor.redact("failed: {\"\(key)\":\"planted-secret\"}") == "failed: {\"\(key)\":\"<redacted>\"}")
    #expect(Redactor.redact("?\(key)=planted-secret&lang=en") == "?\(key)=<redacted>&lang=en")
}

@Test
func redactsColonAssignmentsAndWholeHeaderLines() {
    #expect(Redactor.redact(#"LoginResponse(token: "abc", id: 1)"#) == "LoginResponse(token: <redacted>, id: 1)")
    #expect(Redactor.redact("LoginResponse(game_token: abc, id: 1)") == "LoginResponse(game_token: <redacted> id: 1)")
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

@Test(arguments: ["left,planted-secret", "left;planted-secret", "left(planted-secret)"])
func queryValuesIncludePunctuation(value: String) {
    #expect(Redactor.redact("?password=\(value)&lang=en") == "?password=<redacted>&lang=en")
    #expect(Redactor.redact("&password=\(value)#fragment") == "&password=<redacted>#fragment")
}

@Test(arguments: ["%26", "%3B", "%23", "%3b"])
func encodedValueTerminatorsAndEncodedKeyPrefixes(separator: String) {
    #expect(Redactor.redact("?password=planted-secret\(separator)lang%3Den")
        == "?password=<redacted>\(separator)lang%3Den")
    #expect(Redactor.redact("%26uid%3D123") == "%26uid%3D<redacted>")
    #expect(Redactor.redact("%3Fltuid%3D123%26lang%3Den") == "%3Fltuid%3D<redacted>%26lang%3Den")
}

@Test(arguments: [#"Optional("planted-secret")"#, #"Box(raw: "planted-secret")"#,
    #"Box(raw: [Optional("planted-secret"), {"nested":"x)y"}])"#])
func redactsCompletePrintedSwiftValues(value: String) {
    #expect(Redactor.redact("Login(token: \(value), id: 1)") == "Login(token: <redacted>, id: 1)")
}

@Test(arguments: [#"AnyHashable("x-rpc-combo_token"): "planted-secret""#,
    #""X-Rpc-Combo_token" = planted-secret;"#, "'token': 'planted-secret'"])
func redactsQuotedAndWrappedKeys(input: String) {
    #expect(!Redactor.redact(input).contains("planted-secret"))
    #expect(Redactor.redact(input).contains("<redacted>"))
}

@Test(arguments: ["Bearer", "bAsIc", "DIGEST"])
func redactsAuthSchemeAndContainingHeaderNames(scheme: String) {
    #expect(Redactor.redact("Login(token: \(scheme) planted-secret, id: 1)") == "Login(token: <redacted> id: 1)")
    #expect(Redactor.redact("request Proxy-Authorization: \(scheme) planted-secret more-private\nnext")
        == "request Proxy-Authorization: <redacted>\nnext")
    #expect(Redactor.redact("request x-cookie-v2=\(scheme) planted-secret more-private\nnext")
        == "request x-cookie-v2=<redacted>\nnext")
}

@Test(arguments: [
    #"server(body: "{\"retcode\":0,\"data\":{\"game_token\":\"abc\"}}")"#,
    #"server(body: "{\\\"retcode\\\":0,\\\"data\\\":{\\\"game_token\\\":\\\"abc\\\"}}")"#,
])
func redactsEscapedJSONInFreeText(input: String) {
    #expect(!Redactor.redact(input).contains("abc"))
    #expect(Redactor.redact(input).contains("<redacted>"))
    #expect(Redactor.redact(Redactor.redact(input)) == Redactor.redact(input))
}

@Test(arguments: ["accountMid", "accountIdV2", "gameToken"])
func camelCaseSensitiveKeysAreNormalized(key: String) {
    #expect(Redactor.redact(metadata: [key: "planted-secret"])[key] == "<redacted>")
    #expect(!Redactor.redact("{\"\(key)\":\"planted-secret\"}").contains("planted-secret"))
    #expect(Redactor.redact("?\(key)=planted-secret&lang=en") == "?\(key)=<redacted>&lang=en")
}

@Test
func metadataKeysAreBoundedBeforeProcessing() {
    let key = String(repeating: "x", count: 1 << 20) + "token"
    let result = Redactor.redact(metadata: [key: "planted-secret"])
    #expect(result.count == 1)
    #expect(result.keys.allSatisfy { $0.utf8.count <= 256 })
    #expect(!result.values.contains("planted-secret"))
}

@Test
func processedMetadataKeysAndCollisionSuffixesStayBounded() {
    let expanding = String(repeating: "a token=x ", count: 25)
    let collisionPrefix = String(repeating: "k", count: 239) + "?token="
    let result = Redactor.redact(metadata: [expanding: "private", collisionPrefix + "x": "private", collisionPrefix + "y": "private"])
    #expect(result.count == 3)
    #expect(result.keys.allSatisfy { $0.utf8.count <= 256 })
    #expect(result.values.allSatisfy { $0 == "<redacted>" })
}

@Test
func mixedCaseContainingHeaderNamesConsumeTheLine() {
    #expect(Redactor.redact("request Proxy-AuThOrIzAtIoN: Bearer planted-secret more-private\nnext")
        == "request Proxy-AuThOrIzAtIoN: <redacted>\nnext")
}

@Test
func redactsRealCookieDescriptionsAndKeepsOrdinaryCookies() throws {
    let cookie = try #require(HTTPCookie(properties: [.domain: "example.test", .path: "/", .name: "ltoken_v2",
        .value: "cookie-private-value", .secure: "TRUE"]))
    let printed = String(describing: cookie)
    #expect(printed.contains("cookie-private-value"))
    #expect(!Redactor.redact(printed).contains("cookie-private-value"))
    let spaced = try #require(HTTPCookie(properties: [.domain: "example.test", .path: "/", .name: "ltoken_v2",
        .value: "cookie-private-left cookie-private-right"]))
    let redactedSpaced = Redactor.redact(String(describing: spaced))
    #expect(!redactedSpaced.contains("cookie-private-left"))
    #expect(!redactedSpaced.contains("cookie-private-right"))
    let ordinary = try #require(HTTPCookie(properties: [.domain: "example.test", .path: "/", .name: "lang", .value: "en-US"]))
    #expect(Redactor.redact(String(describing: ordinary)).contains("en-US"))
}

@Test(arguments: [
    "name: ltoken_v2 value: cookie-private-value", "name=ltoken_v2 value=cookie-private-value",
    #"<NSHTTPCookie name:"ltoken_v2" value:"cookie-private-value">"#,
    #"<NSHTTPCookie name:"ltoken_v2" value:"prefix>cookie-private-value">"#,
    "<NSHTTPCookie\nname: ltoken_v2\nvalue: cookie-private-value\n>",
])
func redactsCookieNameValuePairs(input: String) {
    #expect(!Redactor.redact(input).contains("cookie-private-value"))
    #expect(Redactor.redact(input).contains("<redacted>"))
    #expect(Redactor.redact(Redactor.redact(input)) == Redactor.redact(input))
}

@Test
func cookieNameScopeDoesNotCrossLinesOrCookieBoundaries() {
    let input = "name=ltoken_v2\nvalue=ordinary\n<NSHTTPCookie name=ltoken_v2 value=private>\n<NSHTTPCookie name=lang value=en-US>"
    let result = Redactor.redact(input)
    #expect(result.contains("value=ordinary"))
    #expect(result.contains("value=en-US"))
    #expect(!result.contains("value=private"))
}

@Test
func redactsTokenShapesButPreservesFileDigestsAndGenericEncodings() {
    let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.signature_abc-123"
    let hoyo = "v2_" + String(repeating: "a", count: 17)
    #expect(Redactor.redact("credential \(jwt) end") == "credential <redacted> end")
    #expect(Redactor.redact("credential \(hoyo) end") == "credential <redacted> end")
    let md5 = "d41d8cd98f00b204e9800998ecf8427e"
    let sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    let base64 = "YWJjZGVmZ2hpamtsbW5vcHFyc3R1dnd4eXowMTIzNDU2Nzg5"
    let ordinary = "MD5 \(md5) SHA256 \(sha256) data \(base64) short v2_1234567890123456"
    #expect(Redactor.redact(ordinary) == ordinary)
    #expect(!Redactor.redact(metadata: ["detail": jwt])["detail"]!.contains(jwt))
}

@Test(arguments: [
    ("password=ab,cd", "password=<redacted>"),
    ("token: abc)def#x", "token: <redacted>"),
    ("Login(token: abc)", "Login(token: <redacted>)"),
    (#"note="(" token: abc)def#x"#, #"note="(" token: <redacted>"#),
    ("password=abc}def]ghi#x", "password=<redacted>"),
])
func unquotedCredentialEndsRespectSurroundingSyntax(input: String, expected: String) {
    #expect(Redactor.redact(input) == expected)
}

@Test
func diagnosticLabelsAndNonHeaderSensitiveValuesKeepTheirContext() {
    for text in ["Session: restored 3 items", "URLSession: task 12 failed"] {
        #expect(Redactor.redact(text) == text)
    }
    #expect(Redactor.redact("token: opaque status remains") == "token: <redacted> status remains")
    #expect(Redactor.redact("x-rpc-combo_token: opaque more-private\nnext") == "x-rpc-combo_token: <redacted>\nnext")
    #expect(Redactor.redact("x-rpc-challenge: opaque more-private\nnext") == "x-rpc-challenge: <redacted>\nnext")
    #expect(Redactor.redact(metadata: ["Session": "opaque"])["Session"] == "<redacted>")
    #expect(Redactor.redact(#"{"Session":"opaque"}"#) == #"{"Session":"<redacted>"}"#)
}
