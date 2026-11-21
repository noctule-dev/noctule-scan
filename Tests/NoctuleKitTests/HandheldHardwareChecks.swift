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

// The checks the handhelds' opt-in hardware suites run over USB serial (`SDS150HardwareTests`,
// `SDS100HardwareTests`), and what their mock twins share: each check takes the model it expects,
// and the port's path (the hardware suites pass the one `resolvePort(for:)` finds, the mock-backed
// tests their pty).
//
// **Hardware safety.** The SDS150 and the SDS100 share a vendor and product ID. A hardware suite
// opens the port its own config key names, else the one port whose USB product name names its
// model (never "the only Uniden port", which with both plugged in is neither), and every check
// that sends anything sends `MDL` first and nothing more unless it names the expected model.

enum HandheldHardwareCheckError: Error, Equatable, CustomStringConvertible {
    /// `MDL` named another scanner; nothing more was sent.
    case wrongModel(expected: ScannerModel, reported: String)
    /// No port to open: the model's config key is unset (or `auto`) and IOKit lists no port named
    /// for the model, or several.
    case noPort(String)

    var description: String {
        switch self {
        case .wrongModel(let expected, let reported):
            "MDL answered \(reported), not an \(expected.rawValue); nothing more was sent"
        case .noPort(let why): why
        }
    }
}

/// The checks, each taking the port's path. Each opens the port once and closes it on every path.
enum HandheldHardwareChecks {
    /// The `config/dev-scanner.env` key that names `model`'s port for the hardware suites:
    /// `SCANNER_SERIAL` for the SDS150 (what `noctule --serial` reads too), `SCANNER_SERIAL_<model>`
    /// for any other (`SCANNER_SERIAL_SDS100`).
    static func configKey(for model: ScannerModel) -> String {
        model == .sds150 ? "SCANNER_SERIAL" : "SCANNER_SERIAL_\(model.rawValue)"
    }

    /// `configured` exactly as written if non-nil (never a fallback); else the one port in
    /// `ports` whose `knownModel` is `model` (its USB product name names it: the SDS100 and the
    /// SDS150 share a product ID, so a port with no model name is never taken). None or several
    /// throws `.noPort`, saying what to do and naming `key`.
    static func resolvePort(for model: ScannerModel, configured: String?, ports: [SerialPortInfo],
                            key: String) throws -> String {
        if let configured { return configured }
        let named = ports.filter { $0.knownModel == model }
        switch named.count {
        case 1:
            return named[0].path
        case 0:
            throw HandheldHardwareCheckError.noPort(
                "No \(model.rawValue) serial port found (no Uniden port whose USB product name names the \(model.rawValue)). "
                + "\(SerialPort.noneFoundHint) Or set \(key) in config/dev-scanner.env.")
        default:
            throw HandheldHardwareCheckError.noPort(
                "Several \(model.rawValue) serial ports found (\(named.map(\.path).joined(separator: ", "))): "
                + "set \(key) in config/dev-scanner.env to the one to test.")
        }
    }

