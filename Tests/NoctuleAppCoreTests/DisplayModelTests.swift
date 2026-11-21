// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleKitTestSupport
import NoctuleMockScanner
import NoctuleStore
@testable import NoctuleAppCore

private func status(_ lines: [(String, String)], flags: String? = nil, softKeys: String = "") throws -> DisplayStatus {
    let all = lines + [(softKeys, "")]
    let f = flags ?? String(repeating: "0", count: all.count)
    return try DisplayStatus(fields: [f] + all.flatMap { [$0.0, $0.1] })
}

private func info(mode: String?, screen: String? = nil) throws -> ScannerInfo {
    var attrs = ""
    if let mode { attrs += " Mode=\"\(mode)\"" }
    if let screen { attrs += " V_Screen=\"\(screen)\"" }
    return try ScannerInfo(xml: XMLNode.parse(Data("<ScannerInfo\(attrs)></ScannerInfo>".utf8)))
}

private func menuInfo(_ screen: String = "menu_selection", title: String = "Set Scan Selection") throws -> ScannerInfo {
    let xml = "<ScannerInfo Mode=\"Menu tree\" V_Screen=\"\(screen)\"><MenuSummary name=\"\(title)\" index=\"4293063672\" /></ScannerInfo>"
    return try ScannerInfo(xml: XMLNode.parse(Data(xml.utf8)))
}

private func pad(_ text: String) -> String { text.padding(toLength: 30, withPad: " ", startingAt: 0) }

private let trailingFields = ["1", "1", "0", "0", "", "", "0", "OFF", "3"]

/// A menu `STS` (sanitized; design §4.2): ten lines, every size flag 1.
private func menuSTS(_ rows: [(String, String)], extra: [String] = []) throws -> DisplayStatus {
    #expect(rows.count == 10)
    return try DisplayStatus(fields: ["1111111111"] + rows.flatMap { [$0.0, $0.1] } + extra + trailingFields)
}

private func listSTS(rowThree: String = "Set Nationwide Systems") throws -> DisplayStatus {
    let blank = (pad(""), pad(""))
    return try menuSTS([
        (pad("Set Scan Selection"), String(repeating: "_", count: 30)),
        (pad("Manage Quick Key Status"), String(repeating: "*", count: 30)),
        (pad("Set Nationwide Systems"), pad("")),
        (pad("Select Lists to Monitor"), pad("")),
        (pad("Set All Lists Off"), pad("")),
        (pad("Set All Lists On"), pad("")),
        blank, blank, blank, blank,
    ])
}

private func nameEntrySTS() throws -> DisplayStatus {
    let glyphs = String(repeating: "\u{FFFD}", count: 9) + " " + String(repeating: "\u{FFFD}", count: 10) + " "
        + String(repeating: "\u{FFFD}", count: 9)
    let blank = (pad(""), pad(""))
    return try menuSTS([
        (pad("Edit Name"), String(repeating: "_", count: 30)),
        (pad("Custom 9"), "*" + String(repeating: " ", count: 29)),
        blank, blank, blank, blank, blank, blank, blank,
        (glyphs, pad("")),
    ])
}

private func numberEntrySTS() throws -> DisplayStatus {
    let blank = (pad(""), pad(""))
    return try menuSTS([
        (pad("Set Range"), String(repeating: "_", count: 30)),
        (pad("30.0"), "*" + String(repeating: " ", count: 29)),
        blank, blank,
        (pad("          (mile)"), pad("")),
        blank, blank, blank, blank, blank,
    ])
}

