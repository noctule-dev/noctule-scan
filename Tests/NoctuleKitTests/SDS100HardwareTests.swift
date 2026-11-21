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

// Opt-in checks against the owner's SDS100 on USB serial (SDS100 design §5.6, §7 H1–H4, H4 at
// 100 ms included), and the same checks run against `MockSerialScanner` (`MockPersonality.sds100`)
// by default, so what they send is known before the owner runs them. The checks themselves are `HandheldHardwareChecks`,
// shared with the SDS150's suites.
//
// **Hardware safety.** The SDS150 and the SDS100 share a vendor and product ID, and on the owner's
// Mac both are plugged in. The hardware suites are skipped unless their variables are set, and
// always while `NOCTULE_NO_USB_DETECTION` is set (agents export it): the trait decides from the
// environment alone, before any port is resolved or opened. A suite opens `SCANNER_SERIAL_SDS100`
// from `config/dev-scanner.env` as written, else the one port whose USB product name names the
// SDS100, and every check but the quiet port's sends `MDL` first and nothing more unless it names
// an SDS100. Nothing here ever sends `KAL`, `GCS`, `KEY`, `MSV`, `MSM` or `POF` to an SDS100: its
// keep-alive is the subscription's own `PSI`, written again.

/// When the SDS100 hardware suites run (`.enabled(if:)`), from the environment alone.
enum SDS100HardwareGate {
    static let readOnlyKey = "NOCTULE_SDS100_HARDWARE_TESTS"
    static let pushKey = "NOCTULE_SDS100_PUSH_TEST"
    static let keepAliveKey = "NOCTULE_SDS100_KEEPALIVE_TEST"
    static let productRateKeepAliveKey = "NOCTULE_SDS100_KEEPALIVE_100MS_TEST"
    /// The USB kill-switch (`USBDetection.disableKey`, which this target doesn't depend on): any
    /// non-empty value skips every hardware suite.
    static let killSwitchKey = "NOCTULE_NO_USB_DETECTION"

    /// `NOCTULE_SDS100_HARDWARE_TESTS=1`, and the kill-switch unset or empty.
    static func readOnlyEnabled(_ environment: [String: String]) -> Bool {
        environment[readOnlyKey] == "1" && (environment[killSwitchKey] ?? "").isEmpty
    }

    /// The read-only gate, and `NOCTULE_SDS100_PUSH_TEST=1` as well.
    static func pushEnabled(_ environment: [String: String]) -> Bool {
        readOnlyEnabled(environment) && environment[pushKey] == "1"
    }

    /// The read-only gate, and `NOCTULE_SDS100_KEEPALIVE_TEST=1` as well (its own variable: the
    /// check takes four minutes and renews the subscription).
    static func keepAliveEnabled(_ environment: [String: String]) -> Bool {
        readOnlyEnabled(environment) && environment[keepAliveKey] == "1"
    }

    /// The read-only gate, and `NOCTULE_SDS100_KEEPALIVE_100MS_TEST=1` as well (its own variable,
    /// apart from the 1000 ms check's: four more minutes, at the product's rate).
    static func productRateKeepAliveEnabled(_ environment: [String: String]) -> Bool {
        readOnlyEnabled(environment) && environment[productRateKeepAliveKey] == "1"
    }
}

