// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import Foundation
import Synchronization
import Testing
import NoctuleDevConfig
import NoctuleKitTestSupport
import NoctuleMockScanner
@testable import NoctuleKit

// Opt-in checks against the owner's SDS150 on USB serial (SDS150 design §8), and the same checks
// run against `MockSerialScanner` on a pseudo-terminal by default, so what they send is known
// before the owner runs them. The checks themselves are `HandheldHardwareChecks`, shared with the
// SDS100's suites.
//
// **Hardware safety.** The hardware suites (read-only, quiet port, push, keep-alive) are skipped
// unless their variables are set, and always while `NOCTULE_NO_USB_DETECTION` is set (agents
// export it): the trait decides from the environment alone, before any port is resolved or
// opened. Only the hardware suites look for a port (`SCANNER_SERIAL` as written, else the one port
// whose USB product name names the SDS150: the SDS100 shares its product ID); the mock-backed tests
// open the pty their mock made, by path.

/// When the hardware suites run (`.enabled(if:)`), from the environment alone.
enum SDS150HardwareGate {
    static let readOnlyKey = "NOCTULE_SDS150_HARDWARE_TESTS"
    static let pushKey = "NOCTULE_SDS150_PUSH_TEST"
    static let keepAliveKey = "NOCTULE_SDS150_KEEPALIVE_TEST"
    /// The `noctule` CLI's USB kill-switch (`USBDetection.disableKey` in `NoctuleCLICore`, which
    /// this target doesn't depend on): any non-empty value skips every hardware suite.
    static let killSwitchKey = "NOCTULE_NO_USB_DETECTION"

    /// `NOCTULE_SDS150_HARDWARE_TESTS=1`, and the kill-switch unset or empty.
    static func readOnlyEnabled(_ environment: [String: String]) -> Bool {
        environment[readOnlyKey] == "1" && (environment[killSwitchKey] ?? "").isEmpty
    }

    /// The read-only gate, and `NOCTULE_SDS150_PUSH_TEST=1` as well.
    static func pushEnabled(_ environment: [String: String]) -> Bool {
        readOnlyEnabled(environment) && environment[pushKey] == "1"
    }

    /// The read-only gate, and `NOCTULE_SDS150_KEEPALIVE_TEST=1` as well (its own variable: the
    /// check takes four minutes and sends `KAL`).
    static func keepAliveEnabled(_ environment: [String: String]) -> Bool {
        readOnlyEnabled(environment) && environment[keepAliveKey] == "1"
    }
}

