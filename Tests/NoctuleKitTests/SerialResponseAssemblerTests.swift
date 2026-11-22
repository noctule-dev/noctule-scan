// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKitTestSupport
@testable import NoctuleKit

/// The recorded `GSI` reply with the CR line endings the scanner sends over serial.
private func gsiSerial() -> String {
    String(decoding: fixture("sds150-gsi-serial.txt"), as: UTF8.self).replacingOccurrences(of: "\n", with: "\r")
}

private let stsLine = "STS,011,A,,B,,C,\r"

@Suite(.timeLimit(.minutes(3))) struct SerialResponseAssemblerTests {
    @Test func fieldsLine() {
        var a = SerialResponseAssembler()
        #expect(a.ingest(Data("MDL,SDS150\r".utf8)) == [.fields(command: "MDL", fields: ["SDS150"])])
    }

    @Test func newlineTerminatorAndCRLF() {
        var a = SerialResponseAssembler()
        let gcs = a.ingest(Data("GCS,CST=4,VOLT=4184mV:100%,CURR=0000mA,TEMP= 27.65C\n".utf8))
        #expect(gcs == [.fields(command: "GCS", fields: ["CST=4", "VOLT=4184mV:100%", "CURR=0000mA", "TEMP= 27.65C"])])
        #expect(a.ingest(Data("VOL,5\r\n".utf8)) == [.fields(command: "VOL", fields: ["5"])])
    }

    @Test func xmlDocument() throws {
        var a = SerialResponseAssembler()
        let out = a.ingest(Data(gsiSerial().utf8))
        #expect(out.count == 1)
        guard case .xml("GSI", let root) = try #require(out.first) else { Issue.record("not a GSI document"); return }
        #expect(root.name == "ScannerInfo")
        let info = try ScannerInfo(xml: root)
        #expect(info.system?.name == "County Roads")
        #expect(info.volume == 5)
        #expect(info.squelch == 2)
        #expect(info.signalBars == 0)
    }

    @Test func everySplitPoint() {
        let bytes = Array((gsiSerial() + stsLine).utf8)
        var whole = SerialResponseAssembler()
        let expected = whole.ingest(Data(bytes))
        #expect(expected.map(\.command) == ["GSI", "STS"])
        for i in 0...bytes.count {
            var a = SerialResponseAssembler()
            let out = a.ingest(Data(bytes[0..<i])) + a.ingest(Data(bytes[i...]))
            #expect(out == expected, "split at \(i)")
        }
    }

    @Test func footerRemoved() throws {
        let text = gsiSerial().replacingOccurrences(of: "</ScannerInfo>", with: "<Footer No=\"1\" EOT=\"1\"/>\r</ScannerInfo>")
        var a = SerialResponseAssembler()
        let out = a.ingest(Data(text.utf8))
        guard case .xml("GSI", let root) = try #require(out.first) else { Issue.record("not a GSI document"); return }
        #expect(out.count == 1)
        #expect(root.child("Footer") == nil)
        #expect(root.child("System") != nil)
    }

    @Test func truncatedDocumentThenReply() {
        let clock = TestClock()
        var a = SerialResponseAssembler(now: { clock.now() })
        let cut = gsiSerial().range(of: "<ConvFrequency")!.lowerBound
        #expect(a.ingest(Data(gsiSerial()[..<cut].utf8)).isEmpty)
        clock.advance(by: .seconds(11))
        #expect(a.ingest(Data("MDL,SDS150\r".utf8)) == [.fields(command: "MDL", fields: ["SDS150"])])
    }

    @Test func newHeaderAbandonsOpenDocument() {
        var a = SerialResponseAssembler()
        let cut = gsiSerial().range(of: "<ConvFrequency")!.lowerBound
        #expect(a.ingest(Data(gsiSerial()[..<cut].utf8)).isEmpty)
        let out = a.ingest(Data(gsiSerial().utf8))
        #expect(out.map(\.command) == ["GSI"])
        #expect(out.count == 1)
    }

    @Test func oversizeDocumentDropped() {
        var a = SerialResponseAssembler(maxDocumentBytes: 200)
        #expect(a.ingest(Data((gsiSerial() + "VOL,5\r").utf8)) == [.fields(command: "VOL", fields: ["5"])])
    }

    @Test func oversizeLineDropped() {
        var a = SerialResponseAssembler(maxLineBytes: 16)
        #expect(a.ingest(Data(String(repeating: "x", count: 40).utf8)).isEmpty)
        #expect(a.ingest(Data("\r".utf8)).isEmpty)
        #expect(a.ingest(Data("VOL,5\r".utf8)) == [.fields(command: "VOL", fields: ["5"])])
    }

    @Test func unparsableDocumentDropped() {
        var a = SerialResponseAssembler()
        #expect(a.ingest(Data("GSI,<XML>,\r<ScannerInfo Mode=\"x\">\r<System Name=\"A\"\r</ScannerInfo>\rVOL,5\r".utf8))
            == [.fields(command: "VOL", fields: ["5"])])
    }

    @Test func oversizeLineInsideDocumentDropsTheDocument() {
        var a = SerialResponseAssembler(maxLineBytes: 100)
        let long = "<Department Name=\"\(String(repeating: "x", count: 150))\" />"
        let text = "GSI,<XML>,\r<ScannerInfo Mode=\"x\">\r<System Name=\"A\" />\r\(long)\r</ScannerInfo>\rVOL,5\r"
        #expect(a.ingest(Data(text.utf8)) == [.fields(command: "VOL", fields: ["5"])])
    }

    @Test func selfClosingRootEndsTheDocument() {
        var a = SerialResponseAssembler()
        let out = a.ingest(Data("MSI,<XML>,\r<MSI Foo=\"x\"/>\rVOL,5\r".utf8))
        #expect(out == [
            .xml(command: "MSI", root: XMLNode(name: "MSI", attributes: ["Foo": "x"])),
            .fields(command: "VOL", fields: ["5"]),
        ])
    }

    @Test func invalidUTF8Kept() {
        var a = SerialResponseAssembler()
        let out = a.ingest(Data("STS,1,".utf8) + [0x1A, 0xB4] + Data(",\r".utf8))
        #expect(out.map(\.command) == ["STS"])
        #expect(out.count == 1)
    }
}

