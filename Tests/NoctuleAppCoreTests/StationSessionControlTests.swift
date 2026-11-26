// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Testing
import NoctuleKit
import NoctuleMockScanner
import NoctuleStore
@testable import NoctuleAppCore

// StationSession control, audio failure, restart, and sleep/wake, against an in-process MockSDS200
// (helpers in SessionTestSupport.swift). Every wait is bounded and every test stops the session
// and the mock in all paths. All names and values are fictional.

private func count(_ commands: [String], _ name: String) -> Int {
    commands.filter { $0.uppercased() == name || $0.uppercased().hasPrefix(name + ",") }.count
}

private func softKeyStatus(_ labels: String) throws -> DisplayStatus {
    let lines = [("Mock", ""), (labels, "")]
    return try DisplayStatus(fields: ["00"] + lines.flatMap { [$0.0, $0.1] })
}

@MainActor
private final class Box<Value> { var value: Value? }

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct StationSessionControlTests {
    // MARK: Keys, levels, hold

    @Test func keysReachMock() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            #expect(rig.session.lastKeyReply == nil)
            rig.session.press(.digit4)
            try await waitUntil("KEY,4,P") { await rig.commands.contains("KEY,4,P") }
            try await waitUntil("the key reply is noted", .seconds(3)) { rig.session.lastKeyReply != nil }
        }
        #expect(outcome.leaked == [])
        #expect(count(outcome.commands, "KEY") == 1)
        #expect(outcome.commands.last == "PSI,0")
    }

    @Test func volumeDebouncedAndClamped() async throws {
        let outcome = try await withSession { rig in
            // A 1 s debounce against 20 ms between calls: the burst always fits in one window.
            rig.session.levelDebounceInterval = .seconds(1)
            rig.start()
            try await rig.waitConnected()
            for level in [10, 20, 30, 35, 40] {
                rig.session.setScannerVolume(level)
                try await Task.sleep(for: .milliseconds(20))
            }
            try await waitUntil("VOL sent", .seconds(5)) { count(await rig.commands, "VOL") >= 1 }
            try await Task.sleep(for: .milliseconds(1500))
            let volumes = await rig.commands.filter { $0.uppercased().hasPrefix("VOL,") }
            #expect(volumes == ["VOL,29"])
            #expect(await rig.mock.control.volume == 29)

            rig.session.setScannerSquelch(-3)
            rig.session.setScannerSquelch(25)
            try await waitUntil("SQL sent", .seconds(5)) { count(await rig.commands, "SQL") >= 1 }
            try await Task.sleep(for: .milliseconds(1500))
            #expect(await rig.commands.filter { $0.uppercased().hasPrefix("SQL,") } == ["SQL,19"])
        }
        #expect(outcome.leaked == [])
    }

    @Test func controlIgnoredWhenNotConnected() async throws {
        let outcome = try await withSession { rig in
            rig.session.press(.digit1)
            rig.session.setScannerVolume(5)
            rig.session.setScannerSquelch(5)
            rig.session.hold(.system)
            try await Task.sleep(for: .milliseconds(400))
            #expect(await rig.commands.isEmpty)
            rig.start()
            try await rig.waitConnected()
            try await Task.sleep(for: .milliseconds(500))
            let commands = await rig.commands
            #expect(count(commands, "KEY") == 0 && count(commands, "VOL") == 0 && count(commands, "SQL") == 0,
                    "nothing queued from before the connection: \(commands)")
        }
        #expect(outcome.leaked == [])
    }

    @Test func holdUsesLabelledSoftKey() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("display") { rig.session.display != nil }
            #expect(rig.session.canHold(.system))
            #expect(rig.session.canHold(.department))
            #expect(rig.session.canHold(.channel))
            rig.session.hold(.department)
            try await waitUntil("KEY,B,P") { await rig.commands.contains("KEY,B,P") }
        }
        #expect(outcome.leaked == [])
        #expect(count(outcome.commands, "KEY") == 1)
    }

    @Test func holdDisabledWithoutLabel() async throws {
        let without = DisplayModel(status: try softKeyStatus(" SCAN        FUNC      MENU "), info: nil)
        let with = DisplayModel(status: try softKeyStatus(" system      Dept     CHANNEL "), info: nil)
        for level in [HoldLevel.system, .department, .channel] {
            #expect(StationSession.holdKey(level, display: without) == nil)
            #expect(StationSession.holdKey(level, display: nil) == nil)
        }
        #expect(StationSession.holdKey(.system, display: with) == .soft1)
        #expect(StationSession.holdKey(.department, display: with) == .soft2)
        #expect(StationSession.holdKey(.channel, display: with) == .soft3)

        let outcome = try await withSession { rig in
            #expect(!rig.session.canHold(.department), "not connected")
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("display") { rig.session.display != nil }
            #expect(rig.session.canHold(.department))
            try await rig.stopSession()
            #expect(!rig.session.canHold(.department), "stopped")
            rig.session.hold(.department)
            try await Task.sleep(for: .milliseconds(300))
            #expect(count(await rig.commands, "KEY") == 0)
        }
        #expect(outcome.leaked == [])
    }

    // MARK: Menus on the mirrored display

    private static func highlightedRow(_ display: DisplayModel?) -> Int? {
        display?.rows.firstIndex { $0.segments.contains { $0.highlighted } }
    }

    @Test func menuScreenIsMirrored() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("display") { rig.session.display != nil }
            rig.session.press(.menu)
            try await waitUntil("menu mirrored", .seconds(2)) {
                rig.session.display?.isMenu == true && rig.session.display?.rows.count == 10
            }
            let title = rig.session.display?.rows.first?.segments.map(\.text).joined() ?? ""
            #expect(title.contains("M E N U"))
            #expect(rig.session.display?.softKeys.isEmpty == true)
            try await waitUntil("highlight on row 1", .seconds(1)) { Self.highlightedRow(rig.session.display) == 1 }
            rig.session.press(.scrollRight)
            try await waitUntil("highlight on row 2", .seconds(1)) { Self.highlightedRow(rig.session.display) == 2 }
            rig.session.press(.avoid)
            try await waitUntil("menu left", .seconds(3)) { rig.session.display?.isMenu == false }
        }
        #expect(outcome.leaked == [])
    }

    @Test func menuDisplayRefreshesFasterThanTheScanPolicy() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            rig.session.press(.menu)
            try await waitUntil("menu mirrored", .seconds(3)) { rig.session.display?.isMenu == true }
            try await Task.sleep(for: .milliseconds(500))
            // Six presses 250 ms apart. The scan policy reads STS at most once a second (about two
            // reads here); the menu policy reads about once per press.
            let before = stsCount(await rig.commands)
            for _ in 0..<6 {
                rig.session.press(.scrollRight)
                try await Task.sleep(for: .milliseconds(250))
            }
            try await Task.sleep(for: .milliseconds(300))
            let reads = stsCount(await rig.commands) - before
            #expect(reads >= 4, "STS reads in the window: \(reads)")
        }
        #expect(outcome.leaked == [])
    }

    /// Final review I2: a held scroll key (replies faster than `afterKey`) must not starve the
    /// display fetch. The reviewer's reproduction: 38 presses 80 ms apart gave 0 STS until release.
    @Test func heldScrollKeyInAMenuKeepsTheDisplayLive() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            rig.session.press(.menu)
            try await waitUntil("menu mirrored", .seconds(3)) { rig.session.display?.isMenu == true }
            try await Task.sleep(for: .milliseconds(500))
            let mark = await commandMark(rig.mock)
            for _ in 0..<38 {
                rig.session.press(.scrollRight)
                try await Task.sleep(for: .milliseconds(80))
            }
            try await waitUntil("38 keys", .seconds(5)) {
                count(Array(await rig.commands.dropFirst(mark)), "KEY") >= 38
            }
            let since = Array(await rig.commands.dropFirst(mark))
            let first = try #require(since.firstIndex(of: "KEY,>,P"))
            let last = try #require(since.lastIndex(of: "KEY,>,P"))
            let whileHeld = stsCount(Array(since[first...last]))
            #expect(whileHeld >= 4, "STS reads while the key was held: \(whileHeld)")
            try await Task.sleep(for: .milliseconds(300))
            #expect(count(Array(await rig.commands.dropFirst(mark)), "KEY") == 38, "every press, once")
        }
        #expect(outcome.leaked == [])
    }

    /// Final review M2: keys already queued must not go out once a stop has begun. Each KEY's reply
    /// takes 400 ms, so the display loop's STS waits for the client behind it, and the stop's own
    /// wait for the display loop gives the queue time to send the next key unless it is stopped first.
    @Test func queuedKeysAreNotSentOnceTheStopBegins() async throws {
        var setup = Setup()
        setup.replyDelays = ["KEY": .milliseconds(400)]
        let outcome = try await withSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            rig.session.press(.menu)
            try await waitUntil("menu mirrored", .seconds(5)) { rig.session.display?.isMenu == true }
            try await Task.sleep(for: .milliseconds(500))
            let mark = await commandMark(rig.mock)
            for _ in 0..<8 { rig.session.press(.scrollRight) }
            try await waitUntil("two keys sent", .seconds(5)) {
                count(Array(await rig.commands.dropFirst(mark)), "KEY") >= 2
            }
            // Mid-way through the second key's reply delay: the display loop waits behind it.
            try await Task.sleep(for: .milliseconds(200))
            let atStop = count(Array(await rig.commands.dropFirst(mark)), "KEY")
            try await rig.stopSession()
            let after = Array(await rig.commands.dropFirst(mark))
            #expect(count(after, "KEY") == atStop, "keys sent after the stop began: \(after)")
            #expect(atStop < 8, "the stop came while keys were queued")
            #expect(after.last == "PSI,0")
        }
        #expect(outcome.leaked == [])
    }

    @Test func unansweredKeyIsNotResent() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            rig.session.press(.menu)
            try await waitUntil("menu mirrored", .seconds(3)) { rig.session.display?.isMenu == true }
            try await waitUntil("highlight on row 1", .seconds(1)) { Self.highlightedRow(rig.session.display) == 1 }
            let before = await rig.commands.filter { $0 == "KEY,>,P" }.count
            await rig.mock.setFaults(MockFaults(dropNextRequest: "KEY"))
            rig.session.press(.scrollRight)
            try await Task.sleep(for: .seconds(3))
            let sent = await rig.commands.filter { $0 == "KEY,>,P" }.count - before
            #expect(sent == 1)
            #expect(Self.highlightedRow(rig.session.display) == 1)
        }
        #expect(outcome.leaked == [])
    }

    // MARK: Audio failure and restart

    @Test func audioFailureSetsHintAndDoesNotReconnect() async throws {
        var setup = Setup()
        setup.faults = MockFaults(wedgeAudio: true)
        let outcome = try await withSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("audio failed (audio \(rig.session.audio))") {
                if case .failed = rig.session.audio { return true }
                return false
            }
            try await waitUntil("restart hint", .seconds(3)) { rig.session.restartHint != nil }
            #expect(rig.session.restartHint == .canRestart)
            try await Task.sleep(for: .seconds(3))
            let setups = await rig.mock.rtsp.receivedMethods.filter { $0 == "SETUP" }.count
            #expect(setups == 1, "no automatic reconnect after .failed")
            #expect(rig.isConnected, "control stays up")
            #expect(!(await rig.commands.contains("MSM,1")), "never restarts on its own")
        }
        #expect(outcome.leaked == [])
    }

    @Test func restartRecovers() async throws {
        var setup = Setup()
        setup.faults = MockFaults(wedgeAudio: true)
        let outcome = try await withSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("restart hint") { rig.session.restartHint == .canRestart }
            let result = await rig.session.restartScanner()
            #expect(result == .restarted)
            try await rig.waitConnected()
            try await rig.waitStreaming()
            #expect(rig.session.restartHint == nil)
            #expect(rig.session.lastRestartFailure == nil)
            #expect(await rig.mock.leakedSessions.count == 1, "only the new, live session is open")
            let commands = await rig.commands
            #expect(commands.filter { $0 == "MSM,1" }.count == 1)
        }
        #expect(outcome.leaked == [])
        #expect(outcome.commands.last == "PSI,0")
    }

    @Test func restartThatFailsLeavesSessionStopped() async throws {
        var setup = Setup()
        setup.restartTiming = ScannerRestartTiming(timeout: .seconds(2), pollInterval: .milliseconds(200),
                                                   silenceGrace: .seconds(1), pollTimeout: .milliseconds(300))
        let outcome = try await withSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitStreaming()
            await rig.mock.control.setAnswering(false)
            let result = await rig.session.restartScanner()
            #expect(result == .didNotComeBack)
            #expect(rig.session.phase == .stopped)
            #expect(!rig.session.warnings.isEmpty)
            #expect(rig.session.lastRestartFailure == .didNotComeBack, "the banner shows the failed restart")
            let accepted = await rig.mock.rtsp.acceptedConnections
            await rig.mock.control.setAnswering(true)
            try await Task.sleep(for: .milliseconds(800))
            #expect(rig.session.phase == .stopped, "never retried")
            #expect(await rig.mock.rtsp.acceptedConnections == accepted)
            #expect((await rig.commands).filter { $0 == "MSM,1" }.count == 1)

            // The user's Reconnect starts afresh and forgets the failed restart.
            let session = rig.session
            Task { await session.reconnect() }
            try await rig.waitConnected()
            #expect(rig.session.lastRestartFailure == nil)
        }
        #expect(outcome.leaked == [])
    }

    @Test func stopRightAfterRestartCancelsIt() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitStreaming()
            let session = rig.session
            let result = Box<RestartOutcome>()
            Task { result.value = await session.restartScanner() }
            try await waitUntil("restarting", .seconds(2)) { rig.session.isRestarting }
            try await rig.stopSession()
            try await waitUntil("restart to return", .seconds(5)) { result.value != nil }
            #expect(result.value == .notAccepted(StationSession.restartCancelledReason))
            #expect(!rig.session.isRestarting)
            try await Task.sleep(for: .milliseconds(500))
            #expect(rig.session.phase == .stopped)
            #expect(!(await rig.commands.contains("MSM,1")), "no MSM,1 after the user stopped")
            #expect(await rig.mock.leakedSessions == [])
        }
        #expect(outcome.leaked == [])
        #expect(!outcome.commands.contains("MSM,1"))
    }

    @Test func startDuringRestartOpensNothing() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitStreaming()
            let session = rig.session
            let result = Box<RestartOutcome>()
            Task { result.value = await session.restartScanner() }
            try await waitUntil("MSM,1 sent", .seconds(5)) { await rig.commands.contains("MSM,1") }
            #expect(rig.session.isRestarting)
            let psiBefore = await rig.commands.filter { $0.hasPrefix("PSI,") && $0 != "PSI,0" }.count
            let acceptedBefore = await rig.mock.rtsp.acceptedConnections
            await rig.session.start()
            await rig.session.reconnect()
            #expect(rig.session.phase == .stopped, "start and reconnect do nothing while restarting")
            #expect(await rig.commands.filter { $0.hasPrefix("PSI,") && $0 != "PSI,0" }.count == psiBefore)
            #expect(await rig.mock.rtsp.acceptedConnections == acceptedBefore)
            try await waitUntil("restart to return", .seconds(10)) { result.value != nil }
            #expect(result.value == .restarted)
            #expect(!rig.session.isRestarting)
            try await rig.waitConnected()
            try await rig.waitStreaming()
            #expect(await rig.mock.rtsp.acceptedConnections == acceptedBefore + 1, "one session, from the restart")
        }
        #expect(outcome.leaked == [])
    }

    /// Sleep during a restart, then wake: the session comes back, whether the sleep came after
    /// `MSM,1` (the restart finishes but doesn't start) or before it (the restart is cancelled).
    @Test(arguments: [true, false])
    func resumeAfterSuspendDuringRestartReconnects(afterMSM: Bool) async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitStreaming()
            let session = rig.session
            let result = Box<RestartOutcome>()
            Task { result.value = await session.restartScanner() }
            if afterMSM {
                try await waitUntil("MSM,1 sent", .seconds(5)) { await rig.commands.contains("MSM,1") }
            } else {
                try await waitUntil("restarting", .seconds(2)) { rig.session.isRestarting }
            }
            await session.suspend()
            let resumed = Done()
            Task { await session.resume(); resumed.value = true }
            try await waitUntil("restart to return", .seconds(10)) { result.value != nil }
            #expect(result.value == (afterMSM ? .restarted : .notAccepted(StationSession.restartCancelledReason)))
            try await waitUntil("resume to return", .seconds(15)) { resumed.value }
            #expect(!session.isRestarting)
            try await rig.waitConnected()
            try await rig.waitStreaming()
            #expect((await rig.commands).filter { $0 == "MSM,1" }.count == (afterMSM ? 1 : 0))
        }
        #expect(outcome.leaked == [])
    }

    // MARK: Sleep and wake

    @Test func wakeWithinCooldownWaits() async throws {
        var setup = Setup()
        setup.cooldown = .seconds(1)
        let outcome = try await withSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitStreaming()
            await rig.session.suspend()
            #expect(rig.session.phase == .stopped)
            #expect(await rig.mock.leakedSessions == [])
            let session = rig.session
            let resumed = Done()
            Task { await session.resume(); resumed.value = true }
            try await waitUntil("waiting for the cooldown") {
                if case .waitingForCooldown = rig.session.phase { return true }
                return false
            }
            try await rig.waitConnected()
            try await rig.waitStreaming()
            try await waitUntil("resume() to return") { resumed.value }
        }
        #expect(outcome.leaked == [])
        #expect(outcome.commands.last == "PSI,0")
    }

    /// A second suspend (sleep, dark wake, sleep again) keeps the first one's "was running", so
    /// the full wake still starts the session (Task 11 QA, fix round 3).
    @Test func doubleSuspendStillResumes() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitStreaming()
            await rig.session.suspend()
            await rig.session.suspend()
            #expect(rig.session.phase == .stopped)
            await rig.session.resume()
            try await rig.waitStreaming()
        }
        #expect(outcome.leaked == [])
    }

    /// A `stop()` that arrives while `suspend()` is still tearing down (slow TEARDOWN) wins: the
    /// wake leaves the session stopped (Task 8 QA probe, closed in Task 11 fix round 3).
    @Test func stopDuringSuspendThenResumeStaysStopped() async throws {
        var setup = Setup()
        setup.replyDelays = ["TEARDOWN": .seconds(1)]
        setup.requestTimeout = .seconds(3)
        let outcome = try await withSession(setup) { rig in
            rig.start()
            try await rig.waitStreaming()
            let session = rig.session
            let suspended = Done(), stopped = Done()
            Task { await session.suspend(); suspended.value = true }
            try await waitUntil("suspend tearing down", .seconds(5)) { session.phase == .stopping }
            Task { await session.stop(); stopped.value = true }
            try await waitUntil("suspend and stop", .seconds(10)) { suspended.value && stopped.value }
            let commands = await rig.mock.control.receivedCommands.count
            await session.resume()
            try await Task.sleep(for: .seconds(1))
            #expect(session.phase == .stopped, "\(session.phase)")
            #expect(await rig.mock.control.receivedCommands.count == commands)
        }
        #expect(outcome.leaked == [])
    }

    /// A suspend that lands after `start()` was called but before its task moved the phase off
    /// `.idle` still counts as running, so the wake starts it (QA probe, Task 8 fix round 1).
    @Test(arguments: Array(0...12))
    func suspendRightAfterStartResumes(yields: Int) async throws {
        let outcome = try await withSession { rig in
            rig.start()
            for _ in 0..<yields { await Task.yield() }
            let phaseAtSuspend = rig.session.phase
            await rig.session.suspend()
            await rig.session.resume()
            do {
                try await rig.waitConnected(.seconds(5))
            } catch {
                Issue.record("yields \(yields): phase at suspend \(phaseAtSuspend), now \(rig.session.phase): stays down after wake")
            }
        }
        #expect(outcome.leaked == [])
    }

    /// A `start()` while a stop is in flight waits for the stop, then starts: the runs never
    /// overlap (no `.inUse` from the session's own lock, no second RTSP session at once).
    @Test func startDuringStopWaitsForIt() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitStreaming()
            let session = rig.session
            let stopped = Done()
            Task { await session.stop(); stopped.value = true }
            for _ in 0..<50 where session.phase != .stopping { await Task.yield() }
            #expect(session.phase == .stopping)
            rig.start()
            try await waitUntil("the stop") { stopped.value }
            try await rig.waitConnected()
            try await rig.waitStreaming()
            #expect(await rig.mock.rtsp.acceptedConnections == 2)
            #expect(await rig.mock.leakedSessions.count == 1, "only the new session is open")
        }
        #expect(outcome.leaked == [])
    }

    @Test func resumeAfterIdleSuspendDoesNothing() async throws {
        let outcome = try await withSession { rig in
            await rig.session.suspend()
            await rig.session.resume()
            try await Task.sleep(for: .milliseconds(300))
            #expect(!rig.isConnected)
            #expect(await rig.commands.isEmpty)
        }
        #expect(outcome.commands == [])
    }

    @Test func wakeRetriesUntilScannerAnswers() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitStreaming()
            await rig.session.suspend()
            await rig.mock.control.setAnswering(false)
            let mdlBefore = count(await rig.commands, "MDL")
            let acceptedBefore = await rig.mock.rtsp.acceptedConnections

            let session = rig.session
            Task { await session.resume() }
            var sawNoAnswer = false
            // The first attempt and two retries go unanswered.
            try await waitUntil("three unanswered MDLs", .seconds(30)) {
                if case .noAnswer = rig.session.phase { sawNoAnswer = true }
                return count(await rig.commands, "MDL") - mdlBefore >= 3
            }
            #expect(await rig.mock.rtsp.acceptedConnections == acceptedBefore, "no RTSP while MDL is unanswered")
            let answeringAgain = ContinuousClock.now
            await rig.mock.control.setAnswering(true)
            try await rig.waitConnected(.seconds(20))
            try await rig.waitStreaming()
            #expect(sawNoAnswer, "the phase is .noAnswer between attempts")
            let accepted = await rig.mock.rtsp.connectionsAcceptedAt.dropFirst(acceptedBefore)
            #expect(!accepted.isEmpty)
            #expect(accepted.allSatisfy { $0 > answeringAgain }, "RTSP only after MDL answers")
        }
        #expect(outcome.leaked == [])
        #expect(outcome.commands.last == "PSI,0")
    }

    @Test func wakeDoesNotRetryConfigurationFailures() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            await rig.session.suspend()
            // device.json as a directory: the settings can't be read (not a network failure).
            try FileManager.default.createDirectory(at: rig.dir.appendingPathComponent("device.json"),
                                                    withIntermediateDirectories: false)
            let before = await rig.commands.count
            await rig.session.resume()
            guard case .noAnswer(let text) = rig.session.phase else {
                Issue.record("phase \(rig.session.phase)"); return
            }
            #expect(text.hasPrefix("Can't read the settings"), "\(text)")
            try await Task.sleep(for: .seconds(1))
            #expect(rig.session.phase == .noAnswer(text), "no retries")
            #expect(await rig.commands.count == before, "nothing sent")
        }
        #expect(outcome.leaked == [])
    }

    @Test func stopEndsWakeRetries() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            await rig.session.suspend()
            await rig.mock.control.setAnswering(false)
            await rig.session.resume()
            #expect({ if case .noAnswer = rig.session.phase { return true }; return false }(),
                    "phase \(rig.session.phase)")
            try await rig.stopSession()
            let mdl = count(await rig.commands, "MDL")
            try await Task.sleep(for: .seconds(1))
            #expect(count(await rig.commands, "MDL") == mdl, "no retries after stop()")
        }
        #expect(outcome.leaked == [])
    }

    // MARK: Owner stops win over a reconnect or a wake (final review C1)

    /// A reconnect is a stop then a start. A `stop()` that arrives while the reconnect's stop is
    /// still tearing down (slow TEARDOWN) wins: the reconnect doesn't start the session again.
    @Test func stopDuringReconnectHaltWins() async throws {
        var setup = Setup()
        setup.replyDelays = ["TEARDOWN": .seconds(1)]
        setup.requestTimeout = .seconds(3)
        let outcome = try await withSession(setup) { rig in
            rig.start()
            try await rig.waitStreaming()
            let session = rig.session
            let reconnected = Done(), stopped = Done()
            Task { await session.reconnect(); reconnected.value = true }
            try await waitUntil("reconnect tearing down", .seconds(5)) { session.phase == .stopping }
            Task { await session.stop(); stopped.value = true }
            try await waitUntil("reconnect and stop", .seconds(10)) { reconnected.value && stopped.value }
            try await Task.sleep(for: .seconds(1))  // well past the 300 ms cooldown
            #expect(session.phase == .stopped, "\(session.phase)")
            #expect(await rig.mock.rtsp.acceptedConnections == 1, "the reconnect opened no new session")
            #expect(await rig.mock.control.activeSubscribers == 0)
        }
        #expect(outcome.leaked == [])
    }

    /// A wake whose `resume()` waits for a restart in flight, then a `stop()` before the restart
    /// finishes: the stop wins, and the resume doesn't start the session.
    @Test func stopWhileResumeWaitsOnRestartStaysStopped() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitStreaming()
            let session = rig.session
            let result = Box<RestartOutcome>()
            Task { result.value = await session.restartScanner() }
            try await waitUntil("MSM,1 sent", .seconds(5)) { await rig.commands.contains("MSM,1") }
            await session.suspend()
            let resumed = Done()
            Task { await session.resume(); resumed.value = true }
            for _ in 0..<20 { await Task.yield() }
            await session.stop()
            #expect(session.isRestarting, "the stop came while the resume still waited on the restart")
            try await waitUntil("restart to return", .seconds(10)) { result.value != nil }
            try await waitUntil("resume to return", .seconds(10)) { resumed.value }
            let accepted = await rig.mock.rtsp.acceptedConnections
            try await Task.sleep(for: .seconds(1))
            #expect(session.phase == .stopped, "\(session.phase)")
            #expect(await rig.mock.rtsp.acceptedConnections == accepted)
            #expect(accepted == 1, "only the first run opened audio")
            #expect(await rig.mock.control.activeSubscribers == 0)
        }
        #expect(outcome.leaked == [])
    }

    /// Sleep during a restart, a wake whose `resume()` waits for the restart, then sleep again
    /// before the restart finishes: the resume doesn't start the session while the Mac sleeps,
    /// and the next wake does.
    @Test func suspendWhileResumeWaitsOnRestartStaysSuspended() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitStreaming()
            let session = rig.session
            let result = Box<RestartOutcome>()
            Task { result.value = await session.restartScanner() }
            try await waitUntil("MSM,1 sent", .seconds(5)) { await rig.commands.contains("MSM,1") }
            await session.suspend()
            let resumed = Done()
            Task { await session.resume(); resumed.value = true }
            for _ in 0..<20 { await Task.yield() }
            await session.suspend()
            #expect(session.isRestarting, "the second sleep came while the resume still waited on the restart")
            try await waitUntil("restart to return", .seconds(10)) { result.value != nil }
            try await waitUntil("resume to return", .seconds(10)) { resumed.value }
            try await Task.sleep(for: .seconds(1))
            #expect(session.phase == .stopped, "asleep: \(session.phase)")
            #expect(await rig.mock.rtsp.acceptedConnections == 1, "nothing opened while asleep")
            #expect(await rig.mock.control.activeSubscribers == 0)
            await session.resume()
            try await rig.waitStreaming()
        }
        #expect(outcome.leaked == [])
    }
}