/// The SDS150 over USB serial (design §8): the opt-in hardware suites, and the same checks on the
/// mock. One serialized suite, so no two hardware suites ever hold the port at once.
@Suite(.serialized, .timeLimit(.minutes(3))) struct SDS150HardwareTests {
    /// The owner's SDS150, read-only. Opt-in: `NOCTULE_SDS150_HARDWARE_TESTS=1` (never with
    /// `NOCTULE_NO_USB_DETECTION` set). Sends `MDL` (an SDS150, else nothing more), then `VER`,
    /// `VOL`, `SQL`, `GSI`, `STS`, one each; never `GCS`, `PSI`, `KEY`, `MSV`, `MSM` or `POF`.
    @Suite(.enabled(if: SDS150HardwareGate.readOnlyEnabled(ProcessInfo.processInfo.environment)))
    struct ReadOnly {
        @Test func readsIdentityAndStatus() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .sds150)
            let report = try await HandheldHardwareChecks.readOnly(path: path, expecting: .sds150)
            print("SDS150 hardware: \(report.model) firmware \(report.firmware), VOL \(report.volume), "
                + "SQL \(report.squelch), GSI mode \(report.mode ?? "nil"), screen \(report.screen ?? "nil"), "
                + "soft keys \(report.softKeys)")
            // Counts only (never display text): the line count and each line's width in characters.
            print("SDS150 hardware: STS \(report.displayWidths.count) lines, widths \(report.displayWidths)")
        }
    }

    /// The owner's SDS150, sending nothing: no `PSI` push may arrive unasked (design §8 check 10).
    /// Opt-in like `ReadOnly`: `NOCTULE_SDS150_HARDWARE_TESTS=1` (never with
    /// `NOCTULE_NO_USB_DETECTION` set). Opens the port, listens for 2 s, closes it; sends nothing.
    /// Run it first as a baseline, then again after `watch`, after the push suite and after `log`.
    @Suite(.enabled(if: SDS150HardwareGate.readOnlyEnabled(ProcessInfo.processInfo.environment)))
    struct QuietPort {
        @Test func noPushArrivesUnasked() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .sds150)
            let report = try await HandheldHardwareChecks.quietPort(path: path)
            print("SDS150 hardware: quiet port: \(report.pushes) unasked PSI pushes, other \(report.other)")
        }
    }

    /// The owner's SDS150: `PSI` pushes while `GSI` is asked (design §8 check 3), then the port held
    /// 1.5 s after `PSI,0`: the pushes must stop. Opt-in:
    /// `NOCTULE_SDS150_HARDWARE_TESTS=1` and `NOCTULE_SDS150_PUSH_TEST=1` (never with
    /// `NOCTULE_NO_USB_DETECTION` set). Sends `MDL` (an SDS150, else nothing more), `PSI,500`, 20
    /// `GSI`s, and `PSI,0` on every path; never `GCS`, `KEY`, `MSV`, `MSM` or `POF`.
    @Suite(.enabled(if: SDS150HardwareGate.pushEnabled(ProcessInfo.processInfo.environment)))
    struct Push {
        @Test func pushesAndRepliesStayApart() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .sds150)
            let report = try await HandheldHardwareChecks.pushWhileReading(path: path, expecting: .sds150)
            print("SDS150 hardware: \(report.replies) GSI replies, \(report.pushes) pushes, "
                + "\(report.pushesAfterStop) after PSI,0, unexpected \(report.unexpected)")
        }
    }

    /// The owner's SDS150: does `KAL` keep the pushes going past 183 s? `PSI,1000` with `KAL` every
    /// 60 s, held 240 s, then `PSI,0` and 1.5 s more. Opt-in: `NOCTULE_SDS150_HARDWARE_TESTS=1` and
    /// `NOCTULE_SDS150_KEEPALIVE_TEST=1` (never with `NOCTULE_NO_USB_DETECTION` set). Sends `MDL`
    /// (an SDS150, else nothing more), `PSI,1000`, three or four `KAL`s (the fourth falls due as the
    /// hold ends) and `PSI,0`; never `GSI`, `GCS`, `KEY`, `MSV`, `MSM` or `POF`. About four minutes.
    @Suite(.enabled(if: SDS150HardwareGate.keepAliveEnabled(ProcessInfo.processInfo.environment)))
    struct KeepAlive {
        @Test func keepAliveKeepsThePushesGoing() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .sds150)
            let report = try await HandheldHardwareChecks.keepAlive(path: path, expecting: .sds150)
            print("SDS150 hardware: keep-alive: \(report.summary)")
        }
    }
}

extension SDS150HardwareTests {
    /// The checks on the mock: exactly what each sends, and `PSI,0` on every path.
    @Suite struct OnTheMock {
        @Test func readOnlySendsExactlyTheSixReads() async throws {
            let mock = try await withMockHandheld { path in
                let report = try await HandheldHardwareChecks.readOnly(path: path, commandTimeout: .milliseconds(700))
                #expect(report.model == "SDS150")
                #expect(report.firmware == "1.01.02")
                #expect(!report.softKeys.isEmpty)
            }
            #expect(await mock.receivedCommands == ["MDL", "VER", "VOL", "SQL", "GSI", "STS"])
            #expect(await mock.activeSubscribers == 0)
        }

        /// The width check (design §7.3) on an idle mock, whose first line carries the three glyph
        /// bytes (at 3 s a transmission is on air and has none): 17 lines, each 30 characters wide,
        /// text and mask alike.
        @Test func readOnlyWidthsIncludeTheIdleGlyphs() async throws {
            _ = try await withMockHandheld(clock: .stepped(at: 0)) { path in
                let report = try await HandheldHardwareChecks.readOnly(path: path, commandTimeout: .milliseconds(700))
                #expect(report.displayWidths == Array(repeating: 30, count: 17))
            }
        }

