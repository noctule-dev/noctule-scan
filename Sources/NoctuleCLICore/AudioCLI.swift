// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleDevConfig

/// Where `listen` and `restart` reach the scanner.
public struct AudioTarget: Equatable, Sendable {
    /// The RTSP host and the RTSP cooldown key: `--host`, else `SCANNER_IP`, else `SCANNER_HOST`.
    public var host: String
    /// `--rtsp-port`, else the config's `SCANNER_RTSP_PORT`, else 554.
    public var rtspPort: UInt16
    /// The UDP control port for the `MDL` probe and `restart`: `--port`, else the config's, else 50536.
    public var controlPort: UInt16

    public init(host: String, rtspPort: UInt16, controlPort: UInt16) {
        self.host = host; self.rtspPort = rtspPort; self.controlPort = controlPort
    }
}

/// `--host` wins (with the config's ports still applying when a config exists); otherwise the
/// dev config's `SCANNER_IP`, falling back to its `SCANNER_HOST`. nil when there's no address.
///
/// The scanner's RTSP server works with an IP-literal URL, and the cooldown store is keyed by
/// IP literal, so `SCANNER_IP` is preferred over the host name.
public func resolveAudioTarget(invocation: CLIInvocation, searchingFrom start: URL) -> AudioTarget? {
    let url = DevScannerConfig.defaultURL(searchingUpFrom: start)
    let config = url.flatMap { try? DevScannerConfig.load(from: $0) }
    let host: String
    if let flag = invocation.host {
        host = flag
    } else if let url, let config {
        host = scannerIP(in: url) ?? config.host
    } else {
        return nil
    }
    return AudioTarget(host: host,
                       rtspPort: invocation.rtspPort ?? config?.rtspPort ?? 554,
                       controlPort: invocation.port ?? config?.port ?? 50536)
}

/// `SCANNER_IP` from the env file, if set and non-empty.
private func scannerIP(in url: URL) -> String? {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    for raw in text.components(separatedBy: .newlines) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "="),
              line[..<eq].trimmingCharacters(in: .whitespaces) == "SCANNER_IP" else { continue }
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
    return nil
}

/// stderr and stdout lines for `noctule listen`.
public enum ListenFormat {
    /// `listen`'s reconnect policy: the full value (after an unclean close) is 120 s, or the
    /// mock-only `--cooldown-seconds`; the clean-close value is `--reconnect-cooldown` (default
    /// 120), clamped to the full one.
    public static func cooldownPolicy(cooldownSeconds: Double?, reconnectCooldown: Int?) -> RTSPCooldownPolicy {
        let full = Duration.milliseconds(Int64(((cooldownSeconds ?? 120) * 1000).rounded()))
        return RTSPCooldownPolicy(full: full, afterCleanClose: .seconds(reconnectCooldown ?? 120))
    }

    /// The line for a state change, or nil for states that aren't reported.
    public static func stateLine(_ state: AudioSessionState) -> String? {
        switch state {
        case .streaming: "audio: streaming"
        case .recovering(let attempt): "audio: recovering (attempt \(attempt))"
        case .failed(let message): "audio: failed: \(message)"
        case .idle, .starting, .stopped: nil
        }
    }

    public static func statsLine(_ stats: AudioStats) -> String {
        "packets \(stats.packets)  lost \(stats.lost)  recoveries \(stats.recoveries)"
    }

    /// `remaining` is rounded up to whole seconds.
    public static func waitingLine(remaining: Duration) -> String {
        let c = remaining.components
        let seconds = max(1, Int(c.seconds) + (c.attoseconds > 0 ? 1 : 0))
        return "audio: waiting \(seconds) s before reconnecting (scanner cooldown)"
    }

    public static func hintLine(_ hint: RestartHint) -> String {
        switch hint {
        case .canRestart: "audio: the scanner's audio isn't responding; run 'noctule restart' to restart it"
        case .powerCycleNeeded: "audio: Scanner not responding on the network. Power-cycle it."
        }
    }

    public static func unreleasedLine(count: Int) -> String {
        "audio: \(count) session(s) could not be closed; the scanner may need a restart"
    }

    /// A plain message for a failed initial start.
    public static func startFailure(_ error: any Error, host: String, port: UInt16) -> String {
        let reason: String
        switch error {
        case RTSPError.closed, RTSPError.timeout(method: "CONNECT"):
            reason = "couldn't connect to the scanner's audio server at \(host):\(port)"
        case RTSPError.timeout(let method):
            reason = "the scanner's audio server didn't answer \(method)"
        case RTSPError.unexpectedStatus(let code, let text):
            reason = "the scanner's audio server answered \(code) \(text)"
        case AudioSessionError.unsupportedPayloadType(let type):
            reason = "the scanner's audio uses an unsupported format (RTP payload type \(type))"
        default:
            reason = "couldn't start the scanner's audio: \(error)"
        }
        return "audio: failed: \(reason)"
    }
}

/// Prompt and outcome text for `noctule restart`.
public enum RestartFormat {
    /// Printed after a successful restart: reviving a wedged audio server with `MSM,1` is an
    /// assumption, untested on hardware (protocol notes §8.8).
    public static let unverifiedRevivalNote =
        "restart: note: whether a restart revives a wedged audio server is unverified; if listen fails, power-cycle the scanner"

    public static func prompt(host: String) -> String { "Restart the scanner at \(host)? [y/N] " }

    /// True for "y" or "yes" (any case, surrounding spaces ignored).
    public static func isConfirmation(_ reply: String?) -> Bool {
        guard let reply else { return false }
        return ["y", "yes"].contains(reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// The outcome line and whether it counts as success.
    public static func outcome(_ outcome: RestartOutcome, seconds: Double, timeoutSeconds: Int) -> (line: String, success: Bool) {
        switch outcome {
        case .restarted:
            ("restart: the scanner is back after \(String(format: "%.1f", seconds)) s", true)
        case .notAccepted(let reason):
            ("restart: the scanner refused the restart (\(reason))", false)
        case .didNotComeBack:
            ("restart: the scanner didn't answer within \(timeoutSeconds) s after the restart; it may need a power cycle", false)
        }
    }
}
