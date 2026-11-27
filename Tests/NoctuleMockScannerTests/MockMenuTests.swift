// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
@testable import NoctuleMockScanner

// The mock's remote menus (design §4) through the real client stack: `ScannerClient` over
// `UDPTransport`. Every wait is bounded; `withMock` stops client and mock in every path.

private let mainTitle = "       --- M E N U ---"
private let listNames = ["Full Database", "Search with Scan", "Lakeview Fire", "County Roads", "Harbor Patrol",
                         "Transit", "Airport Ops", "Public Works", "Parks", "Marine", "Rail Yard", "Events"]
private let stars = String(repeating: "*", count: 30)
private let underscores = String(repeating: "_", count: 30)

private func isRejected(_ error: any Error) -> Bool {
    if case ScannerClientError.rejected = error { return true }
    return false
}

private func isTimeout(_ error: any Error) -> Bool {
    if case ScannerClientError.timeout = error { return true }
    return false
}

/// Menu, then Set Scan Selection, then Select Lists to Monitor, by keys.
private func openLists(_ client: ScannerClient) async throws {
    try await client.press(.menu)
    try await client.press(.enterYes)
    try await client.press(.enterYes)
}

/// Index of the highlighted row of a menu `STS` (mask all `*`), counting from the first row.
private func highlightedRow(_ status: DisplayStatus) -> Int? {
    status.lines.dropFirst().firstIndex { $0.highlightMask == stars }.map { $0 - 1 }
}