        /// A line whose text isn't as wide as its mask fails the check, naming the line and the two
        /// widths, never the text.
        @Test func displayLineWidthMismatchFails() async throws {
            let leaked = Mutex(false)
            _ = try await withMockHandheld(clock: .stepped(at: 0)) { path in
                var report: HandheldHardwareChecks.ReadOnlyReport?
                try await withKnownIssue {
                    report = try await HandheldHardwareChecks.readOnly(
                        path: path, commandTimeout: .milliseconds(700), port: RewritingTransport.shortenedDisplayLine(0))
                } matching: { issue in
                    if "\(issue)".contains("Mock") || mentions("Mock")(issue) { leaked.withLock { $0 = true } }
                    return mentions("STS line 0: text is 29 characters, its mask 30")(issue)
                }
                #expect(report?.displayWidths.first == 29)
            }
            #expect(!leaked.withLock { $0 }, "an issue quoted the display text")
        }

        /// An `STS` of one line fails the check (a display has at least two).
        @Test func singleLineDisplayFails() async throws {
            let leaked = Mutex(false)
            _ = try await withMockHandheld(clock: .stepped(at: 0)) { path in
                var report: HandheldHardwareChecks.ReadOnlyReport?
                try await withKnownIssue {
                    report = try await HandheldHardwareChecks.readOnly(
                        path: path, commandTimeout: .milliseconds(700), port: RewritingTransport.singleLineDisplay())
                } matching: { issue in
                    if "\(issue)".contains("Mock") || mentions("Mock")(issue) { leaked.withLock { $0 = true } }
                    return mentions("STS has 1 line")(issue)
                }
                #expect(report?.displayWidths == [30])
            }
            #expect(!leaked.withLock { $0 }, "an issue quoted the display text")
        }

        /// The `[spec]` name is an SDS150 too.
        @Test func readOnlyAcceptsTheSpecModelName() async throws {
            var personality = MockPersonality.sds150
            personality.reportedModel = "SDS150GBT"
            let mock = try await withMockHandheld(personality: personality) { path in
                let report = try await HandheldHardwareChecks.readOnly(path: path, commandTimeout: .milliseconds(700))
                #expect(report.model == "SDS150GBT")
            }
            #expect(await mock.receivedCommands == ["MDL", "VER", "VOL", "SQL", "GSI", "STS"])
        }

        /// Another scanner on the port gets `MDL` and nothing more.
        @Test func readOnlyStopsAtAnotherModel() async throws {
            var personality = MockPersonality.sds150
            personality.reportedModel = "SDS100"
            let mock = try await withMockHandheld(personality: personality) { path in
                await #expect(throws: HandheldHardwareCheckError.wrongModel(expected: .sds150, reported: "SDS100")) {
                    _ = try await HandheldHardwareChecks.readOnly(path: path, commandTimeout: .milliseconds(700))
                }
            }
            #expect(await mock.receivedCommands == ["MDL"])
        }

        @Test func pushSendsPSITwentyGSIsAndPSI0() async throws {
            let mock = try await withMockHandheld { path in
                // The default hold after `PSI,0` (1.5 s): pushes stop, and nothing more is sent.
                let report = try await HandheldHardwareChecks.pushWhileReading(
                    path: path, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
                    commandTimeout: .milliseconds(700))
                #expect(report.replies == 20)
                #expect(report.pushes > 0)
                #expect(report.unexpected.isEmpty)
                #expect(report.pushesAfterStop == 0)
            }
            #expect(await mock.receivedCommands == ["MDL", "PSI,100"] + Array(repeating: "GSI", count: 20) + ["PSI,0"])
            #expect(await mock.activeSubscribers == 0)
        }

        /// A lost `GSI` reply is a failed check, not an early exit: the other 19 are still asked, and
        /// the subscription still ends.
        @Test func pushEndsWithPSI0AfterAFailedCheck() async throws {
            let mock = try await withMockHandheld(faults: MockFaults(dropNextReply: "GSI")) { path in
                await withKnownIssue {
                    _ = try await HandheldHardwareChecks.pushWhileReading(
                        path: path, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
                        commandTimeout: .milliseconds(300), holdAfterStop: mockHold)
                }
            }
            #expect(await mock.receivedCommands == ["MDL", "PSI,100"] + Array(repeating: "GSI", count: 20) + ["PSI,0"])
            #expect(await mock.activeSubscribers == 0)
        }

