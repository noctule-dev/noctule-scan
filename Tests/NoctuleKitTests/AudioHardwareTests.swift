// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Synchronization
import Testing
import NoctuleDevConfig
@testable import NoctuleKit

/// Research spike against the real development scanner. Opt-in: `NOCTULE_AUDIO_HARDWARE_TESTS=1`.
///
/// Opens at most two RTSP sessions, one after the other and at least 120 s apart (reconnect
/// cooldown, enforced by `RTSPClient` and a file store), and TEARS DOWN each one on every path
/// (`RTSPClient.close()` runs after success, a thrown error, a failed `#require`, or a timeout).
/// The control plane is read-only: `GSI` once per second over a Plan 1 `ScannerClient`,
/// disconnected on every path (it never starts a push, so there is no `PSI,0` to send).
///
/// The scanner is addressed by `SCANNER_IP` (an IP literal), and requests follow the exact shape
/// that works on the SDS200 (OPTIONS first; protocol notes §6). Earlier shapes hung its audio
/// server until a power cycle (LESSONS.md).
/// The address comes from the git-ignored `config/dev-scanner.env` and is never printed.
///
/// Prints aggregate numbers only: no audio, no SSRC value, no system or talkgroup names.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["NOCTULE_AUDIO_HARDWARE_TESTS"] == "1"), .serialized)
struct AudioHardwareTests {
    private struct SpikeTimedOut: Error {}
    private struct NoScannerIP: Error {}

    /// What one RTP packet looked like. The SSRC is kept only to check it's constant.
    private struct Record: Sendable {
        var sequence: UInt16
        var timestamp: UInt32
        var ssrc: UInt32
        var payloadType: UInt8
        var marker: Bool
        var payloadBytes: Int
        /// Largest absolute linear sample in the payload (0 means digital silence).
        var peak: Int
        var receivedAt: ContinuousClock.Instant
    }

    private final class Recorder: Sendable {
        private let records = Mutex<[Record]>([])
        func append(_ record: Record) { records.withLock { $0.append(record) } }
        var snapshot: [Record] { records.withLock { $0 } }
    }

    private struct SessionOutcome {
        var unreleasedSessions: [String]
        var sessionTimeout: Int?
        var teardownStatuses: [Int]
        var droppedWrongSource: Int
        var droppedMalformed: Int
    }

    /// Where to reach the scanner: its IP literal, never its host name.
    private struct Target: Sendable {
        var ip: String
        var udpPort: UInt16
        var rtspPort: UInt16
        /// Strings to scrub from anything printed.
        var secrets: [String]
    }

    private static func target() throws -> Target {
        guard let url = DevScannerConfig.defaultURL(searchingUpFrom: URL(fileURLWithPath: #filePath)) else {
            throw DevScannerConfigError.missingHost
        }
        let config = try DevScannerConfig.load(from: url)
        // DevScannerConfig prefers SCANNER_HOST; this spike needs SCANNER_IP.
        let text = try String(contentsOf: url, encoding: .utf8)
        let ip = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("SCANNER_IP") && $0.contains("=") }
            .map { String($0[$0.index(after: $0.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces) }
        guard let ip, !ip.isEmpty else { throw NoScannerIP() }
        return Target(ip: ip, udpPort: config.port, rtspPort: config.rtspPort, secrets: [ip, config.host])
    }

    private static func redact(_ error: any Error, _ target: Target) -> String {
        target.secrets.reduce(String(describing: error)) { $0.replacingOccurrences(of: $1, with: "<scanner>") }
    }

    /// The SDS200 hangs if port 554 sees a new connection soon after the last one closed; 120 s is
    /// proven safe. The file store makes the cooldown hold across test runs and the CLI.
    private static let cooldown: Duration = .seconds(120)
    private static let cooldownStore = FileRTSPCooldownStore(url: FileRTSPCooldownStore.defaultURL)

    /// Sleeps until `cooldown` has passed since the last recorded close of a connection to `ip`.
    private static func waitOutCooldown(_ target: Target, label: String) async throws {
        guard let last = await cooldownStore.lastClosed(host: target.ip) else {
            print("Audio[\(label)]: no recorded close; no cooldown wait")
            return
        }
        let elapsed = Date().timeIntervalSince(last)
        let wait = 120 - elapsed + 1  // one second of margin
        guard wait > 0 else {
            print("Audio[\(label)]: last close \(Int(elapsed)) s ago; no cooldown wait")
            return
        }
        print("Audio[\(label)]: last close \(Int(elapsed)) s ago; waiting \(Int(wait.rounded(.up))) s for the reconnect cooldown")
        try await Task.sleep(for: .seconds(wait))
    }

    /// Runs `body` (bounded by `limit`) or throws `SpikeTimedOut`.
    private static func within<T: Sendable>(
        _ limit: Duration, _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw SpikeTimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw SpikeTimedOut() }
            return first
        }
    }

