// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
@testable import NoctuleMockScanner

// Conformance tests: Plan 1's real client stack (ScannerClient over UDPTransport) is the oracle,
// talking to MockControlServer on loopback. Every wait is bounded.

private struct ControlRig: Sendable {
    let server: MockControlServer
    let clock: MockClock
    let port: UInt16
    let client: ScannerClient

    func newClient(timeout: Duration = .seconds(1)) -> ScannerClient {
        ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: port), commandTimeout: timeout)
    }
}

/// Starts a control server on a stepped clock and a connected client, runs `body`, and always
/// disconnects and stops.
private func withControl(
    at time: Double = 0, scenario: MockScenario = .default, rebootDuration: Duration = .milliseconds(500),
    limit: Duration = .seconds(10), _ body: @escaping @Sendable (ControlRig) async throws -> Void
) async throws {
    let clock = MockClock.stepped(at: time)
    let server = MockControlServer(scenario: scenario, clock: clock, rebootDuration: rebootDuration)
    let port = try await server.start()
    let client = ScannerClient(transport: UDPTransport(host: "127.0.0.1", port: port), commandTimeout: .seconds(1))
    var failure: (any Error)?
    do {
        try await client.connect()
        try await within(limit) { try await body(ControlRig(server: server, clock: clock, port: port, client: client)) }
    } catch {
        failure = error
    }
    await client.disconnect()
    await server.stop()
    if let failure { throw failure }
}

/// Collects pushed updates into a list, in the background.
private final class PushLog: Sendable {
    private let items = Mutex<[ScannerInfo]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<ScannerInfo>) {
        task.withLock { $0 = Task { [self] in for await info in stream { self.items.withLock { $0.append(info) } } } }
    }

    var all: [ScannerInfo] { items.withLock { $0 } }
    var count: Int { items.withLock { $0.count } }
    func cancel() { task.withLock { $0?.cancel() } }
}