        /// A `PSI` that couldn't be written whole is a thrown failure, and `PSI,0` still goes out.
        @Test func pushSendsPSI0WhenPSICantBeWritten() async throws {
            let mock = try await withMockHandheld { path in
                let writes = WriteCounter()
                await #expect(throws: SerialTransportError.self) {
                    _ = try await HandheldHardwareChecks.pushWhileReading(
                        path: path, commandTimeout: .milliseconds(700), holdAfterStop: mockHold,
                        port: { SerialTransport(path: $0, write: writes.failing(2)) })
                }
            }
            #expect(await mock.receivedCommands == ["MDL", "PSI,0"])
            #expect(await mock.activeSubscribers == 0)
        }

        /// Another scanner on the port gets `MDL` and nothing more: no `PSI`, no `GSI`, no `PSI,0`.
        @Test func pushStopsAtAnotherModel() async throws {
            var personality = MockPersonality.sds150
            personality.reportedModel = "SDS100"
            let mock = try await withMockHandheld(personality: personality) { path in
                await #expect(throws: HandheldHardwareCheckError.wrongModel(expected: .sds150, reported: "SDS100")) {
                    _ = try await HandheldHardwareChecks.pushWhileReading(
                        path: path, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
                        commandTimeout: .milliseconds(700), holdAfterStop: mockHold)
                }
            }
            #expect(await mock.receivedCommands == ["MDL"])
        }

        /// A scanner that refuses `PSI` delivers no push, which fails the check; `PSI,0` still goes out.
        @Test func pushEndsWithPSI0WhenPSIIsRejected() async throws {
            let mock = try await withMockHandheld(faults: MockFaults(rejectNext: "PSI")) { path in
                var report: HandheldHardwareChecks.PushReport?
                await withKnownIssue {
                    report = try await HandheldHardwareChecks.pushWhileReading(
                        path: path, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
                        commandTimeout: .milliseconds(700), holdAfterStop: mockHold)
                }
                #expect(report?.pushes == 0)
                #expect(report?.unexpected == ["the line \"PSI,NG\""], "the rejection is reported, not passed over")
            }
            #expect(await mock.receivedCommands == ["MDL", "PSI,100"] + Array(repeating: "GSI", count: 20) + ["PSI,0"])
            #expect(await mock.activeSubscribers == 0)
        }

        /// A push still in flight when `PSI,0` goes out, delivered or not, must never fail the check.
        /// The mock writes one push right before its reply to `PSI,0` (`MockFaults.pushBeforeStop`),
        /// so every run has that push on the wire, and the test checks that it did. Otherwise the
        /// pushes come at the SDS150's fastest, every 40 ms (`PSI,25` gave a 41 ms median on
        /// hardware, protocol notes §8), on four mocks at once, ten runs each, with the `GSI`s 5 ms
        /// apart so pushes come between the replies. (It asked for 2 ms, a rate no scanner gives, to
        /// have pushes in flight by chance: once the mock's push timer was strict, the CI runner
        /// really sent 500 pushes a second from each mock, its three cores couldn't read them as fast,
        /// and the backlog came long after the check's 250 ms grace. At 40 ms no run of 40 had a push
        /// in flight by chance.)
        ///
        /// Each run has a fresh mock: on a reopened port the tail of a push that was being written
        /// at the close can arrive after the open's flush, which the check reports (rightly) as a
        /// line left over from before the port was opened.
        @Test func pushesInFlightAtPSI0DontFailTheCheck() async throws {
            try await withThrowingTaskGroup(of: [MockSerialScanner].self) { group in
                for _ in 1...4 {
                    group.addTask {
                        var mocks: [MockSerialScanner] = []
                        for _ in 1...10 {
                            mocks.append(try await withMockHandheld(faults: MockFaults(pushBeforeStop: true)) { path in
                                let report = try await HandheldHardwareChecks.pushWhileReading(
                                    path: path, pushInterval: .milliseconds(40), spacing: .milliseconds(5),
                                    commandTimeout: .milliseconds(700), holdAfterStop: mockHold)
                                #expect(report.pushesBeforeLastReply > 0)
                                #expect(report.pushesAfterStop == 0)
                                #expect(report.pushRightBeforeStopReply, "no push was in flight at PSI,0")
                            })
                        }
                        return mocks
                    }
                }
                for try await mocks in group {
                    for mock in mocks {
                        #expect(await mock.receivedCommands == ["MDL", "PSI,40"] + Array(repeating: "GSI", count: 20) + ["PSI,0"])
                        #expect(await mock.activeSubscribers == 0)
                    }
                }
            }
        }

        /// A push broken in transit (as one landing inside another reply would be) is named: the
        /// client drops it silently, so this is the only sign of it.
        @Test func garbledPushIsReported() async throws {
            _ = try await withMockHandheld { path in
                var report: HandheldHardwareChecks.PushReport?
                try await withKnownIssue {
                    report = try await HandheldHardwareChecks.pushWhileReading(
                        path: path, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
                        commandTimeout: .milliseconds(700), holdAfterStop: mockHold, port: RewritingTransport.garbling("PSI"))
                } matching: { issue in mentions("PSI push 1 did not parse (root <Garbled>)")(issue) }
                #expect(report?.unexpected == ["PSI push 1 did not parse (root <Garbled>)"])
                #expect((report?.pushes ?? 0) > 0)
            }
        }

        /// A `GSI` reply broken in transit fails that request and is named.
        @Test func garbledReplyIsReported() async throws {
            _ = try await withMockHandheld { path in
                var report: HandheldHardwareChecks.PushReport?
                try await withKnownIssue {
                    report = try await HandheldHardwareChecks.pushWhileReading(
                        path: path, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
                        commandTimeout: .milliseconds(700), holdAfterStop: mockHold, port: RewritingTransport.garbling("GSI"))
                } matching: { issue in
                    mentions("GSI 1 of 20 failed")(issue) || mentions("19 of 20 GSI replies parsed")(issue)
                        || mentions("a GSI reply did not parse (root <Garbled>)")(issue)
                }
                #expect(report?.replies == 19)
                #expect(report?.unexpected == ["a GSI reply did not parse (root <Garbled>)"])
            }
        }

        /// A scanner whose pushes go on after `PSI,0` fails the check (here `PSI,0` never leaves the
        /// Mac, which looks the same from the port): the hold after it is what shows it.
        @Test func pushesThatGoOnAfterPSI0FailTheCheck() async throws {
            let mock = try await withMockHandheld { path in
                var report: HandheldHardwareChecks.PushReport?
                try await withKnownIssue {
                    report = try await HandheldHardwareChecks.pushWhileReading(
                        path: path, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
                        commandTimeout: .milliseconds(700), holdAfterStop: .milliseconds(800),
                        port: { SwallowingStopTransport(path: $0) })
                } matching: { issue in mentions("after PSI,0: the subscription didn't end")(issue) }
                #expect((report?.pushesAfterStop ?? 0) > 0)
            }
            #expect(await mock.receivedCommands == ["MDL", "PSI,100"] + Array(repeating: "GSI", count: 20))
        }

        /// The quiet-port check sends nothing at all, and passes on a port nobody subscribed.
        @Test func quietPortSendsNothingAndPassesOnAQuietPort() async throws {
            let mock = try await withMockHandheld { path in
                let report = try await HandheldHardwareChecks.quietPort(path: path, listen: .milliseconds(500))
                #expect(report.pushes == 0)
                #expect(report.other == [])
            }
            #expect(await mock.receivedCommands == [])
        }

        /// A subscription an earlier client left running (it closed without `PSI,0`) fails the
        /// quiet-port check, which still sends nothing.
        @Test func quietPortFailsWhileAnEarlierSubscriptionRuns() async throws {
            let mock = try await withMockHandheld { path in
                let earlier = SerialTransport(path: path)
                try await earlier.open()
                try await earlier.send(ScannerCommand("PSI", "100"))
                await earlier.close()
                var report: HandheldHardwareChecks.QuietReport?
                try await withKnownIssue {
                    report = try await HandheldHardwareChecks.quietPort(path: path, listen: .milliseconds(500))
                } matching: { issue in mentions("arrived with nothing asked")(issue) }
                #expect((report?.pushes ?? 0) > 0)
            }
            #expect(await mock.receivedCommands == ["PSI,100"])
        }

        /// A level the SDS150 can't have fails the check, naming the command and the value.
        @Test(arguments: ["VOL", "SQL"])
        func levelOutOfRangeFails(_ command: String) async throws {
            let mock = try await withMockHandheld { path in
                var report: HandheldHardwareChecks.ReadOnlyReport?
                try await withKnownIssue {
                    report = try await HandheldHardwareChecks.readOnly(
                        path: path, commandTimeout: .milliseconds(700), port: RewritingTransport.level(command, 16))
                } matching: { issue in mentions("\(command) answered 16, outside the SDS150's 0…15")(issue) }
                #expect((command == "VOL" ? report?.volume : report?.squelch) == 16)
            }
            #expect(await mock.receivedCommands == ["MDL", "VER", "VOL", "SQL", "GSI", "STS"])
        }
    }
}

