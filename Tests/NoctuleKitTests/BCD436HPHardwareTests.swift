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

// Opt-in checks against the owner's BCD436HP on USB serial (BCD436HP design §5.9, §6), and the same checks run against `MockSerialScanner` (`MockPersonality.bcd436hp`)
// by default, so what they send is known before the owner runs them. The checks themselves are `HandheldHardwareChecks`,
// shared with the SDS150's and SDS100's suites.
//
// **Hardware safety.** The SDS150, the SDS100 and the BCD436HP share a vendor and product ID, and on the owner's
// Mac both are plugged in. The hardware suites are skipped unless their variables are set, and
// always while `NOCTULE_NO_USB_DETECTION` is set (agents export it): the trait decides from the
// environment alone, before any port is resolved or opened. A suite opens `SCANNER_SERIAL_BCD436HP`
// from `config/dev-scanner.env` as written, else the one port whose USB product name names the
// BCD436HP, and every check but the quiet port's sends `MDL` first and nothing more unless it names
// a BCD436HP. Nothing here ever sends `KAL`, `GCS`, `KEY`, `MSV`, `MSM` or `POF` to a BCD436HP: its
// keep-alive is the subscription's own `PSI`, written again.

/// When the BCD436HP hardware suites run (`.enabled(if:)`), from the environment alone.
enum BCD436HPHardwareGate {
    static let readOnlyKey = "NOCTULE_BCD436HP_HARDWARE_TESTS"
    static let pushKey = "NOCTULE_BCD436HP_PUSH_TEST"
    static let keepAliveKey = "NOCTULE_BCD436HP_KEEPALIVE_TEST"
    /// The USB kill-switch (`USBDetection.disableKey`, which this target doesn't depend on): any
    /// non-empty value skips every hardware suite.
    static let killSwitchKey = "NOCTULE_NO_USB_DETECTION"

    /// `NOCTULE_BCD436HP_HARDWARE_TESTS=1`, and the kill-switch unset or empty.
    static func readOnlyEnabled(_ environment: [String: String]) -> Bool {
        environment[readOnlyKey] == "1" && (environment[killSwitchKey] ?? "").isEmpty
    }

    /// The read-only gate, and `NOCTULE_BCD436HP_PUSH_TEST=1` as well.
    static func pushEnabled(_ environment: [String: String]) -> Bool {
        readOnlyEnabled(environment) && environment[pushKey] == "1"
    }

    /// The read-only gate, and `NOCTULE_BCD436HP_KEEPALIVE_TEST=1` as well (its own variable: the
    /// check takes four minutes and renews the subscription).
    static func keepAliveEnabled(_ environment: [String: String]) -> Bool {
        readOnlyEnabled(environment) && environment[keepAliveKey] == "1"
    }
}

