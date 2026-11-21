// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import SwiftUI

/// Mac-native controls under the front panel: Hold (a menu of the soft keys labelled SYSTEM,
/// DEPT and CHANNEL), Avoid, Listen (playback on or off), Logging (pause or resume logging and
/// recording; the designer's "Record"), and the app's own volume. While the scanner is in a menu,
/// Hold and Avoid are off (Avoid leaves the menu on the scanner; remote menus design §5.3); the
/// Scanner view's keypad Avoid still works, as on the radio. A station without audio (a USB
/// station; SDS150 design §7.2) has no Listen and no app volume. A USB station with a line-in has
/// both (line-in design §6.2), off while its input is blocked (`canListen`); its meter isn't here
/// (`LineInMeterPlacement`: beside VOL in the Scanner view, a row of its own in the Mac-style view).
/// Under the bar, the line-in's notices (`LineInNoticesView`): the clip warning with Volume −1, and
/// Open Privacy Settings.
struct MacControlsBar: View {
    @Bindable var session: StationSession

    /// Which of the bar's controls are enabled.
    struct Enablement: Equatable {
        var hold: Bool
        var avoid: Bool
        var listen: Bool
        var logging: Bool
        /// Listen and the app volume slider are shown only when true (the station has audio).
        var showsAudioControls: Bool
        /// The app volume slider, off while the station can't play (a blocked line-in).
        var appVolume: Bool

        /// `canListen` is the session's (false while a line-in is blocked).
        init(connected: Bool, canHoldAny: Bool, inMenu: Bool, hasAudio: Bool, canListen: Bool = true) {
            hold = connected && canHoldAny && !inMenu
            avoid = connected && !inMenu
            listen = connected && hasAudio && canListen
            logging = connected
            showsAudioControls = hasAudio
            appVolume = hasAudio && canListen
        }
    }

    private var connected: Bool {
        if case .connected = session.phase { return true }
        return false
    }

    var body: some View {
        let enabled = Enablement(connected: connected, canHoldAny: HoldLevel.allCases.contains(where: session.canHold),
                                 inMenu: session.menu.isInMenu, hasAudio: session.hasAudio,
                                 canListen: session.canListen)
        VStack(alignment: .leading, spacing: 8) {
            bar(enabled)
            LineInNoticesView(session: session)
        }
    }

    private func bar(_ enabled: Enablement) -> some View {
        HStack(spacing: 14) {
            Menu {
                holdItem("System", .system)
                holdItem("Department", .department)
                holdItem("Channel", .channel)
            } label: {
                Label("Hold", systemImage: "pause.circle")
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(!enabled.hold)
            .tracksKeyboardFocus()
            .help("Hold on the current system, department or channel")

            Button { session.press(.avoid) } label: {
                Label("Avoid", systemImage: "nosign")
            }
            .disabled(!enabled.avoid)
            .tracksKeyboardFocus()
            .help("Press Avoid (twice for a permanent avoid, as on the scanner)")

            Divider().frame(height: 18)

            if enabled.showsAudioControls {
                Toggle(isOn: $session.listening) {
                    Label("Listen", systemImage: session.listening ? "headphones" : "headphones.slash")
                }
                .toggleStyle(.button)
                .disabled(!enabled.listen)
                .tracksKeyboardFocus()
                .help("Play the scanner's audio on this Mac")
            }

            Toggle(isOn: logging) {
                Label("Logging", systemImage: session.loggingPaused ? "pause.circle" : "record.circle")
            }
            .toggleStyle(.button)
            .disabled(!enabled.logging)
            .tracksKeyboardFocus()
            .help(enabled.showsAudioControls ? "Log hits and record transmissions" : "Log hits")

            if enabled.showsAudioControls {
                Divider().frame(height: 18)

                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: appVolume, in: 0...1)
                        .frame(width: 120)
                        .accessibilityLabel("App volume")
                        .tracksKeyboardFocus()
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .disabled(!enabled.appVolume)
                .help("This Mac's playback volume (the scanner's own volume is the VOL knob)")
            }

            Spacer(minLength: 0)
        }
        .controlSize(.regular)
    }

    private func holdItem(_ title: String, _ level: HoldLevel) -> some View {
        Button(title) { session.hold(level) }
            .disabled(!session.canHold(level))
    }