extension SDS150HardwareTests {
    /// The gates are decided from the environment alone, before any port is resolved or opened.
    @Suite struct Gates {
        @Test func offByDefault() {
            #expect(!SDS150HardwareGate.readOnlyEnabled([:]))
            #expect(!SDS150HardwareGate.pushEnabled([:]))
        }

        @Test func readOnlyNeedsExactlyOne() {
            #expect(SDS150HardwareGate.readOnlyEnabled(["NOCTULE_SDS150_HARDWARE_TESTS": "1"]))
            #expect(!SDS150HardwareGate.readOnlyEnabled(["NOCTULE_SDS150_HARDWARE_TESTS": "true"]))
            #expect(!SDS150HardwareGate.readOnlyEnabled(["NOCTULE_HARDWARE_TESTS": "1"]))
        }

        /// The push suite needs its own variable as well as the read-only suite's.
        @Test func pushNeedsBoth() {
            #expect(!SDS150HardwareGate.pushEnabled(["NOCTULE_SDS150_PUSH_TEST": "1"]))
            #expect(!SDS150HardwareGate.pushEnabled(["NOCTULE_SDS150_HARDWARE_TESTS": "1"]))
            #expect(SDS150HardwareGate.pushEnabled(["NOCTULE_SDS150_HARDWARE_TESTS": "1", "NOCTULE_SDS150_PUSH_TEST": "1"]))
        }

