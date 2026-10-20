import Foundation
import Testing
import LauncherCore

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