/// The BCD436HP over USB serial (design §5.6): the opt-in hardware suites, and the same checks on
/// the mock. One serialized suite, so no two of its hardware suites ever hold the port at once.
// Ten minutes: the opt-in keep-alive checks hold 240 s on a real radio (plus the port, the
// quiet-port check and PSI,0), and Swift Testing applies the shortest limit on the way down, so a
// three-minute limit here would cancel them at 180 s. The mock sub-suites carry three minutes.
@Suite(.serialized, .timeLimit(.minutes(10))) struct BCD436HPHardwareTests {
    /// The owner's BCD436HP, read-only (H1). Opt-in: `NOCTULE_BCD436HP_HARDWARE_TESTS=1` (never with
    /// `NOCTULE_NO_USB_DETECTION` set). Sends `MDL` (a BCD436HP, else nothing more), then `VER`,
    /// `VOL`, `SQL`, `GSI`, `STS`, one each; never `GCS`, `PSI`, `KAL`, `KEY`, `MSV`, `MSM` or `POF`.
    @Suite(.enabled(if: BCD436HPHardwareGate.readOnlyEnabled(ProcessInfo.processInfo.environment)))
    struct ReadOnly {
        @Test func readsIdentityAndStatus() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .bcd436hp)
            let report = try await HandheldHardwareChecks.readOnly(path: path, expecting: .bcd436hp)
            print("BCD436HP hardware: \(report.model) firmware \(report.firmware), VOL \(report.volume), "
                + "SQL \(report.squelch), GSI mode \(report.mode ?? "nil"), screen \(report.screen ?? "nil"), "
                + "soft keys \(report.softKeys)")
            // Counts only (never display text): the line count and each line's width in characters.
            print("BCD436HP hardware: STS \(report.displayWidths.count) lines, form \(report.displayForm), "
                + "widths \(report.displayWidths)")
            // Attribute names only, never their values.
            print("BCD436HP hardware: GSI Property attributes \(report.propertyAttributeNames)")
            // A battery reading is not radio traffic.
            print("BCD436HP hardware: GSI Property Battery "
                + (report.batteryAttribute.map { "present (\"\($0)\")" } ?? "absent"))
        }
    }

    /// The owner's BCD436HP, sending nothing: no `PSI` push may arrive unasked (H2). Opt-in like
    /// `ReadOnly`. Opens the port, listens for 2 s, closes it; sends nothing. Run it first as a
    /// baseline, then again after the others.
    @Suite(.enabled(if: BCD436HPHardwareGate.readOnlyEnabled(ProcessInfo.processInfo.environment)))
    struct QuietPort {
        @Test func noPushArrivesUnasked() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .bcd436hp)
            let report = try await HandheldHardwareChecks.quietPort(path: path)
            print("BCD436HP hardware: quiet port: \(report.pushes) unasked PSI pushes, other \(report.other)")
        }
    }

    /// The owner's BCD436HP: `PSI` pushes while `GSI` is asked (H3), then the port held 1.5 s after
    /// `PSI,0`: the pushes must stop. Opt-in: `NOCTULE_BCD436HP_HARDWARE_TESTS=1` and
    /// `NOCTULE_BCD436HP_PUSH_TEST=1` (never with `NOCTULE_NO_USB_DETECTION` set). Sends `MDL` (a
    /// BCD436HP, else nothing more), `PSI,500`, 20 `GSI`s, and `PSI,0` on every path; never `KAL`,
    /// `GCS`, `KEY`, `MSV`, `MSM` or `POF`.
    @Suite(.enabled(if: BCD436HPHardwareGate.pushEnabled(ProcessInfo.processInfo.environment)))
    struct Push {
        @Test func pushesAndRepliesStayApart() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .bcd436hp)
            let report = try await HandheldHardwareChecks.pushWhileReading(path: path, expecting: .bcd436hp)
            print("BCD436HP hardware: \(report.replies) GSI replies, \(report.pushes) pushes, "
                + "\(report.pushesAfterStop) after PSI,0, unexpected \(report.unexpected)")
        }
    }

    /// The owner's BCD436HP: does renewing the subscription keep the pushes going past 183 s? At
    /// the product's rate: `PSI,100` (`ModelProfile.pushInterval`, what `log` and the app subscribe
    /// and renew with), the same `PSI,100` again every 60 s (the profile's renewal), held 240 s,
    /// then `PSI,0` and 1.5 s more. Fails on anything in `unexpected` (a push that didn't parse, a
    /// stray line). Opt-in: `NOCTULE_BCD436HP_HARDWARE_TESTS=1` and `NOCTULE_BCD436HP_KEEPALIVE_TEST=1`
    /// (never with `NOCTULE_NO_USB_DETECTION` set). Sends `MDL` (a BCD436HP, else nothing more),
    /// `PSI,100`, three or four renewals (`PSI,100`) and `PSI,0`; never `KAL`, `GSI`, `GCS`, `KEY`,
    /// `MSV`, `MNU`, `MSB`, `HLD`, `MSM` or `POF`. About four minutes.
    @Suite(.enabled(if: BCD436HPHardwareGate.keepAliveEnabled(ProcessInfo.processInfo.environment)))
    struct KeepAlive {
        @Test func renewalsKeepThePushesGoing() async throws {
            let path = try HandheldHardwareChecks.resolvePort(for: .bcd436hp)
            let report = try await renewalAtTheProductRate(path: path)
            print("BCD436HP hardware: keep-alive at 100 ms: \(report.summary)")
        }
    }
}

