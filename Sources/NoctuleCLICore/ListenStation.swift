// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleStore

/// What `listen --station` does with the station it names (Plan 19; line-in design §7).
public enum ListenStationPlan: Equatable, Sendable {
    /// A network station: RTSP from its address, with its reconnect wait after a clean close.
    case network(AudioTarget, RTSPCooldownPolicy)
    /// A USB station with an audio input: that input alone. No serial port, no station lock, no
    /// scanner traffic, no RTSP and no cooldown record.
    case lineIn(LineInConfig)
    /// Nothing to listen to: print `line` and exit with `exitCode`.
    case refused(line: String, exitCode: Int32)
}

/// `listen --station`'s decisions and copy.
public enum ListenStation {
    public static let addressConflictLine = "listen: --station can't be combined with --host or --rtsp-port"
    public static let meterNeedsLineInLine = "listen: --meter needs a line-in station"

    public static func noAudioInputLine(stationName: String) -> String { "listen: \(stationName) has no audio input" }
    public static func noAddressLine(stationName: String) -> String { "listen: \(stationName) has no address" }
    /// A line-in that has streamed and then fails: the run waits for it, as `log` does.
    public static func failedWaitingLine(_ reason: String) -> String { "audio: \(reason); waiting" }

    /// What `station` (with its device settings) gives `listen`. A network station gives its host, its
    /// RTSP port, its UDP port for the failure probe (`--port` still wins) and its reconnect wait after
    /// a clean close (`--reconnect-cooldown` still wins), the full value staying 120 s unless the
    /// mock-only `--cooldown-seconds` sets it. `--meter` needs a line-in. A USB station gives its
    /// saved audio input, or nothing.
    public static func plan(station: Station, device: StationDeviceSettings, invocation: CLIInvocation) -> ListenStationPlan {
        let meter: Bool
        if case .listen(_, _, _, _, let m) = invocation.command { meter = m } else { meter = false }
        switch station.connection.transport {
        case .network:
            if meter { return .refused(line: meterNeedsLineInLine, exitCode: 2) }
            let host = (station.connection.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !host.isEmpty else { return .refused(line: noAddressLine(stationName: station.name), exitCode: 1) }
            let target = AudioTarget(host: host, rtspPort: station.connection.rtspPort,
                                     controlPort: invocation.port ?? station.connection.udpPort)
            let policy = ListenFormat.cooldownPolicy(
                cooldownSeconds: invocation.cooldownSeconds,
                reconnectCooldown: invocation.reconnectCooldown ?? station.connection.reconnectCooldownSeconds)
            return .network(target, policy)
        case .usbSerial, .bluetooth:
            guard let lineIn = device.lineIn else {
                return .refused(line: noAudioInputLine(stationName: station.name), exitCode: 1)
            }
            return .lineIn(lineIn)
        }
    }
}

/// The status of a `listen --station` run on a line-in: which line each state of the source prints,
/// whether the run must end, and the meter, drawn only while the input streams.
public struct LineInListenStatus: Sendable {
    public enum Outcome: Equatable, Sendable {
        case none
        /// A status line for stderr.
        case print(String)
        /// The input can't be opened (denied, or failing before it ever streamed): print the line and exit 1.
        case fail(String)
    }

    private let config: LineInConfig
    private var meter = LineInTextMeter()
    private var last: LineInState?
    /// The input has streamed at least once in this run.
    public private(set) var hasStreamed = false

    public init(config: LineInConfig) { self.config = config }

    public var isStreaming: Bool {
        if case .streaming = last { return true }
        return false
    }

    /// A state of the source. `.streaming` prints `audio: line-in <name> (<channel>)` and `.missing`
    /// the waiting line, once per change (the run goes on: the source watches for the input and
    /// streams again when it is back). `.denied` ends the run, and so does `.failed` before the input
    /// has ever streamed (the kill-switch, an input that can't be opened); after that, `.failed` is a
    /// wait as `log` treats it (`audio: <reason>; waiting`, once per change: the source keeps
    /// watching the input and starts it again, as after a replug). Leaving `.streaming` drops the
    /// meter, so nothing held from before an unplug is shown after it.
    @discardableResult
    public mutating func handle(_ state: LineInState) -> Outcome {
        let changed = state != last
        if isStreaming, changed { meter = LineInTextMeter() }
        last = state
        switch state {
        case .streaming:
            hasStreamed = true
            return changed ? .print(StationCLI.lineInLine(config)) : .none
        case .missing(let name):
            return changed ? .print("audio: line-in \"\(name)\" isn't connected; waiting") : .none
        case .denied:
            return .fail("audio: failed: \(StationCLI.terminalDeniedText)")
        case .failed(let reason):
            guard hasStreamed else { return .fail("audio: failed: \(reason)") }
            return changed ? .print(ListenStation.failedWaitingLine(reason)) : .none
        case .starting, .stopped:
            return .none
        }
    }

    /// A level of the source; ignored unless the input is streaming.
    public mutating func handle(_ level: LineInLevel) {
        guard isStreaming else { return }
        meter.update(level)
    }

    /// The meter's line at `now`, or nil while the input isn't streaming.
    public func meterLine(at now: ContinuousClock.Instant) -> String? {
        isStreaming ? meter.line(at: now) : nil
    }
}

/// What to write to stderr for the meter and the status lines beside it. On a terminal the meter
/// is redrawn in place (`\r`, the line cleared after it, no newline), and a status line first clears
/// the meter's line; into a file or a pipe each is a line of its own.
public struct MeterOutput: Sendable {
    public let isTerminal: Bool
    /// A meter line is on the terminal with no newline after it.
    private var meterShown = false

    public init(isTerminal: Bool) { self.isTerminal = isTerminal }

    public mutating func meter(_ line: String) -> String {
        guard isTerminal else { return line + "\n" }
        meterShown = true
        return "\r" + line + "\u{1B}[K"
    }

    public mutating func status(_ line: String) -> String {
        guard isTerminal, meterShown else { return line + "\n" }
        meterShown = false
        return "\r\u{1B}[K" + line + "\n"
    }

    /// At the end of the run: a newline after a meter still drawn in place, so the shell's prompt
    /// starts on a line of its own.
    public mutating func finish() -> String {
        guard isTerminal, meterShown else { return "" }
        meterShown = false
        return "\n"
    }
}
