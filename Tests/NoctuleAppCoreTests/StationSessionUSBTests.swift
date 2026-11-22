// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleKit
import NoctuleMockScanner
import NoctuleStore
@testable import NoctuleAppCore

/// `StationSession` on a USB station (Plan 8 Task 5; SDS150 design §7.2): it runs through the
/// same `StationRunner` as `noctule log`, waits for the port with nothing opened, resumes after an
/// unplug, and has no audio. See `withUSBSession` for what every test checks at the end.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct StationSessionUSBTests {
    private let hint = SerialPort.noneFoundHint
    private let differentScannerWarning = "a different scanner answered (SDS200); still waiting for the SDS150"

    @Test func usbStationConnects() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            #expect(rig.session.phase == .connected(model: "SDS150", firmware: "1.01.02"))
            try await waitUntil("the display") { rig.session.display != nil }
            try await rig.waitForPush()
            #expect(await rig.received("STS") >= 1)
            #expect(!rig.session.hasAudio)
            #expect(rig.session.audio == .idle)
            #expect(rig.output.plays == 0)
            #expect(rig.session.model == .sds150)
            #expect(rig.session.usbPort == rig.link)
        }
    }

    @Test func usbStationLogsAHit() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            rig.clock.set(usbFirstTransmissionAt + 0.01)
            try await waitUntil("a hit") { !rig.session.recentHits.isEmpty }
            rig.clock.set(0)
            try await waitUntil("the hit to end") { rig.session.recentHits.first?.hit.endedAt != nil }
            let hit = try #require(rig.session.recentHits.first)
            #expect(hit.audioPath == nil)
            #expect(hit.audioError == nil)
            #expect(hit.hit.endedAt != nil)
        }
    }

    /// Review Focus 1: the station opens with the scanner unplugged, waits with nothing opened or
    /// sent, and connects when it appears.
    @Test func opensWhileUnpluggedAndConnectsOnPlugIn() async throws {
        var setup = USBSetup()
        setup.startMock = false
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.session.phase == .waitingForScanner(hint: hint))
            #expect(!rig.startReturned)
            #expect(rig.session.info == nil && rig.session.display == nil)
            _ = try await rig.mock.start()
            try await rig.waitConnected()
            #expect(await rig.commands.first == "MDL")
        }
    }

    /// Review Focus 2: a stop ends the wait for the port at once, with nothing sent to a scanner
    /// that appears afterwards, and the station lock is free.
    @Test func stopWhileWaitingForThePortIsPrompt() async throws {
        var setup = USBSetup()
        setup.startMock = false
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            try await rig.stopSession(limit: .seconds(1))
            #expect(rig.session.phase == .stopped)
            #expect(lockIsFree(rig.station, rig.dir))
            _ = try await rig.mock.start()
            try await Task.sleep(for: .milliseconds(500))
            #expect(await rig.commands == [])
            #expect(rig.session.phase == .stopped)
        }
    }

    @Test func suspendWhileWaitingThenResume() async throws {
        var setup = USBSetup()
        setup.startMock = false
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            let suspended = Done()
            let session = rig.session
            Task { await session.suspend(); suspended.value = true }
            try await waitUntil("suspend", .seconds(1)) { suspended.value }
            #expect(rig.session.phase == .stopped)
            try await waitUntil("start() to return", .seconds(1)) { rig.startReturned }
            _ = try await rig.mock.start()
            Task { await session.resume() }
            try await rig.waitConnected()
        }
    }

    @Test func unplugShowsWaitingAndResumes() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            try await waitUntil("the display") { rig.session.display != nil }
            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            #expect(rig.session.info == nil)
            #expect(rig.session.display == nil)
            #expect(!rig.session.menu.isInMenu)
            #expect(rig.session.model == .sds150, "the model is kept through the wait")
            // The lost connection's loops are gone, not only stopped from sending.
            #expect(rig.session.displayTask == nil)
            #expect(rig.session.batteryTask == nil)
            #expect(rig.session.keyTask == nil && rig.session.keyGate == nil)
            let mark = await rig.commands.count
            _ = try await rig.mock.replug()
            try await rig.waitConnected()
            #expect(rig.session.phase == .connected(model: "SDS150", firmware: "1.01.02"))
            try await rig.waitForPush()
            rig.clock.set(usbFirstTransmissionAt + 0.01)
            try await waitUntil("a hit after the replug") { !rig.session.recentHits.isEmpty }
            rig.clock.set(0)
            let second = await rig.commands(since: mark)
            #expect(second.filter { $0 == "PSI,100" }.count == 1, "\(second)")
            #expect(second.prefix(3) == ["MDL", "VER", "PSI,100"], "\(second)")
        }
    }

    /// The display loop of the lost connection is ended at the disconnect, not left to find the
    /// next connection's client. The runner's `control()` is nil until the resume's `.connected`,
    /// so a loop left running (its next fetch due 1 s after the last one, here) would find the new
    /// client once the scanner is back within that second, and fetch forever beside the new loop:
    /// two `STS` a second instead of one.
    @Test func displayLoopEndsAtAnUnplug() async throws {
        try await withUSBSession { rig in
            var policy = DisplayRefreshPolicy()
            policy.minInterval = .seconds(1)
            policy.maxInterval = .seconds(1)
            rig.session.displayPolicy = policy
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            try await waitUntil("the display") { rig.session.display != nil }
            // Unplug right after a fetch, so the old loop's next one would fall about 1 s from now,
            // after the quick replug below has connected again.
            let fetched = await rig.received("STS")
            try await waitUntil("the next STS", .seconds(5)) { await rig.received("STS") > fetched }
            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            let mark = await rig.commands.count
            _ = try await rig.mock.replug()
            try await rig.waitConnected()
            try await Task.sleep(for: .milliseconds(3200))
            let second = await rig.commands(since: mark)
            // One loop: at connect, then every second (4, or 5 on a boundary); two loops: 7 or more.
            let fetches = second.filter { $0 == "STS" }.count
            #expect(fetches <= 5, "two display loops after the replug: \(second)")
            #expect(fetches >= 3, "the new connection's display loop didn't run: \(second)")
            #expect(second.prefix(3) == ["MDL", "VER", "PSI,100"], "\(second)")
        }
    }

    /// The Scanner view keeps up with a fast scan: on an SDS150 (`displayRefreshInterval` 100 ms)
    /// each channel step a push shows brings an `STS` read, where the 1 s minimum read about one
    /// step in four. A screen that doesn't change is read no more often than before.
    @Test func displayFollowsAFastScan() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            try await waitUntil("the display") { rig.session.display != nil }
            // Still: the idle channel stays put, so nothing brings a read forward.
            try await Task.sleep(for: .milliseconds(600))
            let still = await rig.received("STS")
            try await Task.sleep(for: .milliseconds(1500))
            #expect(await rig.received("STS") - still <= 1)
            // Scanning: the mock's idle channel is the scenario second's (one per second), so
            // alternating between seconds 0.5 and 1.5 (both idle) changes channel each time: eight
            // steps, 250 ms apart.
            let before = await rig.received("STS")
            for step in 1...8 {
                rig.clock.set(step.isMultiple(of: 2) ? 0.5 : 1.5)
                try await Task.sleep(for: .milliseconds(250))
            }
            let reads = await rig.received("STS") - before
            #expect(reads >= 6, "\(reads) STS reads for 8 channel steps")
            #expect(reads <= 10, "\(reads) STS reads for 8 channel steps")
        }
    }

    /// Review Focus 4: keys still queued when the scanner goes away are dropped, never sent to the
    /// replugged scanner.
    @Test func keysQueuedAtAnUnplugAreNotSentAfterTheReplug() async throws {
        var setup = USBSetup()
        setup.replyDelays = ["KEY": .seconds(1)]
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            for _ in 0..<8 { rig.session.press(.scrollRight) }
            try await waitUntil("the first key") { await rig.received("KEY") >= 1 }
            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            let mark = await rig.commands.count
            _ = try await rig.mock.replug()
            try await rig.waitConnected()
            try await Task.sleep(for: .milliseconds(400))
            let after = await rig.commands(since: mark)
            #expect(!after.contains { $0.hasPrefix("KEY") }, "\(after)")
        }
    }

    /// Review Focus 4: a level change inside its debounce when the scanner goes away is dropped.
    @Test func levelChangePendingAtAnUnplugIsDropped() async throws {
        try await withUSBSession { rig in
            rig.session.levelDebounceInterval = .seconds(1)
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            rig.session.setScannerVolume(9)
            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            _ = try await rig.mock.replug()
            try await rig.waitConnected()
            try await Task.sleep(for: .milliseconds(1300))
            let commands = await rig.commands
            #expect(!commands.contains { $0.hasPrefix("VOL") }, "\(commands)")
        }
    }

    /// Review Focus 4: an unplug inside a menu closes the mirrored menu; after the replug no menu
    /// command goes out before the new connection has read the scanner.
    @Test func unplugInAMenuClosesIt() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            try await rig.session.menu.enter()
            try await waitUntil("the menu") { rig.session.menu.isInMenu }
            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            #expect(!rig.session.menu.isInMenu)
            let mark = await rig.commands.count
            _ = try await rig.mock.replug()
            try await rig.waitConnected()
            try await Task.sleep(for: .milliseconds(300))
            let after = await rig.commands(since: mark)
            #expect(!after.contains { $0.hasPrefix("MSV") }, "\(after)")
            let firstRead = after.firstIndex { $0 == "GSI" || $0 == "STS" }
            let firstMenuRead = after.firstIndex { $0 == "MSI" }
            if let firstMenuRead {
                #expect(firstRead != nil && firstRead! < firstMenuRead, "\(after)")
            }
            #expect(after.prefix(3) == ["MDL", "VER", "PSI,100"], "\(after)")
        }
    }

    /// Review Focus 2: a stop during the runner's wait for the scanner is prompt.
    @Test func stopDuringTheRunnersWaitIsPrompt() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            try await rig.stopSession(limit: .seconds(1))
            #expect(rig.session.phase == .stopped)
            #expect(lockIsFree(rig.station, rig.dir))
        }
    }

    /// Review Focus 5: another scanner behind the port is asked `MDL` once and left alone; the
    /// session keeps waiting with one warning.
    @Test func wrongScannerKeepsWaitingAndWarnsOnce() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            let other = rig.otherScanner(reporting: "SDS200")
            _ = try await other.start()
            try await Task.sleep(for: .seconds(1))
            #expect(rig.session.phase == .waitingForScanner(hint: hint))
            #expect(rig.session.warnings == [differentScannerWarning])
            #expect(await other.receivedCommands == ["MDL"])
            await other.stop()
            #expect(await other.activeSubscribers == 0)
            #expect(rig.session.phase == .waitingForScanner(hint: hint))
        }
    }

    /// A scanner that refuses `PSI` isn't reopened by the session: the run ends in `.noAnswer` with
    /// the port closed; Reconnect starts again.
    @Test func rejectedPushEndsInNoAnswer() async throws {
        var setup = USBSetup()
        setup.faults = MockFaults(rejectNext: "PSI")
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitPhase(.noAnswer(SerialPort.notSendingUpdatesHint))
            try await waitUntil("start() to return") { rig.startReturned }
            let probe = SerialTransport(path: rig.link)
            try await probe.open()
            await probe.close()
            let mark = await rig.commands.count
            try await Task.sleep(for: .milliseconds(600))
            let commands = await rig.commands
            #expect(commands.count == mark, "sent after the rejection: \(commands.dropFirst(mark))")
            #expect(commands.filter { $0.hasPrefix("PSI") } == ["PSI,100"], "\(commands)")
            #expect(commands.filter { $0 == "MDL" }.count == 1)
            #expect(rig.session.phase == .noAnswer(SerialPort.notSendingUpdatesHint))
            #expect(lockIsFree(rig.station, rig.dir))
            await rig.session.reconnect()
            try await rig.waitConnected()
        }
    }

    @Test func busyPortSaysSo() async throws {
        try await withUSBSession { rig in
            let holder = SerialTransport(path: rig.link)
            try await holder.open()
            rig.start()
            try await rig.waitPhase(.noAnswer(StationSession.busyPortMessage(rig.link)))
            try await waitUntil("start() to return") { rig.startReturned }
            #expect(await rig.commands == [])
            #expect(lockIsFree(rig.station, rig.dir))
            // A held port is like `.inUse`: not a no-answer, so a wake doesn't retry it.
            #expect(!rig.session.lastFailureWasNoAnswer)
            await holder.close()
        }
    }

    @Test func silentScannerIsNoAnswer() async throws {
        var setup = USBSetup()
        setup.faults = MockFaults(dropNextRequest: "MDL")
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitPhase(.noAnswer(StationSession.noAnswerUSBMessage(port: rig.link)))
            try await waitUntil("start() to return") { rig.startReturned }
            #expect(await rig.received("MDL") == 1)
            try await Task.sleep(for: .milliseconds(1500))
            #expect(await rig.received("MDL") == 1, "the session opened the port again by itself")
            #expect(rig.session.phase == .noAnswer(StationSession.noAnswerUSBMessage(port: rig.link)))
            #expect(lockIsFree(rig.station, rig.dir))
            // No USB failure is retried after a wake (design §13 Z): only Reconnect opens the port again.
            #expect(!rig.session.lastFailureWasNoAnswer)
        }
    }

    /// Final review I2: a wake whose start finds the scanner plugged in but silent opens the port
    /// and sends `MDL` once, and never again by itself. Over USB each retry would open the port
    /// (which design §13 H bounds to three probes while the runner waits); the network session's
    /// backoff retries stay as they are (`StationSessionControlTests.wakeRetriesUntilScannerAnswers`).
    @Test func wakeDoesNotRetryASilentUSBScanner() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            await rig.session.suspend()
            #expect(rig.session.phase == .stopped)
            // The scanner stays on its port but answers nothing from here on.
            await rig.mock.setFaults(MockFaults(dropNextRequest: "MDL", dropCount: 100))
            let mdlBefore = await rig.received("MDL")
            await rig.session.resume()
            #expect(rig.session.phase == .noAnswer(StationSession.noAnswerUSBMessage(port: rig.link)))
            #expect(!rig.session.lastFailureWasNoAnswer)
            #expect(await rig.received("MDL") == mdlBefore + 1)
            // Five of the rig's 200 ms backoff steps: a retry would have opened the port and sent `MDL`.
            try await Task.sleep(for: .seconds(1))
            #expect(await rig.received("MDL") == mdlBefore + 1, "the wake opened the port again by itself")
            #expect(rig.session.phase == .noAnswer(StationSession.noAnswerUSBMessage(port: rig.link)))
            #expect(lockIsFree(rig.station, rig.dir))
        }
    }

    /// Final review M1: a start that fails otherwise than by silence or a busy port (here the
    /// scanner answers `MDL,NG`) is reported as what it was, not as a no-answer that tells the user
    /// to unplug the scanner, and isn't retried after a wake either.
    @Test func rejectedModelQueryIsNotANoAnswer() async throws {
        var setup = USBSetup()
        setup.faults = MockFaults(rejectNext: "MDL")
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitPhase(.noAnswer("The scanner refused MDL."))
            try await waitUntil("start() to return") { rig.startReturned }
            #expect(await rig.received("MDL") == 1)
            #expect(!rig.session.lastFailureWasNoAnswer)
            #expect(lockIsFree(rig.station, rig.dir))
        }
    }

    @Test func usbVolumeUsesTheModelsRange() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            rig.session.setScannerVolume(29)
            try await waitUntil("VOL,15") { await rig.commands.contains("VOL,15") }
            #expect(await rig.received("VOL") == 1)
        }
    }

    @Test func restartIsRefusedOverUSB() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            let mark = await rig.commands.count
            let outcome = await rig.session.restartScanner()
            #expect(outcome == .notAccepted(StationSession.restartNotSupportedMessage))
            #expect(rig.session.warnings.last == StationSession.restartNotSupportedMessage)
            #expect(!rig.session.isRestarting)
            #expect(rig.session.phase == .connected(model: "SDS150", firmware: "1.01.02"))
            try await Task.sleep(for: .milliseconds(200))
            // Only the display and battery loops' reads may follow: nothing was stopped, sent or restarted.
            let after = await rig.commands(since: mark)
            #expect(after.allSatisfy { $0 == "STS" || $0 == "GCS" }, "\(after)")
        }
    }

    @Test func bluetoothStationIsRefused() async throws {
        var setup = USBSetup()
        setup.transport = .bluetooth
        try await withUSBSession(setup) { rig in
            let held = try StationLock.acquire(stationID: rig.station.id, settingsDirectory: rig.dir)
            defer { held.release() }
            rig.start()
            try await rig.waitPhase(.noAnswer(StationSession.notSupportedHereMessage), .seconds(3))
            try await waitUntil("start() to return") { rig.startReturned }
            #expect(rig.session.runner == nil)
            #expect(await rig.commands == [])
            let outcome = await rig.session.restartScanner()
            #expect(outcome == .notAccepted(StationSession.restartNotSupportedMessage))
        }
    }

    /// The environment's keep-alive interval reaches the subscription: with the mock's pushes
    /// good for 0.5 s of scenario time, `KAL` every 200 ms keeps them coming through 2 s.
    @Test func keepAliveIsPassed() async throws {
        var setup = USBSetup()
        setup.keepAliveInterval = .milliseconds(200)
        setup.pushLifetime = 0.5
        let outcome = try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            var pushesAtHalfTime = 0
            for step in 1...20 {
                try await Task.sleep(for: .milliseconds(100))
                rig.clock.advance(by: 0.1)
                if step == 10 { pushesAtHalfTime = await rig.mock.pushesSent }
            }
            let pushes = await rig.mock.pushesSent
            #expect(pushes > pushesAtHalfTime, "pushes stopped: \(pushesAtHalfTime) then \(pushes)")
            #expect(await rig.received("KAL") >= 2)
            #expect(rig.isConnected)
        }
        let lastKeepAlive = outcome.commands.lastIndex(of: "KAL")
        let lastStop = outcome.commands.lastIndex(of: "PSI,0")
        #expect(lastKeepAlive != nil && lastStop != nil && lastKeepAlive! < lastStop!, "\(outcome.commands)")
    }

    // MARK: The battery (Plan 8 Task 6; SDS150 design §7.2)

    /// One `GCS` right after connect, then one every `batteryPollInterval`.
    @Test func batteryIsReadAtConnectAndEveryInterval() async throws {
        var setup = USBSetup()
        setup.batteryPollInterval = .milliseconds(200)
        try await withUSBSession(setup) { rig in
            #expect(rig.session.battery == nil)
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("the battery", .seconds(2)) { rig.session.battery != nil }
            #expect(rig.session.battery?.percent == 100)
            #expect(rig.session.battery?.state == .full)
            try await Task.sleep(for: .milliseconds(700))
            let commands = await rig.commands
            #expect(commands.filter { $0 == "GCS" }.count >= 3, "\(commands)")
        }
    }

    /// An unplug clears the reading and ends its loop; the connection after the replug reads it again.
    @Test func batteryIsClearedByAnUnplugAndReadAgainAfterTheReplug() async throws {
        try await withUSBSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            try await waitUntil("the battery") { rig.session.battery != nil }
            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            #expect(rig.session.battery == nil)
            #expect(rig.session.batteryTask == nil)
            let mark = await rig.commands.count
            _ = try await rig.mock.replug()
            try await rig.waitConnected()
            try await waitUntil("the battery after the replug") { rig.session.battery != nil }
            #expect(rig.session.battery?.percent == 100)
            let second = await rig.commands(since: mark)
            #expect(second.filter { $0 == "GCS" }.count == 1, "the 60 s interval: one read at connect: \(second)")
        }
    }

    /// The battery loop ends before the stop's `PSI,0`: no `GCS` follows it, and the reading is gone.
    @Test func noGCSAfterPSI0() async throws {
        var setup = USBSetup()
        setup.batteryPollInterval = .milliseconds(20)
        let outcome = try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("a few battery reads") { await rig.received("GCS") >= 5 }
            try await rig.stopSession()
            #expect(rig.session.battery == nil)
            #expect(rig.session.batteryTask == nil)
            let commands = await rig.commands
            #expect(commands.last == "PSI,0", "\(commands.suffix(5))")
        }
        let lastStop = try #require(outcome.commands.lastIndex(of: "PSI,0"))
        #expect(!outcome.commands[lastStop...].contains("GCS"), "\(outcome.commands.suffix(5))")
        #expect(outcome.commands.last == "PSI,0", "\(outcome.commands.suffix(5))")
    }

    /// One missed read keeps the reading; a second in a row clears it; the next good read brings
    /// it back and starts the count again, so one more miss keeps it. (Each dropped `GCS` times
    /// out after the client's 2 s.)
    @Test func twoMissedReadsClearTheReading() async throws {
        var setup = USBSetup()
        setup.batteryPollInterval = .milliseconds(200)
        try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("the battery") { rig.session.battery != nil }
            await rig.mock.setFaults(MockFaults(dropNextRequest: "GCS", dropCount: 2))
            let mark = await rig.received("GCS")
            // The second dropped `GCS` goes out only after the first has timed out.
            try await waitUntil("the second missed read", .seconds(5)) { await rig.received("GCS") >= mark + 2 }
            #expect(rig.session.battery?.percent == 100, "one missed read cleared the reading")
            try await waitUntil("the reading to clear", .seconds(5)) { rig.session.battery == nil }
            let commands = await rig.commands
            #expect(commands.filter { $0 == "GCS" }.count == mark + 2, "cleared before the second miss: \(commands)")
            try await waitUntil("the reading to return", .seconds(5)) { rig.session.battery != nil }
            #expect(rig.session.battery?.percent == 100)
            // A good read resets the count: one more miss after it is the first, not the third.
            await rig.mock.setFaults(MockFaults(dropNextRequest: "GCS", dropCount: 1))
            let again = await rig.received("GCS")
            // Watched throughout, until the `GCS` after the dropped one (sent only once that one
            // has timed out) has been answered: a clear would last at least the 200 ms interval.
            let cleared = Done()
            try await waitUntil("the read after one more miss", .seconds(5)) {
                if rig.session.battery == nil { cleared.value = true }
                return await rig.received("GCS") >= again + 2
            }
            try await Task.sleep(for: .milliseconds(100))
            #expect(!cleared.value, "a good read didn't reset the miss count")
            #expect(rig.session.battery?.percent == 100)
            #expect(rig.isConnected)
        }
    }

    /// The battery is the profile's (`supportsChargeStatus`), not the transport's: a USB scanner
    /// whose model has none (an SDS200 on a serial port) never gets a `GCS`.
    @Test func usbModelWithoutChargeStatusSendsNoGCS() async throws {
        var setup = USBSetup()
        setup.personality = .sds200
        setup.batteryPollInterval = .milliseconds(50)
        let outcome = try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            #expect(rig.session.model == .sds200)
            try await waitUntil("the display") { rig.session.display != nil }
            try await Task.sleep(for: .milliseconds(300))
            #expect(rig.session.battery == nil)
            #expect(rig.session.batteryTask == nil)
        }
        #expect(!outcome.commands.contains { $0.uppercased().hasPrefix("GCS") }, "\(outcome.commands)")
    }

    // MARK: The SDS100 (SDS100 design §5.2, §5.5)

    /// What an SDS100 session must never send: no `KAL` (its keep-alive is the renewal), no `GCS`
    /// (no charge status), no `KEY` or `MSV` (`allowingKeys` names the test's own menu key);
    /// and it ends with the stop's `PSI,0`. (`withUSBSession` checks `MSM`, `POF`, the
    /// subscription and the cooldown store.)
    private func expectSDS100Rules(_ outcome: USBOutcome, allowingKeys keys: [String] = [],
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        let forbidden = ["KAL", "GCS", "KEY", "MSV"]
        let sent = outcome.commands.filter { command in forbidden.contains { command == $0 || command.hasPrefix($0 + ",") } }
        #expect(sent == keys, "\(outcome.commands)", sourceLocation: sourceLocation)
        #expect(outcome.commands.last == "PSI,0", "\(outcome.commands.suffix(5))", sourceLocation: sourceLocation)
    }

    /// An SDS100 station connects as an SDS150's does, minus the battery: no reading and no `GCS`
    /// however long it runs, and the knobs' 0–15 (a volume or squelch past it is sent as 15).
    @Test func sds100SessionConnectsWithNoBattery() async throws {
        var setup = USBSetup()
        setup.personality = .sds100
        setup.batteryPollInterval = .milliseconds(100)
        let outcome = try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            #expect(rig.session.phase == .connected(model: "SDS100", firmware: "1.26.01"))
            #expect(rig.session.model == .sds100)
            #expect(!rig.session.hasAudio)
            try await rig.waitForPush()
            // More than two battery intervals.
            try await Task.sleep(for: .milliseconds(350))
            #expect(rig.session.battery == nil)
            #expect(rig.session.batteryTask == nil)
            #expect(await rig.received("GCS") == 0)
            let profile = ModelProfile.profile(for: rig.session.model)
            #expect(profile.volumeRange == 0...15)
            #expect(profile.squelchRange == 0...15)
            rig.session.setScannerVolume(29)
            rig.session.setScannerSquelch(29)
            try await waitUntil("VOL,15 and SQL,15") {
                let commands = await rig.commands
                return commands.contains("VOL,15") && commands.contains("SQL,15")
            }
        }
        // Two debounced sets in their own tasks: either may go first.
        #expect(outcome.commands.filter { $0.hasPrefix("VOL") || $0.hasPrefix("SQL") }.sorted() == ["SQL,15", "VOL,15"],
                "\(outcome.commands)")
        expectSDS100Rules(outcome)
    }

    /// Review Focus 3: renewals go out on time while the app keeps the request slot busy. The
    /// scanner is in a menu (the test's one `KEY,M,P`), so the menu's `GSI` and `MSI` reads run
    /// every 2 s; the display policy reads `STS` every 100 ms there (as a screen that changes on
    /// every push would: in a menu the mock's pushes describe the menu, not the scenario), each
    /// reply held 80 ms. With a 200 ms renewal, at least five renewals reach the scanner in 3 s,
    /// none closer than the interval to the one before (less the mock's receive jitter).
    @Test func sds100RenewsWhileTheDisplayLoopIsBusy() async throws {
        var setup = USBSetup()
        setup.personality = .sds100
        setup.keepAliveInterval = .milliseconds(200)
        setup.replyDelays = ["STS": .milliseconds(80)]
        let outcome = try await withUSBSession(setup) { rig in
            var policy = DisplayRefreshPolicy(model: .sds100)
            policy.menuMinInterval = .milliseconds(100)
            policy.menuIdleInterval = .milliseconds(100)
            rig.session.displayPolicy = policy
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            try await rig.session.menu.enter()
            try await waitUntil("the menu") { rig.session.menu.isInMenu }
            try await waitUntil("a push in the menu") { rig.session.info?.isMenu == true }

            let renewals = Mutex<[ContinuousClock.Instant]>([])
            await rig.mock.setCommandObserver { command in
                if command == "PSI,100" { renewals.withLock { $0.append(.now) } }
            }
            let mark = await rig.commands.count
            try await Task.sleep(for: .seconds(3))
            await rig.mock.setCommandObserver(nil)
            let busy = await rig.commands(since: mark)
            let times = renewals.withLock { $0 }

            #expect(times.count >= 5, "\(times.count) renewals in 3 s: \(busy)")
            let gaps = zip(times, times.dropFirst()).map { $0.duration(to: $1) }
            // Measured where the mock receives them, so a little jitter is allowed; a catch-up
            // schedule at a fixed rate (gaps of 120-136 ms behind a busy slot) still fails.
            #expect(gaps.allSatisfy { $0 >= .milliseconds(180) }, "\(gaps)")
            // The slot was busy: STS about every 100 ms (each held 80 ms), and the menu's reads.
            #expect(busy.filter { $0 == "STS" }.count >= 15, "\(busy)")
            #expect(busy.contains("GSI") && busy.contains("MSI"), "\(busy)")
            #expect(rig.isConnected)
        }
        expectSDS100Rules(outcome, allowingKeys: ["KEY,M,P"])
    }

    /// The SDS100 station waits while unplugged (the waiting phase; the menu the test entered, the
    /// display and the info dropped as for the SDS150) and connects again after the replug with a
    /// fresh `PSI,100`, sending no menu command before it has read the scanner.
    @Test func sds100SessionWaitsAndResumes() async throws {
        var setup = USBSetup()
        setup.personality = .sds100
        let outcome = try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            try await waitUntil("the display") { rig.session.display != nil }
            try await rig.session.menu.enter()
            try await waitUntil("the menu") { rig.session.menu.isInMenu }
            await rig.mock.unplug()
            try await rig.waitPhase(.waitingForScanner(hint: hint))
            #expect(rig.session.info == nil)
            #expect(rig.session.display == nil)
            #expect(!rig.session.menu.isInMenu)
            #expect(rig.session.model == .sds100, "the model is kept through the wait")
            #expect(rig.session.displayTask == nil)
            #expect(rig.session.batteryTask == nil)
            #expect(rig.session.keyTask == nil && rig.session.keyGate == nil)
            let mark = await rig.commands.count
            _ = try await rig.mock.replug()
            try await rig.waitConnected()
            #expect(rig.session.phase == .connected(model: "SDS100", firmware: "1.26.01"))
            try await rig.waitForPush()
            let second = await rig.commands(since: mark)
            #expect(second.prefix(3) == ["MDL", "VER", "PSI,100"], "\(second)")
            #expect(second.filter { $0 == "PSI,100" }.count == 1, "\(second)")
            #expect(!second.contains { $0.hasPrefix("KEY") || $0.hasPrefix("MSV") }, "\(second)")
            #expect(rig.session.battery == nil)
        }
        expectSDS100Rules(outcome, allowingKeys: ["KEY,M,P"])
    }
}