/// The keep-alive check at the BCD436HP's own push interval (100 ms), failing on anything in
/// `unexpected`. The defaults are the hardware run's; the mock twin shortens them.
private func renewalAtTheProductRate(
    path: String, keepAlive: PushKeepAlive? = nil, hold: Duration = .seconds(240),
    maxGap: Duration = .seconds(5), commandTimeout: Duration = .seconds(2),
    holdAfterStop: Duration = .milliseconds(1500)
) async throws -> HandheldHardwareChecks.KeepAliveReport {
    let report = try await HandheldHardwareChecks.keepAlive(
        path: path, expecting: .bcd436hp, pushInterval: ModelProfile.profile(for: .bcd436hp).pushInterval,
        keepAlive: keepAlive, hold: hold, maxGap: maxGap, commandTimeout: commandTimeout,
        holdAfterStop: holdAfterStop)
    #expect(report.unexpected.isEmpty, "unexpected at 100 ms: \(report.unexpected.joined(separator: "; "))")
    return report
}

/// What no BCD436HP check may ever send: `KAL` (the SDS150's keep-alive) included, and the
/// product's own menu and hold commands.
private func expectNothingForbidden(_ commands: [String], sourceLocation: SourceLocation = #_sourceLocation) {
    for name in ["KAL", "GCS", "KEY", "MSV", "MNU", "MSB", "HLD", "MSM", "POF"] {
        #expect(!commands.contains { $0 == name || $0.hasPrefix(name + ",") }, "\(name) in \(commands)",
                sourceLocation: sourceLocation)
    }
}