@Suite struct DisplayModelTests {
    @Test func fixtureRowsAndSoftKeys() throws {
        var a = UDPDatagramAssembler()
        guard case .fields("STS", let f) = a.feed(fixture("sts-trunk-sds200-1.24.00.txt")).first else {
            Issue.record("no STS"); return
        }
        let m = DisplayModel(status: try DisplayStatus(fields: f), info: nil)
        #expect(m.rows.count == 16)
        #expect(m.softKeys == [SoftKey(key: .soft1, label: "SYSTEM"),
                               SoftKey(key: .soft2, label: "DEPT"),
                               SoftKey(key: .soft3, label: "CHANNEL")])
        #expect(!m.isMenu)
    }

    @Test func largeRowsFollowFlagMap() throws {
        let s = try status(Array(repeating: ("x", ""), count: 16), flags: "00001010100000000")
        let m = DisplayModel(status: s, info: nil)
        let large = m.rows.enumerated().filter { $0.element.large }.map(\.offset)
        #expect(large == [4, 6, 8])
        #expect(m.rows.count == 16)
    }

    @Test func maskSplitsSegments() throws {
        let s = try status([("ABCDEF", " **  *"), ("short", "*"), ("long", "*****"), ("none", "")])
        let m = DisplayModel(status: s, info: nil)
        let r0 = try #require(m.rows.first)
        #expect(r0.segments == [DisplaySegment(text: "A", highlighted: false),
                                DisplaySegment(text: "BC", highlighted: true),
                                DisplaySegment(text: "DE", highlighted: false),
                                DisplaySegment(text: "F", highlighted: true)])
        let r1 = try #require(m.rows.dropFirst().first)
        #expect(r1.segments == [DisplaySegment(text: "s", highlighted: true),
                                DisplaySegment(text: "hort", highlighted: false)])
        let r2 = try #require(m.rows.dropFirst(2).first)
        #expect(r2.segments == [DisplaySegment(text: "long", highlighted: true)])
        let r3 = try #require(m.rows.dropFirst(3).first)
        #expect(r3.segments == [DisplaySegment(text: "none", highlighted: false)])
        #expect(m.rows.count == 4)
    }

    @Test func menuDetectedFromInfo() throws {
        let s = try status([("a", "")])
        #expect(DisplayModel(status: s, info: try info(mode: "Menu Tree")).isMenu)
        #expect(DisplayModel(status: s, info: try info(mode: "Scan", screen: "TOP MENU")).isMenu)
        #expect(!DisplayModel(status: s, info: try info(mode: "Scan", screen: "trunk_scan")).isMenu)
        #expect(!DisplayModel(status: s, info: try info(mode: nil)).isMenu)
        #expect(!DisplayModel(status: s, info: nil).isMenu)
    }

    @Test func menuListHasNoSoftKeyRow() throws {
        let m = DisplayModel(status: try listSTS(), info: try menuInfo())
        #expect(m.isMenu)
        #expect(m.rows.count == 10)
        #expect(m.softKeys.isEmpty)
        #expect(m.rows[1].segments == [DisplaySegment(text: "Manage Quick Key Status       ", highlighted: true)])
    }

    @Test func titleMaskUnderlines() throws {
        let m = DisplayModel(status: try listSTS(), info: try menuInfo())
        #expect(m.rows[0].segments.first?.underlined == true)
        #expect(m.rows[0].segments.first?.highlighted == false)
        #expect(m.rows[2].segments.first?.underlined == false)
    }

    @Test func inputScreenKeepsSoftKeyRow() throws {
        let m = DisplayModel(status: try nameEntrySTS(), info: try menuInfo("menu_input", title: "Edit Name"))
        #expect(m.isMenu)
        #expect(m.rows.count == 9)
        #expect(m.softKeys.count == 3)
        #expect(m.softKeys.map(\.key) == [.soft1, .soft2, .soft3])
        #expect(m.softKeys.allSatisfy { $0.isGlyph && $0.label.isEmpty })
        #expect(m.rows[1].segments[0] == DisplaySegment(text: "C", highlighted: true))
    }

    @Test func inputSoftKeysSplitOnColumnRanges() throws {
        // Printable labels with spaces inside them, and a character in each gap column (9 and 20):
        // only the ranges 0..<9, 10..<20, 21..<30 give these labels.
        let line = "My Label9" + "X" + "Set  Name " + "Y" + "Ok Done Z"
        #expect(line.count == 30)
        let blank = (pad(""), pad(""))
        let status = try menuSTS(Array(repeating: blank, count: 9) + [(line, pad(""))])
        let m = DisplayModel(status: status, info: try menuInfo("menu_input", title: "Edit Name"))
        #expect(m.softKeys.map(\.label) == ["My Label9", "Set  Name", "Ok Done Z"])
        #expect(m.softKeys.allSatisfy { !$0.isGlyph })
    }

    @Test func numberEntryHasThreeBlankSoftKeys() throws {
        let m = DisplayModel(status: try numberEntrySTS(), info: try menuInfo("menu_input", title: "Set Range"))
        #expect(m.rows.count == 9)
        #expect(m.softKeys == [SoftKey(key: .soft1, label: "", isGlyph: false),
                               SoftKey(key: .soft2, label: "", isGlyph: false),
                               SoftKey(key: .soft3, label: "", isGlyph: false)])
    }

    @Test func scanScreenUnchanged() throws {
        var a = UDPDatagramAssembler()
        guard case .fields("STS", let f) = a.feed(fixture("sts-trunk-sds200-1.24.00.txt")).first else {
            Issue.record("no STS"); return
        }
        let m = DisplayModel(status: try DisplayStatus(fields: f), info: nil)
        #expect(m.rows.count == 16)
        #expect(m.softKeys == [SoftKey(key: .soft1, label: "SYSTEM"),
                               SoftKey(key: .soft2, label: "DEPT"),
                               SoftKey(key: .soft3, label: "CHANNEL")])
        #expect(m.softKeys.allSatisfy { !$0.isGlyph })
        #expect(m.rows.allSatisfy { $0.segments.allSatisfy { !$0.underlined } })
    }

    @Test func stsWithExtraCommasStillBuildsADisplay() throws {
        // A comma inside a row's text splits it into two fields and shifts every later field by one;
        // two commas shift by two.
        let blank = [pad(""), pad("")]
        let fields = ["1111111111", pad("Set Scan Selection"), String(repeating: "_", count: 30),
                      pad("Manage Quick Key Status"), String(repeating: "*", count: 30),
                      "Set Nationwide", " Systems", pad(""), "Select Lists", " to Monitor",
                      pad("")] + blank + blank + blank + blank + blank + blank + blank + trailingFields
        let status = try DisplayStatus(fields: fields)
        let m = DisplayModel(status: status, info: try menuInfo())
        #expect(m.rows.count == 10)
        #expect(m.softKeys.isEmpty)
    }

    @Test func softKeyLookupIgnoresCaseAndSpaces() throws {
        let m = DisplayModel(status: try status([("a", "")], softKeys: "  SYSTEM     DEPT   CHANNEL "), info: nil)
        #expect(m.softKey(labelled: " system ") == .soft1)
        #expect(m.softKey(labelled: "Dept") == .soft2)
        #expect(m.softKey(labelled: "channel") == .soft3)
        #expect(m.softKey(labelled: "SITE") == nil)
        let few = DisplayModel(status: try status([("a", "")], softKeys: "SYSTEM"), info: nil)
        #expect(few.softKeys == [SoftKey(key: .soft1, label: "SYSTEM")])
        #expect(few.softKey(labelled: "DEPT") == nil)
    }

    @Test func nonASCIIGlyphsReplaced() throws {
        let s = try status([("\u{01}AB\u{7F}é C", "")])
        let m = DisplayModel(status: s, info: nil)
        let r = try #require(m.rows.first)
        #expect(r.segments.map(\.text).joined() == "·AB·· C")
    }

    @Test func glyphsKeepMaskAlignment() throws {
        let m = DisplayModel(status: try status([("é😀AB", "  **")]), info: nil)
        let r = try #require(m.rows.first)
        #expect(r.segments == [DisplaySegment(text: "··", highlighted: false),
                               DisplaySegment(text: "AB", highlighted: true)])
    }

    @Test func mockScreenRowsAndSoftKeys() async throws {
        let mock = MockSDS200(scenario: .default, options: .init(clock: .stepped(at: 1)))
        let ports = try await mock.start()
        let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: ports.udpPort),
                                   commandTimeout: .seconds(2))
        var failure: (any Error)?
        var model: DisplayModel?
        do { try await client.connect(); model = DisplayModel(status: try await client.displayStatus(), info: nil) } catch { failure = error }
        await client.disconnect()
        await mock.stop()
        if let failure { throw failure }
        let m = try #require(model)
        #expect(m.rows.count == 16)
        #expect(m.softKeys == [SoftKey(key: .soft1, label: "SYSTEM"),
                               SoftKey(key: .soft2, label: "DEPT"),
                               SoftKey(key: .soft3, label: "CHANNEL")])
        #expect(m.rows.enumerated().filter { $0.element.large }.map(\.offset) == [4, 6, 8])
    }

    /// The SDS150's idle `STS` carries three icon glyph bytes (0x80, 0x81, 0x8D: an assumption, see
    /// `MockPersonality`) at columns 0-2 of its first line. Over serial they go through
    /// `SerialResponseAssembler` and `String(scannerBytes:)`: each lone byte must stay one character,
    /// or the highlight mask would shift (design §7.3).
    @Test func glyphBytesKeepTheirColumns() async throws {
        let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 0), personality: .sds150)
        let path = try await mock.start()
        let client = ScannerClient(transport: SerialTransport(path: path), commandTimeout: .seconds(2))
        var failure: (any Error)?
        var status: DisplayStatus?
        do { try await client.connect(); status = try await client.displayStatus() } catch { failure = error }
        await client.disconnect()
        await mock.stop()
        if let failure { throw failure }
        var display = try #require(status)
        let first = try #require(display.lines.first)
        #expect(first.text.count == 30)
        #expect(first.highlightMask.count == 30)
        // Highlight columns 3-5.
        display.lines[0].highlightMask = "   ***" + String(repeating: " ", count: 24)
        let row = try #require(DisplayModel(status: display, info: nil).rows.first)
        #expect(row.segments.map(\.text.count).reduce(0, +) == 30)
        #expect(row.segments.first?.text.hasPrefix("···") == true)
        #expect(row.segments.filter(\.highlighted).map(\.text) == ["   "])
        let drawn = row.segments.flatMap { segment in segment.text.map { ($0, segment.highlighted) } }
        #expect(drawn.count == 30)
        #expect(drawn.enumerated().filter { $0.element.1 }.map(\.offset) == [3, 4, 5])
    }

    @Test func monochromePalettesAreExact() {
        for model in ScannerModel.allCases {
            let bw = DisplayPalette.factory(model: model, mode: .blackOnWhite)
            let wb = DisplayPalette.factory(model: model, mode: .whiteOnBlack)
            let black = RGB(r: 0, g: 0, b: 0), white = RGB(r: 1, g: 1, b: 1)
            #expect(bw.background == white); #expect(bw.text == black)
            #expect(wb.background == black); #expect(wb.text == white)
            #expect(bw.highlightBackground == black); #expect(bw.highlightText == white)
            #expect(wb.highlightBackground == white); #expect(wb.highlightText == black)
        }
        let c = DisplayPalette.factory(model: .sds200, mode: .color)
        #expect(c.background != c.text)
    }
}
