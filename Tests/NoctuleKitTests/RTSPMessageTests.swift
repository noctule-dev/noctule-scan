// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
@testable import NoctuleKit

private let describeSDP = "v=0\r\no=- 0000000000 0000000000 IN IP4 127.0.0.1\r\ns=scanner.au\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\na=sdplang:en\r\na=control:*\r\nm=audio 0 RTP/AVP 0\r\na=control:trackID=1\r\n"

private func describeResponse() -> Data {
    let head = "RTSP/1.0 200 OK\r\nCSeq: 1\r\nServer: Scanner Audio Server 0.0.1\r\nContent-Base: rtsp://192.0.2.10/au:scanner.au/\r\nContent-Type: application/sdp\r\nContent-Length: 157\r\n\r\n"
    return Data((head + describeSDP).utf8)
}

@Test func encodesSetup() {
    let r = RTSPRequest(method: "SETUP", url: "rtsp://h/au:scanner.au/trackID=1", cseq: 3,
                        headers: [("Transport", "RTP/AVP;unicast;client_port=50000")])
    #expect(String(decoding: r.encoded, as: UTF8.self) ==
        "SETUP rtsp://h/au:scanner.au/trackID=1 RTSP/1.0\r\nCSeq: 3\r\nUser-Agent: NoctuleScan\r\nTransport: RTP/AVP;unicast;client_port=50000\r\n\r\n")
}

@Test func parsesRealDescribeResponseInPieces() {
    #expect(describeSDP.utf8.count == 157)
    let data = describeResponse()
    var p = RTSPResponseParser()
    var out: [RTSPResponse] = []
    out += p.feed(data.prefix(30))
    out += p.feed(data.dropFirst(30).prefix(150))
    out += p.feed(data.dropFirst(180))
    #expect(out.count == 1)
    #expect(out.first?.statusCode == 200)
    #expect(out.first?.reason == "OK")
    #expect(out.first?.cseq == 1)
    #expect(out.first?.header("content-base") == "rtsp://192.0.2.10/au:scanner.au/")
    #expect(out.first?.header("Server") == "Scanner Audio Server 0.0.1")
    #expect(out.first?.body.count == 157)
    #expect(p.protocolError == nil)
}

@Test func parsesSessionWithTimeout() {
    var p = RTSPResponseParser()
    let r = p.feed(Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: 12345678;timeout=60\r\nTransport: RTP/AVP;unicast;client_port=50000-50001;server_port=6970\r\n\r\n".utf8))
    #expect(r.count == 1)
    #expect(r.first?.session?.id == "12345678")
    #expect(r.first?.session?.timeoutSeconds == 60)
}

@Test func sessionWithoutTimeout() {
    var p = RTSPResponseParser()
    let r = p.feed(Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\nSession: abc\r\n\r\n".utf8))
    #expect(r.first?.session == RTSPSession(id: "abc", timeoutSeconds: nil))
}

@Test func parsesPipelinedResponses() {
    var p = RTSPResponseParser()
    let two = "RTSP/1.0 200 OK\r\nCSeq: 4\r\n\r\nRTSP/1.0 200 OK\r\nCSeq: 5\r\nContent-Length: 2\r\n\r\nhi"
    let r = p.feed(Data(two.utf8))
    #expect(r.count == 2)
    #expect(r.map(\.cseq) == [4, 5])
    #expect(r.last?.body == Data("hi".utf8))
}

@Test func flagsMalformedStatusLine() {
    var p = RTSPResponseParser()
    let r = p.feed(Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
    #expect(r.isEmpty)
    #expect(p.protocolError != nil)
}

@Test func parsesRealSDP() throws {
    let sdp = "v=0\r\no=- 0000000000 0000000000 IN IP4 127.0.0.1\r\ns=scanner.au\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\na=sdplang:en\r\na=control:*\r\nm=audio 0 RTP/AVP 0\r\na=control:trackID=1\r\n"
    let d = try SDPAudioDescription.parse(sdp)
    #expect(d.payloadType == 0); #expect(d.control == "trackID=1")
}

@Test func sdpFallsBackToSessionControlAndRejectsNoAudio() throws {
    let d = try SDPAudioDescription.parse("v=0\r\na=control:*\r\nm=audio 0 RTP/AVP 8\r\n")
    #expect(d.payloadType == 8); #expect(d.control == "*")
    #expect(throws: RTSPError.self) { try SDPAudioDescription.parse("v=0\r\nm=video 0 RTP/AVP 96\r\n") }
}