    /// The port `model`'s hardware suites open: its config key (`configKey(for:)`) from
    /// `config/dev-scanner.env`, used exactly as written; else the one port IOKit lists whose
    /// product name names `model` (registry reads only, nothing opened; IOKit isn't asked when the
    /// key is set). None or several is an error saying what to do.
    static func resolvePort(for model: ScannerModel) throws -> String {
        let key = configKey(for: model)
        if let url = DevScannerConfig.defaultURL(searchingUpFrom: URL(fileURLWithPath: #filePath)),
           let path = try DevScannerConfig.serialPath(from: url, key: key) {
            return path
        }
        return try resolvePort(for: model, configured: nil, ports: IOKitSerialPortFinder().unidenPorts(), key: key)
    }

    /// `MDL`, and nothing more (thrown, `wrongModel`) unless it names `expected`.
    private static func checkModel(_ client: ScannerClient, expecting expected: ScannerModel) async throws -> String {
        let model = try await client.modelInfo()
        guard model.model == expected else {
            throw HandheldHardwareCheckError.wrongModel(expected: expected, reported: model.reported)
        }
        return model.reported
    }

    struct ReadOnlyReport: Sendable {
        var model: String
        var firmware: String
        var volume: Int
        var squelch: Int
        var mode: String?
        var screen: String?
        var softKeys: [String]
        /// The width of each `STS` line's text, in characters (the line count is its length). Never the
        /// text itself: on hardware that would be real channel names.
        var displayWidths: [Int]
        /// The `Battery` attribute of the `GSI` document's `Property` element as written; nil when
        /// it has none.
        var batteryAttribute: String?
    }

    /// `MDL`, `VER`, `VOL`, `SQL`, `GSI`, `STS`, one each and in that order, then the port is
    /// closed. `MDL` must name `expected` (for the SDS150, `SDS150` or `SDS150GBT`), or nothing more
    /// is sent; `VER` is non-empty; `VOL` and `SQL` are within the expected model's ranges; `GSI`
    /// and `STS` parse, and `STS`'s last line has soft-key labels, has at least two lines, and every
    /// line's text and mask are the same width in characters (SDS150 design §7.3: icon glyph bytes
    /// must keep one character per column once decoded, or the highlight shifts); the report holds
    /// the widths and `GSI`'s `Battery` attribute. A reply that fails to come or to parse ends the
    /// run there (thrown).
    ///
    /// `port` builds the transport on `path`; tests hand in one that alters a reply.
    static func readOnly(path: String, expecting expected: ScannerModel = .sds150,
                         commandTimeout: Duration = .seconds(2),
                         port: (String) -> any ScannerTransport = { SerialTransport(path: $0) })
        async throws -> ReadOnlyReport {
        let transport = TappedTransport(port(path))
        let client = ScannerClient(transport: transport, commandTimeout: commandTimeout)
        try await client.connect()
        do {
            let report = try await readOnlyChecks(client, transport: transport, expecting: expected)
            await client.disconnect()
            return report
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private static func readOnlyChecks(_ client: ScannerClient, transport: TappedTransport,
                                       expecting expected: ScannerModel) async throws -> ReadOnlyReport {
        let reported = try await checkModel(client, expecting: expected)
        let profile = ModelProfile.profile(for: expected)
        let firmware = try await client.firmwareVersion()
        #expect(!firmware.isEmpty, "VER answered no version")
        let volume = try await client.volume()
        #expect(profile.volumeRange?.contains(volume) == true,
                "VOL answered \(volume), outside the \(expected.rawValue)'s \(levels(profile.volumeRange))")
        let squelch = try await client.squelch()
        #expect(profile.squelchRange?.contains(squelch) == true,
                "SQL answered \(squelch), outside the \(expected.rawValue)'s \(levels(profile.squelchRange))")
        let info = try await client.scannerInfo()
        #expect(info.mode != nil, "GSI's ScannerInfo has no Mode")
        // The reply the client parsed: the tap holds it by the time `scannerInfo` returns.
        let gsi = transport.seen.last { response in
            if case .xml("GSI", _) = response { return true }
            return false
        }
        var battery: String?
        if case .xml(_, let root) = gsi { battery = root.child("Property")?.attributes["Battery"] }
        let display = try await client.displayStatus()
        #expect(!display.softKeyLabels.isEmpty, "STS's last line has no soft-key labels")
        #expect(display.lines.count >= 2, "STS has \(display.lines.count) line(s)")
        for (index, line) in display.lines.enumerated() {
            // Counts only, never the text.
            #expect(line.text.count == line.highlightMask.count,
                    "STS line \(index): text is \(line.text.count) characters, its mask \(line.highlightMask.count)")
        }
        return ReadOnlyReport(model: reported, firmware: firmware, volume: volume, squelch: squelch,
                              mode: info.mode, screen: info.screen, softKeys: display.softKeyLabels,
                              displayWidths: display.lines.map(\.text.count), batteryAttribute: battery)
    }

    /// A level range as `0…15` (`none` for a model without one).
    private static func levels(_ range: ClosedRange<Int>?) -> String {
        range.map { "\($0.lowerBound)…\($0.upperBound)" } ?? "none"
    }

    struct PushReport: Sendable {
        /// `GSI` replies that parsed (of 20).
        var replies: Int
        /// `PSI` pushes the client delivered while subscribed.
        var pushes: Int
        /// Parsed `PSI` documents on the wire before the last `GSI` reply that came back: the client
        /// had handled every one of them by then (it handles responses in arrival order), so each
        /// must be among `pushes`.
        var pushesBeforeLastReply: Int
        /// Parsed `PSI` documents on the wire in all, up to the close (some may come after `PSI,0`
        /// and are not delivered).
        var pushesOnTheWire: Int
        /// Every response that was neither a parsed push, a parsed `GSI` reply, the `MDL` reply,
        /// nor `PSI,OK`, described: a push landing inside another reply would show up here.
        var unexpected: [String]
        /// `PSI` documents that arrived more than `stopGrace` after `PSI,0` was written, while the
        /// port was still held: a subscription `PSI,0` didn't end.
        var pushesAfterStop: Int
        /// Whether a parsed push came on the wire right before the reply to `PSI,0` (the second
        /// `PSI,OK`): a push in flight when the subscription ended.
        var pushRightBeforeStopReply: Bool
    }

    static let pushRequests = 20

    /// `MDL` (it must name `expected`, else nothing more is sent), then subscribes
    /// (`PSI,<pushInterval>`), sends 20 `GSI`s `spacing` apart while the pushes arrive, and then
    /// always `PSI,0`, whatever failed in between; then holds the port for `holdAfterStop` (1.5 s)
    /// with nothing sent, and closes it. Every reply and every push must parse, at least one push
    /// must arrive, no push on the wire before the last `GSI` reply may be lost, nothing else may
    /// come back (bar `PSI,OK`), and no push may arrive later than `stopGrace` (250 ms, for a push
    /// already on its way) after `PSI,0`: holding the port open shows whether `PSI,0` itself works,
    /// apart from whether it survives the close (which the quiet-port check shows on the next
    /// open). A `GSI` that fails is recorded and the next one still sent, so the count of `GSI`s is
    /// always 20 while the port is open. Nothing else is sent: no keep-alive (the check is far
    /// shorter than any push lifetime).
    ///
    /// `port` builds the transport on `path`; tests hand in one whose writes fail, that alters a
    /// reply, or that never sends `PSI,0`.
    static func pushWhileReading(path: String, expecting expected: ScannerModel = .sds150,
                                 pushInterval: Duration = .milliseconds(500),
                                 spacing: Duration = .milliseconds(250),
                                 commandTimeout: Duration = .seconds(2),
                                 holdAfterStop: Duration = .milliseconds(1500),
                                 stopGrace: Duration = .milliseconds(250),
                                 port: (String) -> any ScannerTransport = { SerialTransport(path: $0) })
        async throws -> PushReport {
        let transport = TappedTransport(port(path))
        let client = ScannerClient(transport: transport, commandTimeout: commandTimeout)
        try await client.connect()
        do {
            _ = try await checkModel(client, expecting: expected)
        } catch {
            await client.disconnect()
            throw error
        }
        var replies = 0
        /// How many tapped responses the client had handled when the last `GSI` reply came back.
        var handled = 0
        var counter: Task<Int, Never>?
        var thrown: (any Error)?
        do {
            let updates = try await client.startPush(interval: pushInterval)
            counter = Task {
                var count = 0
                for await _ in updates { count += 1 }
                return count
            }
            for index in 1...pushRequests {
                do {
                    _ = try await client.scannerInfo()
                    replies += 1
                    handled = transport.countThroughLastReply("GSI")
                } catch {
                    Issue.record("GSI \(index) of \(pushRequests) failed: \(error)")
                }
                if index < pushRequests { try? await Task.sleep(for: spacing) }
            }
        } catch {
            thrown = error
        }
        // Every path: PSI,0 (also when the subscription couldn't start: a failed or short write of
        // `PSI` may still have reached the scanner), then the hold with nothing sent, then close.
        // `disconnect` never sends it twice, and it ends the push stream, so the count below can't
        // wait forever.
        try? await client.stopPush()
        let stoppedAt = ContinuousClock.now
        try? await Task.sleep(for: holdAfterStop)
        await client.disconnect()
        let pushes = await counter?.value ?? 0
        if let thrown { throw thrown }

        var unexpected: [String] = []
        var before = 0, onTheWire = 0, pushNumber = 0
        /// Whether anything we asked for has been answered yet: what comes before that may be
        /// left over from before the port was opened (the flush at open can't take bytes the
        /// scanner was still sending).
        var answered = false
        /// Whether the one `MDL` reply has been seen (a second one is unexpected).
        var modelAnswered = false
        let pushesAfterStop = transport.arrivals.filter { arrival in
            guard case .xml("PSI", _) = arrival.response else { return false }
            return arrival.at > stoppedAt + stopGrace
        }.count
        for (index, response) in transport.seen.enumerated() {
            switch response {
            case .fields("MDL", _), .fields("PSI", _), .fields("GSI", _), .xml("GSI", _): answered = true
            default: break
            }
            switch response {
            case .xml("PSI", let root):
                pushNumber += 1
                guard (try? ScannerInfo(xml: root)) != nil else {
                    unexpected.append("PSI push \(pushNumber) did not parse (root <\(root.name)>)")
                    continue
                }
                onTheWire += 1
                if index < handled { before += 1 }
            case .xml("GSI", let root):
                if (try? ScannerInfo(xml: root)) == nil { unexpected.append("a GSI reply did not parse (root <\(root.name)>)") }
            case .fields("PSI", ["OK"]):
                break
            case .fields("MDL", _) where !modelAnswered:
                modelAnswered = true
            case .fields(let command, let fields):
                unexpected.append("the line \"\(([command] + fields).joined(separator: ","))\""
                    + (answered ? "" : " before any reply (left over from before the port was opened?)"))
            case .xml(let command, let root):
                unexpected.append("a \(command) document (root <\(root.name)>)")
            }
        }
        let seen = transport.seen
        let stopReply = seen.indices.filter { index in
            if case .fields("PSI", ["OK"]) = seen[index] { true } else { false }
        }.dropFirst().first
        let pushRightBeforeStopReply = stopReply.map { index in
            guard index > 0, case .xml("PSI", let root) = seen[index - 1] else { return false }
            return (try? ScannerInfo(xml: root)) != nil
        } ?? false
        let report = PushReport(replies: replies, pushes: pushes, pushesBeforeLastReply: before,
                                pushesOnTheWire: onTheWire, unexpected: unexpected, pushesAfterStop: pushesAfterStop,
                                pushRightBeforeStopReply: pushRightBeforeStopReply)
        #expect(report.replies == pushRequests, "\(report.replies) of \(pushRequests) GSI replies parsed")
        #expect(report.pushes > 0, "no PSI push reached the client")
        #expect(report.pushes >= report.pushesBeforeLastReply,
                "\(report.pushesBeforeLastReply) pushes were on the wire before the last GSI reply, but only \(report.pushes) reached the client: pushes were lost while subscribed")
        #expect(report.pushes <= report.pushesOnTheWire,
                "\(report.pushes) pushes reached the client, but only \(report.pushesOnTheWire) parsed on the wire")
        #expect(unexpected.isEmpty, "unexpected responses: \(unexpected.joined(separator: "; "))")
        #expect(report.pushesAfterStop == 0,
                "\(report.pushesAfterStop) PSI push(es) arrived more than \(stopGrace) after PSI,0: the subscription didn't end")
        return report
    }

    struct KeepAliveReport: Sendable {
        /// `PSI` pushes the client delivered while subscribed.
        var pushes: Int
        /// What the keep-alive writes: its command (`KAL`), or the subscription's own `PSI` again.
        var action: PushKeepAlive.Action
        /// Keep-alives written before `PSI,0`: `KAL`s, or for a renewal the `PSI`s after the first.
        var keepAlives: Int
        /// The longest time with no push: from the `PSI`, between pushes, and from the last push
        /// to the end of the hold.
        var longestGap: Duration
        /// When the last push arrived, counted from the `PSI`; nil when none did.
        var lastPush: Duration?
        /// How long the subscription was held (from the `PSI` to the end of the hold).
        var held: Duration
        /// Every response that was neither a parsed push nor `PSI,OK` nor the `MDL` reply,
        /// described: a reply to `KAL` (an `ERR` included), or a refused renewal (`PSI,NG`),
        /// shows up here.
        var unexpected: [String]
        /// `PSI` documents that arrived more than `stopGrace` after `PSI,0` was written.
        var pushesAfterStop: Int
        /// Keep-alives written after `PSI,0` (the client must never write one).
        var keepAlivesAfterStop: Int

        /// What a keep-alive is called in the report: `KAL`, or `PSI renewals`.
        var keepAliveName: String {
            switch action {
            case .command(let name): name
            case .renewSubscription: "PSI renewals"
            }
        }

        /// One line for the suite's output.
        var summary: String {
            "\(pushes) pushes, \(keepAlives) \(keepAliveName) sent, longest gap \(seconds(longestGap)) s, last push "
                + (lastPush.map { "\(seconds($0)) s" } ?? "never") + " after PSI (held \(seconds(held)) s), "
                + "\(pushesAfterStop) pushes and \(keepAlivesAfterStop) \(keepAliveName) after PSI,0, unexpected \(unexpected)"
        }
    }

    /// Seconds to one decimal.
    static func seconds(_ duration: Duration) -> String {
        String(format: "%.1f", Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18)
    }

    /// Does the keep-alive keep the handheld pushing past the 183 s after which it stops by
    /// itself (protocol notes §8 item 10)? `MDL` must name `expected`, else nothing more is sent.
    /// Then `PSI,<pushInterval>` (1000 ms) with `keepAlive` (nil: the expected model's profile's,
    /// `KAL` every 60 s on the SDS150, the `PSI` written again every 60 s on the SDS100; written by
    /// the client), held for `hold` (240 s) with nothing else sent; the hold ends early only if the
    /// push stream ends (a rejected `PSI`, the link gone). Passes only if pushes are still arriving
    /// at the end: no gap of more than `maxGap` (5 s) from the `PSI`, between pushes or before the
    /// end of the hold. The failure says when the last push arrived, counted from the `PSI`: that is
    /// the answer to "does the keep-alive reset it". Then always `PSI,0` (also after a thrown
    /// error, or a `PSI` that couldn't be written or was rejected), the port held `holdAfterStop`
    /// (1.5 s) with nothing sent, and closed: no push may arrive more than `stopGrace` (250 ms)
    /// after `PSI,0`, and no keep-alive may follow it. Every other line or document that comes back
    /// is reported in `unexpected`, not failed: a reply to `KAL` is what the check wants to see
    /// (the spec says it has none, and the client drops one), and a keep-alive the scanner didn't
    /// take would show as pushes that stopped. Sends nothing but `MDL`, `PSI`, the keep-alive and
    /// `PSI,0`. A model whose profile has no keep-alive, with none given, fails before the port is
    /// opened.
    ///
    /// `port` builds the transport on `path`; tests hand in one whose writes fail.
    static func keepAlive(path: String, expecting expected: ScannerModel = .sds150,
                          pushInterval: Duration = .milliseconds(1000),
                          keepAlive: PushKeepAlive? = nil,
                          hold: Duration = .seconds(240), maxGap: Duration = .seconds(5),
                          commandTimeout: Duration = .seconds(2),
                          holdAfterStop: Duration = .milliseconds(1500),
                          stopGrace: Duration = .milliseconds(250),
                          port: (String) -> any ScannerTransport = { SerialTransport(path: $0) })
        async throws -> KeepAliveReport {
        let keepAlive = try #require(keepAlive ?? ModelProfile.profile(for: expected).pushKeepAlive,
                                     "the \(expected.rawValue) has no keep-alive")
        let transport = TappedTransport(port(path))
        let client = ScannerClient(transport: transport, commandTimeout: commandTimeout)
        try await client.connect()
        do {
            _ = try await checkModel(client, expecting: expected)
        } catch {
            await client.disconnect()
            throw error
        }

        let ended = Mutex(false)
        var collector: Task<[ContinuousClock.Instant], Never>?
        var thrown: (any Error)?
        let start = ContinuousClock.now
        do {
            let updates = try await client.startPushUpdates(interval: pushInterval, keepAlive: keepAlive)
            collector = Task {
                var arrivals: [ContinuousClock.Instant] = []
                for await update in updates { arrivals.append(update.receivedAt) }
                ended.withLock { $0 = true }
                return arrivals
            }
            let deadline = ContinuousClock.now + hold
            while ContinuousClock.now < deadline, !ended.withLock({ $0 }) {
                try await Task.sleep(for: min(.milliseconds(250), ContinuousClock.now.duration(to: deadline)))
            }
        } catch {
            thrown = error
        }
        let endOfHold = ContinuousClock.now
        // Every path: PSI,0 (a failed or short `PSI` write may still have reached the scanner),
        // then the hold with nothing sent, then close. `stopPush` ends the stream, so the
        // collector always ends.
        try? await client.stopPush()
        let stoppedAt = ContinuousClock.now
        try? await Task.sleep(for: holdAfterStop)
        await client.disconnect()
        let arrivals = await collector?.value ?? []
        if let thrown { throw thrown }

        let sent = transport.sent
        let subscribedIndex = sent.firstIndex { $0.text.hasPrefix("PSI,") && $0.text != "PSI,0" }
        let psiAt = subscribedIndex.map { sent[$0].at } ?? start
        let stopIndex = sent.firstIndex { $0.text == "PSI,0" } ?? sent.endIndex
        /// Whether the write at `index` was a keep-alive: its command, or a `PSI` other than
        /// `PSI,0` after the subscription's own.
        func isKeepAlive(_ index: Int) -> Bool {
            switch keepAlive.action {
            case .command(let name):
                return sent[index].text == name
            case .renewSubscription:
                return index != subscribedIndex && sent[index].text.hasPrefix("PSI,") && sent[index].text != "PSI,0"
            }
        }
        var longest = Duration.zero
        for (earlier, later) in zip([psiAt] + arrivals, arrivals + [endOfHold]) {
            longest = max(longest, later - earlier)
        }
        var unexpected: [String] = []
        var answered = false
        var pushNumber = 0
        for response in transport.seen {
            switch response {
            case .xml("PSI", let root):
                pushNumber += 1
                if (try? ScannerInfo(xml: root)) == nil {
                    unexpected.append("PSI push \(pushNumber) did not parse (root <\(root.name)>)")
                }
            case .fields("PSI", ["OK"]):
                answered = true
            case .fields("MDL", _) where !answered:
                answered = true
            case .fields(let command, let fields):
                unexpected.append("the line \"\(([command] + fields).joined(separator: ","))\""
                    + (answered ? "" : " before any reply (left over from before the port was opened?)"))
            case .xml(let command, let root):
                unexpected.append("a \(command) document (root <\(root.name)>)")
            }
        }
        let report = KeepAliveReport(
            pushes: arrivals.count,
            action: keepAlive.action,
            keepAlives: sent.indices[..<stopIndex].filter(isKeepAlive).count,
            longestGap: longest,
            lastPush: arrivals.last.map { $0 - psiAt },
            held: endOfHold - psiAt,
            unexpected: unexpected,
            pushesAfterStop: transport.arrivals.filter { arrival in
                guard case .xml("PSI", _) = arrival.response else { return false }
                return arrival.at > stoppedAt + stopGrace
            }.count,
            keepAlivesAfterStop: sent.indices[stopIndex...].filter(isKeepAlive).count)

        let lastPush = report.lastPush.map { "the last push arrived \(seconds($0)) s after PSI" } ?? "no push arrived"
        #expect(report.pushes > 0, "no PSI push arrived in \(seconds(report.held)) s")
        #expect(endOfHold - (arrivals.last ?? psiAt) <= maxGap,
                "pushes stopped: \(lastPush), \(seconds(report.held)) s held, \(report.keepAlives) \(report.keepAliveName) sent")
        #expect(report.longestGap <= maxGap,
                "a gap of \(seconds(report.longestGap)) s with no push (over \(seconds(maxGap)) s); \(lastPush)")
        #expect(report.pushesAfterStop == 0,
                "\(report.pushesAfterStop) PSI push(es) arrived more than \(stopGrace) after PSI,0: the subscription didn't end")
        #expect(report.keepAlivesAfterStop == 0, "\(report.keepAlivesAfterStop) \(report.keepAliveName) written after PSI,0")
        return report
    }

    struct QuietReport: Sendable {
        /// `PSI` documents that arrived although nothing was asked (parsed or not).
        var pushes: Int
        /// Everything else that arrived unasked, described (the tail of a push cut off at an
        /// earlier close shows up here as stray lines).
        var other: [String]
    }

    /// Opens the port, sends **nothing at all** for `listen` (2 s), and closes it: no `PSI`
    /// document may arrive. One that does means a subscription is still running, an earlier
    /// client's `PSI,0` never took effect (SDS150 design §8 check 10). Anything else that arrives
    /// is reported, not failed. The way to look at the port without `cat`, `screen` or `stty`.
    /// Sending nothing, it needs no expected model: whatever is on the port hears nothing.
    static func quietPort(path: String, listen: Duration = .seconds(2),
                          port: (String) -> any ScannerTransport = { SerialTransport(path: $0) })
        async throws -> QuietReport {
        let transport = port(path)
        try await transport.open()
        let responses = transport.responses
        let collector = Task {
            var seen: [ScannerResponse] = []
            for await response in responses { seen.append(response) }
            return seen
        }
        try? await Task.sleep(for: listen)
        // Closing finishes `responses`, so the collector always ends.
        await transport.close()
        let seen = await collector.value
        var report = QuietReport(pushes: 0, other: [])
        for response in seen {
            switch response {
            case .xml("PSI", _): report.pushes += 1
            case .xml(let command, let root): report.other.append("a \(command) document (root <\(root.name)>)")
            case .fields(let command, let fields): report.other.append("the line \"\(([command] + fields).joined(separator: ","))\"")
            }
        }
        #expect(report.pushes == 0,
                "\(report.pushes) PSI push(es) arrived with nothing asked: a subscription is still running (an earlier PSI,0 didn't take effect)")
        return report
    }
}