        /// A shell that exports the USB kill-switch never runs them.
        @Test func killSwitchWins() {
            let all = ["NOCTULE_SDS150_HARDWARE_TESTS": "1", "NOCTULE_SDS150_PUSH_TEST": "1"]
            for value in ["1", "0", "yes"] {
                var environment = all
                environment["NOCTULE_NO_USB_DETECTION"] = value
                #expect(!SDS150HardwareGate.readOnlyEnabled(environment))
                #expect(!SDS150HardwareGate.pushEnabled(environment))
            }
            var empty = all
            empty["NOCTULE_NO_USB_DETECTION"] = ""
            #expect(SDS150HardwareGate.readOnlyEnabled(empty))
            #expect(SDS150HardwareGate.pushEnabled(empty))
        }
    }
}

/// The keep-alive check's mock: an SDS150 whose pushes stop `lifetime` real seconds after the
/// `PSI` (a real clock) unless a `KAL` restarts them, or (`restartedByKAL: false`) whatever is sent.
private func keepAliveMock(lifetime: Double = 0.6, restartedByKAL: Bool = true) -> MockPersonality {
    var personality = MockPersonality.sds150
    personality.pushLifetime = lifetime
    if !restartedByKAL { personality.pushLifetimeRestarts = [] }
    return personality
}

/// The keep-alive check with every duration short: `PSI,50`, `KAL` every 150 ms (four chances
/// inside the mock's 0.6 s), held 1.2 s (twice the lifetime), a gap of 0.4 s allowed.
private func shortKeepAliveCheck(_ path: String, port: ((String) -> any ScannerTransport)? = nil)
    async throws -> HandheldHardwareChecks.KeepAliveReport {
    try await HandheldHardwareChecks.keepAlive(
        path: path, pushInterval: .milliseconds(50), keepAlive: PushKeepAlive(command: "KAL", interval: .milliseconds(150)),
        hold: .milliseconds(1200), maxGap: .milliseconds(400), commandTimeout: .milliseconds(700),
        holdAfterStop: mockHold, port: port ?? { SerialTransport(path: $0) })
}

/// What no SDS150 check may ever send.
private func expectNothingForbidden(_ commands: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    for name in ["GCS", "KEY", "MSV", "MSM", "POF"] {
        #expect(!commands.contains { $0 == name || $0.hasPrefix(name + ",") }, "\(name) in \(commands)",
                sourceLocation: sourceLocation)
    }
}

