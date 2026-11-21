// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import Testing
@testable import NoctuleScan

/// The sleep hold (Review Focus 1): the Mac sleeps only after sessions have suspended, or at
/// the deadline. Driven directly, without IOKit.
@MainActor @Suite struct PowerGateTests {
    /// What happened, in order.
    @MainActor final class Log {
        var events: [String] = []
    }

    /// Lets a waiting resume go on.
    @MainActor final class Released {
        var value = false
    }

    /// Polls for at most `seconds`.
    private func eventually(_ seconds: Double = 2, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func messageTypesMapToEvents() {
        #expect(PowerGate.event(for: 0xE000_0270) == .canSleep)
        #expect(PowerGate.event(for: 0xE000_0280) == .willSleep)
        #expect(PowerGate.event(for: 0xE000_0300) == .other)  // has powered on: dark wakes too
        #expect(PowerGate.event(for: 0xE000_0320) == .other)  // will power on
        #expect(PowerGate.event(for: 0xE000_0290) == .other)  // will not sleep
    }

    @Test func canSleepAllowsAtOnceWithoutSuspending() {
        let log = Log()
        let gate = PowerGate(suspend: { log.events.append("suspend") }, resume: { log.events.append("resume") })
        gate.handle(.canSleep) { log.events.append("allow") }
        #expect(log.events == ["allow"])
    }

    @Test func willSleepAllowsOnlyAfterSuspendFinishes() async {
        let log = Log()
        let gate = PowerGate(deadline: .seconds(10), suspend: {
            log.events.append("suspend started")
            try? await Task.sleep(for: .milliseconds(200))
            log.events.append("suspend finished")
        }, resume: {})
        let started = Date()
        gate.handle(.willSleep) { log.events.append("allow") }
        #expect(log.events.isEmpty)  // the answer isn't given synchronously
        #expect(await eventually { log.events.contains("allow") })
        #expect(log.events == ["suspend started", "suspend finished", "allow"])
        #expect(Date().timeIntervalSince(started) >= 0.2)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(log.events.filter { $0 == "allow" }.count == 1)
    }

    /// The suspend hangs until the test releases it, so an allow at all is the deadline's: it
    /// can't be the suspend finishing, however late this process's timers wake (an upper bound on
    /// the time, 0.9 s, failed on the CI runner at 1.5–2.1 s; LESSONS.md 2026-11-21).
    @Test func willSleepAllowsAtTheDeadlineIfSuspendHangs() async {
        let log = Log()
        let released = Released()
        let gate = PowerGate(deadline: .milliseconds(150), suspend: {
            log.events.append("suspend started")
            while !released.value { try? await Task.sleep(for: .milliseconds(10)) }
            log.events.append("suspend finished")
        }, resume: {})
        let started = Date()
        gate.handle(.willSleep) { log.events.append("allow") }
        #expect(await eventually(10) { log.events.contains("allow") })
        let elapsed = Date().timeIntervalSince(started)
        // Not before the deadline; and within a bound loose enough for a late wakeup (the runner's
        // were up to 2 s) that still catches a deadline that fires far too late.
        #expect(elapsed >= 0.15 && elapsed < 5, "allowed \(elapsed) s in (deadline 0.15 s)")
        #expect(log.events == ["suspend started", "allow"])
        // The suspend carries on; the sleep is still allowed only once.
        released.value = true
        #expect(await eventually(10) { log.events.contains("suspend finished") })
        #expect(log.events == ["suspend started", "allow", "suspend finished"])
    }

    @Test func wakeResumes() async {
        let log = Log()
        let gate = PowerGate(suspend: {}, resume: { log.events.append("resume") })
        var allowed = false
        gate.handle(.wake) { allowed = true }
        #expect(await eventually { log.events == ["resume"] })
        #expect(!allowed)
    }

    /// A wake right after a sleep never overtakes the suspend. The suspend runs until the test
    /// lets it finish, which it does once the deadline has allowed the sleep, not after a fixed
    /// 200 ms: a deadline timer that woke late (the CI runner, LESSONS.md 2026-11-20) came after
    /// that suspend had finished, so the sleep was allowed after it, not at the deadline.
    @Test func wakeWaitsForTheSuspendBeforeIt() async {
        let log = Log()
        let (release, finish) = AsyncStream.makeStream(of: Void.self)
        let gate = PowerGate(deadline: .milliseconds(50), suspend: {
            log.events.append("suspend started")
            for await _ in release { break }
            log.events.append("suspend finished")
        }, resume: { log.events.append("resume") })
        gate.handle(.willSleep) { log.events.append("allow") }
        gate.handle(.wake) { log.events.append("unexpected allow") }
        #expect(await eventually { log.events.contains("allow") })
        finish.yield()
        #expect(await eventually { log.events.contains("resume") })
        #expect(log.events == ["suspend started", "allow", "suspend finished", "resume"])
    }

    /// QA's probe: a sleep while a wake's resume is still running (waiting out the cooldown)
    /// suspends at once and allows the sleep only after that, not at the deadline. The deadline
    /// is long (5 s) so a slow machine can't mistake the deadline for the suspend's end.
    @Test func sleepDuringLongResumeSuspendsBeforeAllow() async {
        let log = Log()
        let gate = PowerGate(deadline: .seconds(5), suspend: {
            log.events.append("suspend")
        }, resume: {
            log.events.append("resume started")
            try? await Task.sleep(for: .seconds(10))  // e.g. waiting out the 120 s cooldown
            log.events.append("resume finished")
        })
        gate.handle(.wake) {}
        try? await Task.sleep(for: .milliseconds(50))
        let started = Date()
        gate.handle(.willSleep) { log.events.append("allow") }
        #expect(await eventually(8) { log.events.contains("allow") })
        #expect(Date().timeIntervalSince(started) < 2.5, "allowed at the deadline, not after the suspend")
        let suspend = log.events.firstIndex(of: "suspend")
        let allow = log.events.firstIndex(of: "allow")
        #expect(suspend != nil && allow != nil && suspend! < allow!, "\(log.events)")
    }

    /// The interrupted resume is cancelled, so it doesn't reconnect after the suspend; the next
    /// wake resumes. The resume waits until the test lets it connect, not for 300 ms: a test that
    /// woke late (LESSONS.md 2026-11-20) found a 300 ms resume already connected before its sleep.
    @Test func interruptedResumeDoesNotReconnectAfterSuspend() async {
        let log = Log()
        let release = Released()
        let gate = PowerGate(deadline: .seconds(5), suspend: {
            log.events.append("suspend")
        }, resume: {
            log.events.append("resume started")
            // Like the cooldown wait: on cancellation (or a suspend) it gives up, never connects.
            do {
                while !release.value { try await Task.sleep(for: .milliseconds(10)) }
            } catch {
                log.events.append("resume interrupted")
                return
            }
            log.events.append("connected")
        })
        gate.handle(.wake) {}
        #expect(await eventually { log.events.contains("resume started") })
        gate.handle(.willSleep) { log.events.append("allow") }
        #expect(await eventually { log.events.contains("allow") && log.events.contains("resume interrupted") },
                "\(log.events)")
        #expect(log.events == ["resume started", "resume interrupted", "suspend", "allow"]
                || log.events == ["resume started", "suspend", "resume interrupted", "allow"]
                || log.events == ["resume started", "suspend", "allow", "resume interrupted"], "\(log.events)")
        #expect(!log.events.contains("connected"))