/// A transport that keeps a copy of every response its base delivers, solicited or not, with
/// when it arrived, and of every command written whole, with when its write returned.
final class TappedTransport: ScannerTransport {
    private let base: any ScannerTransport
    private let log = Mutex<[(response: ScannerResponse, at: ContinuousClock.Instant)]>([])
    private let sentLog = Mutex<[(text: String, at: ContinuousClock.Instant)]>([])

    init(_ base: any ScannerTransport) { self.base = base }

    var seen: [ScannerResponse] { log.withLock { $0.map(\.response) } }
    var arrivals: [(response: ScannerResponse, at: ContinuousClock.Instant)] { log.withLock { $0 } }
    /// Commands whose write returned without an error, as `NAME[,args]`, in order.
    var sent: [(text: String, at: ContinuousClock.Instant)] { sentLog.withLock { $0 } }

    /// The number of responses up to and including the last `.xml(command, …)` seen so far.
    func countThroughLastReply(_ command: String) -> Int {
        log.withLock { responses in
            let last = responses.lastIndex {
                if case .xml(let name, _) = $0.response { return name == command }
                return false
            }
            return last.map { $0 + 1 } ?? 0
        }
    }

    func open() async throws { try await base.open() }
    func send(_ command: ScannerCommand) async throws {
        try await base.send(command)
        let text = ([command.name] + command.arguments).joined(separator: ",")
        sentLog.withLock { $0.append((text, ContinuousClock.now)) }
    }
    func close() async { await base.close() }