// `GLT` replies over serial come in pages (seen on the SDS150 and the SDS100, 2026-11-19; quick-keys design
// §3.1): every `GLT` document ends with `<Footer No="n" EOT="0|1"/>`, each page is its own `GLT,<XML>,`
// document, and the assembler hands the client one document with every page's elements, as the UDP
// assembler does. Fictional rows.

/// Page `number` of a `GLT,FL` reply of `last` pages, holding a list row per index, CR-separated.
private func gltPage(_ number: Int, of last: Int, _ indexes: [Int]) -> String {
    var lines = ["GLT,<XML>,", "<?xml version=\"1.0\" encoding=\"utf-8\"?>", "<GLT>"]
    lines += indexes.map { "<FL Index=\"\($0)\" Name=\"Mock List \($0)\" Monitor=\"On\" Q_Key=\"None\" N_Tag=\"None\"/>" }
    lines += ["<Footer No=\"\(number)\" EOT=\"\(number == last ? 1 : 0)\"/>", "</GLT>"]
    return lines.joined(separator: "\r") + "\r"
}

/// The `Index` of every child of a `GLT` document, and whether any child is a footer.
private func gltIndexes(_ response: ScannerResponse?) -> (indexes: [String], footer: Bool)? {
    guard case .xml("GLT", let root)? = response, root.name == "GLT" else { return nil }
    return (root.children.compactMap { $0.attributes["Index"] },
            root.children.contains { $0.name == "Footer" || $0.name == "Foot" })
}

/// A push in the `GSI` form, with no footer.
private func psiPush() -> String { gsiSerial().replacingOccurrences(of: "GSI,<XML>,", with: "PSI,<XML>,") }