    /// Binds a receiver, then OPTIONS, DESCRIBE, SETUP, PLAY (the working SDS200 sequence), and runs `body` while a recorder collects
    /// every packet. TEARDOWN (via `close()`), receiver close, and recorder stop run on EVERY
    /// path: success, a thrown error, a failed `#require`, or `body` overrunning `limit`.
    private static func withAudioSession<T: Sendable>(
        _ target: Target, label: String, limit: Duration,
        _ body: @escaping @Sendable (RTSPClient, RTPReceiver, Recorder, ContinuousClock.Instant) async throws -> T
    ) async -> (Result<T, any Error>, SessionOutcome) {
        let receiver = RTPReceiver(expectedSourceHost: target.ip)
        let rtsp = RTSPClient(host: target.ip, port: target.rtspPort, requestTimeout: .seconds(3),
                              reconnectCooldown: cooldown, cooldownStore: cooldownStore)
        let recorder = Recorder()
        var collector: Task<Void, Never>?
        var result: Result<T, any Error>
        do {
            let port = try await receiver.bind()
            let packets = receiver.packets
            collector = Task {
                for await received in packets {
                    let packet = received.packet
                    let peak = MuLaw.decode(packet.payload).map { abs(Int($0)) }.max() ?? 0
                    recorder.append(Record(
                        sequence: packet.sequence, timestamp: packet.timestamp, ssrc: packet.ssrc,
                        payloadType: packet.payloadType, marker: packet.marker,
                        payloadBytes: packet.payload.count, peak: peak, receivedAt: received.receivedAt))
                }
            }
            func elapsed(since start: ContinuousClock.Instant) -> String {
                let d = ContinuousClock.now - start
                let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
                return String(format: "%.0f ms", ms)
            }
            var step = ContinuousClock.now
            try await rtsp.connect()
            print("Audio[\(label)]: connect ok (\(elapsed(since: step)))")
            step = ContinuousClock.now
            let methods = try await rtsp.options()
            print("Audio[\(label)]: OPTIONS ok (\(elapsed(since: step))), Public \(methods.joined(separator: ","))")
            step = ContinuousClock.now
            let (base, sdp) = try await rtsp.describe()
            print("Audio[\(label)]: DESCRIBE ok (\(elapsed(since: step))), SDP payload type \(sdp.payloadType),"
                + " control \(sdp.control ?? "nil")")
            step = ContinuousClock.now
            _ = try await rtsp.setup(controlURL: base + "trackID=1", clientPort: port)
            print("Audio[\(label)]: SETUP ok (\(elapsed(since: step))),"
                + " session timeout \(await rtsp.sessionTimeoutSeconds.map(String.init) ?? "none")")
            step = ContinuousClock.now
            try await rtsp.play()
            let playedAt = ContinuousClock.now
            print("Audio[\(label)]: PLAY ok (\(elapsed(since: step)))")
            result = .success(try await within(limit) { try await body(rtsp, receiver, recorder, playedAt) })
        } catch {
            result = .failure(error)
            print("Audio[\(label)]: FAILED: \(redact(error, target))")
        }
        // Cleanup, on every path. close() tears down (best effort, never throws, bounded) and
        // closes TCP gracefully. The RTP socket closes only after that, and 0.5 s later, as the
        // proven reference client does (see RTPReceiver's ordering note).
        await rtsp.close()
        try? await Task.sleep(for: .milliseconds(500))
        await receiver.close()
        collector?.cancel()
        _ = await collector?.value
        let outcome = SessionOutcome(
            unreleasedSessions: await rtsp.unreleasedSessions,
            sessionTimeout: await rtsp.sessionTimeoutSeconds,
            teardownStatuses: await rtsp.teardownStatuses,
            droppedWrongSource: await receiver.droppedWrongSource,
            droppedMalformed: await receiver.droppedMalformed)
        print("Audio[\(label)]: TEARDOWN statuses \(outcome.teardownStatuses),"
            + " unreleased sessions \(outcome.unreleasedSessions.count)")
        return (result, outcome)
    }

    private enum Classification: String, Sendable {
        case continuous, squelchGated = "squelch-gated", inconclusive
        /// Packets and signal both seen, but neither pattern dominates.
        case mixed
    }

    /// Window i is [PLAY+i s, PLAY+i+1 s), bracketed by the GSI samples at i and i+1. It's quiet
    /// when Sig == 0 at both ends (so a transmission starting mid-window doesn't count as quiet),
    /// and open when Sig > 0 at either end.
    private struct Windows: Sendable {
        var quietWith = 0, quietWithout = 0, openWith = 0, openWithout = 0
        var rows: [String] = []