    var responses: AsyncStream<ScannerResponse> {
        let upstream = base.responses
        return AsyncStream { continuation in
            let relay = Task { [self] in
                for await response in upstream {
                    log.withLock { $0.append((response, ContinuousClock.now)) }
                    continuation.yield(response)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }
}

/// A transport that replaces the first response `rewrite` changes (a non-nil result) and passes
/// everything else through: a reply corrupted in transit, for the mock-backed tests.
final class RewritingTransport: ScannerTransport {
    private let base: any ScannerTransport
    private let rewrite: @Sendable (ScannerResponse) -> ScannerResponse?
    private let done = Mutex(false)

    init(_ base: any ScannerTransport, rewrite: @escaping @Sendable (ScannerResponse) -> ScannerResponse?) {
        self.base = base
        self.rewrite = rewrite
    }

    func open() async throws { try await base.open() }
    func send(_ command: ScannerCommand) async throws { try await base.send(command) }
    func close() async { await base.close() }

    var responses: AsyncStream<ScannerResponse> {
        let upstream = base.responses
        return AsyncStream { continuation in
            let relay = Task { [self] in
                for await response in upstream { continuation.yield(altered(response)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in relay.cancel() }
        }
    }

    private func altered(_ response: ScannerResponse) -> ScannerResponse {
        done.withLock { done in
            guard !done, let changed = rewrite(response) else { return response }
            done = true
            return changed
        }
    }

    /// The serial port at `path`, with the first `.xml(command, …)` given a root `<Garbled>`.
    static func garbling(_ command: String) -> (String) -> any ScannerTransport {
        { path in
            RewritingTransport(SerialTransport(path: path)) { response in
                guard case .xml(let name, var root) = response, name == command else { return nil }
                root.name = "Garbled"
                return .xml(command: command, root: root)
            }
        }
    }

    /// The serial port at `path`, with the first `STS` reply's line `index` one character short in
    /// its text (its mask unchanged): a display whose decoded width differs from its mask's.
    static func shortenedDisplayLine(_ index: Int) -> (String) -> any ScannerTransport {
        { path in
            RewritingTransport(SerialTransport(path: path)) { response in
                guard case .fields(let name, var fields) = response, name == "STS", fields.count > 2 + 2 * index else { return nil }
                fields[1 + 2 * index].removeLast()
                return .fields(command: name, fields: fields)
            }
        }
    }

    /// The serial port at `path`, with the first `STS` reply cut down to its first line.
    static func singleLineDisplay() -> (String) -> any ScannerTransport {
        { path in
            RewritingTransport(SerialTransport(path: path)) { response in
                guard case .fields(let name, let fields) = response, name == "STS", fields.count > 2 else { return nil }
                return .fields(command: name, fields: ["0", fields[1], fields[2]])
            }
        }
    }

    /// The serial port at `path`, with the first `<command>,<n>` reply answering `<command>,<level>`.
    static func level(_ command: String, _ level: Int) -> (String) -> any ScannerTransport {
        { path in
            RewritingTransport(SerialTransport(path: path)) { response in
                guard case .fields(let name, _) = response, name == command else { return nil }
                return .fields(command: command, fields: [String(level)])
            }
        }
    }
}

/// The serial port at `path`, except that `PSI,0` is reported sent but never written: a scanner
/// for which `PSI,0` doesn't end the subscription, as far as the check can tell.
final class SwallowingStopTransport: ScannerTransport {
    private let base: SerialTransport

    init(path: String) { base = SerialTransport(path: path) }

    func open() async throws { try await base.open() }
    func close() async { await base.close() }
    var responses: AsyncStream<ScannerResponse> { base.responses }

    func send(_ command: ScannerCommand) async throws {
        if command.name == "PSI", command.arguments == ["0"] { return }
        try await base.send(command)
    }
}

/// A port write that fails (`EIO`, nothing written) once, and otherwise writes for real.
final class WriteCounter: Sendable {
    private let count = Mutex(0)

    /// Fails the `n`-th write only.
    func failing(_ n: Int) -> SerialTransport.PortWrite {
        { [self] fd, data in
            let fails = count.withLock { written in
                written += 1
                return written == n
            }
            return fails ? (-1, EIO) : SerialTransport.portWrite(fd, data)
        }
    }
}

/// True for an issue whose comments mention `text`.
func mentions(_ text: String) -> (Issue) -> Bool {
    { issue in issue.comments.contains { $0.rawValue.contains(text) } }
}

private struct TimedOut: Error {}

/// How long the mock-backed push checks hold the port after `PSI,0` (the hardware default is 1.5 s).
let mockHold: Duration = .milliseconds(300)

/// A mock handheld (`personality`, an SDS150 by default) on a stepped clock (or `clock`), its
/// port's path, `body` (failing with `TimedOut` after 10 s, so a check that never ends can't hang
/// the run), then the mock stopped on every path.
func withMockHandheld(personality: MockPersonality = .sds150, faults: MockFaults = .none,
                      clock: MockClock = .stepped(at: 3),
                      _ body: @escaping @Sendable (String) async throws -> Void) async throws -> MockSerialScanner {
    let mock = MockSerialScanner(scenario: .default, clock: clock, personality: personality)
    await mock.setFaults(faults)
    do {
        let path = try await mock.start()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await body(path) }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    } catch {
        await mock.stop()
        throw error
    }
    await mock.stop()
    return mock
}
#endif