/// The SDS100 over USB serial (design §5.6): the opt-in hardware suites, and the same checks on
/// the mock. One serialized suite, so no two of its hardware suites ever hold the port at once.
@Suite(.serialized) struct SDS100HardwareTests {
    /// The owner's SDS100, read-only (H1). Opt-in: `NOCTULE_SDS100_HARDWARE_TESTS=1` (never with
    /// `NOCTULE_NO_USB_DETECTION` set). Sends `MDL` (an SDS100, else nothing more), then `VER`,
    /// `VOL`, `SQL`, `GSI`, `STS`, one each; never `GCS`, `PSI`, `KAL`, `KEY`, `MSV`, `MSM` or `POF`.
    @Suite(.enabled(if: SDS100HardwareGate.readOnlyEnabled(ProcessInfo.processInfo.environment)))
    struct ReadOnly {
        @Test func readsIdentityAndStatus() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .sds100)
            let report = try await HandheldHardwareChecks.readOnly(path: path, expecting: .sds100)
            print("SDS100 hardware: \(report.model) firmware \(report.firmware), VOL \(report.volume), "
                + "SQL \(report.squelch), GSI mode \(report.mode ?? "nil"), screen \(report.screen ?? "nil"), "
                + "soft keys \(report.softKeys)")
            // Counts only (never display text): the line count and each line's width in characters.
            print("SDS100 hardware: STS \(report.displayWidths.count) lines, widths \(report.displayWidths)")
            // A battery reading is not radio traffic.
            print("SDS100 hardware: GSI Property Battery "
                + (report.batteryAttribute.map { "present (\"\($0)\")" } ?? "absent"))
        }
    }

    /// The owner's SDS100, sending nothing: no `PSI` push may arrive unasked (H2). Opt-in like
    /// `ReadOnly`. Opens the port, listens for 2 s, closes it; sends nothing. Run it first as a
    /// baseline, then again after the others.
    @Suite(.enabled(if: SDS100HardwareGate.readOnlyEnabled(ProcessInfo.processInfo.environment)))
    struct QuietPort {
        @Test func noPushArrivesUnasked() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .sds100)
            let report = try await HandheldHardwareChecks.quietPort(path: path)
            print("SDS100 hardware: quiet port: \(report.pushes) unasked PSI pushes, other \(report.other)")
        }
    }

    /// The owner's SDS100: `PSI` pushes while `GSI` is asked (H3), then the port held 1.5 s after
    /// `PSI,0`: the pushes must stop. Opt-in: `NOCTULE_SDS100_HARDWARE_TESTS=1` and
    /// `NOCTULE_SDS100_PUSH_TEST=1` (never with `NOCTULE_NO_USB_DETECTION` set). Sends `MDL` (an
    /// SDS100, else nothing more), `PSI,500`, 20 `GSI`s, and `PSI,0` on every path; never `KAL`,
    /// `GCS`, `KEY`, `MSV`, `MSM` or `POF`.
    @Suite(.enabled(if: SDS100HardwareGate.pushEnabled(ProcessInfo.processInfo.environment)))
    struct Push {
        @Test func pushesAndRepliesStayApart() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .sds100)
            let report = try await HandheldHardwareChecks.pushWhileReading(path: path, expecting: .sds100)
            print("SDS100 hardware: \(report.replies) GSI replies, \(report.pushes) pushes, "
                + "\(report.pushesAfterStop) after PSI,0, unexpected \(report.unexpected)")
        }
    }

    /// The owner's SDS100: does renewing the subscription keep the pushes going past 183 s (H4)?
    /// `PSI,1000`, the same `PSI,1000` again every 60 s (the SDS100 profile's renewal), held 240 s,
    /// then `PSI,0` and 1.5 s more. Opt-in: `NOCTULE_SDS100_HARDWARE_TESTS=1` and
    /// `NOCTULE_SDS100_KEEPALIVE_TEST=1` (never with `NOCTULE_NO_USB_DETECTION` set). Sends `MDL`
    /// (an SDS100, else nothing more), `PSI,1000`, three or four renewals (`PSI,1000`) and
    /// `PSI,0`; never `KAL`, `GSI`, `GCS`, `KEY`, `MSV`, `MSM` or `POF`. About four minutes.
    @Suite(.enabled(if: SDS100HardwareGate.keepAliveEnabled(ProcessInfo.processInfo.environment)))
    struct KeepAlive {
        @Test func renewalsKeepThePushesGoing() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .sds100)
            let report = try await HandheldHardwareChecks.keepAlive(path: path, expecting: .sds100)
            print("SDS100 hardware: keep-alive: \(report.summary)")
        }
    }

    /// H4 at the product's rate: the same check with `PSI,100` (`ModelProfile.pushInterval`, what
    /// `log` and the app subscribe and renew with), pushes about every 137 ms, so a renewal's
    /// `PSI,OK` can land beside a push document. Fails on anything in `unexpected` (a push that
    /// didn't parse, a stray line), which the 1000 ms check only reports. Opt-in:
    /// `NOCTULE_SDS100_HARDWARE_TESTS=1` and `NOCTULE_SDS100_KEEPALIVE_100MS_TEST=1` (never with
    /// `NOCTULE_NO_USB_DETECTION` set). Sends `MDL` (an SDS100, else nothing more), `PSI,100`,
    /// three or four renewals (`PSI,100`) and `PSI,0`; never `KAL`, `GSI`, `GCS`, `KEY`, `MSV`,
    /// `MSM` or `POF`. About four minutes.
    @Suite(.enabled(if: SDS100HardwareGate.productRateKeepAliveEnabled(ProcessInfo.processInfo.environment)))
    struct KeepAliveAtTheProductRate {
        @Test func renewalsKeepThePushesGoingAt100ms() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .sds100)
            let report = try await renewalAtTheProductRate(path: path)
            print("SDS100 hardware: keep-alive at 100 ms: \(report.summary)")
        }
    }
}