    private var logging: Binding<Bool> {
        Binding(get: { !session.loggingPaused }, set: { session.loggingPaused = !$0 })
    }

    private var appVolume: Binding<Double> {
        Binding(get: { Double(session.appVolume) }, set: { session.appVolume = Float($0) })
    }
}

/// The bottom of the window: at the leading edge the Stations button (shows the picker, leaves the
/// session running) and Disconnect (closes the window, which releases the session, and shows the
/// picker; no confirmation), then the connection, audio and logging indicators. A station without
/// audio (USB) shows its battery, when there is a reading, and "No audio over USB" in the audio
/// indicator's place; a USB station with a line-in shows the battery and the line-in's state
/// there (`ScannerIndicators.lineIn`).
struct ScannerStatusBar: View {
    let session: StationSession
    let showStations: () -> Void
    let disconnect: () -> Void

    private var connected: Bool {
        if case .connected = session.phase { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 10) {
                Button(action: showStations) {
                    Label("Stations", systemImage: StationFooterText.stationsSymbol)
                }
                .help(StationFooterText.stationsHelp)
                Button(action: disconnect) {
                    Label("Disconnect", systemImage: StationFooterText.disconnectSymbol)
                }
                .help(StationFooterText.disconnectHelp)
            }
            .buttonStyle(.borderless)
            .labelStyle(.iconOnly)
            .fixedSize()
            indicator(ScannerIndicators.phase(session.phase, stationName: session.station.name))
                .layoutPriority(1)
            Spacer(minLength: 8)
            if let latest = session.warnings.last {
                // The latest runner warning; all recent ones in the tooltip.
                Label {
                    Text(latest).truncationMode(.tail)
                } icon: {
                    Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange)
                }
                .frame(maxWidth: 320, alignment: .leading)
                .help(session.warnings.suffix(5).joined(separator: "\n"))
            }
            if let lineIn = session.lineInConfig {
                if let battery = ScannerIndicators.battery(session.battery) {
                    indicator(battery)
                }
                indicator(ScannerIndicators.lineIn(session.lineIn, listening: session.listening,
                                                   deviceName: lineIn.deviceName))
            } else if session.hasAudio {
                indicator(ScannerIndicators.audio(session.audio, listening: session.listening))
            } else {
                if let battery = ScannerIndicators.battery(session.battery) {
                    indicator(battery)
                }
                indicator(ScannerIndicators.noAudioOverUSB)
            }
            indicator(ScannerIndicators.logging(paused: session.loggingPaused, connected: connected))
        }
        .font(.callout)
        .lineLimit(1)
    }

    private func indicator(_ item: StatusIndicator) -> some View {
        Label {
            Text(item.text).truncationMode(.middle)
        } icon: {
            Image(systemName: item.symbol).foregroundStyle(Self.color(item.tone))
        }
        .help(item.help ?? item.text)
    }

    static func color(_ tone: StatusIndicator.Tone) -> Color {
        switch tone {
        case .neutral: .secondary
        case .busy: .blue
        case .good: .green
        case .warning: .orange
        case .bad: .red
        }
    }
}

/// What the problem banner says and offers, from the session's state (most pressing first):
/// a restart in progress; the station in use elsewhere (Try Again); a failed restart (Reconnect
/// only, with the advice to power-cycle); failed audio (Reconnect, plus Restart scanner only while
/// the scanner still answers on control); no answer (Reconnect). A USB station waiting for its
/// scanner (after the in-use cases) gets the hint and a Stations button, which ends the wait (SDS150
/// design §7.2). Nil: no banner.
struct ProblemBannerContent: Equatable {
    var title: String
    var detail: String?
    /// "Reconnect" or "Try Again"; both call `reconnect()`. Nil while restarting.
    var retryTitle: String?
    var offersRestart = false
    var restarting = false
    /// A Stations button that calls the window's disconnect (close the window, release the session,
    /// show the picker): the way out of a USB station's wait for its scanner.
    var offersStations = false

