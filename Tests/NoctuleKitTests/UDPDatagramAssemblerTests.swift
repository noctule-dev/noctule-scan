// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
@testable import NoctuleKit

final class TestClock: Sendable {
    private let instant = Mutex(ContinuousClock.Instant.now)
    func now() -> ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(by duration: Duration) { instant.withLock { $0 += duration } }
}

private func gsi(_ body: String) -> Data { Data("GSI,<XML>,\(body)".utf8) }

@Test func lineResponses() {
    var a = UDPDatagramAssembler()
    #expect(a.feed(Data("MDL,SDS200\r".utf8)) == [.fields(command: "MDL", fields: ["SDS200"])])
}

@Test func multipleLinesInOneDatagram() {
    var a = UDPDatagramAssembler()
    #expect(a.feed(Data("VOL,2\rSQL,3\r\n".utf8)) == [
        .fields(command: "VOL", fields: ["2"]),
        .fields(command: "SQL", fields: ["3"]),
    ])
}

@Test func nulCharactersAreStripped() {
    var a = UDPDatagramAssembler()
    #expect(a.feed(Data("MDL,SDS\u{0}200\r\u{0}".utf8)) == [.fields(command: "MDL", fields: ["SDS200"])])
}

@Test func xmlNodeParsesAttributesAndChildren() throws {
    let root = try XMLNode.parse(Data(#"<A x="1"><B y="2"/><C/><B y="3"/></A>"#.utf8))
    #expect(root.name == "A")
    #expect(root.attributes == ["x": "1"])
    #expect(root.children.map(\.name) == ["B", "C", "B"])
    #expect(root.child("B")?.attributes["y"] == "2")
    #expect(root.child("Z") == nil)
}

@Test func xmlNodeThrowsOnMalformed() {
    #expect(throws: XMLNodeError.self) { try XMLNode.parse(Data("<A><B".utf8)) }
}

@Test func singleDocumentWithoutFooter() throws {
    var a = UDPDatagramAssembler()
    let out = a.feed(Data(#"GSI,<XML>,<?xml version="1.0"?><ScannerInfo Mode="Trunk Scan"><System Name="A"/></ScannerInfo>"#.utf8))
    guard case .xml("GSI", let root) = try #require(out.first) else { Issue.record(); return }
    #expect(root.attributes["Mode"] == "Trunk Scan")
    #expect(root.child("System")?.attributes["Name"] == "A")
}

@Test func payloadLeadingWhitespaceIsTrimmed() throws {
    var a = UDPDatagramAssembler()
    let out = a.feed(Data("GSI,<XML>, \r\n<ScannerInfo Mode=\"M\"/>".utf8))
    #expect(out.first?.command == "GSI")
}

@Test func mergesFragmentsInOrder() throws {
    var a = UDPDatagramAssembler()
    #expect(a.feed(gsi(#"<ScannerInfo Mode="M"><System Name="One"/><Footer No="1" EOT="0"/></ScannerInfo>"#)).isEmpty)
    let out = a.feed(gsi(#"<ScannerInfo><Department Name="Two"/><Footer No="2" EOT="1"/></ScannerInfo>"#))
    guard case .xml("GSI", let root) = try #require(out.first) else { Issue.record(); return }
    #expect(root.attributes["Mode"] == "M")
    #expect(root.children.map(\.name) == ["System", "Department"])
}

@Test func dropsSequenceGapThenRecovers() {
    var a = UDPDatagramAssembler()
    _ = a.feed(gsi(#"<ScannerInfo><System Name="One"/><Footer No="1" EOT="0"/></ScannerInfo>"#))
    #expect(a.feed(gsi(#"<ScannerInfo><System Name="Three"/><Footer No="3" EOT="1"/></ScannerInfo>"#)).isEmpty)
    #expect(a.feed(gsi(#"<ScannerInfo><System Name="B"/></ScannerInfo>"#)).count == 1)
}

@Test func expiresStaleSequences() {
    let clock = TestClock()
    var a = UDPDatagramAssembler(now: { clock.now() })
    _ = a.feed(gsi(#"<ScannerInfo><System Name="One"/><Footer No="1" EOT="0"/></ScannerInfo>"#))
    clock.advance(by: .seconds(11))
    #expect(a.feed(gsi(#"<ScannerInfo><System Name="Two"/><Footer No="2" EOT="1"/></ScannerInfo>"#)).isEmpty)
}

@Test func freshSequenceSurvivesWithinAge() {
    let clock = TestClock()
    var a = UDPDatagramAssembler(now: { clock.now() })
    _ = a.feed(gsi(#"<ScannerInfo><System Name="One"/><Footer No="1" EOT="0"/></ScannerInfo>"#))
    clock.advance(by: .seconds(5))
    #expect(a.feed(gsi(#"<ScannerInfo><System Name="Two"/><Footer No="2" EOT="1"/></ScannerInfo>"#)).count == 1)
}

@Test func nonPositiveFooterNumberIsDropped() {
    var a = UDPDatagramAssembler()
    #expect(a.feed(gsi(#"<ScannerInfo><Footer No="0" EOT="1"/></ScannerInfo>"#)).isEmpty)
    #expect(a.feed(gsi(#"<ScannerInfo><Footer No="x" EOT="1"/></ScannerInfo>"#)).isEmpty)
}

@Test func tooManyFragmentsDiscardsSequence() {
    var a = UDPDatagramAssembler(maxFragments: 2)
    _ = a.feed(gsi(#"<ScannerInfo><A/><Footer No="1" EOT="0"/></ScannerInfo>"#))
    _ = a.feed(gsi(#"<ScannerInfo><B/><Footer No="2" EOT="0"/></ScannerInfo>"#))
    #expect(a.feed(gsi(#"<ScannerInfo><C/><Footer No="3" EOT="1"/></ScannerInfo>"#)).isEmpty)
}

@Test func tooManyBytesDiscardsSequence() {
    var a = UDPDatagramAssembler(maxDocumentBytes: 100)
    _ = a.feed(gsi(#"<ScannerInfo><A/><Footer No="1" EOT="0"/></ScannerInfo>"#))
    let big = String(repeating: "x", count: 200)
    #expect(a.feed(gsi(#"<ScannerInfo><B Name="\#(big)"/><Footer No="2" EOT="1"/></ScannerInfo>"#)).isEmpty)
}

@Test func bareXMLContinuationUsesExpectedCommand() {
    var a = UDPDatagramAssembler()
    a.expectXML(for: "PSI")
    let out = a.feed(Data(#"<ScannerInfo Mode="X"/>"#.utf8))
    #expect(out.first?.command == "PSI")
}

@Test func bareXMLWithoutExpectationIsDropped() {
    var a = UDPDatagramAssembler()
    #expect(a.feed(Data(#"<ScannerInfo Mode="X"/>"#.utf8)).isEmpty)
}

@Test func malformedXMLIsDropped() {
    var a = UDPDatagramAssembler()
    #expect(a.feed(Data("GSI,<XML>,<ScannerInfo><System".utf8)).isEmpty)
}

@Test func invalidUTF8IsReplacedNotFatal() {
    var a = UDPDatagramAssembler()
    var bytes = Data("STS,0,ab".utf8); bytes.append(0xFF); bytes.append(contentsOf: Data(",x".utf8))
    guard case .fields("STS", let f) = a.feed(bytes).first else { Issue.record(); return }
    #expect(f[1] == "ab\u{FFFD}")
}

/// Paged replies over UDP (`XMLFragmentSequences`, shared with the serial assembler): an unfinished sequence
/// never merges with the next reply, and another command's footered document leaves it alone.
@Suite(.timeLimit(.minutes(1))) struct UDPDatagramAssemblerSequenceTests {
    private func glt(_ number: Int, eot: Bool, _ indexes: [Int]) -> Data {
        let rows = indexes.map { "<FL Index=\"\($0)\" Name=\"Mock List \($0)\"/>" }.joined()
        return Data("GLT,<XML>,<?xml version=\"1.0\"?><GLT>\(rows)<Footer No=\"\(number)\" EOT=\"\(eot ? 1 : 0)\"/></GLT>".utf8)
    }

    private func indexes(_ out: [ScannerResponse]) -> [String]? {
        guard out.count == 1, case .xml("GLT", let root)? = out.first else { return nil }
        return root.children.compactMap { $0.attributes["Index"] }
    }

    @Test func aNewFirstPageReplacesAnUnfinishedReply() {
        var a = UDPDatagramAssembler()
        #expect(a.feed(glt(1, eot: false, [1, 2])).isEmpty)
        #expect(a.feed(glt(2, eot: false, [3, 4])).isEmpty)
        #expect(a.feed(glt(1, eot: false, [7])).isEmpty)
        #expect(indexes(a.feed(glt(2, eot: true, [8, 9]))) == ["7", "8", "9"])
    }

    @Test func aFooteredDocumentOfAnotherCommandLeavesTheSequenceAlone() {
        var a = UDPDatagramAssembler()
        #expect(a.feed(glt(1, eot: false, [1, 2])).isEmpty)
        let push = a.feed(Data(#"PSI,<XML>,<ScannerInfo Mode="M"><System Name="A"/><Footer No="1" EOT="1"/></ScannerInfo>"#.utf8))
        #expect(push.map(\.command) == ["PSI"])
        #expect(indexes(a.feed(glt(2, eot: true, [3]))) == ["1", "2", "3"])
    }
}