/// The keep-alive check at the SDS100's own push interval (100 ms), failing on anything in
/// `unexpected`. The defaults are the hardware run's; the mock twin shortens them.
private func renewalAtTheProductRate(
    path: String, keepAlive: PushKeepAlive? = nil, hold: Duration = .seconds(240),
    maxGap: Duration = .seconds(5), commandTimeout: Duration = .seconds(2),
    holdAfterStop: Duration = .milliseconds(1500)
) async throws -> HandheldHardwareChecks.KeepAliveReport {
    let report = try await HandheldHardwareChecks.keepAlive(
        path: path, expecting: .sds100, pushInterval: ModelProfile.profile(for: .sds100).pushInterval,
        keepAlive: keepAlive, hold: hold, maxGap: maxGap, commandTimeout: commandTimeout,
        holdAfterStop: holdAfterStop)
    #expect(report.unexpected.isEmpty, "unexpected at 100 ms: \(report.unexpected.joined(separator: "; "))")
    return report
}

/// What no SDS100 check may ever send: `KAL` (the SDS150's keep-alive) included.
private func expectNothingForbidden(_ commands: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    for name in ["KAL", "GCS", "KEY", "MSV", "MSM", "POF"] {
        #expect(!commands.contains { $0 == name || $0.hasPrefix(name + ",") }, "\(name) in \(commands)",
                sourceLocation: sourceLocation)
    }
}

extension SDS100HardwareTests {
    /// The checks on the mock SDS100: exactly what each sends, and `PSI,0` on every path.
    @Suite struct OnTheMock {
        @Test func readOnlySendsExactlyTheSixReads() async throws {
            let mock = try await withMockHandheld(personality: .sds100) { path in
                let report = try await HandheldHardwareChecks.readOnly(
                    path: path, expecting: .sds100, commandTimeout: .milliseconds(700))
                #expect(report.model == "SDS100")
                #expect(report.firmware == "1.26.01")
                #expect(!report.softKeys.isEmpty)
                #expect(report.displayWidths.count >= 2)
                #expect(report.batteryAttribute == nil, "the mock's GSI has no Battery")
            }
            #expect(await mock.receivedCommands == ["MDL", "VER", "VOL", "SQL", "GSI", "STS"])
            #expect(await mock.activeSubscribers == 0)
        }

        /// The width check on an idle mock, whose first line carries the SDS100's four glyph bytes
        /// (0x06, 0x07, 0x1A, 0x1B): 17 lines, each 30 characters wide, text and mask alike.
        @Test func readOnlyWidthsIncludeTheIdleGlyphs() async throws {
            _ = try await withMockHandheld(personality: .sds100, clock: .stepped(at: 0)) { path in
                let report = try await HandheldHardwareChecks.readOnly(
                    path: path, expecting: .sds100, commandTimeout: .milliseconds(700))
                #expect(report.displayWidths == Array(repeating: 30, count: 17))
            }
        }

        /// A `Battery` attribute on `GSI`'s `Property` is reported as written (H1 asks whether
        /// the SDS100 has one).
        @Test func readOnlyReportsTheBatteryAttribute() async throws {
            _ = try await withMockHandheld(personality: .sds100) { path in
                let report = try await HandheldHardwareChecks.readOnly(
                    path: path, expecting: .sds100, commandTimeout: .milliseconds(700),
                    port: { path in
                        RewritingTransport(SerialTransport(path: path)) { response in
                            guard case .xml("GSI", var root) = response,
                                  let index = root.children.firstIndex(where: { $0.name == "Property" }) else { return nil }
                            root.children[index].attributes["Battery"] = "3"
                            return .xml(command: "GSI", root: root)
                        }
                    })
                #expect(report.batteryAttribute == "3")
            }
        }