extension SDS150HardwareTests {
    /// The keep-alive check on the mock (real clock, short durations): exactly `MDL`, `PSI`, the
    /// `KAL`s and `PSI,0`.
    @Suite struct KeepAliveOnTheMock {
        // Unskipped 2026-11-22: the mock's strict push timer (2026-11-20) delivers every push, and
        // these passed in every mode of the flaky sweep (LESSONS.md 2026-11-22).
        @Test
        func passesWhenKALRestartsTheLifetime() async throws {
            let sent = Mutex(-1)
            let mock = try await withMockHandheld(personality: keepAliveMock(), clock: .real()) { path in
                let report = try await shortKeepAliveCheck(path)
                sent.withLock { $0 = report.keepAlives }
                #expect(report.pushes > 10)
                // At most one per 150 ms over 1.2 s, and not many fewer.
                #expect(report.keepAlives >= 5 && report.keepAlives <= 8, "\(report.summary)")
                #expect(report.longestGap <= .milliseconds(400))
                #expect(report.unexpected.isEmpty, "\(report.summary)")
                #expect(report.pushesAfterStop == 0)
                #expect(report.keepAlivesAfterStop == 0)
            }
            let commands = await mock.receivedCommands
            #expect(Array(commands.prefix(2)) == ["MDL", "PSI,50"], "\(commands)")
            #expect(commands.last == "PSI,0", "\(commands)")
            #expect(commands.dropFirst(2).dropLast().allSatisfy { $0 == "KAL" }, "\(commands)")
            // Every KAL the check wrote reached the mock. Not a fixed number: how many a 150 ms timer
            // fits in 1.2 s depends on how late it wakes (six under background priority; local sweep).
            #expect(commands.filter { $0 == "KAL" }.count == sent.withLock { $0 }, "\(commands)")
            expectNothingForbidden(commands)
            #expect(await mock.activeSubscribers == 0)
        }

        /// A scanner whose 183 s `KAL` doesn't reset fails the check, and the failure names when
        /// the last push arrived: the answer the check is for.
        @Test func failsNamingTheLastPushWhenKALDoesntRestartIt() async throws {
            let mock = try await withMockHandheld(personality: keepAliveMock(restartedByKAL: false), clock: .real()) { path in
                var report: HandheldHardwareChecks.KeepAliveReport?
                // The answer the check is for must be among its failures, in its own words.
                let namedTheLastPush = Mutex(false)
                try await withKnownIssue {
                    report = try await shortKeepAliveCheck(path)
                } matching: { issue in
                    let named = mentions("pushes stopped: the last push arrived ")(issue)
                    if named { namedTheLastPush.withLock { $0 = true } }
                    return named || mentions("a gap of ")(issue)
                }
                #expect(namedTheLastPush.withLock { $0 }, "the failure didn't say when the last push arrived")
                let last = try #require(report?.lastPush)
                #expect(last >= .milliseconds(450) && last <= .milliseconds(850), "\(report?.summary ?? "")")
                #expect((report?.keepAlives ?? 0) >= 5)
                #expect(report?.keepAlivesAfterStop == 0)
            }
            let commands = await mock.receivedCommands
            #expect(commands.first == "MDL" && commands.last == "PSI,0", "\(commands)")
            expectNothingForbidden(commands)
            #expect(await mock.activeSubscribers == 0)
        }

        /// Another scanner on the port gets `MDL` and nothing more.
        @Test func stopsAtAnotherModel() async throws {
            var personality = keepAliveMock()
            personality.reportedModel = "SDS100"
            let mock = try await withMockHandheld(personality: personality, clock: .real()) { path in
                await #expect(throws: HandheldHardwareCheckError.wrongModel(expected: .sds150, reported: "SDS100")) {
                    _ = try await shortKeepAliveCheck(path)
                }
            }
            #expect(await mock.receivedCommands == ["MDL"])
        }

        /// A reply to `KAL` (here the mock answers it `ERR`, as a scanner that doesn't know it
        /// would) is reported, not failed: the pushes are what the check judges.
        @Test func reportsAReplyToKAL() async throws {
            var personality = keepAliveMock()
            personality.silentCommands = []
            let mock = try await withMockHandheld(personality: personality, clock: .real()) { path in
                let report = try await shortKeepAliveCheck(path)
                #expect(!report.unexpected.isEmpty)
                #expect(report.unexpected.allSatisfy { $0 == "the line \"ERR\"" }, "\(report.unexpected)")
                #expect(report.unexpected.count == report.keepAlives, "\(report.summary)")
            }
            #expect(await mock.receivedCommands.last == "PSI,0")
        }

