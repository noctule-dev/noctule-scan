// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
@testable import NoctuleMockScanner
@testable import NoctuleKit

// The opt-in command trace (`NOCTULE_TRACE`, a diagnostic for the quick-keys hang on the real SDS150). The sink
// is process-wide, so the suite is serialized and every test puts it back.

private final class Captured: Sendable {
    private let storage = Mutex<[String]>([])
    var lines: [String] { storage.withLock { $0 } }
    func add(_ line: String) { storage.withLock { $0.append(line) } }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct CommandTraceTests {
    @Test func offByDefaultAndNeverEvaluated() {
        CommandTrace.install(nil)
        let evaluated = Mutex(false)
        CommandTrace.log({ evaluated.withLock { $0 = true }; return "never" }())
        #expect(!evaluated.withLock { $0 })
        #expect(!CommandTrace.isOn)
    }

    @Test func linesCarryAMillisecondTimestamp() {
        let captured = Captured()
        CommandTrace.install { captured.add($0) }
        defer { CommandTrace.install(nil) }
        CommandTrace.log("hello")
        #expect(CommandTrace.isOn)
        // Other suites' clients run meanwhile and write to the same global sink.
        let line = captured.lines.first { $0.hasSuffix(" hello") } ?? ""
        #expect(line.hasPrefix("t="), "\(line)")
        #expect(line.hasSuffix(" hello"), "\(line)")
    }

    @Test func requestSummaryNamesOnlyTheSetValues() throws {
        #expect(CommandTrace.describe(try ScannerCommand("GLT", "SYS", "1")) == "GLT,SYS,1")
        var values = Array(repeating: "0", count: 100)
        values[7] = "2"
        #expect(CommandTrace.describe(try ScannerCommand("FQK", arguments: values)) == "FQK,[100 values: 7=2]")
        values[41] = "1"
        #expect(CommandTrace.describe(try ScannerCommand("SQK", arguments: ["7"] + values)) == "SQK,7,[100 values: 7=2, 41=1]")
        #expect(CommandTrace.describe(try ScannerCommand("FQK", arguments: Array(repeating: "0", count: 100)))
                == "FQK,[100 values: none]")
    }