        /// The SDS150 on the port gets `MDL` and nothing more.
        @Test func readOnlyStopsAtAnSDS150() async throws {
            let mock = try await withMockHandheld(personality: .sds150) { path in
                await #expect(throws: HandheldHardwareCheckError.wrongModel(expected: .sds100, reported: "SDS150")) {
                    _ = try await HandheldHardwareChecks.readOnly(
                        path: path, expecting: .sds100, commandTimeout: .milliseconds(700))
                }
            }
            #expect(await mock.receivedCommands == ["MDL"])
        }

        @Test func wrongModelSaysNothingMoreWasSent() {
            #expect(HandheldHardwareCheckError.wrongModel(expected: .sds100, reported: "SDS150").description
                == "MDL answered SDS150, not an SDS100; nothing more was sent")
        }

        /// The levels are the expected model's: a level the SDS100 can't have fails, naming it.
        @Test(arguments: ["VOL", "SQL"])
        func levelOutOfRangeFails(_ command: String) async throws {
            let mock = try await withMockHandheld(personality: .sds100) { path in
                var report: HandheldHardwareChecks.ReadOnlyReport?
                try await withKnownIssue {
                    report = try await HandheldHardwareChecks.readOnly(
                        path: path, expecting: .sds100, commandTimeout: .milliseconds(700),
                        port: RewritingTransport.level(command, 16))
                } matching: { issue in mentions("\(command) answered 16, outside the SDS100's 0…15")(issue) }
                #expect((command == "VOL" ? report?.volume : report?.squelch) == 16)
            }
            #expect(await mock.receivedCommands == ["MDL", "VER", "VOL", "SQL", "GSI", "STS"])
        }

        @Test func pushSendsPSITwentyGSIsAndPSI0() async throws {
            let mock = try await withMockHandheld(personality: .sds100) { path in
                let report = try await HandheldHardwareChecks.pushWhileReading(
                    path: path, expecting: .sds100, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
                    commandTimeout: .milliseconds(700))
                #expect(report.replies == 20)
                #expect(report.pushes > 0)
                #expect(report.unexpected.isEmpty, "\(report.unexpected)")
                #expect(report.pushesAfterStop == 0)
            }
            let commands = await mock.receivedCommands
            #expect(commands == ["MDL", "PSI,100"] + Array(repeating: "GSI", count: 20) + ["PSI,0"])
            expectNothingForbidden(commands)
            #expect(await mock.activeSubscribers == 0)
        }

        /// The SDS150 on the port gets `MDL` and nothing more: no `PSI`, no `GSI`, no `PSI,0`.
        @Test func pushStopsAtAnSDS150() async throws {
            let mock = try await withMockHandheld(personality: .sds150) { path in
                await #expect(throws: HandheldHardwareCheckError.wrongModel(expected: .sds100, reported: "SDS150")) {
                    _ = try await HandheldHardwareChecks.pushWhileReading(
                        path: path, expecting: .sds100, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
                        commandTimeout: .milliseconds(700), holdAfterStop: mockHold)
                }
            }
            #expect(await mock.receivedCommands == ["MDL"])
        }

        /// The quiet-port check sends nothing at all, and passes on a port nobody subscribed.
        @Test func quietPortSendsNothingAndPassesOnAQuietPort() async throws {
            let mock = try await withMockHandheld(personality: .sds100) { path in
                let report = try await HandheldHardwareChecks.quietPort(path: path, listen: .milliseconds(500))
                #expect(report.pushes == 0)
                #expect(report.other == [])
            }
            #expect(await mock.receivedCommands == [])
        }
    }
}

/// The keep-alive check's mock: an SDS100 whose pushes stop `lifetime` real seconds after the
/// latest `PSI` (a real clock; any `PSI` while subscribed restarts the count).
private func renewalMock(lifetime: Double = 0.6) -> MockPersonality {
    var personality = MockPersonality.sds100
    personality.pushLifetime = lifetime
    return personality
}

/// The keep-alive check with every duration short: `PSI,50`, renewed every 150 ms (four chances
/// inside the mock's 0.6 s), held 1.2 s (twice the lifetime), a gap of 0.4 s allowed.
private func shortRenewalCheck(_ path: String, port: ((String) -> any ScannerTransport)? = nil)
    async throws -> HandheldHardwareChecks.KeepAliveReport {
    try await HandheldHardwareChecks.keepAlive(
        path: path, expecting: .sds100, pushInterval: .milliseconds(50),
        keepAlive: PushKeepAlive(action: .renewSubscription, interval: .milliseconds(150)),
        hold: .milliseconds(1200), maxGap: .milliseconds(400), commandTimeout: .milliseconds(700),
        holdAfterStop: mockHold, port: port ?? { SerialTransport(path: $0) })
}