        init(samples: [Int?], records: [Record], playedAt: ContinuousClock.Instant) {
            guard samples.count >= 2 else { return }
            for i in 0..<(samples.count - 1) {
                let lo = playedAt + .seconds(i), hi = playedAt + .seconds(i + 1)
                let inWindow = records.filter { $0.receivedAt >= lo && $0.receivedAt < hi }
                let ends = [samples[i], samples[i + 1]]
                let quiet = ends.allSatisfy { $0 == 0 }
                let open = ends.contains { ($0 ?? 0) > 0 }
                switch (quiet, open, inWindow.isEmpty) {
                case (true, _, false): quietWith += 1
                case (true, _, true): quietWithout += 1
                case (_, true, false): openWith += 1
                case (_, true, true): openWithout += 1
                default: break
                }
                let sigs = ends.map { $0.map(String.init) ?? "nil" }.joined(separator: "→")
                rows.append("t=\(i)s Sig \(sigs) packets=\(inWindow.count) peak=\(inWindow.map(\.peak).max() ?? 0)")
            }
        }

        var classification: Classification {
            let quiet = quietWith + quietWithout
            let anyPackets = quietWith + openWith > 0
            if !anyPackets && openWith + openWithout == 0 { return .inconclusive }
            // Never Sig == 0 at both ends of a window: nothing says what happens in quiet.
            if quiet == 0 { return .inconclusive }
            if quiet > 0, quietWith > 0, Double(quietWith) >= 0.8 * Double(quiet) { return .continuous }
            if quiet > 0, openWith > 0, Double(quietWithout) >= 0.8 * Double(quiet) { return .squelchGated }
            return .mixed
        }

        /// Enough evidence to stop capturing early.
        var conclusive: Bool {
            switch classification {
            case .continuous: quietWith >= 10
            case .squelchGated: quietWithout >= 10 && openWith >= 2
            default: false
            }
        }
    }

    @Test func rtpCharacteristicsAndSecondSession() async throws {
        let target = try Self.target()
        let maxSeconds = 60, minSeconds = 20
        try await Self.waitOutCooldown(target, label: "1")

        // Session 1: capture up to 60 s while sampling GSI once per second, GET_PARAMETER every
        // 15 s and once at the end.
        let (first, firstOutcome) = await Self.withAudioSession(target, label: "1", limit: .seconds(100)) {
            rtsp, _, recorder, playedAt in
            let scanner = ScannerClient(transport: UDPTransport(host: target.ip, port: target.udpPort))
            var samples: [Int?] = []
            var keepalives = 0
            var failure: (any Error)?
            do {
                try await scanner.connect()
                for second in 0...maxSeconds {
                    try await Task.sleep(until: playedAt + .seconds(second), clock: .continuous)
                    samples.append(try await scanner.scannerInfo().signalBars)
                    if second > 0, second % 15 == 0 {
                        try await rtsp.keepalive()
                        keepalives += 1
                    }
                    if second >= minSeconds,
                       Windows(samples: samples, records: recorder.snapshot, playedAt: playedAt).conclusive {
                        break
                    }
                }
                try await rtsp.keepalive()
                keepalives += 1
            } catch {
                failure = error
            }
            await scanner.disconnect()  // read-only; no push was started
            if let failure { throw failure }
            return (samples, recorder.snapshot, keepalives, playedAt)
        }

        let (samples, records, keepalives, playedAt) = try first.get()
        let windows = Windows(samples: samples, records: records, playedAt: playedAt)
        let classification = windows.classification
        Self.report(records: records, outcome: firstOutcome, keepalives: keepalives,
                    seconds: max(0, samples.count - 1), playedAt: playedAt)
        for row in windows.rows { print("Audio[1]: \(row)") }
        print("Audio[1]: windows quiet(Sig 0) with packets \(windows.quietWith), without \(windows.quietWithout);"
            + " open(Sig>0) with packets \(windows.openWith), without \(windows.openWithout)")
        print("Audio[1]: CLASSIFICATION \(classification.rawValue)")

        let sawSignal = samples.contains { ($0 ?? 0) > 0 }
        if sawSignal || !records.isEmpty {
            #expect(!records.isEmpty, "Sig > 0 was seen but session 1 received no RTP packets")
        }
        #expect(firstOutcome.teardownStatuses == [200])
        #expect(firstOutcome.unreleasedSessions.isEmpty)
        #expect(records.allSatisfy { $0.payloadType == 0 })
        // STOP rule: only open the second session if the first was clean.
        try #require(firstOutcome.teardownStatuses == [200] && (records.count > 0 || !sawSignal),
                     "session 1 not clean; second session skipped")