        /// A rejected `PSI` ends the hold at once, fails the check, and still ends with `PSI,0`.
        @Test func rejectedPSIStillEndsWithPSI0() async throws {
            let start = ContinuousClock.now
            let mock = try await withMockHandheld(personality: keepAliveMock(), faults: MockFaults(rejectNext: "PSI"),
                                                clock: .real()) { path in
                var report: HandheldHardwareChecks.KeepAliveReport?
                await withKnownIssue {
                    report = try await shortKeepAliveCheck(path)
                }
                #expect(report?.pushes == 0)
                #expect(report?.unexpected == ["the line \"PSI,NG\""])
            }
            #expect(ContinuousClock.now - start < .milliseconds(1300), "the hold wasn't cut short")
            #expect(await mock.receivedCommands == ["MDL", "PSI,50", "PSI,0"])
            #expect(await mock.activeSubscribers == 0)
        }

        /// With no keep-alive given, the check uses the SDS150 profile's: `KAL`, never a repeated
        /// `PSI` (what the hardware suite runs). The profile's 60 s means none falls due in a short
        /// hold, so the report's action and summary are what show which keep-alive was chosen.
        @Test func defaultsToTheProfilesKAL() async throws {
            let mock = try await withMockHandheld(personality: .sds150, clock: .real()) { path in
                let report = try await HandheldHardwareChecks.keepAlive(
                    path: path, expecting: .sds150, pushInterval: .milliseconds(50), hold: .milliseconds(400),
                    maxGap: .milliseconds(400), commandTimeout: .milliseconds(700), holdAfterStop: mockHold)
                #expect(report.pushes > 0)
                #expect(report.action == .command("KAL"))
                #expect(report.summary.contains("0 KAL sent"), "\(report.summary)")
            }
            let commands = await mock.receivedCommands
            #expect(commands == ["MDL", "PSI,50", "PSI,0"], "\(commands)")
            #expect(commands.filter { $0.hasPrefix("PSI,") && $0 != "PSI,0" }.count == 1, "a repeated PSI: \(commands)")
            expectNothingForbidden(commands)
        }

        /// A `PSI` that couldn't be written is a thrown failure, and `PSI,0` still goes out.
        @Test func unwritablePSIStillEndsWithPSI0() async throws {
            let mock = try await withMockHandheld(personality: keepAliveMock(), clock: .real()) { path in
                let writes = WriteCounter()
                await #expect(throws: SerialTransportError.self) {
                    _ = try await shortKeepAliveCheck(path, port: { SerialTransport(path: $0, write: writes.failing(2)) })
                }
            }
            #expect(await mock.receivedCommands == ["MDL", "PSI,0"])
            #expect(await mock.activeSubscribers == 0)
        }
    }
}

extension SDS150HardwareTests.Gates {
    /// The keep-alive check needs its own variable as well as the read-only suite's, and the
    /// kill-switch wins.
    @Test func keepAliveNeedsBoth() {
        #expect(!SDS150HardwareGate.keepAliveEnabled([:]))
        #expect(!SDS150HardwareGate.keepAliveEnabled(["NOCTULE_SDS150_KEEPALIVE_TEST": "1"]))
        #expect(!SDS150HardwareGate.keepAliveEnabled(["NOCTULE_SDS150_HARDWARE_TESTS": "1"]))
        #expect(!SDS150HardwareGate.keepAliveEnabled(["NOCTULE_SDS150_HARDWARE_TESTS": "1", "NOCTULE_SDS150_PUSH_TEST": "1"]))
        let both = ["NOCTULE_SDS150_HARDWARE_TESTS": "1", "NOCTULE_SDS150_KEEPALIVE_TEST": "1"]
        #expect(SDS150HardwareGate.keepAliveEnabled(both))
        #expect(!SDS150HardwareGate.pushEnabled(both))
        var killed = both
        killed["NOCTULE_NO_USB_DETECTION"] = "1"
        #expect(!SDS150HardwareGate.keepAliveEnabled(killed))
    }
}
#endif