/// The serial port at `path`, except that every `PSI` after the first that isn't `PSI,0` (a
/// renewal) is reported sent but never written: a scanner the renewals never reach.
private final class SwallowingRenewalTransport: ScannerTransport {
    private let base: SerialTransport
    private let subscribed = Mutex(false)

    init(path: String) { base = SerialTransport(path: path) }

    func open() async throws { try await base.open() }
    func close() async { await base.close() }
    var responses: AsyncStream<ScannerResponse> { base.responses }

    func send(_ command: ScannerCommand) async throws {
        if command.name == "PSI", command.arguments != ["0"] {
            let renewal = subscribed.withLock { subscribed in
                defer { subscribed = true }
                return subscribed
            }
            if renewal { return }
        }
        try await base.send(command)
    }
}

extension SDS100HardwareTests {
    /// The keep-alive check on the mock SDS100 (real clock, short durations): exactly `MDL`, the
    /// `PSI` and its renewals, and `PSI,0`; never `KAL`.
    @Suite struct KeepAliveOnTheMock {
        @Test(.skippedOnCIRunner("real-clock 50 ms pushes and 150 ms renewals; the CI runner delivered about half, three runs of three"))
        func passesWhenRenewalsRestartTheLifetime() async throws {
            let mock = try await withMockHandheld(personality: renewalMock(), clock: .real()) { path in
                let report = try await shortRenewalCheck(path)
                #expect(report.pushes > 10)
                // At most one per 150 ms over 1.2 s, and not many fewer.
                #expect(report.keepAlives >= 5 && report.keepAlives <= 8, "\(report.summary)")
                #expect(report.summary.contains("\(report.keepAlives) PSI renewals sent"), "\(report.summary)")
                #expect(report.longestGap <= .milliseconds(400))
                #expect(report.unexpected.isEmpty, "\(report.summary)")
                #expect(report.pushesAfterStop == 0)
                #expect(report.keepAlivesAfterStop == 0)
            }
            let commands = await mock.receivedCommands
            #expect(commands.first == "MDL", "\(commands)")
            #expect(commands.last == "PSI,0", "\(commands)")
            #expect(commands.dropFirst().dropLast().allSatisfy { $0 == "PSI,50" }, "\(commands)")
            #expect(commands.filter { $0 == "PSI,50" }.count >= 8, "\(commands)")
            expectNothingForbidden(commands)
            #expect(await mock.activeSubscribers == 0)
        }