// MARK: Hold by HLD on the BCD436HP (Plan 23 Task 8)

private func holdInfo(_ body: String, mode: String = "Scan Mode", screen: String = "trunk_scan") throws -> ScannerInfo {
    try ScannerInfo(xml: XMLNode.parse(Data("<ScannerInfo Mode=\"\(mode)\" V_Screen=\"\(screen)\">\(body)</ScannerInfo>".utf8)))
}

private let holdSystem = "<System Name=\"Fictional\" Index=\"101\" Hold=\"Off\"/>"
private let holdDept = "<Department Name=\"Dept\" Index=\"200\" Hold=\"Off\"/>"

@MainActor
@Suite(.serialized, .timeLimit(.minutes(3))) struct StationSessionHoldCommandTests {
    @Test func holdTargetMapsEachLevel() throws {
        let trunk = try holdInfo(holdSystem + holdDept + "<TGID Name=\"TG\" Index=\"1000\" Hold=\"Off\"/>")
        #expect(StationSession.holdTarget(.system, info: trunk) == .system(index: 101))
        #expect(StationSession.holdTarget(.department, info: trunk) == .department(index: 200, system: 101))
        #expect(StationSession.holdTarget(.channel, info: trunk) == .trunkChannel(index: 1000))
        let conv = try holdInfo(holdSystem + holdDept + "<ConvFrequency Name=\"C\" Index=\"1000\" Hold=\"Off\"/>")
        #expect(StationSession.holdTarget(.channel, info: conv) == .conventionalChannel(index: 1000))
        #expect(StationSession.holdTarget(.system, info: nil) == nil)
        let noDept = try holdInfo(holdSystem)
        #expect(StationSession.holdTarget(.department, info: noDept) == nil)
        #expect(StationSession.holdTarget(.channel, info: noDept) == nil)
    }

    @Test func noHoldTargetForAnUnprogrammedTalkgroup() throws {
        let info = try holdInfo(holdSystem + holdDept + "<TGID Name=\"\" Index=\"4294967295\" Hold=\"Off\"/>")
        #expect(StationSession.holdTarget(.channel, info: info) == nil)
        #expect(StationSession.holdTarget(.system, info: info) == .system(index: 101))
    }

    @Test func noHoldInAMenu() throws {
        let info = try holdInfo(holdSystem + holdDept + "<TGID Name=\"TG\" Index=\"1000\" Hold=\"Off\"/>",
                                mode: "Menu Tree", screen: "menu_selection")
        for level in HoldLevel.allCases { #expect(StationSession.holdTarget(level, info: info) == nil) }
    }

    private func bcdSetup() -> USBSetup {
        var setup = USBSetup()
        setup.personality = .bcd436hp
        return setup
    }

    @Test func holdSendsOneHLDAndTheNextPushShowsIt() async throws {
        let outcome = try await withUSBSession(bcdSetup()) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            let system = try #require(rig.session.info?.system?.index)
            #expect(rig.session.canHold(.system))
            rig.session.hold(.system)
            try await waitUntil("HLD sent") { await rig.received("HLD") == 1 }
            try await waitUntil("the push shows the hold") { rig.session.info?.system?.hold == true }
            #expect(await rig.commands.contains("HLD,SYS,\(system),"))
            #expect(await rig.mock.holds == ["SYS:\(system)"])
            try await waitUntil("flag clear") { rig.session.canHold(.system) }
            rig.session.hold(.system)
            try await waitUntil("released") { rig.session.info?.system?.hold == false }
            #expect(await rig.received("HLD") == 2)
            #expect(await rig.received("KEY") == 0)
        }
        #expect(outcome.commands.last == "PSI,0")
    }

    @Test func doubleClickSendsOneHLD() async throws {
        var setup = bcdSetup()
        setup.replyDelays = ["HLD": .milliseconds(600)]
        let outcome = try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            rig.session.hold(.system)
            #expect(!rig.session.canHold(.system), "in flight")
            rig.session.hold(.system)
            rig.session.hold(.department)
            try await Task.sleep(for: .milliseconds(1200))
            #expect(await rig.received("HLD") == 1)
            #expect(rig.session.canHold(.system), "the flag clears after the reply")
        }
        #expect(outcome.commands.last == "PSI,0")
    }

    /// The HLD waits for the request slot behind a slow `STS`; the stop closes the gate first, so
    /// once it holds the slot it writes nothing.
    @Test func holdAfterStopSendsNothing() async throws {
        var setup = bcdSetup()
        setup.replyDelays = ["STS": .seconds(2)]
        let outcome = try await withUSBSession(setup) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            try await waitUntil("an STS holds the slot") { await rig.received("STS") >= 1 }
            #expect(rig.session.canHold(.system))
            rig.session.hold(.system)
            try await Task.sleep(for: .milliseconds(100))
            try await rig.stopSession()
            try await Task.sleep(for: .milliseconds(300))
            #expect(await rig.received("HLD") == 0)
            #expect(!rig.session.warnings.contains { $0.contains("couldn't hold") }, "\(rig.session.warnings)")
        }
        #expect(!outcome.commands.contains { $0.hasPrefix("HLD") })
    }

    @Test func unprogrammedTalkgroupDisablesChannelOnASession() async throws {
        let outcome = try await withUSBSession(bcdSetup()) { rig in
            rig.start()
            try await rig.waitConnected()
            try await rig.waitForPush()
            var found = false
            for _ in 0..<200 where !found {
                if rig.session.info?.channel?.index == ScannerInfo.unprogrammedIndex { found = true; break }
                rig.clock.advance(by: 0.5)
                try await Task.sleep(for: .milliseconds(60))
            }
            try #require(found, "the scenario's unprogrammed talkgroup never showed")
            #expect(!rig.session.canHold(.channel))
            rig.session.hold(.channel)
            try await Task.sleep(for: .milliseconds(300))
            #expect(await rig.received("HLD") == 0)
        }
        #expect(!outcome.commands.contains { $0.hasPrefix("HLD") })
    }

    @Test func sdsHoldUnchanged() async throws {
        let outcome = try await withSession { rig in
            rig.start()
            try await rig.waitConnected()
            try await waitUntil("display") { rig.session.display != nil }
            rig.session.hold(.system)
            try await waitUntil("KEY,A,P") { await rig.commands.contains("KEY,A,P") }
        }
        #expect(!outcome.commands.contains { $0.hasPrefix("HLD") })
    }
}