        // Session 2: after the reconnect cooldown (never right after session 1), about 3 s, then
        // TEARDOWN.
        try await Self.waitOutCooldown(target, label: "2")
        let (second, secondOutcome) = await Self.withAudioSession(target, label: "2", limit: .seconds(10)) {
            _, _, recorder, playedAt in
            try await Task.sleep(until: playedAt + .seconds(3), clock: .continuous)
            return recorder.snapshot
        }
        let secondRecords = try second.get()
        print("Audio[2]: packets in ~3 s: \(secondRecords.count),"
            + " peak>0 packets: \(secondRecords.filter { $0.peak > 0 }.count),"
            + " dropped wrong-source \(secondOutcome.droppedWrongSource), malformed \(secondOutcome.droppedMalformed)")
        #expect(secondOutcome.teardownStatuses == [200])
        #expect(secondOutcome.unreleasedSessions.isEmpty)
        #expect(secondRecords.allSatisfy { $0.payloadType == 0 })
        if classification == .continuous {
            #expect(!secondRecords.isEmpty, "continuous stream, but session 2 received no packets")
        }
    }

    private static func report(records: [Record], outcome: SessionOutcome, keepalives: Int,
                               seconds: Int, playedAt: ContinuousClock.Instant) {
        func histogram<K: Hashable & Comparable>(_ values: [K]) -> String {
            Dictionary(grouping: values, by: { $0 }).map { ($0.key, $0.value.count) }
                .sorted { $0.0 < $1.0 }.map { "\($0.0)×\($0.1)" }.joined(separator: " ")
        }
        func ms(_ d: Duration) -> Double {
            Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        }

        print("Audio[1]: packets \(records.count) in \(seconds) s;"
            + " dropped wrong-source \(outcome.droppedWrongSource), malformed \(outcome.droppedMalformed)")
        print("Audio[1]: session timeout \(outcome.sessionTimeout.map { "\($0) s" } ?? "none"),"
            + " GET_PARAMETER ok \(keepalives)×")
        guard let start = records.first?.receivedAt, let end = records.last?.receivedAt else {
            print("Audio[1]: no packets")
            return
        }
        print("Audio[1]: first packet \(String(format: "%.0f", ms(start - playedAt))) ms after PLAY reply")
        let span = ms(end - start) / 1000
        print("Audio[1]: first-to-last span \(String(format: "%.2f", span)) s,"
            + " rate \(String(format: "%.1f", span > 0 ? Double(records.count - 1) / span : 0)) packets/s")
        print("Audio[1]: payload types \(histogram(records.map { Int($0.payloadType) }))")
        print("Audio[1]: payload bytes \(histogram(records.map(\.payloadBytes)))")
        print("Audio[1]: marker bits set \(records.filter(\.marker).count)")
        let ssrcs = Set(records.map(\.ssrc))
        print("Audio[1]: SSRC \(ssrcs.count == 1 ? "constant" : "changes (\(ssrcs.count) values)"),"
            + " \(ssrcs.contains(0) ? "zero present" : "nonzero")")

        var tracker = RTPSequenceTracker()
        for record in records { _ = tracker.observe(record.sequence) }
        print("Audio[1]: sequence received \(tracker.received) lost \(tracker.lost)"
            + " duplicates \(tracker.duplicates) reordered \(tracker.reordered)")

        let pairs = zip(records, records.dropFirst())
        let steps = pairs.filter { $1.sequence == $0.sequence &+ 1 }.map { Int64($1.timestamp &- $0.timestamp) }
        print("Audio[1]: timestamp step (consecutive seq) \(histogram(steps))")
        let gaps = pairs.map { ms($1.receivedAt - $0.receivedAt) }.sorted()
        if !gaps.isEmpty {
            let median = gaps[gaps.count / 2]
            let p95 = gaps[min(gaps.count - 1, Int(Double(gaps.count) * 0.95))]
            print("Audio[1]: inter-arrival ms median \(String(format: "%.1f", median))"
                + " p95 \(String(format: "%.1f", p95)) max \(String(format: "%.1f", gaps.last ?? 0))"
                + " gaps>100ms \(gaps.filter { $0 > 100 }.count) gaps>500ms \(gaps.filter { $0 > 500 }.count)")
        }
        let silent = records.filter { $0.peak == 0 }.count
        print("Audio[1]: digitally silent packets \(silent) of \(records.count);"
            + " peak histogram (log2 buckets) \(histogram(records.map { $0.peak == 0 ? 0 : Int(log2(Double($0.peak))) + 1 }))")

    }
}