@Suite(.timeLimit(.minutes(1))) struct SerialResponseAssemblerPagesTests {
    @Test func threePagesAreOneDocumentHoweverTheBytesSplit() throws {
        let bytes = Array((gltPage(1, of: 3, [1, 2, 3]) + gltPage(2, of: 3, [4, 5]) + gltPage(3, of: 3, [6])).utf8)
        for i in 0...bytes.count {
            var a = SerialResponseAssembler()
            let out = a.ingest(Data(bytes[0..<i])) + a.ingest(Data(bytes[i...]))
            #expect(out.count == 1, "split at \(i)")
            let glt = gltIndexes(out.first)
            #expect(glt?.indexes == ["1", "2", "3", "4", "5", "6"], "split at \(i)")
            #expect(glt?.footer == false, "split at \(i)")
        }
        // Seven bytes at a time, as `--fault split-writes` writes.
        var a = SerialResponseAssembler()
        var out: [ScannerResponse] = []
        for start in stride(from: 0, to: bytes.count, by: 7) {
            out += a.ingest(Data(bytes[start..<min(start + 7, bytes.count)]))
        }
        #expect(out.count == 1)
        #expect(gltIndexes(out.first)?.indexes == ["1", "2", "3", "4", "5", "6"])
    }

    @Test func aPushBetweenPagesComesOnItsOwn() throws {
        var a = SerialResponseAssembler()
        #expect(a.ingest(Data(gltPage(1, of: 2, [1, 2]).utf8)).isEmpty, "page 1 alone is not a reply")
        let push = a.ingest(Data(psiPush().utf8))
        #expect(push.map(\.command) == ["PSI"])
        guard case .xml("PSI", let root)? = push.first else { Issue.record("not a push"); return }
        #expect(root.name == "ScannerInfo")
        let rest = a.ingest(Data(gltPage(2, of: 2, [3]).utf8))
        #expect(rest.count == 1)
        #expect(gltIndexes(rest.first)?.indexes == ["1", "2", "3"])
    }

    @Test func otherRepliesBetweenPagesLeaveTheSequenceAlone() throws {
        var a = SerialResponseAssembler()
        let text = gltPage(1, of: 2, [1]) + "VOL,5\r" + stsLine + gltPage(2, of: 2, [2])
        let out = a.ingest(Data(text.utf8))
        #expect(out.map(\.command) == ["VOL", "STS", "GLT"])
        #expect(gltIndexes(out.last)?.indexes == ["1", "2"])
    }

    @Test func aGapDropsThatReplyAndTheNextOneWorks() throws {
        var a = SerialResponseAssembler()
        #expect(a.ingest(Data((gltPage(1, of: 3, [1, 2]) + gltPage(3, of: 3, [5])).utf8)).isEmpty)
        // The page that would have filled the gap has nothing to join any more.
        #expect(a.ingest(Data(gltPage(2, of: 3, [3, 4]).utf8)).isEmpty)
        let next = a.ingest(Data((gltPage(1, of: 2, [7]) + gltPage(2, of: 2, [8])).utf8))
        #expect(next.count == 1)
        #expect(gltIndexes(next.first)?.indexes == ["7", "8"])
    }

    /// A reply that never finished (pages 1 and 2 of 3, page 3 lost) can't swallow or merge with the next one:
    /// the next reply's `No="1"` starts afresh, so exactly one document comes out, holding only its own rows.
    @Test func aNewFirstPageReplacesAnUnfinishedReply() throws {
        var a = SerialResponseAssembler()
        let stale = gltPage(1, of: 3, [1, 2]) + gltPage(2, of: 3, [3, 4])
        #expect(a.ingest(Data(stale.utf8)).isEmpty)
        let out = a.ingest(Data((gltPage(1, of: 2, [7]) + gltPage(2, of: 2, [8, 9])).utf8))
        #expect(out.count == 1)
        #expect(gltIndexes(out.first)?.indexes == ["7", "8", "9"])
        // And nothing of the unfinished reply comes out later.
        #expect(a.ingest(Data(gltPage(3, of: 3, [5]).utf8)).isEmpty)
    }

    /// A page cut off by a new document (its closing line lost) loses its reply: the sequence is dropped then and
    /// there, so a later page 2 can't complete it with the cut page's rows missing.
    @Test func aPageCutOffByANewDocumentDropsItsReply() throws {
        var a = SerialResponseAssembler()
        #expect(a.ingest(Data(gltPage(1, of: 2, [1]).utf8)).isEmpty)
        let cut = "GLT,<XML>,\r<?xml version=\"1.0\" encoding=\"utf-8\"?>\r<GLT>\r<FL Index=\"2\" Name=\"Mock List 2\"/>\r"
        #expect(a.ingest(Data(cut.utf8)).isEmpty)
        #expect(a.ingest(Data(psiPush().utf8)).map(\.command) == ["PSI"])
        #expect(a.ingest(Data(gltPage(2, of: 2, [3]).utf8)).isEmpty)
        // The next reply still works.
        let next = a.ingest(Data(gltPage(1, of: 1, [4]).utf8))
        #expect(gltIndexes(next.first)?.indexes == ["4"])
    }

    /// Sequences are per command: a document of another command that carries a footer of its own (a whole one,
    /// `No="1" EOT="1"`) between two `GLT` pages is emitted on its own, and the `GLT` still completes.
    @Test func aFooteredDocumentOfAnotherCommandLeavesTheSequenceAlone() throws {
        var a = SerialResponseAssembler()
        let footeredGSI = gsiSerial().replacingOccurrences(
            of: "</ScannerInfo>", with: "<Footer No=\"1\" EOT=\"1\"/>\r</ScannerInfo>")
        let text = gltPage(1, of: 2, [1, 2]) + footeredGSI + gltPage(2, of: 2, [3])
        let out = a.ingest(Data(text.utf8))
        #expect(out.map(\.command) == ["GSI", "GLT"])
        guard case .xml("GSI", let gsi)? = out.first else { Issue.record("not a GSI document"); return }
        #expect(gsi.child("Footer") == nil)
        #expect(gltIndexes(out.last)?.indexes == ["1", "2", "3"])
    }

    @Test func aLonePageAndAFooterlessDocumentAreEmittedAsBefore() throws {
        var a = SerialResponseAssembler()
        let lone = a.ingest(Data(gltPage(1, of: 1, [9]).utf8))
        #expect(lone.count == 1)
        #expect(gltIndexes(lone.first)?.indexes == ["9"])
        #expect(gltIndexes(lone.first)?.footer == false)
        let gsi = a.ingest(Data(gsiSerial().utf8))
        #expect(gsi.map(\.command) == ["GSI"])
    }

    @Test func anEmptyReplyIsOneEmptyDocument() throws {
        var a = SerialResponseAssembler()
        let out = a.ingest(Data(gltPage(1, of: 1, []).utf8))
        #expect(out == [.xml(command: "GLT", root: XMLNode(name: "GLT"))])
    }

    @Test func aSequenceOlderThanTheMaxAgeIsDropped() throws {
        let clock = TestClock()
        var a = SerialResponseAssembler(now: { clock.now() })
        #expect(a.ingest(Data(gltPage(1, of: 2, [1]).utf8)).isEmpty)
        clock.advance(by: .seconds(11))
        #expect(a.ingest(Data(gltPage(2, of: 2, [2]).utf8)).isEmpty)
        #expect(a.ingest(Data("MDL,SDS150\r".utf8)) == [.fields(command: "MDL", fields: ["SDS150"])])
        // A sequence within the age still completes.
        #expect(a.ingest(Data(gltPage(1, of: 2, [3]).utf8)).isEmpty)
        clock.advance(by: .seconds(5))
        #expect(gltIndexes(a.ingest(Data(gltPage(2, of: 2, [4]).utf8)).first)?.indexes == ["3", "4"])
    }

    @Test func aSequenceOverTheByteLimitIsDropped() throws {
        let page = gltPage(1, of: 3, [1, 2, 3])
        var a = SerialResponseAssembler(maxDocumentBytes: page.utf8.count + 40)
        let text = page + gltPage(2, of: 3, [4, 5, 6]) + gltPage(3, of: 3, [7]) + "VOL,5\r"
        #expect(a.ingest(Data(text.utf8)) == [.fields(command: "VOL", fields: ["5"])])
    }

    @Test func aSequenceOverThePageLimitIsDropped() throws {
        var a = SerialResponseAssembler(maxFragments: 2)
        let text = gltPage(1, of: 3, [1]) + gltPage(2, of: 3, [2]) + gltPage(3, of: 3, [3])
        #expect(a.ingest(Data(text.utf8)).isEmpty)
        let two = a.ingest(Data((gltPage(1, of: 2, [1]) + gltPage(2, of: 2, [2])).utf8))
        #expect(gltIndexes(two.first)?.indexes == ["1", "2"])
    }
}
