// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKitTestSupport
@testable import NoctuleKit

/// The outcome of waiting a bounded time for a stream's next element.
private enum Next<T: Sendable>: Sendable {
    case value(T)
    case finished
    case timedOut
}

/// Waits at most `limit` for the stream's next element, so no test can hang on a stream.
private func next<T: Sendable>(_ stream: AsyncStream<T>, within limit: Duration = .seconds(2)) async -> Next<T> {
    await withTaskGroup(of: Next<T>.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            if let value = await iterator.next() { return .value(value) }
            return Task.isCancelled ? .timedOut : .finished
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return .timedOut
        }
        let first = await group.next() ?? .timedOut
        group.cancelAll()
        return first
    }
}

/// Polls `condition` until it holds or `limit` passes; returns whether it held.
private func eventually(within limit: Duration = .seconds(2), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite(.timeLimit(.minutes(3))) struct ScannerClientTests {
    @Test func readsIdentity() async throws {
        let c = ScannerClient(transport: SimulatedScannerTransport.sds200()); try await c.connect()
        let m = try await c.modelInfo(); #expect(m.model == .sds200)
        #expect(m.reported == "SDS200")
        #expect(try await c.firmwareVersion() == "1.24.00")
    }

    @Test func timesOutWhenScannerIsSilent() async throws {
        let c = ScannerClient(transport: SimulatedScannerTransport { _ in [] }, commandTimeout: .milliseconds(100))
        try await c.connect()
        let start = ContinuousClock.now
        await #expect(throws: ScannerClientError.timeout(command: "MDL")) { _ = try await c.modelInfo() }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func timeoutFreesTheSlotForTheNextCommand() async throws {
        let t = SimulatedScannerTransport { command in
            command.name == "VER" ? [.fields(command: "VER", fields: ["Version 1.24.00"])] : []
        }
        let c = ScannerClient(transport: t, commandTimeout: .milliseconds(100)); try await c.connect()
        await #expect(throws: ScannerClientError.timeout(command: "MDL")) { _ = try await c.modelInfo() }
        #expect(try await c.firmwareVersion() == "1.24.00")
    }

    @Test func pushDoesNotSatisfyPendingCommand() async throws {
        let pushed = XMLNode(name: "ScannerInfo", attributes: ["Mode": "Push"])
        let gsi = SimulatedScannerTransport.sds200GSIResponse()
        let t = SimulatedScannerTransport { command in
            command.name == "GSI" ? [.xml(command: "PSI", root: pushed), gsi] : []
        }
        let c = ScannerClient(transport: t); try await c.connect()
        let pushes = try await c.startPush()
        let info = try await c.scannerInfo()
        #expect(info.mode == "Trunk Scan")
        guard case .value(let push) = await next(pushes) else { Issue.record("no push received"); return }
        #expect(push.mode == "Push")
        await c.disconnect()
    }

    @Test func rejectedCommandThrows() async throws {
        let t = SimulatedScannerTransport { _ in [.fields(command: "VOL", fields: ["NG"])] }
        let c = ScannerClient(transport: t); try await c.connect()
        await #expect(throws: ScannerClientError.rejected(command: "VOL", response: "VOL,NG")) { try await c.setVolume(3) }
    }

    private static let msiDocument = """
        MSI,<XML>,
        <?xml version="1.0" encoding="utf-8"?>
        <MSI Name="Select Lists to Monitor" Index="4293063468" MenuType="TypeSelect" Value="Full Database             :Off" Selected="0" >
          <MenuItem Name="Full Database" Index="0" Value="Off" />
          <MenuItem Name="Lakeview Fire" Index="2" Value="On" />
          <Footer No="1" EOT="1"/>
        </MSI>
        """

    @Test func menuScreenSendsMSI() async throws {
        var assembler = UDPDatagramAssembler()
        let reply = assembler.feed(Data(Self.msiDocument.utf8))
        let t = SimulatedScannerTransport { command in command.name == "MSI" ? reply : [] }
        let c = ScannerClient(transport: t); try await c.connect()
        let screen = try await c.menuScreen()
        #expect(await t.sentCommands.last?.wireBytes == Data("MSI\r".utf8))
        #expect(screen.title == "Select Lists to Monitor")
        #expect(screen.kind == .select)
        #expect(screen.items.map(\.index) == [0, 2])
    }

    @Test func menuScreenRejectsNonXML() async throws {
        let t = SimulatedScannerTransport { command in [.fields(command: command.name, fields: ["NG"])] }
        let c = ScannerClient(transport: t); try await c.connect()
        await #expect(throws: ScannerClientError.rejected(command: "MSI", response: "MSI,NG")) { _ = try await c.menuScreen() }
        let wrong = SimulatedScannerTransport { _ in [.xml(command: "MSI", root: XMLNode(name: "ScannerInfo"))] }
        let d = ScannerClient(transport: wrong); try await d.connect()
        await #expect(throws: ScannerClientError.unexpectedResponse(command: "MSI")) { _ = try await d.menuScreen() }
    }

    @Test func setMenuValueSendsReservedFieldEmpty() async throws {
        let t = SimulatedScannerTransport { command in [.fields(command: command.name, fields: ["OK"])] }
        let c = ScannerClient(transport: t); try await c.connect()
        try await c.setMenuValue("14")
        try await c.setMenuValue("Custom 9")
        let wire = await t.sentCommands.map(\.wireBytes)
        #expect(wire == [Data("MSV,,14\r".utf8), Data("MSV,,Custom 9\r".utf8)])
    }

    @Test func setMenuValueRejected() async throws {
        let t = SimulatedScannerTransport { command in [.fields(command: command.name, fields: ["NG"])] }
        let c = ScannerClient(transport: t); try await c.connect()
        await #expect(throws: ScannerClientError.rejected(command: "MSV", response: "MSV,NG")) { try await c.setMenuValue("3") }
    }

    @Test func setMenuValueRefusesComma() async throws {
        let t = SimulatedScannerTransport { command in [.fields(command: command.name, fields: ["OK"])] }
        let c = ScannerClient(transport: t); try await c.connect()
        await #expect(throws: ScannerCommandError.invalidArgument("a,b")) { try await c.setMenuValue("a,b") }
        await #expect(throws: ScannerCommandError.invalidArgument("a\nb")) { try await c.setMenuValue("a\nb") }
        // By scalar: "\r\n" is one Character (final review I3), and a lone CR or LF.
        await #expect(throws: ScannerCommandError.invalidArgument("a\r\nb")) { try await c.setMenuValue("a\r\nb") }
        await #expect(throws: ScannerCommandError.invalidArgument("\n")) { try await c.setMenuValue("\n") }
        await #expect(throws: ScannerCommandError.invalidArgument("\r")) { try await c.setMenuValue("\r") }
        #expect(await t.sentCommands.isEmpty)
    }

    @Test func pressSendsKeyCommand() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        try await c.press(.avoid)
        #expect(await t.sentCommands.last == (try ScannerCommand("KEY", "L", "P")))
    }

    @Test func disconnectStopsActivePush() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        _ = try await c.startPush(interval: .milliseconds(500))
        await c.disconnect()
        let sent = await t.sentCommands
        #expect(sent.contains(try ScannerCommand("PSI", "500")))
        #expect(sent.last == (try ScannerCommand("PSI", "0")))
    }

    @Test func disconnectWithoutPushDoesNotSendPSI() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        _ = try await c.volume()
        await c.disconnect()
        #expect(await t.sentCommands == [try ScannerCommand("VOL")])
    }

    @Test func requiresConnection() async throws {
        let c = ScannerClient(transport: SimulatedScannerTransport.sds200())
        await #expect(throws: ScannerClientError.notConnected) { _ = try await c.volume() }
        try await c.connect()
        #expect(try await c.volume() == 2)
        await c.disconnect()
        await #expect(throws: ScannerClientError.notConnected) { _ = try await c.volume() }
    }

    @Test func readsAndSetsLevels() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        #expect(try await c.volume() == 2)
        #expect(try await c.squelch() == 1)
        try await c.setVolume(3)
        try await c.setSquelch(4)
        #expect(await t.sentCommands == [
            try ScannerCommand("VOL"), try ScannerCommand("SQL"),
            try ScannerCommand("VOL", "3"), try ScannerCommand("SQL", "4"),
        ])
    }

    @Test func readsScannerInfoAndDisplay() async throws {
        let c = ScannerClient(transport: SimulatedScannerTransport.sds200()); try await c.connect()
        let info = try await c.scannerInfo()
        #expect(info.system?.name == "LWPC P25-2")
        let display = try await c.displayStatus()
        #expect(display.lines.count == 17)
    }

    @Test func readsChargeStatus() async throws {
        let t = SimulatedScannerTransport { command in
            command.name == "GCS"
                ? [.fields(command: "GCS", fields: ["CST=6", "VOLT=3900mV:70%", "CURR=0850mA", "TEMP= 27.65C"])]
                : []
        }
        let c = ScannerClient(transport: t); try await c.connect()
        let charge = try await c.chargeStatus()
        #expect(charge.state == .charging)
        #expect(charge.percent == 70)
        #expect(charge.milliamps == 850)
        #expect(await t.sentCommands == [try ScannerCommand("GCS")])
    }

    @Test func chargeStatusWithAnUnreadableReplyThrows() async throws {
        let junk = SimulatedScannerTransport { command in [.fields(command: command.name, fields: ["CST=x"])] }
        let c = ScannerClient(transport: junk); try await c.connect()
        await #expect(throws: ScannerClientError.unexpectedResponse(command: "GCS")) { _ = try await c.chargeStatus() }

        let xml = SimulatedScannerTransport { command in
            [.xml(command: command.name, root: XMLNode(name: "ScannerInfo"))]
        }
        let d = ScannerClient(transport: xml); try await d.connect()
        await #expect(throws: ScannerClientError.unexpectedResponse(command: "GCS")) { _ = try await d.chargeStatus() }
    }

    @Test func sendReturnsRawResponse() async throws {
        let c = ScannerClient(transport: SimulatedScannerTransport.sds200()); try await c.connect()
        #expect(try await c.send(ScannerCommand("MDL")) == .fields(command: "MDL", fields: ["SDS200"]))
    }

    @Test func unmatchedResponsesAreDropped() async throws {
        let t = SimulatedScannerTransport { command in
            command.name == "VOL"
                ? [.fields(command: "MDL", fields: ["SDS200"]), .xml(command: "GSI", root: XMLNode(name: "ScannerInfo")),
                   .fields(command: "VOL", fields: ["5"])]
                : []
        }
        let c = ScannerClient(transport: t); try await c.connect()
        await t.emit(.fields(command: "STS", fields: ["stray"]))
        #expect(try await c.volume() == 5)
    }

    @Test func unexpectedReplyShapeThrows() async throws {
        let t = SimulatedScannerTransport { command in [.fields(command: command.name, fields: ["abc"])] }
        let c = ScannerClient(transport: t); try await c.connect()
        await #expect(throws: ScannerClientError.unexpectedResponse(command: "VOL")) { _ = try await c.volume() }
        await #expect(throws: ScannerClientError.unexpectedResponse(command: "KEY")) { try await c.press(.menu) }
    }

    @Test func onlyOneRequestInFlight() async throws {
        let t = SimulatedScannerTransport { _ in [] }
        let c = ScannerClient(transport: t, commandTimeout: .seconds(5)); try await c.connect()
        let model = Task { try await c.modelInfo().reported }
        let version = Task { try await c.firmwareVersion() }

        defer { model.cancel(); version.cancel() }

        guard await eventually({ await t.sentCommands.count == 1 }) else { Issue.record("nothing sent"); return }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await t.sentCommands.count == 1)
        await t.emit(reply(to: await t.sentCommands[0]))

        guard await eventually({ await t.sentCommands.count == 2 }) else { Issue.record("second never sent"); return }
        await t.emit(reply(to: await t.sentCommands[1]))

        #expect(try await model.value == "SDS200")
        #expect(try await version.value == "1.24.00")
        #expect(Set(await t.sentCommands.map(\.name)) == ["MDL", "VER"])
    }

    @Test func disconnectFailsInFlightRequest() async throws {
        let t = SimulatedScannerTransport { _ in [] }
        let c = ScannerClient(transport: t, commandTimeout: .seconds(5)); try await c.connect()
        let pending = Task { try await c.modelInfo() }
        #expect(await eventually { await t.sentCommands.count == 1 })
        let start = ContinuousClock.now
        await c.disconnect()
        await #expect(throws: ScannerClientError.notConnected) { _ = try await pending.value }
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test func cancellationFreesTheSlot() async throws {
        let t = SimulatedScannerTransport { command in
            command.name == "VER" ? [.fields(command: "VER", fields: ["Version 1.24.00"])] : []
        }
        let c = ScannerClient(transport: t, commandTimeout: .seconds(5)); try await c.connect()
        let pending = Task { try await c.modelInfo() }
        #expect(await eventually { await t.sentCommands.count == 1 })
        let start = ContinuousClock.now
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        #expect(try await c.firmwareVersion() == "1.24.00")
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    // MARK: onlyIf: decided at the slot (flaky-sweep review I2)

    @Test func onlyIfIsDecidedOnceTheRequestHoldsTheSlot() async throws {
        let t = SimulatedScannerTransport { _ in [] }
        let c = ScannerClient(transport: t, commandTimeout: .seconds(5)); try await c.connect()
        let wanted = Mutex(true)
        let asked = Mutex(0)
        let model = Task { try await c.modelInfo().reported }
        #expect(await eventually { await t.sentCommands.count == 1 })
        let set = Task {
            try await c.setListKey(3, on: true, onlyIf: {
                asked.withLock { $0 += 1 }
                return wanted.withLock { $0 }
            })
        }
        #expect(await eventually { await c.requestsWaitingForTheSlot == 1 })
        // Asked nothing while it waits; the caller changes its mind meanwhile.
        #expect(asked.withLock { $0 } == 0)
        wanted.withLock { $0 = false }
        await t.emit(reply(to: await t.sentCommands[0]))
        #expect(try await model.value == "SDS200")
        await #expect(throws: ScannerClientError.withheld(command: "FQK")) { try await set.value }
        #expect(asked.withLock { $0 } == 1, "asked once, holding the slot")
        #expect(await t.sentCommands.map(\.name) == ["MDL"], "nothing written for the withheld set")
        // The slot is free again at once.
        let version = Task { try await c.firmwareVersion() }
        #expect(await eventually { await t.sentCommands.count == 2 })
        await t.emit(reply(to: await t.sentCommands[1]))
        #expect(try await version.value == "1.24.00")
    }

    @Test func onlyIfStillWantedSendsTheCommandOnce() async throws {
        let t = SimulatedScannerTransport { command in
            command.name == "FQK" ? [.fields(command: "FQK", fields: ["OK"])] : []
        }
        let c = ScannerClient(transport: t, commandTimeout: .seconds(5)); try await c.connect()
        let asked = Mutex(0)
        let model = Task { try await c.modelInfo().reported }
        #expect(await eventually { await t.sentCommands.count == 1 })
        let set = Task { try await c.setListKey(3, on: true, onlyIf: { asked.withLock { $0 += 1 }; return true }) }
        #expect(await eventually { await c.requestsWaitingForTheSlot == 1 })
        await t.emit(reply(to: await t.sentCommands[0]))
        _ = try await model.value
        try await set.value
        #expect(asked.withLock { $0 } == 1)
        let sent = await t.sentCommands
        #expect(sent.map(\.name) == ["MDL", "FQK"])
        #expect(sent.last?.arguments.count == 100)
    }

    @Test func everyStateChangingCallTakesOnlyIf() async throws {
        let t = SimulatedScannerTransport { _ in [] }
        let c = ScannerClient(transport: t, commandTimeout: .seconds(5)); try await c.connect()
        let no: @Sendable () -> Bool = { false }
        await #expect(throws: ScannerClientError.withheld(command: "FQK")) { try await c.setListKey(1, on: true, onlyIf: no) }
        await #expect(throws: ScannerClientError.withheld(command: "SQK")) {
            try await c.setSystemKey(1, inList: 2, on: false, onlyIf: no)
        }
        await #expect(throws: ScannerClientError.withheld(command: "DQK")) {
            try await c.setDepartmentKey(1, inList: 2, system: 3, on: true, onlyIf: no)
        }
        await #expect(throws: ScannerClientError.withheld(command: "KEY")) { try await c.press(.menu, onlyIf: no) }
        await #expect(throws: ScannerClientError.withheld(command: "MSV")) { try await c.setMenuValue("4", onlyIf: no) }
        #expect(await t.sentCommands.isEmpty)
    }

    @Test func pushStreamReceivesPushes() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        let pushes = try await c.startPush(interval: .milliseconds(250))
        #expect(await t.sentCommands.last == (try ScannerCommand("PSI", "250")))
        await t.emit(.xml(command: "PSI", root: XMLNode(name: "ScannerInfo", attributes: ["Mode": "One"])))
        await t.emit(.xml(command: "PSI", root: XMLNode(name: "ScannerInfo", attributes: ["Mode": "Two"])))
        guard case .value(let first) = await next(pushes) else { Issue.record("no first push"); return }
        guard case .value(let second) = await next(pushes) else { Issue.record("no second push"); return }
        #expect(first.mode == "One"); #expect(second.mode == "Two")
        await c.disconnect()
    }

    @Test func rejectedPushFinishesStream() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        let pushes = try await c.startPush()
        await t.emit(.fields(command: "PSI", fields: ["NG"]))
        guard case .finished = await next(pushes) else { Issue.record("stream did not finish"); return }
        await c.disconnect()
        #expect(await t.sentCommands == [try ScannerCommand("PSI", "500")])
    }

    @Test func stopPushSendsPSI0AndFinishesStream() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        let pushes = try await c.startPush()
        try await c.stopPush()
        guard case .finished = await next(pushes) else { Issue.record("stream did not finish"); return }
        #expect(await t.sentCommands.last == (try ScannerCommand("PSI", "0")))
        await c.disconnect()
        #expect(await t.sentCommands.count == 2)
    }

    @Test func concurrentDisconnectsStopPushOnce() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        _ = try await c.startPush()
        async let first: Void = c.disconnect()
        async let second: Void = c.disconnect()
        _ = await (first, second)
        #expect(await t.sentCommands.filter { $0.name == "PSI" }.map(\.arguments) == [["500"], ["0"]])
    }

    @Test func cancellingPushConsumerSendsPSI0Once() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        let pushes = try await c.startPush()
        let consumer = Task { for await _ in pushes {} }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        await consumer.value
        let stop = try ScannerCommand("PSI", "0")
        #expect(await eventually { await t.sentCommands.contains(stop) })
        await c.disconnect()
        #expect(await t.sentCommands.filter { $0.name == "PSI" }.map(\.arguments) == [["500"], ["0"]])
    }

    @Test func droppingPushStreamSendsPSI0Once() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        do { _ = try await c.startPush() }
        let stop = try ScannerCommand("PSI", "0")
        #expect(await eventually { await t.sentCommands.contains(stop) })
        await c.disconnect()
        #expect(await t.sentCommands.filter { $0.name == "PSI" }.map(\.arguments) == [["500"], ["0"]])
    }

    @Test func droppedStreamDoesNotStopANewerPush() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        do { _ = try await c.startPush() }
        let pushes = try await c.startPush(interval: .milliseconds(250))
        try await Task.sleep(for: .milliseconds(50))
        // Whether or not the dropped stream's PSI,0 went out, it must precede the new PSI,250.
        #expect(await t.sentCommands.filter { $0.name == "PSI" }.last?.arguments == ["250"])
        await t.emit(.xml(command: "PSI", root: XMLNode(name: "ScannerInfo", attributes: ["Mode": "Live"])))
        guard case .value(let info) = await next(pushes) else { Issue.record("newer push stream not live"); return }
        #expect(info.mode == "Live")
        await c.disconnect()
        #expect(await t.sentCommands.filter { $0.name == "PSI" }.last?.arguments == ["0"])
    }

    @Test func disconnectFinishesPushStream() async throws {
        let c = ScannerClient(transport: SimulatedScannerTransport.sds200()); try await c.connect()
        let pushes = try await c.startPush()
        await c.disconnect()
        guard case .finished = await next(pushes) else { Issue.record("stream did not finish"); return }
    }

    @Test func transportEndingDisconnectsClient() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        let pushes = try await c.startPush()
        await t.finishResponses()
        guard case .finished = await next(pushes) else { Issue.record("push stream did not finish"); return }
        let start = ContinuousClock.now
        await #expect(throws: ScannerClientError.notConnected) { _ = try await c.modelInfo() }
        #expect(ContinuousClock.now - start < .milliseconds(100))
        #expect(await t.sentCommands == [try ScannerCommand("PSI", "500")])

        try await c.connect()
        #expect(try await c.modelInfo().model == .sds200)
        #expect(await t.openCount == 2)
        await c.disconnect()
    }

    @Test func transportEndingFailsInFlightAndQueuedRequests() async throws {
        let t = SimulatedScannerTransport { _ in [] }
        let c = ScannerClient(transport: t, commandTimeout: .seconds(5)); try await c.connect()
        let inFlight = Task { try await c.modelInfo() }
        #expect(await eventually { await t.sentCommands.count == 1 })
        let queued = Task { try await c.firmwareVersion() }
        try await Task.sleep(for: .milliseconds(20))
        let start = ContinuousClock.now
        await t.finishResponses()
        await #expect(throws: ScannerClientError.notConnected) { _ = try await inFlight.value }
        await #expect(throws: ScannerClientError.notConnected) { _ = try await queued.value }
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(await t.sentCommands.map(\.name) == ["MDL"])
    }

    /// The stamps are taken when a push arrives, not when the consumer reads it: each is at or after
    /// its own emit, in order, and before the late read began. (No window on the gap between them:
    /// a 70–130 ms one was too tight on the 3-core CI runner; LESSONS.md 2026-11-22.)
    @Test func pushUpdatesAreStampedOnArrival() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        let pushes = try await c.startPushUpdates(interval: .milliseconds(100))
        #expect(await t.sentCommands == [try ScannerCommand("PSI", "100")])
        let firstEmitted = ContinuousClock.now
        await t.emit(.xml(command: "PSI", root: XMLNode(name: "ScannerInfo", attributes: ["Mode": "One"])))
        try await Task.sleep(for: .milliseconds(100))
        let secondEmitted = ContinuousClock.now
        await t.emit(.xml(command: "PSI", root: XMLNode(name: "ScannerInfo", attributes: ["Mode": "Two"])))
        // Consume late: the stamps must reflect arrival, not when the consumer read them.
        try await Task.sleep(for: .milliseconds(150))
        let consumedAt = ContinuousClock.now
        guard case .value(let first) = await next(pushes) else { Issue.record("no first push"); return }
        guard case .value(let second) = await next(pushes) else { Issue.record("no second push"); return }
        #expect(first.info.mode == "One"); #expect(second.info.mode == "Two")
        #expect(first.receivedAt >= firstEmitted && second.receivedAt >= secondEmitted)
        #expect(first.receivedAt < second.receivedAt)
        #expect(second.receivedAt < consumedAt, "stamped \(second.receivedAt - consumedAt) after the read began")
        await c.disconnect()
        #expect(await t.sentCommands.filter { $0.name == "PSI" }.map(\.arguments) == [["100"], ["0"]])
    }

    @Test func cancellingPushUpdatesConsumerSendsPSI0Once() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        let pushes = try await c.startPushUpdates()
        let consumer = Task { for await _ in pushes {} }
        try await Task.sleep(for: .milliseconds(20))
        consumer.cancel()
        await consumer.value
        let stop = try ScannerCommand("PSI", "0")
        #expect(await eventually { await t.sentCommands.contains(stop) })
        await c.disconnect()
        #expect(await t.sentCommands.filter { $0.name == "PSI" }.map(\.arguments) == [["500"], ["0"]])
    }

    @Test func startPushReplacesPushUpdatesWithoutASecondSubscription() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        let updates = try await c.startPushUpdates(interval: .milliseconds(250))
        let infos = try await c.startPush(interval: .milliseconds(250))
        guard case .finished = await next(updates) else { Issue.record("earlier stream not finished"); return }
        await t.emit(.xml(command: "PSI", root: XMLNode(name: "ScannerInfo", attributes: ["Mode": "Live"])))
        guard case .value(let info) = await next(infos) else { Issue.record("newer stream not live"); return }
        #expect(info.mode == "Live")
        await c.disconnect()
        #expect(await t.sentCommands.filter { $0.name == "PSI" }.map(\.arguments) == [["250"], ["250"], ["0"]])
    }

    @Test func startPushRejectsSubMillisecondInterval() async throws {
        let t = SimulatedScannerTransport.sds200(); let c = ScannerClient(transport: t); try await c.connect()
        await #expect(throws: ScannerClientError.self) { _ = try await c.startPush(interval: .microseconds(999)) }
        await #expect(throws: ScannerClientError.self) { _ = try await c.startPush(interval: .zero) }
        do {
            _ = try await c.startPush(interval: .microseconds(500))
            Issue.record("expected invalidArgument")
        } catch let error as ScannerClientError {
            guard case .invalidArgument = error else { Issue.record("wrong error \(error)"); return }
        }
        #expect(await t.sentCommands.isEmpty)
        _ = try await c.startPush(interval: .milliseconds(1))
        #expect(await t.sentCommands == [try ScannerCommand("PSI", "1")])
        await c.disconnect()
    }
}

private func reply(to command: ScannerCommand) -> ScannerResponse {
    switch command.name {
    case "MDL": .fields(command: "MDL", fields: ["SDS200"])
    default: .fields(command: "VER", fields: ["Version 1.24.00"])
    }
}