@Suite(.timeLimit(.minutes(1))) struct MockControlServerTests {
    @Test func modelAndFirmware() async throws {
        try await withControl { rig in
            let model = try await rig.client.modelInfo()
            #expect(model.reported == "SDS200")
            #expect(model.model == .sds200)
            #expect(try await rig.client.firmwareVersion() == "1.26.01")
        }
    }

    @Test func volumeAndSquelchAreStatefulWithSDS200Ranges() async throws {
        try await withControl { rig in
            try await rig.client.setVolume(12)
            #expect(try await rig.client.volume() == 12)
            try await rig.client.setVolume(29)
            #expect(try await rig.client.volume() == 29)
            await #expect(throws: ScannerClientError.rejected(command: "VOL", response: "VOL,NG")) {
                try await rig.client.setVolume(30)
            }
            #expect(try await rig.client.volume() == 29)

            try await rig.client.setSquelch(19)
            #expect(try await rig.client.squelch() == 19)
            await #expect(throws: ScannerClientError.rejected(command: "SQL", response: "SQL,NG")) {
                try await rig.client.setSquelch(20)
            }
            await #expect(throws: ScannerClientError.rejected(command: "SQL", response: "SQL,NG")) {
                try await rig.client.setSquelch(-1)
            }
            #expect(await rig.server.volume == 29)
            #expect(await rig.server.squelch == 19)
            // GSI reflects the settings.
            let info = try await rig.client.scannerInfo()
            #expect(info.volume == 29)
            #expect(info.squelch == 19)
        }
    }

    @Test func conventionalTransmissionReportsAConventionalSystem() async throws {
        // A transmission with no talkgroup is a conventional channel: SystemType "Conventional",
        // so the client treats it as active on its frequency (not as a trunk control channel).
        let idle = MockIdle(system: "Test County P25", site: "Test Site", frequencyMHz: 851.0125)
        let conv = MockTransmission(at: 1, duration: 1, system: "Test Valley Conv", department: "Test Harbor",
                                    channel: "Test Marina", tgid: nil, frequencyMHz: 155.1234, rssi: -60,
                                    programmed: false)
        let tg = MockTransmission(at: 3, duration: 1, system: "Test County P25", department: "Test Fire",
                                  channel: "Test Dispatch", tgid: "4711", frequencyMHz: 851.2375, rssi: -60)
        let scenario = MockScenario(idle: idle, transmissions: [conv, tg])
        try await withControl(at: 1.5, scenario: scenario) { rig in
            let info = try await rig.client.scannerInfo()
            #expect(info.systemType == "Conventional")
            #expect(!info.isTrunk)
            #expect(info.hasActiveChannel)
            #expect(info.talkgroupID == nil)
            #expect(info.frequencyMHz == 155.1234)
            #expect(info.channel?.name == "Test Marina")
            #expect(info.channel?.isProgrammed == false)
            rig.clock.set(3.5)
            let trunk = try await rig.client.scannerInfo()
            #expect(trunk.systemType == "P25 Trunk")
            #expect(trunk.isTrunk && trunk.hasActiveChannel)
            rig.clock.set(0)
            #expect(try await rig.client.scannerInfo().systemType == "P25 Trunk")
        }
    }

    @Test func scannerInfoMatchesSteppedTransmission() async throws {
        let scenario = MockScenario.default
        let second = scenario.transmissions[1]
        try await withControl(at: second.at + 1) { rig in
            let info = try await rig.client.scannerInfo()
            #expect(info.mode == "Trunk Scan")
            #expect(info.screen == "trunk_scan")
            #expect(info.system?.name == second.system)
            #expect(info.systemType == "P25 Trunk")
            #expect(info.department?.name == second.department)
            #expect(info.channel?.name == second.channel)
            #expect(info.talkgroupID == second.tgid)
            #expect(info.unitID == second.unitID)
            #expect(info.frequencyMHz == second.frequencyMHz)
            #expect(info.modulation == second.modulation)
            #expect(info.toneOrCode == second.toneOrCode)
            #expect(info.rssi == second.rssi)
            #expect(info.channel?.isProgrammed == true)
            #expect(info.department?.isProgrammed == true)
            #expect((info.signalBars ?? 0) > 0)

            // The unprogrammed one carries the sentinel index.
            let unprogrammed = try #require(scenario.transmissions.first { !$0.programmed })
            rig.clock.set(unprogrammed.at + 0.5)
            let other = try await rig.client.scannerInfo()
            #expect(other.channel?.name == unprogrammed.channel)
            #expect(other.channel?.index == ScannerInfo.unprogrammedIndex)
            #expect(other.channel?.isProgrammed == false)
            #expect(other.department?.isProgrammed == false)
            #expect(other.talkgroupID == unprogrammed.tgid)

            // Idle: scanning, no channel, Sig 0.
            rig.clock.set(0)
            let idle = try await rig.client.scannerInfo()
            #expect(idle.mode == "Trunk Scan")
            #expect(idle.channel == nil)
            #expect(idle.signalBars == 0)
            #expect(idle.system?.name == scenario.idle.system)
            #expect(idle.frequencyMHz == scenario.idle.frequencyMHz)
        }
    }

    @Test func weatherScenarioUsesWxChannel() async throws {
        try await withControl(at: 5, scenario: .weather) { rig in
            let info = try await rig.client.scannerInfo()
            #expect(info.mode == "WX Scan")
            let wx = try #require(info.raw.child("WxChannel"))
            #expect(wx.attributes["Freq"] == " 162.425000MHz")
            #expect(wx.attributes["Mod"] == "FM")
            #expect(wx.attributes["Name"] == "Lakeview Weather")
            #expect(info.raw.child("TGID") == nil)
            let display = try await rig.client.displayStatus()
            #expect(display.lines.count == 17)
            #expect(display.lines.contains { $0.text.contains("Lakeview Weather") })
        }
    }

    @Test func displayStatusHas17LinesAndSoftKeys() async throws {
        let second = MockScenario.default.transmissions[1]
        try await withControl(at: second.at + 1) { rig in
            let display = try await rig.client.displayStatus()
            #expect(display.lines.count == 17)
            #expect(display.softKeyLabels == ["SYSTEM", "DEPT", "CHANNEL"])
            #expect(display.lines.allSatisfy { $0.text.count == $0.highlightMask.count })
            #expect(display.lines.contains { $0.text.contains(second.channel) })
            #expect(display.lines.contains { $0.text.contains(second.system) })
            #expect(display.lines.contains { $0.text.contains("VOL:") && $0.text.contains("SQL:") })
            #expect(!display.trailing.isEmpty)
        }
    }

    @Test func keyPressIsAcknowledged() async throws {
        try await withControl { rig in
            try await rig.client.press(.menu)
            try await rig.client.press(.soft1)
            let commands = await rig.server.receivedCommands
            #expect(commands.contains("KEY,M,P"))
            #expect(commands.contains("KEY,A,P"))
        }
    }

    @Test func unknownCommandGetsERR() async throws {
        let server = MockControlServer(scenario: .default, clock: .stepped())
        let port = try await server.start()
        let transport = UDPTransport(host: "127.0.0.1", port: port)
        do {
            try await transport.open()
            let responses = transport.responses
            try await transport.send(ScannerCommand("ZZZ", "1"))
            let first = try await within(.seconds(2)) { () -> ScannerResponse? in
                for await response in responses { return response }
                return nil
            }
            #expect(first == .fields(command: "ERR", fields: []))
        } catch {
            Issue.record(error)
        }
        await transport.close()
        await server.stop()
        #expect(await server.receivedCommands == ["ZZZ,1"])
    }

    @Test func pushFollowsClockAcrossTransmissionBoundaryAndStops() async throws {
        let second = MockScenario.default.transmissions[1]
        try await withControl(at: second.at - 0.5) { rig in
            let pushes = PushLog(try await rig.client.startPush(interval: .milliseconds(50)))
            defer { pushes.cancel() }
            try await eventually { pushes.count >= 2 }
            #expect(pushes.all.first?.channel == nil)
            #expect(await rig.server.activeSubscribers == 1)

            rig.clock.advance(by: 1)  // crosses into transmission 2
            try await eventually { pushes.all.last?.channel?.name == second.channel }
            #expect(pushes.all.last?.talkgroupID == second.tgid)

            try await rig.client.stopPush()
            try await eventually { await rig.server.activeSubscribers == 0 }
            #expect(await rig.server.receivedCommands.contains("PSI,0"))
            let sent = await rig.server.pushesSent
            try await Task.sleep(for: .milliseconds(250))
            #expect(await rig.server.pushesSent == sent)
        }
    }

    @Test func pushesArePerClientAddress() async throws {
        try await withControl { rig in
            let other = rig.newClient()
            try await other.connect()
            let mine = PushLog(try await rig.client.startPush(interval: .milliseconds(50)))
            let theirs = PushLog(try await other.startPush(interval: .milliseconds(50)))
            defer { mine.cancel(); theirs.cancel() }
            try await eventually { mine.count >= 2 && theirs.count >= 2 }
            #expect(await rig.server.activeSubscribers == 2)

            try await other.stopPush()
            try await eventually { await rig.server.activeSubscribers == 1 }
            let before = mine.count
            try await eventually { mine.count >= before + 3 }
            await other.disconnect()
        }
    }

    @Test func stallPSIAfterStopsPushesButStillAcks() async throws {
        try await withControl { rig in
            await rig.server.setStallPSIAfter(0.3)
            let start = ContinuousClock.now
            let pushes = PushLog(try await rig.client.startPush(interval: .milliseconds(50)))
            defer { pushes.cancel() }
            try await Task.sleep(for: .seconds(1))
            let count = pushes.count
            #expect((2...8).contains(count), "\(count) pushes")
            let sent = await rig.server.pushesSent
            try await Task.sleep(for: .milliseconds(200))
            #expect(await rig.server.pushesSent == sent)
            // Control still answers while pushes are stalled.
            #expect(try await rig.client.modelInfo().model == .sds200)
            #expect(ContinuousClock.now - start < .seconds(3))
        }
    }

    @Test func msmRebootGoesSilentThenAnswers() async throws {
        try await withControl(rebootDuration: .milliseconds(600)) { rig in
            let phases = Mutex<[MockRebootPhase]>([])
            await rig.server.setRebootHandler { phase in phases.withLock { $0.append(phase) } }
            let pushes = PushLog(try await rig.client.startPush(interval: .milliseconds(50)))
            defer { pushes.cancel() }
            try await eventually { pushes.count >= 1 }

            let sender = rig.newClient()
            try await sender.connect()
            try await sender.restartScanner()  // MSM,1 → MSM,OK, then disconnects
            #expect(await rig.server.receivedCommands.contains("MSM,1"))
            #expect(await rig.server.isRebooting)
            try await eventually { phases.withLock { $0 } == [.began] }
            // The reboot drops PSI subscriptions.
            #expect(await rig.server.activeSubscribers == 0)

            let probe = rig.newClient(timeout: .milliseconds(200))
            try await probe.connect()
            await #expect(throws: ScannerClientError.timeout(command: "MDL")) { try await probe.modelInfo() }
            await probe.disconnect()

            try await eventually(.seconds(3)) { await !rig.server.isRebooting }
            #expect(phases.withLock { $0 } == [.began, .finished])
            let after = rig.newClient()
            try await after.connect()
            #expect(try await after.modelInfo().model == .sds200)
            await after.disconnect()

            // ScannerRestartMonitor (the real reboot waiter) sees it come back too.
            #expect(await ScannerRestartMonitor.isAnswering(host: "127.0.0.1", port: rig.port))
        }
    }

    @Test func notAnsweringIsSilent() async throws {
        try await withControl { rig in
            await rig.server.setAnswering(false)
            let probe = rig.newClient(timeout: .milliseconds(200))
            try await probe.connect()
            await #expect(throws: ScannerClientError.timeout(command: "MDL")) { try await probe.modelInfo() }
            await rig.server.setAnswering(true)
            #expect(try await probe.modelInfo().model == .sds200)
            await probe.disconnect()
            // Commands are logged even while silent.
            #expect(await rig.server.receivedCommands.filter { $0 == "MDL" }.count == 2)
        }
    }
}