@Suite(.timeLimit(.minutes(1))) struct MockMenuTests {
    @Test func menuKeyEntersAndAvoidLeaves() async throws {
        try await withMock(at: 3) { _, client in
            #expect(try await client.scannerInfo().hasActiveChannel)
            try await client.press(.menu)
            let info = try await client.scannerInfo()
            #expect(info.isMenu)
            #expect(info.menuTitle == mainTitle)
            #expect(!info.hasActiveChannel)
            try await client.press(.avoid)
            let after = try await client.scannerInfo()
            #expect(!after.isMenu)
            #expect(after.hasActiveChannel)
        }
    }

    @Test func stsListScreenMatchesHardwareShape() async throws {
        try await withMock { _, client in
            try await client.press(.menu)
            let status = try await client.displayStatus()
            #expect(status.lines.count == 10)
            #expect(status.lines.allSatisfy { $0.sizeFlag == "1" })
            #expect(status.lines[0].highlightMask == underscores)
            #expect(status.lines[1].text == "Set Scan Selection            ")
            #expect(status.lines[1].highlightMask == stars)
            #expect(status.lines[5].text == "Analyze                       ")
            #expect(status.lines[2].highlightMask == String(repeating: " ", count: 30))
            #expect(status.lines[8].text == String(repeating: " ", count: 30))
            #expect(status.trailing == ["1", "1", "0", "0", "", "", "0", "OFF", "3"])
        }
    }

    @Test func scrollWrapsAndWindowScrollsByOne() async throws {
        try await withMock { _, client in
            try await openLists(client)
            var status = try await client.displayStatus()
            #expect(status.lines[0].text.hasPrefix("Select Lists to Monitor"))
            #expect(status.lines[1].text == "Full Database             :Off")
            #expect(status.lines[3].text == "Lakeview Fire             :On ")
            for _ in 0..<9 { try await client.press(.scrollRight) }
            status = try await client.displayStatus()
            for row in 0..<9 { #expect(status.lines[1 + row].text.hasPrefix(listNames[1 + row]), "row \(row)") }
            #expect(highlightedRow(status) == 8)
            for _ in 0..<3 { try await client.press(.scrollRight) }
            status = try await client.displayStatus()
            #expect(status.lines[1].text.hasPrefix(listNames[0]))
            #expect(highlightedRow(status) == 0)
            try await client.press(.scrollLeft)  // wraps back to the last row
            status = try await client.displayStatus()
            #expect(status.lines[9].text.hasPrefix(listNames[11]))
            #expect(highlightedRow(status) == 8)
        }
    }

    @Test func msiListsEveryItemAndOmitsAnalyze() async throws {
        try await withMock { _, client in
            try await client.press(.menu)
            let screen = try await client.menuScreen()
            #expect(screen.kind == .select)
            #expect(screen.title == mainTitle)
            #expect(screen.items.map(\.name) == ["Set Scan Selection", "Set Your Location", "Select Service Types",
                                                  "Search for...", "Display Options", "Settings"])
            #expect(screen.items.map(\.index) == [0, 1, 2, 3, 5, 6])
            #expect(screen.selectedIndex == 0)
        }
    }

    @Test func topMenuListsSelectServiceTypes() async throws {
        try await withMock { _, client in
            try await client.press(.menu)
            let top = try await client.menuScreen()
            let entry = try #require(top.items.first { $0.name == "Select Service Types" })
            #expect(top.items.map(\.name).firstIndex(of: "Select Service Types")
                    == top.items.map(\.name).firstIndex(of: "Set Your Location")! + 1)
            try await client.setMenuValue(String(entry.index))
            let screen = try await client.menuScreen()
            #expect(screen.title == "Select Service Types")
            #expect(screen.items.map(\.name) == ["Multi-Dispatch", "Law Dispatch", "Fire Dispatch", "EMS Dispatch",
                                                  "Custom 1", "Hospital", "Railroad"])
            #expect(screen.items.map(\.value) == ["On", "On", "On", "On", "On", "Off", "Off"])
            try await client.setMenuValue("5")  // Hospital on
            try await client.setMenuValue("0")  // Multi-Dispatch off
            let after = try await client.menuScreen()
            #expect(after.items.map(\.value) == ["Off", "On", "On", "On", "On", "On", "Off"])
        }
    }

    @Test func funcKeyShowsInProperty() async throws {
        try await withMock { _, client in
            #expect(try await client.scannerInfo().functionOn == false)
            try await client.press(.function)
            #expect(try await client.scannerInfo().functionOn == true)
            try await client.press(.digit1)
            #expect(try await client.scannerInfo().functionOn == false)
            try await client.press(.function)
            try await client.press(.function)
            #expect(try await client.scannerInfo().functionOn == true, "a second F is itself an F")
        }
    }

    @Test func msiOnAnOnOffListNamesEveryItemWithItsState() async throws {
        try await withMock { _, client in
            try await openLists(client)
            let screen = try await client.menuScreen()
            #expect(screen.items.map(\.name) == listNames)
            #expect(screen.items.map(\.index) == Array(0..<12))
            #expect(screen.items.map(\.value) == ["Off", "Off"] + Array(repeating: "On", count: 10))
        }
    }

    @Test func msvOpensSubmenuAndPicksValue() async throws {
        try await withMock { mock, client in
            try await client.press(.menu)
            try await client.setMenuValue("5")
            try await client.setMenuValue("0")
            #expect(try await client.menuScreen().items.map(\.name) == ["Decimal Format", "Hex Format"])
            #expect(try await client.menuScreen().selectedIndex == 0)
            try await client.setMenuValue("1")
            #expect(await mock.menuPath == [mainTitle, "Display Options"])
            try await client.setMenuValue("0")
            #expect(try await client.menuScreen().selectedIndex == 1)
            #expect(await mock.menuActions.last == "set Set ID Format (P25/Mot) Hex Format")
        }
    }

    @Test func msvTogglesOnOffItemAndStays() async throws {
        try await withMock { mock, client in
            try await openLists(client)
            try await client.setMenuValue("11")
            let screen = try await client.menuScreen()
            #expect(screen.items[11].value == "Off")
            #expect(screen.selectedIndex == 11)
            #expect(screen.title == "Select Lists to Monitor")
            let status = try await client.displayStatus()
            #expect(status.lines[1].highlightMask == stars)  // the radio's highlight didn't move
            #expect(status.lines[9].text == "Parks                     :On ")
            #expect(await mock.menuActions.last == "toggle Events Off")
            try await client.setMenuValue("11")
            #expect(try await client.menuScreen().items[11].value == "On")
            #expect(await mock.menuActions.last == "toggle Events On")
        }
    }

    @Test func setAllListsOffTurnsEveryListOff() async throws {
        try await withMock { mock, client in
            try await client.press(.menu)
            try await client.setMenuValue("0")
            try await client.setMenuValue("1")
            #expect(await mock.menuActions.last == "run Set All Lists Off")
            try await client.setMenuValue("0")
            #expect(try await client.menuScreen().items.allSatisfy { $0.value == "Off" })
        }
    }

    @Test func msvSetsNameAndReturnsToParent() async throws {
        try await withMock { mock, client in
            try await client.press(.menu)
            try await client.setMenuValue("3")
            try await client.setMenuValue("0")
            #expect(try await client.menuScreen().title == "Select Custom")
            #expect(try await client.menuScreen().items.map(\.name) == (0..<10).map { "Custom \($0)" })
            try await client.setMenuValue("9")
            try await client.setMenuValue("0")
            #expect(try await client.menuScreen().value == "Custom 9")
            try await client.setMenuValue("Harbor Net")
            #expect(await mock.menuActions.last == "set Edit Name Harbor Net")
            #expect(await mock.menuPath == [mainTitle, "Search for...", "Select Custom", "Harbor Net"])
            #expect(try await client.scannerInfo().menuScreenKind == .selection)
            try await client.press(.menu)
            #expect(try await client.menuScreen().items[9].name == "Harbor Net")
        }
    }

    @Test func msvSetsRangeAndLeavesTheMenu() async throws {
        try await withMock(at: 3) { mock, client in
            try await client.press(.menu)
            try await client.setMenuValue("1")
            try await client.setMenuValue("0")
            try await client.setMenuValue("31.0")
            #expect(!(await mock.isInMenu))
            #expect(await mock.menuPath == [])
            #expect(await mock.menuActions.last == "set Set Range 31.0")
            let left = try await client.scannerInfo()
            #expect(!left.isMenu)
            try await client.press(.menu)
            try await client.setMenuValue("1")
            try await client.setMenuValue("0")
            #expect(try await client.menuScreen().value == "31.0")
        }
    }

    @Test func entryScreensMatchHardwareShape() async throws {
        try await withMock { _, client in
            try await client.press(.menu)
            try await client.setMenuValue("1")
            try await client.setMenuValue("0")
            #expect(try await client.scannerInfo().menuScreenKind == .input)
            #expect(try await client.scannerInfo().menuTitle == "Set Range")
            var screen = try await client.menuScreen()
            #expect(screen.kind == .input)
            #expect(screen.input?.maxLength == 5)
            #expect(screen.input?.allowedCharacters == "0123456789.")
            var status = try await client.displayStatus()
            #expect(status.lines.count == 10)
            #expect(status.lines.allSatisfy { $0.sizeFlag == "1" })
            #expect(status.lines[0].text.hasPrefix("Set Range"))
            #expect(status.lines[0].highlightMask == underscores)
            #expect(status.lines[1].text.hasPrefix("30.0"))
            #expect(status.lines[1].highlightMask == "*" + String(repeating: " ", count: 29))
            #expect(status.lines[4].text == "          (mile)              ")
            #expect(status.lines[9].text == String(repeating: " ", count: 30))
            #expect(status.trailing == ["1", "1", "0", "0", "", "", "0", "OFF", "3"])

            try await client.press(.menu)  // back to Set Your Location
            try await client.press(.menu)  // back to the top
            try await client.setMenuValue("3")
            try await client.setMenuValue("0")
            try await client.setMenuValue("0")
            try await client.setMenuValue("0")
            screen = try await client.menuScreen()
            #expect(screen.title == "Edit Name")
            #expect(screen.input?.maxLength == 64)
            status = try await client.displayStatus()
            #expect(status.lines[1].text.hasPrefix("Custom 0"))
            #expect(status.lines[1].highlightMask == "*" + String(repeating: " ", count: 29))
            #expect(status.lines[9].text.count == 30)
            #expect(status.lines[9].text.allSatisfy { !($0.isASCII && $0.isLetter) })
        }
    }

    @Test func nameEntrySoftKeyRowIsRawNonUTF8Bytes() async throws {
        // The client decodes leniently, so check the bytes on a raw socket: the glyph row of §4.2.
        let options = MockSDS200.Options(clock: .stepped(at: 0))
        let mock = MockSDS200(scenario: .default, options: options)
        let ports = try await mock.start()
        let socket = try RawUDP(port: ports.udpPort)
        defer { socket.close() }
        var failure: (any Error)?
        do {
            for command in ["KEY,M,P", "MSV,,3", "MSV,,0", "MSV,,0", "MSV,,0"] {
                #expect(await socket.exchange(command) != nil)
            }
            let reply = try #require(await socket.exchange("STS"))
            let glyphs: [UInt8] = [0xC8, 0xC8, 0xC8, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0x20, 0xD8, 0xD0, 0xD9, 0xDA,
                                   0xDB, 0xDC, 0xDD, 0xDE, 0xDF, 0xD0, 0x20, 0xD0, 0xD1, 0xD2, 0xD3, 0xD4, 0xD5,
                                   0xD6, 0xD6, 0xD6]
            #expect(reply.range(of: Data(glyphs)) != nil)
            #expect(String(data: reply, encoding: .utf8) == nil)
        } catch {
            failure = error
        }
        await mock.stop()
        if let failure { throw failure }
    }

    @Test func menuCancelsEntryUnchanged() async throws {
        try await withMock { mock, client in
            try await client.press(.menu)
            try await client.setMenuValue("1")
            try await client.setMenuValue("0")
            for key in [FrontPanelKey.digit5, .dotNo, .digit5] { try await client.press(key) }
            #expect(try await client.displayStatus().lines[1].text.hasPrefix("5.5 "))
            try await client.press(.menu)
            #expect(await mock.menuPath == [mainTitle, "Set Your Location"])
            try await client.setMenuValue("0")
            #expect(try await client.menuScreen().value == "30.0")
            #expect(await mock.menuActions.isEmpty)
        }
    }

    @Test func numberKeysReplaceThenAppendAndEnterSaves() async throws {
        try await withMock { mock, client in
            try await client.press(.menu)
            try await client.setMenuValue("1")
            try await client.setMenuValue("0")
            for key in [FrontPanelKey.digit1, .digit2, .dotNo, .digit5] { try await client.press(key) }
            #expect(try await client.displayStatus().lines[1].text.hasPrefix("12.5 "))
            try await client.press(.enterYes)
            #expect(await mock.menuActions.last == "set Set Range 12.5")
            #expect(!(await mock.isInMenu))
        }
    }

    @Test func menuKeyClimbsOneLevelAndStaysAtTheTop() async throws {
        try await withMock { mock, client in
            try await openLists(client)
            #expect(await mock.menuPath.count == 3)
            try await client.press(.menu)
            #expect(await mock.menuPath == [mainTitle, "Set Scan Selection"])
            try await client.press(.menu)
            try await client.press(.menu)
            #expect(await mock.menuPath == [mainTitle])
            try await openLists(client)
            try await client.press(.avoid)
            #expect(!(await mock.isInMenu))
        }
    }

    @Test func analyzeAnswersTypeError() async throws {
        try await withMock { _, client in
            try await client.press(.menu)
            for _ in 0..<4 { try await client.press(.scrollRight) }
            try await client.press(.enterYes)
            let screen = try await client.menuScreen()
            #expect(screen.kind == .error)
            let text = try #require(screen.errorText)
            #expect(text.contains("can't remote control"))
            #expect(text.contains("Please goto scan mode to remote control."))
            #expect(try await client.scannerInfo().menuScreenKind == .selection)
            let status = try await client.displayStatus()
            #expect(status.lines[0].text.hasPrefix("Analyze"))
            #expect(status.lines[1].text.hasPrefix("System Status"))
            #expect(status.lines[2].text.hasPrefix("LCN Finder"))
        }
    }

    @Test func msiOutsideMenuIsBareError() async throws {
        try await withMock { _, client in
            let screen = try await client.menuScreen()
            #expect(screen.kind == .error)
            #expect(screen.errorText == nil)
        }
    }

    @Test func msvRejections() async throws {
        try await withMock { mock, client in
            func rejects(_ value: String) async throws {
                await #expect { try await client.setMenuValue(value) } throws: { isRejected($0) }
            }
            try await rejects("0")  // outside a menu
            try await client.press(.menu)
            try await rejects("4")  // Analyze is on the screen but not in MSI
            try await rejects("99")
            try await rejects("-1")
            try await rejects("abc")
            try await client.setMenuValue("1")
            try await client.setMenuValue("0")
            try await rejects("12.5.5.5")  // over MaxLength 5
            try await rejects("1a")  // outside EnableKeys
            try await client.press(.menu)
            try await client.press(.menu)
            try await client.setMenuValue("3")
            try await client.setMenuValue("0")
            try await client.setMenuValue("0")
            try await client.setMenuValue("0")
            try await rejects("é")
            try await rejects(String(repeating: "a", count: 65))
            #expect(await mock.menuActions.isEmpty)
            #expect(await mock.menuPath.last == "Edit Name")
            // Analyze's screens can't be remote-controlled either.
            try await client.press(.avoid)
            try await client.press(.menu)
            for _ in 0..<4 { try await client.press(.scrollRight) }
            try await client.press(.enterYes)
            try await rejects("0")
            #expect(await mock.menuActions.isEmpty)
        }
    }

    @Test func actionItemsRun() async throws {
        try await withMock { mock, client in
            try await client.press(.menu)
            try await client.setMenuValue("6")
            try await client.setMenuValue("0")
            #expect(await mock.menuActions.last == "run Clear User Data")
            #expect(await mock.menuPath == [mainTitle, "Settings"])  // assumed: an action stays put
        }
    }

    @Test func powerCycleAndRestartLeaveTheMenuAndRestoreValues() async throws {
        try await withMock { mock, client in
            try await openLists(client)
            try await client.setMenuValue("11")
            #expect(try await client.menuScreen().items[11].value == "Off")
            await mock.powerCycle()
            #expect(!(await mock.isInMenu))
            #expect(await mock.menuActions.isEmpty)
            try await openLists(client)
            #expect(try await client.menuScreen().items[11].value == "On")
        }
    }

    // MARK: Faults

    @Test func dropNextReplyStillActs() async throws {
        try await withMock { mock, client in
            try await client.press(.menu)
            await mock.setFaults(MockFaults(dropNextReply: "KEY"))
            await #expect { try await client.press(.scrollRight) } throws: { isTimeout($0) }
            #expect(highlightedRow(try await client.displayStatus()) == 1)
            try await client.press(.scrollRight)  // the fault cleared itself
            #expect(highlightedRow(try await client.displayStatus()) == 2)
        }
    }

    @Test func dropNextRequestDoesNothing() async throws {
        try await withMock { mock, client in
            try await client.press(.menu)
            await mock.setFaults(MockFaults(dropNextRequest: "MSV"))
            await #expect { try await client.setMenuValue("0") } throws: { isTimeout($0) }
            #expect(await mock.menuPath == [mainTitle])
            #expect(await mock.control.receivedCommands.last == "MSV,,0")  // logged all the same
            try await client.setMenuValue("0")
            #expect(await mock.menuPath == [mainTitle, "Set Scan Selection"])
        }
    }

    @Test func dropCountCoversSeveralDatagrams() async throws {
        try await withMock { mock, client in
            await mock.setFaults(MockFaults(dropNextRequest: "MDL", dropCount: 2))
            for _ in 0..<2 {
                await #expect { _ = try await client.modelInfo() } throws: { isTimeout($0) }
            }
            let model = try await client.modelInfo()
            #expect(model.reported == "SDS200")
        }
    }

    @Test func rejectNextAnswersNGAndDoesNothing() async throws {
        try await withMock { mock, client in
            try await client.press(.menu)
            await mock.setFaults(MockFaults(rejectNext: "MSV"))
            await #expect { try await client.setMenuValue("0") } throws: { isRejected($0) }
            #expect(await mock.menuPath == [mainTitle], "not carried out")
            #expect(await mock.menuActions.isEmpty)
            #expect(await mock.control.receivedCommands.last == "MSV,,0")
            try await client.press(.scrollRight)  // other commands are untouched
            try await client.setMenuValue("0")  // the fault cleared itself
            #expect(await mock.menuPath == [mainTitle, "Set Scan Selection"])
        }
    }

    @Test func dropFaultsOnlyMatchTheirCommand() async throws {
        try await withMock { mock, client in
            await mock.setFaults(MockFaults(dropNextReply: "KEY"))
            let model = try await client.modelInfo()  // not a KEY
            #expect(model.reported == "SDS200")
            await #expect { try await client.press(.menu) } throws: { isTimeout($0) }
            #expect(await mock.isInMenu)  // the key was carried out
        }
    }

    @Test func replyDelayHoldsTheReplyNotTheEffect() async throws {
        let delay = Duration.milliseconds(1500)
        try await withMock(replyDelays: ["MSV": delay], commandTimeout: .seconds(4)) { mock, client in
            try await client.press(.menu)
            let replied = Mutex(false)
            let started = ContinuousClock.now
            let call = Task {
                try await client.setMenuValue("0")
                replied.withLock { $0 = true }
            }
            try await eventually { await mock.menuPath.count == 2 }
            let effectAfter = started.duration(to: .now)
            #expect(effectAfter < .milliseconds(750), "effect took \(effectAfter)")  // well under the delay
            #expect(!replied.withLock { $0 })  // the effect is visible, the reply is not here yet
            try await call.value
            #expect(replied.withLock { $0 })
            #expect(started.duration(to: .now) >= delay)  // the reply was held for the whole delay
        }
    }

    @Test func rebootWithMSMResetsTheMenu() async throws {
        try await withMock(rebootDuration: .milliseconds(300), commandTimeout: .seconds(2)) { mock, client in
            try await openLists(client)
            try await client.setMenuValue("11")
            #expect(await mock.menuActions == ["toggle Events Off"])
            _ = try await client.send(try ScannerCommand("MSM", "1"))
            try await eventually { await mock.isControlAnswering }
            #expect(!(await mock.isInMenu))
            #expect(await mock.menuActions.isEmpty)
            try await openLists(client)
            #expect(try await client.menuScreen().items[11].value == "On")
        }
    }

    @Test func stoppingDuringAReplyDelayIsClean() async throws {
        try await withMock(replyDelays: ["KEY": .seconds(5)], commandTimeout: .seconds(8)) { mock, client in
            let call = Task { try? await client.press(.menu) }
            try await eventually { await mock.isInMenu }
            call.cancel()
            // The body returns now; withMock stops the mock with the reply still pending.
        }
    }

    // MARK: Pushes

    @Test func psiPushesMenuStateAndNoHits() async throws {
        try await withMock(at: 3) { mock, client in
            let stream = try await client.startPush(interval: .milliseconds(50))
            try await client.press(.menu)
            let inMenu = try await within(.seconds(3)) { () -> ScannerInfo? in
                for await info in stream where info.isMenu { return info }
                return nil
            }
            #expect(inMenu?.hasActiveChannel == false)
            #expect(inMenu?.menuTitle == mainTitle)
            try await client.press(.avoid)
            let back = try await within(.seconds(3)) { () -> ScannerInfo? in
                for await info in stream where !info.isMenu { return info }
                return nil
            }
            #expect(back?.hasActiveChannel == true)
            try await client.stopPush()
            try await eventually { await mock.control.receivedCommands.contains("PSI,0") }
        }
    }
}

/// One UDP socket to the mock's control port, for checking exact reply bytes.
private final class RawUDP: @unchecked Sendable {
    let fd: Int32

    init(port: UInt16) throws {
        fd = socket(AF_INET, SOCK_DGRAM, 0)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED)
        }
    }

    /// Sends `command` and returns the one reply datagram, or nil on timeout. The waiting `recv`
    /// runs on a dispatch thread (`offThePool`): the in-process mock needs the pool to answer.
    func exchange(_ command: String) async -> Data? {
        await offThePool { self.blockingExchange(command) }
    }

    private func blockingExchange(_ command: String) -> Data? {
        let bytes = Array((command + "\r").utf8)
        guard send(fd, bytes, bytes.count, 0) == bytes.count else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = recv(fd, &buffer, buffer.count, 0)  // off the cooperative pool: run through offThePool
        return count > 0 ? Data(buffer[0..<count]) : nil
    }

    func close() { Darwin.close(fd) }
}
