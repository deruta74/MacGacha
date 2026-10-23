// SPDX-License-Identifier: GPL-3.0-only
// MacGacha — https://github.com/deruta74/MacGacha — see LICENSE and NOTICE (additional term under GPL section 7(b)).
import Foundation
import Testing
@testable import Launch

struct HTTPRequestHeadTests {
    @Test func authorityControlsHostAndHopHeadersAreStripped() throws {
        let request = try HTTPRequestHead(Data("GET http://Origin.Test.:8080/x?q=secret HTTP/1.1\r\nHost: spoof.test\r\nConnection: keep-alive, X-Hop\r\nX-Hop: secret\r\nProxy-Authorization: secret\r\nKeep-Alive: timeout=2\r\nProxy-Connection: keep-alive\r\nTE: trailers\r\nTrailer: X-Trailer\r\nAccept: */*\r\n\r\n".utf8))
        #expect(request.authority.host == "origin.test" && request.authority.port == 8080)
        #expect(String(decoding: request.forwarded, as: UTF8.self) == "GET /x?q=secret HTTP/1.1\r\nAccept: */*\r\nHost: origin.test:8080\r\nConnection: close\r\n\r\n")
    }
    @Test(arguments: [
        "GET /x HTTP/1.1\r\n\r\n", "CONNECT blocked.test HTTP/1.1\r\n\r\n",
        "GET http://user@origin.test/x HTTP/1.1\r\n\r\n", "GET http://origin.test:abc/x HTTP/1.1\r\n\r\n",
        "GET http://origin.test:65536/x HTTP/1.1\r\n\r\n", "GET http://origin.test:0/x HTTP/1.1\r\n\r\n",
        "GET http://origin.test/x HTTP/1.1\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n",
        "GET http://origin.test/x HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
        "GET http://origin.test/x HTTP/1.1\r\nContent-Length: 1, 2\r\n\r\n",
        "GET http://origin.test/x HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n",
        "GET http://origin.test/x HTTP/1.1\r\nTransfer-Encoding: chunked, gzip\r\n\r\n",
        "GET http://origin.test/x HTTP/1.1\r\nX-Test: one\r\n two\r\n\r\n",
        "GET http://origin.test/x HTTP/1.1\nHost: origin.test\n\n",
        "GET http://origin.test/x HTTP/1.1\rHost: origin.test\r\n\r\n",
        "GET http://origin.test/x HTTP/1.1\r\nUpgrade: websocket\r\n\r\n",
        "GET http://origin.test/x#fragment HTTP/1.1\r\n\r\n",
    ]) func malformedRequestRejected(raw: String) {
        #expect(throws: (any Error).self) { _ = try HTTPRequestHead(Data(raw.utf8)) }
    }
    @Test func chunkedFramingPreservesBytesAndStopsBeforeNextMessage() throws {
        var frame = HTTPBodyFrame(.chunked)
        var output = Data(), buffer = Data()
        let wire = "3;test=yes\r\nabc\r\n2\r\nde\r\n0\r\nX-Sum: ok\r\n\r\n"
        for byte in wire.utf8 {
            buffer.append(byte)
            while let piece = try frame.take(from: &buffer, eof: false) { output.append(piece) }
        }
        #expect(frame.done && output == Data(wire.utf8))
        buffer.append(Data("NEXT".utf8))
        #expect(try frame.take(from: &buffer, eof: false) == nil && buffer == Data("NEXT".utf8))
    }
    @Test func chunkedPayloadMayContainArbitraryLineEndings() throws {
        let bytes = Data([0, 10, 13, 255])
        var buffer = Data("4\r\n".utf8) + bytes + Data("\r\n0\r\n\r\n".utf8)
        var frame = HTTPBodyFrame(.chunked), output = Data()
        let expected = buffer
        while let piece = try frame.take(from: &buffer, eof: true) { output.append(piece) }
        #expect(output == expected && frame.done)
    }
    @Test(arguments: ["xyz\r\n", "1\na\n0\n\n", "1\r\na!\r\n", "0\r\nContent-Length: 4\r\n\r\n"])
    func malformedChunksRejected(raw: String) {
        var frame = HTTPBodyFrame(.chunked), buffer = Data(raw.utf8)
        #expect(throws: (any Error).self) { while try frame.take(from: &buffer, eof: true) != nil {} }
    }
    @Test func responseFramingHonoursNoBodyAndRejectsAmbiguity() throws {
        for (method, status) in [("HEAD", 200), ("GET", 100), ("GET", 204), ("GET", 304)] {
            let head = try HTTPResponseHead(Data("HTTP/1.1 \(status) OK\r\nContent-Length: 99\r\n\r\n".utf8), method: method)
            #expect(head.body == .none)
        }
        #expect(throws: (any Error).self) {
            _ = try HTTPResponseHead(Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8), method: "GET")
        }
    }
}