    static func make(phase: SessionPhase, audio: AudioSessionState, restartHint: RestartHint?,
                     lastRestartFailure: RestartOutcome?, isRestarting: Bool,
                     stationName: String) -> ProblemBannerContent? {
        if isRestarting {
            return ProblemBannerContent(title: ScannerCopy.restarting, retryTitle: nil, restarting: true)
        }
        if case .inUse = phase {
            return ProblemBannerContent(title: ScannerIndicators.phase(phase, stationName: stationName).text,
                                        detail: "Close it there, then try again.", retryTitle: "Try Again")
        }
        if case .scannerInUse = phase {
            return ProblemBannerContent(title: ScannerIndicators.phase(phase, stationName: stationName).text,
                                        detail: "Close that station's window, then try again.", retryTitle: "Try Again")
        }
        if case .waitingForScanner(let hint) = phase {
            return ProblemBannerContent(title: ScannerIndicators.phase(phase, stationName: stationName).text,
                                        detail: hint, retryTitle: nil, offersStations: true)
        }
        let audioFailed: Bool
        if case .failed = audio { audioFailed = true } else { audioFailed = false }
        if let failure = lastRestartFailure {
            let detail = switch failure {
            case .notAccepted(let reason): "The scanner didn't accept the restart (\(reason)). If audio stays off, power-cycle it."
            default: "The scanner didn't come back after the restart. Power-cycle it."
            }
            return ProblemBannerContent(title: audioFailed ? ScannerCopy.audioFailed : "The restart didn't work",
                                        detail: detail, retryTitle: "Reconnect")
        }
        if audioFailed {
            switch restartHint {
            case .canRestart:
                return ProblemBannerContent(title: ScannerCopy.audioFailed,
                                            detail: "Control still answers. Try Reconnect first; Restart scanner reboots it.",
                                            retryTitle: "Reconnect", offersRestart: true)
            case .powerCycleNeeded:
                return ProblemBannerContent(title: ScannerCopy.audioFailed, detail: ScannerCopy.powerCycleHint,
                                            retryTitle: "Reconnect")
            case nil:
                return ProblemBannerContent(title: ScannerCopy.audioFailed, detail: "Hits are still logged, without audio.",
                                            retryTitle: "Reconnect")
            }
        }
        if case .noAnswer(let message) = phase {
            return ProblemBannerContent(title: "Can't reach the scanner", detail: message, retryTitle: "Reconnect")
        }
        return nil
    }
}

/// Across the top of the window when `ProblemBannerContent` has something to say. Restart
/// scanner asks first (`confirmationDialog` with the exact copy and the station's host). Stations
/// calls `disconnect` (the window's: close it, release the session, show the picker).
struct ScannerProblemBanner: View {
    let session: StationSession
    let disconnect: () -> Void
    @State private var confirmingRestart = false

    static func content(for session: StationSession) -> ProblemBannerContent? {
        ProblemBannerContent.make(phase: session.phase, audio: session.audio, restartHint: session.restartHint,
                                  lastRestartFailure: session.lastRestartFailure, isRestarting: session.isRestarting,
                                  stationName: session.station.name)
    }

    private var host: String { (session.station.connection.host ?? "").trimmingCharacters(in: .whitespaces) }

    var body: some View {
        if let content = Self.content(for: session) {
            banner(content)
        }
    }

    private func banner(_ content: ProblemBannerContent) -> some View {
        HStack(spacing: 12) {
            if content.restarting {
                ProgressView().controlSize(.small)
                Text(content.title).font(.headline)
                Spacer()
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(content.title).font(.headline)
                    if let detail = content.detail {
                        Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if let retry = content.retryTitle {
                    Button(retry) { Task { await session.reconnect() } }
                        .disabled(session.isRestarting)
                        .tracksKeyboardFocus()
                }
                if content.offersRestart {
                    Button("Restart scanner…") { confirmingRestart = true }
                        .disabled(session.isRestarting)
                        .tracksKeyboardFocus()
                }
                if content.offersStations {
                    Button("Stations", action: disconnect)
                        .tracksKeyboardFocus()
                        .help("Stop waiting, close this window and show the Stations window")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.12))
        .confirmationDialog(ScannerCopy.restartTitle(host: host), isPresented: $confirmingRestart,
                            titleVisibility: .visible) {
            Button(ScannerCopy.restartButton) { Task { _ = await session.restartScanner() } }
            Button(ScannerCopy.cancelButton, role: .cancel) {}
        } message: {
            Text(ScannerCopy.restartNote)
        }
    }
}
#endif