        /// A scanner the renewals never reach stops pushing, which fails the check, and the
        /// failure names when the last push arrived: the answer the check is for.
        @Test func failsNamingTheLastPushWhenRenewalsVanish() async throws {
            let mock = try await withMockHandheld(personality: renewalMock(), clock: .real()) { path in
                var report: HandheldHardwareChecks.KeepAliveReport?
                let namedTheLastPush = Mutex(false)
                try await withKnownIssue {
                    report = try await shortRenewalCheck(path, port: { SwallowingRenewalTransport(path: $0) })
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
            #expect(commands == ["MDL", "PSI,50", "PSI,0"], "\(commands)")
            #expect(await mock.activeSubscribers == 0)
        }

        /// With no keep-alive given, the check uses the SDS100 profile's: a renewal (here none
        /// falls due in the short hold), never `KAL`.
        @Test func defaultsToTheProfilesRenewal() async throws {
            let mock = try await withMockHandheld(personality: .sds100, clock: .real()) { path in
                let report = try await HandheldHardwareChecks.keepAlive(
                    path: path, expecting: .sds100, pushInterval: .milliseconds(50), hold: .milliseconds(400),
                    maxGap: .milliseconds(400), commandTimeout: .milliseconds(700), holdAfterStop: mockHold)
                #expect(report.pushes > 0)
                #expect(report.action == .renewSubscription)
                #expect(report.summary.contains("0 PSI renewals sent"), "\(report.summary)")
            }
            let commands = await mock.receivedCommands
            #expect(commands == ["MDL", "PSI,50", "PSI,0"], "\(commands)")
        }

        /// The product-rate check (H4 at 100 ms) on the mock, renewing every 300 ms (slower than
        /// the pushes, LESSONS 2026-11-16) inside a 0.6 s lifetime: exactly `MDL`, `PSI,100` and
        /// its renewals, and `PSI,0`; never `KAL`.
        @Test(.skippedOnCIRunner("real-clock 100 ms pushes and 300 ms renewals, as the 50 ms check"))
        func productRateSendsOnlyPSI100AndItsRenewals() async throws {
            let mock = try await withMockHandheld(personality: renewalMock(), clock: .real()) { path in
                let report = try await renewalAtTheProductRate(
                    path: path, keepAlive: PushKeepAlive(action: .renewSubscription, interval: .milliseconds(300)),
                    hold: .milliseconds(1500), maxGap: .milliseconds(400), commandTimeout: .milliseconds(700),
                    holdAfterStop: mockHold)
                #expect(report.pushes > 5)
                #expect(report.keepAlives >= 3 && report.keepAlives <= 5, "\(report.summary)")
                #expect(report.pushesAfterStop == 0)
                #expect(report.keepAlivesAfterStop == 0)
            }
            let commands = await mock.receivedCommands
            #expect(commands.first == "MDL", "\(commands)")
            #expect(commands.last == "PSI,0", "\(commands)")
            #expect(commands.dropFirst().dropLast().allSatisfy { $0 == "PSI,100" }, "\(commands)")
            #expect(commands.filter { $0 == "PSI,100" }.count >= 4, "\(commands)")
            expectNothingForbidden(commands)
            #expect(await mock.activeSubscribers == 0)
        }

        /// The SDS150 on the port gets `MDL` and nothing more: no `PSI`, no `KAL`.
        @Test func stopsAtAnSDS150() async throws {
            let mock = try await withMockHandheld(personality: .sds150, clock: .real()) { path in
                await #expect(throws: HandheldHardwareCheckError.wrongModel(expected: .sds100, reported: "SDS150")) {
                    _ = try await shortRenewalCheck(path)
                }
            }
            #expect(await mock.receivedCommands == ["MDL"])
        }

        /// A rejected `PSI` ends the hold at once, fails the check, and still ends with `PSI,0`.
        @Test func rejectedPSIStillEndsWithPSI0() async throws {
            let start = ContinuousClock.now
            let mock = try await withMockHandheld(personality: renewalMock(), faults: MockFaults(rejectNext: "PSI"),
                                                  clock: .real()) { path in
                var report: HandheldHardwareChecks.KeepAliveReport?
                await withKnownIssue {
                    report = try await shortRenewalCheck(path)
                }
                #expect(report?.pushes == 0)
                #expect(report?.unexpected == ["the line \"PSI,NG\""])
            }
            #expect(ContinuousClock.now - start < .milliseconds(1300), "the hold wasn't cut short")
            #expect(await mock.receivedCommands == ["MDL", "PSI,50", "PSI,0"])
            #expect(await mock.activeSubscribers == 0)
        }

        /// A `PSI` that couldn't be written is a thrown failure, and `PSI,0` still goes out.
        @Test func unwritablePSIStillEndsWithPSI0() async throws {
            let mock = try await withMockHandheld(personality: renewalMock(), clock: .real()) { path in
                let writes = WriteCounter()
                await #expect(throws: SerialTransportError.self) {
                    _ = try await shortRenewalCheck(path, port: { SerialTransport(path: $0, write: writes.failing(2)) })
                }
            }
            #expect(await mock.receivedCommands == ["MDL", "PSI,0"])
            #expect(await mock.activeSubscribers == 0)
        }
    }
}

extension SDS100HardwareTests {
    /// Which port a hardware suite opens: the configured path as written, else the one port whose
    /// USB product name names the model. Nothing here is opened.
    @Suite struct Ports {
        private func port(_ path: String, _ productName: String?) -> SerialPortInfo {
            SerialPortInfo(path: path, productName: productName, vendorID: SerialPort.unidenVendorID,
                           productID: 0x001A, serialNumber: nil)
        }

        /// The key each handheld's suites read: the SDS150's is `noctule --serial`'s own.
        @Test func configKeys() {
            #expect(HandheldHardwareChecks.configKey(for: .sds150) == "SCANNER_SERIAL")
            #expect(HandheldHardwareChecks.configKey(for: .sds100) == "SCANNER_SERIAL_SDS100")
        }