extension BCD436HPHardwareTests {
    /// The checks on the mock BCD436HP: exactly what each sends, and `PSI,0` on every path.
    @Suite(.timeLimit(.minutes(3))) struct OnTheMock {
        @Test func readOnlySendsExactlyTheSixReads() async throws {
            let mock = try await withMockHandheld(personality: .bcd436hp) { path in
                let report = try await HandheldHardwareChecks.readOnly(
                    path: path, expecting: .bcd436hp, commandTimeout: .milliseconds(700))
                #expect(report.model == "BCD436HP")
                #expect(report.firmware == "1.28.24")
                #expect(report.softKeys.isEmpty, "the BCD436HP has no soft-key line")
                #expect(report.displayWidths.count >= 2)
                #expect(report.batteryAttribute == nil, "the mock's GSI has no Battery")
                #expect(report.displayForm.count == report.displayWidths.count)
                #expect(report.displayForm.allSatisfy { $0.isNumber })
                #expect(!report.propertyAttributeNames.isEmpty)
            }
            #expect(await mock.receivedCommands == ["MDL", "VER", "VOL", "SQL", "GSI", "STS"])
            #expect(await mock.activeSubscribers == 0)
        }

        /// The width check on an idle mock: 14 lines, each the layout's 24 characters wide. The idle
        /// BCD436HP mock carries no glyph bytes.
        @Test func readOnlyWidthsOnTheIdleMock() async throws {
            _ = try await withMockHandheld(personality: .bcd436hp, clock: .stepped(at: 0)) { path in
                let report = try await HandheldHardwareChecks.readOnly(
                    path: path, expecting: .bcd436hp, commandTimeout: .milliseconds(700))
                #expect(report.displayWidths == Array(repeating: 24, count: 14))
            }
        }

        /// A `Battery` attribute on `GSI`'s `Property` is reported as written (H1 asks whether
        /// the BCD436HP has one).
        @Test func readOnlyReportsTheBatteryAttribute() async throws {
            _ = try await withMockHandheld(personality: .bcd436hp) { path in
                let report = try await HandheldHardwareChecks.readOnly(
                    path: path, expecting: .bcd436hp, commandTimeout: .milliseconds(700),
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

        /// The SDS100 on the port gets `MDL` and nothing more.
        @Test func readOnlyStopsAtAnSDS100() async throws {
            let mock = try await withMockHandheld(personality: .sds100) { path in
                await #expect(throws: HandheldHardwareCheckError.wrongModel(expected: .bcd436hp, reported: "SDS100")) {
                    _ = try await HandheldHardwareChecks.readOnly(
                        path: path, expecting: .bcd436hp, commandTimeout: .milliseconds(700))
                }
            }
            #expect(await mock.receivedCommands == ["MDL"])
        }

        @Test func wrongModelSaysNothingMoreWasSent() {
            #expect(HandheldHardwareCheckError.wrongModel(expected: .bcd436hp, reported: "SDS100").description
                == "MDL answered SDS100, not a BCD436HP; nothing more was sent")
        }

        /// The levels are the expected model's: a level the BCD436HP can't have fails, naming it.
        @Test(arguments: ["VOL", "SQL"])
        func levelOutOfRangeFails(_ command: String) async throws {
            let mock = try await withMockHandheld(personality: .bcd436hp) { path in
                var report: HandheldHardwareChecks.ReadOnlyReport?
                try await withKnownIssue {
                    report = try await HandheldHardwareChecks.readOnly(
                        path: path, expecting: .bcd436hp, commandTimeout: .milliseconds(700),
                        port: RewritingTransport.level(command, 16))
                } matching: { issue in mentions("\(command) answered 16, outside the BCD436HP's 0…15")(issue) }
                #expect((command == "VOL" ? report?.volume : report?.squelch) == 16)
            }
            #expect(await mock.receivedCommands == ["MDL", "VER", "VOL", "SQL", "GSI", "STS"])
        }

        @Test func pushSendsPSITwentyGSIsAndPSI0() async throws {
            let mock = try await withMockHandheld(personality: .bcd436hp) { path in
                let report = try await HandheldHardwareChecks.pushWhileReading(
                    path: path, expecting: .bcd436hp, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
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

        /// The SDS100 on the port gets `MDL` and nothing more: no `PSI`, no `GSI`, no `PSI,0`.
        @Test func pushStopsAtAnSDS100() async throws {
            let mock = try await withMockHandheld(personality: .sds100) { path in
                await #expect(throws: HandheldHardwareCheckError.wrongModel(expected: .bcd436hp, reported: "SDS100")) {
                    _ = try await HandheldHardwareChecks.pushWhileReading(
                        path: path, expecting: .bcd436hp, pushInterval: .milliseconds(100), spacing: .milliseconds(30),
                        commandTimeout: .milliseconds(700), holdAfterStop: mockHold)
                }
            }
            #expect(await mock.receivedCommands == ["MDL"])
        }

        /// The quiet-port check sends nothing at all, and passes on a port nobody subscribed.
        @Test func quietPortSendsNothingAndPassesOnAQuietPort() async throws {
            let mock = try await withMockHandheld(personality: .bcd436hp) { path in
                let report = try await HandheldHardwareChecks.quietPort(path: path, listen: .milliseconds(500))
                #expect(report.pushes == 0)
                #expect(report.other == [])
            }
            #expect(await mock.receivedCommands == [])
        }
    }
}

/// The keep-alive check's mock: a BCD436HP whose pushes stop `lifetime` real seconds after the
/// latest `PSI` (a real clock; any `PSI` while subscribed restarts the count).
private func renewalMock(lifetime: Double = 0.6) -> MockPersonality {
    var personality = MockPersonality.bcd436hp
    personality.pushLifetime = lifetime
    return personality
}

/// The keep-alive check with every duration short: `PSI,50`, renewed every 150 ms (four chances
/// inside the mock's 0.6 s), held 1.2 s (twice the lifetime), a gap of 0.4 s allowed.
private func shortRenewalCheck(_ path: String, port: ((String) -> any ScannerTransport)? = nil)
    async throws -> HandheldHardwareChecks.KeepAliveReport {
    try await HandheldHardwareChecks.keepAlive(
        path: path, expecting: .bcd436hp, pushInterval: .milliseconds(50),
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

extension BCD436HPHardwareTests {
    /// The keep-alive check on the mock BCD436HP (real clock, short durations): exactly `MDL`, the
    /// `PSI` and its renewals, and `PSI,0`; never `KAL`.
    @Suite(.timeLimit(.minutes(3))) struct KeepAliveOnTheMock {
        // Unskipped 2026-11-22: the mock's strict push timer (2026-11-20) delivers every push, and
        // these passed in every mode of the flaky sweep (LESSONS.md 2026-11-22).
        @Test
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

        /// With no keep-alive given, the check uses the BCD436HP profile's: a renewal (here none
        /// falls due in the short hold), never `KAL`.
        @Test func defaultsToTheProfilesRenewal() async throws {
            let mock = try await withMockHandheld(personality: .bcd436hp, clock: .real()) { path in
                let report = try await HandheldHardwareChecks.keepAlive(
                    path: path, expecting: .bcd436hp, pushInterval: .milliseconds(50), hold: .milliseconds(400),
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
        // Unskipped 2026-11-22: the mock's strict push timer (2026-11-20) delivers every push, and
        // these passed in every mode of the flaky sweep (LESSONS.md 2026-11-22).
        @Test
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

        /// The SDS100 on the port gets `MDL` and nothing more: no `PSI`, no `KAL`.
        @Test func stopsAtAnSDS100() async throws {
            let mock = try await withMockHandheld(personality: .sds100, clock: .real()) { path in
                await #expect(throws: HandheldHardwareCheckError.wrongModel(expected: .bcd436hp, reported: "SDS100")) {
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

extension BCD436HPHardwareTests {
    /// Which port a hardware suite opens: the configured path as written, else the one port whose
    /// USB product name names the model. Nothing here is opened.
    @Suite(.timeLimit(.minutes(3))) struct Ports {
        private func port(_ path: String, _ productName: String?) -> SerialPortInfo {
            SerialPortInfo(path: path, productName: productName, vendorID: SerialPort.unidenVendorID,
                           productID: 0x001A, serialNumber: nil)
        }

        /// The key each handheld's suites read: the SDS150's is `noctule --serial`'s own.
        @Test func configKeys() {
            #expect(HandheldHardwareChecks.configKey(for: .sds150) == "SCANNER_SERIAL")
            #expect(HandheldHardwareChecks.configKey(for: .sds100) == "SCANNER_SERIAL_SDS100")
            #expect(HandheldHardwareChecks.configKey(for: .bcd436hp) == "SCANNER_SERIAL_BCD436HP")
        }

        @Test func configuredWinsExactly() throws {
            let ports = [port("/dev/cu.test-b", "BCD436HP Serial Port")]
            #expect(try HandheldHardwareChecks.resolvePort(
                for: .bcd436hp, configured: "/tmp/test-port", ports: ports, key: "SCANNER_SERIAL_BCD436HP") == "/tmp/test-port")
            #expect(try HandheldHardwareChecks.resolvePort(
                for: .bcd436hp, configured: "/tmp/test-port", ports: [], key: "SCANNER_SERIAL_BCD436HP") == "/tmp/test-port")
        }

        /// With both handhelds plugged in, each suite finds its own by the product name.
        @Test func eachModelFindsItsOwnPort() throws {
            let ports = [port("/dev/cu.test-a", "SDS100 Serial Port"), port("/dev/cu.test-b", "BCD436HP Serial Port"),
                         port("/dev/cu.test-c", "SDS150 Serial Port")]
            #expect(try HandheldHardwareChecks.resolvePort(
                for: .bcd436hp, configured: nil, ports: ports, key: "SCANNER_SERIAL_BCD436HP") == "/dev/cu.test-b")
            #expect(try HandheldHardwareChecks.resolvePort(
                for: .sds100, configured: nil, ports: ports, key: "SCANNER_SERIAL_SDS100") == "/dev/cu.test-a")
        }

        /// None of the model (the other handheld only, a port with no model name, nothing at all)
        /// says what to do and names the key.
        @Test func noneOfTheModelNamesTheKey() {
            for ports in [[port("/dev/cu.test-a", "SDS100 Serial Port")], [port("/dev/cu.test-c", nil)], []] {
                let error = #expect(throws: HandheldHardwareCheckError.self) {
                    try HandheldHardwareChecks.resolvePort(
                        for: .bcd436hp, configured: nil, ports: ports, key: "SCANNER_SERIAL_BCD436HP")
                }
                #expect(error?.description.contains("SCANNER_SERIAL_BCD436HP") == true, "\(String(describing: error))")
                #expect(error?.description.contains("BCD436HP") == true)
            }
        }

        /// Several of the model names each path and the key; none is picked.
        @Test func severalOfTheModelNamePathsAndTheKey() {
            let ports = [port("/dev/cu.test-b", "BCD436HP Serial Port"), port("/dev/cu.test-d", "BCD436HP Serial Port"),
                         port("/dev/cu.test-a", "SDS100 Serial Port")]
            let error = #expect(throws: HandheldHardwareCheckError.self) {
                try HandheldHardwareChecks.resolvePort(
                    for: .bcd436hp, configured: nil, ports: ports, key: "SCANNER_SERIAL_BCD436HP")
            }
            let text = error?.description ?? ""
            #expect(text.contains("/dev/cu.test-b") && text.contains("/dev/cu.test-d"), "\(text)")
            #expect(!text.contains("/dev/cu.test-a"), "\(text)")
            #expect(text.contains("SCANNER_SERIAL_BCD436HP"), "\(text)")
        }
    }

    /// The gates are decided from the environment alone, before any port is resolved or opened.
    @Suite(.timeLimit(.minutes(3))) struct Gates {
        @Test func offByDefault() {
            #expect(!BCD436HPHardwareGate.readOnlyEnabled([:]))
            #expect(!BCD436HPHardwareGate.pushEnabled([:]))
            #expect(!BCD436HPHardwareGate.keepAliveEnabled([:]))
        }

        @Test func readOnlyNeedsExactlyOne() {
            #expect(BCD436HPHardwareGate.readOnlyEnabled(["NOCTULE_BCD436HP_HARDWARE_TESTS": "1"]))
            #expect(!BCD436HPHardwareGate.readOnlyEnabled(["NOCTULE_BCD436HP_HARDWARE_TESTS": "true"]))
            #expect(!BCD436HPHardwareGate.readOnlyEnabled(["NOCTULE_HARDWARE_TESTS": "1"]))
            // The SDS100's variable never enables the BCD436HP's suites.
            #expect(!BCD436HPHardwareGate.readOnlyEnabled(["NOCTULE_SDS100_HARDWARE_TESTS": "1"]))
        }

        /// The push suite needs its own variable as well as the read-only suite's.
        @Test func pushNeedsBoth() {
            #expect(!BCD436HPHardwareGate.pushEnabled(["NOCTULE_BCD436HP_PUSH_TEST": "1"]))
            #expect(!BCD436HPHardwareGate.pushEnabled(["NOCTULE_BCD436HP_HARDWARE_TESTS": "1"]))
            #expect(!BCD436HPHardwareGate.pushEnabled(["NOCTULE_BCD436HP_HARDWARE_TESTS": "1", "NOCTULE_BCD436HP_PUSH_TEST": "true"]))
            #expect(BCD436HPHardwareGate.pushEnabled(["NOCTULE_BCD436HP_HARDWARE_TESTS": "1", "NOCTULE_BCD436HP_PUSH_TEST": "1"]))
        }

        /// The keep-alive check needs its own variable as well as the read-only suite's.
        @Test func keepAliveNeedsBoth() {
            #expect(!BCD436HPHardwareGate.keepAliveEnabled(["NOCTULE_BCD436HP_KEEPALIVE_TEST": "1"]))
            #expect(!BCD436HPHardwareGate.keepAliveEnabled(["NOCTULE_BCD436HP_HARDWARE_TESTS": "1"]))
            #expect(!BCD436HPHardwareGate.keepAliveEnabled(["NOCTULE_BCD436HP_HARDWARE_TESTS": "1", "NOCTULE_BCD436HP_PUSH_TEST": "1"]))
            #expect(!BCD436HPHardwareGate.keepAliveEnabled(["NOCTULE_BCD436HP_HARDWARE_TESTS": "1", "NOCTULE_BCD436HP_KEEPALIVE_TEST": "yes"]))
            let both = ["NOCTULE_BCD436HP_HARDWARE_TESTS": "1", "NOCTULE_BCD436HP_KEEPALIVE_TEST": "1"]
            #expect(BCD436HPHardwareGate.keepAliveEnabled(both))
            #expect(!BCD436HPHardwareGate.pushEnabled(both))
        }

        /// A shell that exports the USB kill-switch never runs them.
        @Test func killSwitchWins() {
            let all = ["NOCTULE_BCD436HP_HARDWARE_TESTS": "1", "NOCTULE_BCD436HP_PUSH_TEST": "1",
                       "NOCTULE_BCD436HP_KEEPALIVE_TEST": "1"]
            for value in ["1", "0", "yes"] {
                var environment = all
                environment["NOCTULE_NO_USB_DETECTION"] = value
                #expect(!BCD436HPHardwareGate.readOnlyEnabled(environment))
                #expect(!BCD436HPHardwareGate.pushEnabled(environment))
                #expect(!BCD436HPHardwareGate.keepAliveEnabled(environment))
            }
            var empty = all
            empty["NOCTULE_NO_USB_DETECTION"] = ""
            #expect(BCD436HPHardwareGate.readOnlyEnabled(empty))
            #expect(BCD436HPHardwareGate.pushEnabled(empty))
            #expect(BCD436HPHardwareGate.keepAliveEnabled(empty))
        }
    }
}
#endif
