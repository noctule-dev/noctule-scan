// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import NoctuleStore

/// The exact user-facing copy the plan fixes (constraints, "Copy").
enum ScannerCopy {
    static let audioFailed = "Scanner audio isn't responding"
    static func restartTitle(host: String) -> String { "Restart the scanner at \(host)?" }
    static let restartButton = "Restart"
    static let cancelButton = "Cancel"
    static let restartNote =
        "Whether a restart revives a stuck audio server is unverified; if audio stays off, power-cycle the scanner."
    static let powerCycleHint = "The scanner isn't answering on the network either. Power-cycle it to bring audio back."
    static let restarting = "Restarting scanner…"
}

/// One status-bar indicator: text, an SF Symbol, a tone for its color, and its tooltip when that
/// isn't the text (`help`).
struct StatusIndicator: Equatable {
    enum Tone: Equatable { case neutral, busy, good, warning, bad }
    var text: String
    var symbol: String
    var tone: Tone
    var help: String? = nil
}

/// The window's connection, audio and logging indicators.
enum ScannerIndicators {
    static func phase(_ phase: SessionPhase, stationName: String) -> StatusIndicator {
        switch phase {
        case .idle:
            StatusIndicator(text: "Not connected", symbol: "circle.dashed", tone: .neutral)
        case .inUse(let pid):
            StatusIndicator(text: pid.map { "\(stationName) is open in another Noctule Scan process (pid \($0))." }
                                ?? "\(stationName) is open in another Noctule Scan process.",
                            symbol: "lock.fill", tone: .warning)
        case .scannerInUse(let other):
            StatusIndicator(text: StationSession.scannerInUseMessage(otherStation: other),
                            symbol: "lock.fill", tone: .warning)
        case .waitingForCooldown(let seconds):
            StatusIndicator(text: "Waiting for scanner cooldown, \(seconds) s", symbol: "hourglass", tone: .busy)
        case .waitingForScanner:
            // The hint goes in the banner (`ProblemBannerContent`); the indicator only says what is happening.
            StatusIndicator(text: "Waiting for the scanner", symbol: "cable.connector", tone: .busy)
        case .connecting:
            StatusIndicator(text: "Connecting…", symbol: "antenna.radiowaves.left.and.right", tone: .busy)
        case .connected(let model, let firmware):
            StatusIndicator(text: "Connected — \(model), firmware \(firmware)",
                            symbol: "antenna.radiowaves.left.and.right", tone: .good)
        case .noAnswer(let message):
            StatusIndicator(text: message, symbol: "exclamationmark.triangle.fill", tone: .bad)
        case .stopping:
            StatusIndicator(text: "Disconnecting…", symbol: "antenna.radiowaves.left.and.right.slash", tone: .busy)
        case .stopped:
            StatusIndicator(text: "Disconnected", symbol: "antenna.radiowaves.left.and.right.slash", tone: .neutral)
        }
    }

    static func audio(_ state: AudioSessionState, listening: Bool) -> StatusIndicator {
        switch state {
        case .idle, .stopped:
            StatusIndicator(text: "Audio off", symbol: "speaker.slash", tone: .neutral)
        case .starting:
            StatusIndicator(text: "Audio starting…", symbol: "speaker", tone: .busy)
        case .streaming:
            listening
                ? StatusIndicator(text: "Listening", symbol: "speaker.wave.2.fill", tone: .good)
                : StatusIndicator(text: "Audio streaming, not playing", symbol: "speaker.slash.fill", tone: .neutral)
        case .recovering(let attempt):
            StatusIndicator(text: "Audio recovering (attempt \(attempt))", symbol: "arrow.triangle.2.circlepath",
                            tone: .warning)
        case .failed:
            StatusIndicator(text: ScannerCopy.audioFailed, symbol: "speaker.badge.exclamationmark", tone: .bad)
        }
    }

    /// In the audio indicator's place for a station without audio (a USB station; SDS150 design §7.2).
    static let noAudioOverUSB = StatusIndicator(text: "No audio over USB", symbol: "speaker.slash", tone: .neutral)

    /// In the audio indicator's place for a USB station with a line-in (line-in design §6.2), from its
    /// state (nil before the first): `Listening · <device>` or `Not listening` while it streams,
    /// `Line-in not connected` while the input is missing (the runner's warning as the help), and
    /// `Line-in blocked` when the system won't allow audio input or the input can't start (the
    /// kill-switch's disabled source among them; ruling R13), with the reason as the help.
    static func lineIn(_ state: LineInState?, listening: Bool, deviceName: String) -> StatusIndicator {
        switch state {
        case .streaming?:
            listening
                ? StatusIndicator(text: "Listening · \(deviceName)", symbol: "speaker.wave.2.fill", tone: .good)
                : StatusIndicator(text: "Not listening", symbol: "speaker.slash.fill", tone: .neutral)
        case .missing?:
            StatusIndicator(text: "Line-in not connected", symbol: "cable.connector", tone: .warning,
                            help: StationRunner.lineInMissingMessage(deviceName: deviceName))
        case .denied?:
            StatusIndicator(text: "Line-in blocked", symbol: "speaker.badge.exclamationmark", tone: .bad,
                            help: StationRunner.lineInDeniedMessage)
        case .failed(let reason)?:
            StatusIndicator(text: "Line-in blocked", symbol: "speaker.badge.exclamationmark", tone: .bad, help: reason)
        case .starting?:
            StatusIndicator(text: "Line-in starting…", symbol: "speaker", tone: .busy)
        case .stopped?, nil:
            StatusIndicator(text: "Line-in off", symbol: "speaker.slash", tone: .neutral)
        }
    }

    /// The scanner's battery from `GCS` (SDS150 design §7.2), nil without a reading: `Battery <n>%`,
    /// plus `, charging` while charging (or recharging) and `, full` when full, nothing more for any
    /// other state or a `CST` code Uniden's spec doesn't list (the owner's unit reports 8 on USB
    /// power; plan D9). Warns at 15 % or less unless charging.
    static func battery(_ status: ChargeStatus?) -> StatusIndicator? {
        guard let status else { return nil }
        let percent = status.percent
        let charging = status.state == .charging || status.state == .recharge
        let full = status.state == .full
        let text = "Battery \(percent)%" + (charging ? ", charging" : full ? ", full" : "")
        let symbol = if charging || full {
            "battery.100percent.bolt"
        } else if percent >= 88 {
            "battery.100percent"
        } else if percent >= 63 {
            "battery.75percent"
        } else if percent >= 38 {
            "battery.50percent"
        } else if percent >= 13 {
            "battery.25percent"
        } else {
            "battery.0percent"
        }
        return StatusIndicator(text: text, symbol: symbol, tone: percent <= 15 && !charging ? .warning : .neutral)
    }

    /// Logging runs only while the session is connected here.
    static func logging(paused: Bool, connected: Bool) -> StatusIndicator {
        guard connected else { return StatusIndicator(text: "Not logging", symbol: "record.circle", tone: .neutral) }
        return paused
            ? StatusIndicator(text: "Logging paused", symbol: "pause.circle.fill", tone: .warning)
            : StatusIndicator(text: "Logging", symbol: "record.circle", tone: .good)
    }
}
#endif