        release.value = true
        gate.handle(.wake) {}
        #expect(await eventually { log.events.last == "connected" }, "\(log.events)")
    }

    /// A sleep right after a wake (still waiting for the previous suspend) cancels that resume.
    @Test func sleepBeforeAPendingResumeStartsCancelsIt() async {
        let log = Log()
        let gate = PowerGate(deadline: .seconds(5), suspend: {
            log.events.append("suspend started")
            try? await Task.sleep(for: .milliseconds(150))
            log.events.append("suspend finished")
        }, resume: { log.events.append("resume") })
        gate.handle(.willSleep) { log.events.append("allow 1") }
        gate.handle(.wake) {}
        gate.handle(.willSleep) { log.events.append("allow 2") }
        #expect(await eventually { log.events.filter { $0.hasPrefix("allow") }.count == 2 })
        try? await Task.sleep(for: .milliseconds(200))
        #expect(!log.events.contains("resume"), "\(log.events)")
    }

    /// Sleep, dark wake (ignored), sleep again, full wake: both sleeps suspend and the wake
    /// resumes once.
    @Test func sleepSleepWakeResumes() async {
        let log = Log()
        let gate = PowerGate(suspend: { log.events.append("suspend") }, resume: { log.events.append("resume") })
        gate.handle(.willSleep) { log.events.append("allow") }
        #expect(await eventually { log.events.count == 2 })
        gate.handle(.willSleep) { log.events.append("allow") }
        #expect(await eventually { log.events.count == 4 })
        gate.handle(.wake) {}
        #expect(await eventually { log.events.count == 5 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.events == ["suspend", "allow", "suspend", "allow", "resume"])
    }

    @Test func otherMessagesDoNothing() async {
        let log = Log()
        let gate = PowerGate(suspend: { log.events.append("suspend") }, resume: { log.events.append("resume") })
        gate.handle(.other) { log.events.append("allow") }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(log.events.isEmpty)
    }
}
#endif
