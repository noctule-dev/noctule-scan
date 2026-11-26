// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKitTestSupport
@testable import NoctuleMockScanner
@testable import NoctuleKit

// ScannerClient's MNU, MSB and HLD sends (Plan 23 Task 5) on the BCD436HP mock. Every name is fictional.

private func onBCD(commandTimeout: Duration = .milliseconds(700),
                   _ body: @escaping @Sendable (ScannerClient, MockSerialScanner) async throws -> Void) async throws {
    let mock = MockSerialScanner(scenario: .default, clock: .stepped(at: 3), personality: .bcd436hp)
    var failure: (any Error)?
    var client: ScannerClient?
    do {
        let path = try await mock.start()
        let connected = ScannerClient(transport: SerialTransport(path: path), commandTimeout: commandTimeout)
        client = connected
        try await connected.connect()
        try await body(connected, mock)
    } catch { failure = error }
    await client?.disconnect()
    await mock.stop()
    if let failure { throw failure }
}

@Suite(.timeLimit(.minutes(1)))
struct ScannerClientMenuCommandTests {
    @Test func openMenuSendsMNUTop() async throws {
        try await onBCD { client, mock in
            try await client.openMenu()
            #expect(await mock.isInMenu)
            await client.disconnect()
            await mock.stop()
            #expect(await mock.receivedCommands.filter { $0.hasPrefix("MNU") } == ["MNU,TOP,"])
        }
    }

    @Test func menuBackAndLeaveSendMSB() async throws {
        try await onBCD { client, mock in
            try await client.openMenu()
            try await client.menuBack()
            #expect(await mock.isInMenu)
            try await client.leaveMenu()
            #expect(!(await mock.isInMenu))
            await client.disconnect()
            await mock.stop()
            #expect(await mock.receivedCommands.filter { $0.hasPrefix("MSB") } == ["MSB,,", "MSB,,RETURN_PREVOUS_MODE"])
        }
    }

    @Test func leaveMenuOutsideAMenuIsRejected() async throws {
        try await onBCD { client, _ in
            await #expect(throws: ScannerClientError.rejected(command: "MSB", response: "MSB,NG")) {
                try await client.leaveMenu()
            }
        }
    }

    @Test func holdTargetsWriteTheExactCommands() throws {
        func wire(_ target: HoldTarget) throws -> String {
            String(decoding: try target.command.wireBytes, as: UTF8.self)
        }
        #expect(try wire(.system(index: 7)) == "HLD,SYS,7,\r")
        #expect(try wire(.department(index: 8, system: 7)) == "HLD,DEPT,8,7\r")
        #expect(try wire(.trunkChannel(index: 9)) == "HLD,TGID,9,\r")
        #expect(try wire(.conventionalChannel(index: 9)) == "HLD,CFREQ,9,\r")
    }

    @Test func holdIsNotResentAfterATimeout() async throws {
        try await onBCD(commandTimeout: .milliseconds(300)) { client, mock in
            await mock.setFaults(MockFaults(dropNextReply: "HLD"))
            await #expect(throws: ScannerClientError.timeout(command: "HLD")) {
                try await client.hold(.system(index: 1))
            }
            try await Task.sleep(for: .milliseconds(100))
            await client.disconnect()
            await mock.stop()
            #expect(await mock.receivedCommands.filter { $0.hasPrefix("HLD") }.count == 1)
        }
    }

    @Test func withheldAtTheSlot() async throws {
        try await onBCD { client, mock in
            await #expect(throws: ScannerClientError.withheld(command: "MNU")) {
                try await client.openMenu(onlyIf: { false })
            }
            await #expect(throws: ScannerClientError.withheld(command: "HLD")) {
                try await client.hold(.system(index: 1), onlyIf: { false })
            }
            await client.disconnect()
            await mock.stop()
            #expect(await mock.receivedCommands.filter { $0.hasPrefix("MNU") || $0.hasPrefix("HLD") }.isEmpty)
        }
    }
}