        @Test func configuredWinsExactly() throws {
            let ports = [port("/dev/cu.test-b", "SDS100 Serial Port")]
            #expect(try HandheldHardwareChecks.resolvePort(
                for: .sds100, configured: "/tmp/test-port", ports: ports, key: "SCANNER_SERIAL_SDS100") == "/tmp/test-port")
            #expect(try HandheldHardwareChecks.resolvePort(
                for: .sds100, configured: "/tmp/test-port", ports: [], key: "SCANNER_SERIAL_SDS100") == "/tmp/test-port")
        }

        /// With both handhelds plugged in, each suite finds its own by the product name.
        @Test func eachModelFindsItsOwnPort() throws {
            let ports = [port("/dev/cu.test-a", "SDS150 Serial Port"), port("/dev/cu.test-b", "SDS100 Serial Port")]
            #expect(try HandheldHardwareChecks.resolvePort(
                for: .sds100, configured: nil, ports: ports, key: "SCANNER_SERIAL_SDS100") == "/dev/cu.test-b")
            #expect(try HandheldHardwareChecks.resolvePort(
                for: .sds150, configured: nil, ports: ports, key: "SCANNER_SERIAL") == "/dev/cu.test-a")
        }

        /// None of the model (the other handheld only, a port with no model name, nothing at all)
        /// says what to do and names the key.
        @Test func noneOfTheModelNamesTheKey() {
            for ports in [[port("/dev/cu.test-a", "SDS150 Serial Port")], [port("/dev/cu.test-c", nil)], []] {
                let error = #expect(throws: HandheldHardwareCheckError.self) {
                    try HandheldHardwareChecks.resolvePort(
                        for: .sds100, configured: nil, ports: ports, key: "SCANNER_SERIAL_SDS100")
                }
                #expect(error?.description.contains("SCANNER_SERIAL_SDS100") == true, "\(String(describing: error))")
                #expect(error?.description.contains("SDS100") == true)
            }
        }

        /// Several of the model names each path and the key; none is picked.
        @Test func severalOfTheModelNamePathsAndTheKey() {
            let ports = [port("/dev/cu.test-b", "SDS100 Serial Port"), port("/dev/cu.test-d", "SDS100 Serial Port"),
                         port("/dev/cu.test-a", "SDS150 Serial Port")]
            let error = #expect(throws: HandheldHardwareCheckError.self) {
                try HandheldHardwareChecks.resolvePort(
                    for: .sds100, configured: nil, ports: ports, key: "SCANNER_SERIAL_SDS100")
            }
            let text = error?.description ?? ""
            #expect(text.contains("/dev/cu.test-b") && text.contains("/dev/cu.test-d"), "\(text)")
            #expect(!text.contains("/dev/cu.test-a"), "\(text)")
            #expect(text.contains("SCANNER_SERIAL_SDS100"), "\(text)")
        }
    }

    /// The gates are decided from the environment alone, before any port is resolved or opened.
    @Suite struct Gates {
        @Test func offByDefault() {
            #expect(!SDS100HardwareGate.readOnlyEnabled([:]))
            #expect(!SDS100HardwareGate.pushEnabled([:]))
            #expect(!SDS100HardwareGate.keepAliveEnabled([:]))
            #expect(!SDS100HardwareGate.productRateKeepAliveEnabled([:]))
        }

        @Test func readOnlyNeedsExactlyOne() {
            #expect(SDS100HardwareGate.readOnlyEnabled(["NOCTULE_SDS100_HARDWARE_TESTS": "1"]))
            #expect(!SDS100HardwareGate.readOnlyEnabled(["NOCTULE_SDS100_HARDWARE_TESTS": "true"]))
            #expect(!SDS100HardwareGate.readOnlyEnabled(["NOCTULE_HARDWARE_TESTS": "1"]))
            // The SDS150's variable never enables the SDS100's suites.
            #expect(!SDS100HardwareGate.readOnlyEnabled(["NOCTULE_SDS150_HARDWARE_TESTS": "1"]))
        }

        /// The push suite needs its own variable as well as the read-only suite's.
        @Test func pushNeedsBoth() {
            #expect(!SDS100HardwareGate.pushEnabled(["NOCTULE_SDS100_PUSH_TEST": "1"]))
            #expect(!SDS100HardwareGate.pushEnabled(["NOCTULE_SDS100_HARDWARE_TESTS": "1"]))
            #expect(!SDS100HardwareGate.pushEnabled(["NOCTULE_SDS100_HARDWARE_TESTS": "1", "NOCTULE_SDS100_PUSH_TEST": "true"]))
            #expect(SDS100HardwareGate.pushEnabled(["NOCTULE_SDS100_HARDWARE_TESTS": "1", "NOCTULE_SDS100_PUSH_TEST": "1"]))
        }

        /// The keep-alive check needs its own variable as well as the read-only suite's.
        @Test func keepAliveNeedsBoth() {
            #expect(!SDS100HardwareGate.keepAliveEnabled(["NOCTULE_SDS100_KEEPALIVE_TEST": "1"]))
            #expect(!SDS100HardwareGate.keepAliveEnabled(["NOCTULE_SDS100_HARDWARE_TESTS": "1"]))
            #expect(!SDS100HardwareGate.keepAliveEnabled(["NOCTULE_SDS100_HARDWARE_TESTS": "1", "NOCTULE_SDS100_PUSH_TEST": "1"]))
            #expect(!SDS100HardwareGate.keepAliveEnabled(["NOCTULE_SDS100_HARDWARE_TESTS": "1", "NOCTULE_SDS100_KEEPALIVE_TEST": "yes"]))
            let both = ["NOCTULE_SDS100_HARDWARE_TESTS": "1", "NOCTULE_SDS100_KEEPALIVE_TEST": "1"]
            #expect(SDS100HardwareGate.keepAliveEnabled(both))
            #expect(!SDS100HardwareGate.pushEnabled(both))
            #expect(!SDS100HardwareGate.productRateKeepAliveEnabled(both))
        }

        /// The 100 ms keep-alive check needs its own variable as well as the read-only suite's;
        /// the 1000 ms check's variable doesn't run it, nor it the 1000 ms check.
        @Test func productRateKeepAliveNeedsBoth() {
            #expect(!SDS100HardwareGate.productRateKeepAliveEnabled(["NOCTULE_SDS100_KEEPALIVE_100MS_TEST": "1"]))
            #expect(!SDS100HardwareGate.productRateKeepAliveEnabled(["NOCTULE_SDS100_HARDWARE_TESTS": "1"]))
            #expect(!SDS100HardwareGate.productRateKeepAliveEnabled(
                ["NOCTULE_SDS100_HARDWARE_TESTS": "1", "NOCTULE_SDS100_KEEPALIVE_100MS_TEST": "yes"]))
            let both = ["NOCTULE_SDS100_HARDWARE_TESTS": "1", "NOCTULE_SDS100_KEEPALIVE_100MS_TEST": "1"]
            #expect(SDS100HardwareGate.productRateKeepAliveEnabled(both))
            #expect(!SDS100HardwareGate.keepAliveEnabled(both))
            #expect(!SDS100HardwareGate.pushEnabled(both))
        }

        /// A shell that exports the USB kill-switch never runs them.
        @Test func killSwitchWins() {
            let all = ["NOCTULE_SDS100_HARDWARE_TESTS": "1", "NOCTULE_SDS100_PUSH_TEST": "1",
                       "NOCTULE_SDS100_KEEPALIVE_TEST": "1", "NOCTULE_SDS100_KEEPALIVE_100MS_TEST": "1"]
            for value in ["1", "0", "yes"] {
                var environment = all
                environment["NOCTULE_NO_USB_DETECTION"] = value
                #expect(!SDS100HardwareGate.readOnlyEnabled(environment))
                #expect(!SDS100HardwareGate.pushEnabled(environment))
                #expect(!SDS100HardwareGate.keepAliveEnabled(environment))
                #expect(!SDS100HardwareGate.productRateKeepAliveEnabled(environment))
            }
            var empty = all
            empty["NOCTULE_NO_USB_DETECTION"] = ""
            #expect(SDS100HardwareGate.readOnlyEnabled(empty))
            #expect(SDS100HardwareGate.pushEnabled(empty))
            #expect(SDS100HardwareGate.keepAliveEnabled(empty))
            #expect(SDS100HardwareGate.productRateKeepAliveEnabled(empty))
        }
    }
}
#endif