    @Test func clientTracesSendsRepliesTimeoutsAndLateReplies() async throws {
        let captured = Captured()
        CommandTrace.install { captured.add($0) }
        defer { CommandTrace.install(nil) }

        let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 3), personality: .sds150,
                                     quickKeySetDelay: .zero)
        let path = try await mock.start()
        let client = ScannerClient(transport: SerialTransport(path: path), commandTimeout: .milliseconds(400))
        var failure: (any Error)?
        do {
            try await client.connect()
            _ = try await client.favoritesLists()
            try await client.setListKey(7, on: true)
            await mock.setFaults(MockFaults(dropNextReply: "FQK"))
            do {
                _ = try await client.listKeyStates()
                Issue.record("a dropped reply should time out")
            } catch ScannerClientError.timeout {}
        } catch { failure = error }
        await client.disconnect()
        await mock.stop()
        if let failure { throw failure }

        let lines = captured.lines
        func has(_ fragment: String) -> Bool { lines.contains { $0.contains(fragment) } }
        #expect(has(" send GLT,FL"), "\(lines)")
        #expect(lines.contains { $0.contains(" reply GLT xml GLT children=") && $0.contains(" ms") }, "\(lines)")
        #expect(has(" send FQK,[100 values: 7=2]"), "\(lines)")
        #expect(has(" reply FQK OK after "), "\(lines)")
        #expect(has(" timeout FQK after "), "\(lines)")

        let favorites = MockFavorites.default
        let names = favorites.lists.map(\.name) + favorites.systems.map(\.name) + favorites.children.map(\.name)
        for name in names {
            #expect(!lines.contains { $0.contains(name) }, "\(name) leaked into the trace")
        }
    }

    @Test func assemblerSaysWhenANewDocumentReplacesAnOpenOne() {
        let captured = Captured()
        CommandTrace.install { captured.add($0) }
        defer { CommandTrace.install(nil) }
        var assembler = SerialResponseAssembler()
        _ = assembler.ingest(Data("GLT,<XML>,\r<GLT>\r<FL Index=\"1\"/>\r".utf8))
        let out = assembler.ingest(Data("PSI,<XML>,\r<ScannerInfo>\r</ScannerInfo>\r".utf8))
        #expect(out.map(\.command) == ["PSI"])
        let dropped = captured.lines.filter { $0.contains("serial: dropped open GLT document") }
        #expect(dropped.count == 1, "\(captured.lines)")
        #expect(dropped.first?.contains(" bytes, 2 lines) for a new PSI document") == true, "\(dropped)")
    }

    @Test func assemblerSaysWhenADocumentDoesNotParse() {
        let captured = Captured()
        CommandTrace.install { captured.add($0) }
        defer { CommandTrace.install(nil) }
        var assembler = SerialResponseAssembler()
        let out = assembler.ingest(Data("GLT,<XML>,\r<GLT>\r<FL Index=\"1\" <<\r</GLT>\r".utf8))
        #expect(out.isEmpty)
        #expect(captured.lines.contains { $0.contains("serial: dropped GLT document: XML didn't parse (") }, "\(captured.lines)")
    }

    /// A paged `GLT` reply that can't be put together says why (a gap in the page numbers, too old, too big),
    /// with the command name only.
    @Test func assemblerSaysWhenItDropsPages() {
        let captured = Captured()
        CommandTrace.install { captured.add($0) }
        defer { CommandTrace.install(nil) }
        func page(_ number: Int, eot: Bool) -> String {
            "GLT,<XML>,\r<GLT>\r<FL Index=\"\(number)\"/>\r<Footer No=\"\(number)\" EOT=\"\(eot ? 1 : 0)\"/>\r</GLT>\r"
        }
        let clock = TestClock()
        var assembler = SerialResponseAssembler(now: { clock.now() }, maxDocumentBytes: 200)
        #expect(assembler.ingest(Data((page(1, eot: false) + page(3, eot: true)).utf8)).isEmpty)
        #expect(captured.lines.contains { $0.contains("serial: dropped GLT pages: page 3 where page 2 was due") },
                "\(captured.lines)")
        let gapLines = captured.lines.count

        #expect(assembler.ingest(Data(page(1, eot: false).utf8)).isEmpty)
        clock.advance(by: .seconds(11))
        #expect(assembler.ingest(Data("VOL,5\r".utf8)) == [.fields(command: "VOL", fields: ["5"])])
        #expect(captured.lines.dropFirst(gapLines).contains { $0.contains("serial: dropped GLT pages: older than") },
                "\(captured.lines)")
        let ageLines = captured.lines.count

        let many = (1...6).map { page($0, eot: $0 == 6) }.joined()
        #expect(assembler.ingest(Data(many.utf8)).isEmpty)
        #expect(captured.lines.dropFirst(ageLines).contains { $0.contains("serial: dropped GLT pages: too big") },
                "\(captured.lines)")
    }

    /// A page lost inside the assembler (cut off by a new document, or open too long) drops its reply at once,
    /// and the trace says so then, not at the next page's gap.
    @Test func assemblerSaysWhenALostPageDropsItsReply() {
        let captured = Captured()
        CommandTrace.install { captured.add($0) }
        defer { CommandTrace.install(nil) }
        func page(_ number: Int, eot: Bool) -> String {
            "GLT,<XML>,\r<GLT>\r<FL Index=\"\(number)\"/>\r<Footer No=\"\(number)\" EOT=\"\(eot ? 1 : 0)\"/>\r</GLT>\r"
        }
        let clock = TestClock()
        var assembler = SerialResponseAssembler(now: { clock.now() })
        _ = assembler.ingest(Data((page(1, eot: false) + "GLT,<XML>,\r<GLT>\r<FL Index=\"2\"/>\r").utf8))
        _ = assembler.ingest(Data("PSI,<XML>,\r<ScannerInfo>\r</ScannerInfo>\r".utf8))
        let cut = captured.lines.filter { $0.contains("serial: dropped GLT pages: ") }
        #expect(cut.count == 1, "\(captured.lines)")
        #expect(cut.first?.contains("serial: dropped GLT pages: a page cut off by a new PSI document") == true, "\(cut)")

        let before = captured.lines.count
        _ = assembler.ingest(Data((page(1, eot: false) + "GLT,<XML>,\r<GLT>\r").utf8))
        clock.advance(by: .seconds(11))
        _ = assembler.ingest(Data("VOL,5\r".utf8))
        let aged = captured.lines.dropFirst(before).filter { $0.contains("serial: dropped GLT pages: ") }
        #expect(aged.count == 1, "\(captured.lines)")
        #expect(aged.first?.contains("serial: dropped GLT pages: older than 10.0 seconds") == true, "\(aged)")
    }
}
