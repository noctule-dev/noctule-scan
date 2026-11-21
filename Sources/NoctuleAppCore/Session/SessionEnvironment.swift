// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit
import NoctuleStore

/// Everything a `StationSession` needs from the outside world. Every path is injectable (tests use
/// temporary directories and an in-memory cooldown store; never `standard()`).
public struct SessionEnvironment: Sendable {
    public var settings: any SettingsStore
    /// Holds `stations.json`, `device.json` and `Stations/<uuid>/` (hit log, runner lock).
    public var settingsDirectory: URL
    /// Recordings go to `<recordingsRoot>/<station name>/` unless the device settings override it.
    public var recordingsRoot: URL
    /// The RTSP reconnect cooldown record, shared with the CLI (`FileRTSPCooldownStore`).
    public var cooldownStore: any RTSPCooldownStore
    /// The *full* reconnect cooldown, after an unclean close (120 s; `NOCTULE_COOLDOWN_SECONDS`
    /// shortens it for mock runs only). `StationSession.start()` combines it with the station's
    /// clean-close setting (`StationConnection.reconnectCooldownPolicy(full:)`) and puts that policy
    /// in the runner's audio config, so the session's wait and the AudioSession's own check always
    /// agree. Never shorten the full cooldown against real hardware.
    public var cooldown: Duration
    public var makeTransport: @Sendable (String, UInt16) -> any ScannerTransport
    public var audioConfig: AudioSessionConfig
    public var makeAudioOutput: @Sendable () -> any AudioOutput
    /// Where a USB station's line-in is played (line-in design §5.6: a smaller jitter buffer than
    /// the SDS200's). `makeAudioOutput` unless the caller gives another.
    public var makeLineInAudioOutput: @Sendable () -> any AudioOutput
    /// Control retry backoff after wake: 5, 10, 20, 30 s, then the last value repeating.
    public var reconnectBackoff: [Duration]
    /// How long `restartScanner()` waits for the scanner to come back (`ScannerRestart.perform`).
    public var restartTiming: ScannerRestartTiming
    /// Test-only (`NOCTULE_TEST_PRESENT_SHEET`): each station window presents a sheet once its
    /// session is open, so the integration tests can check that a signal still quits.
    public var presentsTestSheet = false
    /// The Uniden serial ports a USB station with no saved port may use (SDS150 design §4.3).
    /// Empty by default, so nothing below the app shell finds a scanner by itself (§13 L): only
    /// `AppDelegate` passes the system's listing, to `standard(makeAudioOutput:serialPorts:)`, and
    /// `applyingOverrides` then applies `USBDetection`'s rule (the kill-switch, and no system
    /// listing with a private `NOCTULE_SETTINGS_DIR`).
    public var serialPorts: any SerialPortListing = FixedSerialPortListing.empty
    /// The interval of a USB scanner's push keep-alive in place of its model's (the runner's
    /// `keepAliveInterval`); nil keeps the model's. Tests only (`NOCTULE_TEST_KEEPALIVE_SECONDS`,
    /// with a private settings directory and the kill-switch).
    public var keepAliveInterval: Duration? = nil
    /// How often a USB station whose scanner went away looks for its port (the runner's
    /// `portPollInterval`).
    public var portPollInterval: Duration = .seconds(1)
    /// How often a USB station's battery is read (`GCS`), on a model that reports it.
    public var batteryPollInterval: Duration = .seconds(60)
    /// How often an open `StationSession.quickKeys` re-reads the quick-key states (design §5.4:
    /// about 2 s); tests shorten it.
    public var quickKeysPollInterval: Duration = .seconds(2)
    /// Every warning a session adds to its `warnings`, with the station's name, as it is added.
    /// The app writes each to stderr (`SessionWarningLog.line`); nil: nothing but the window.
    public var onWarning: (@Sendable (_ station: String, _ text: String) -> Void)? = nil
    /// Makes a USB station's line-in source (line-in design §5.4); nil: no station has a line-in.
    /// Nil by default, so nothing below the app shell opens an audio input by itself: only
    /// `AppDelegate` passes the system's (`EngineLineInSource`, which this library can't name), and
    /// `applyingOverrides` then applies `LineInDetection`'s rule (the kill-switch makes every source
    /// a `DisabledLineInSource`).
    public var lineInSources: LineInSourceFactory? = nil
    /// The Mac's audio inputs, for the station editor. Empty by default; the app shell passes Core
    /// Audio's (`CoreAudioInputs`), and the kill-switch empties it again.
    public var audioInputs: any AudioInputListing = FixedAudioInputListing.empty
    /// Tests only (`NOCTULE_TEST_LINE_IN`, with a private settings directory and the kill-switch):
    /// the path of `noctule-mock-scanner --line-out`'s stream, for the app shell to build its line-in
    /// factory from (a `PipeLineInSource` on it). Nil otherwise.
    public var lineInTestStream: String? = nil

    public init(settings: any SettingsStore, settingsDirectory: URL, recordingsRoot: URL,
                cooldownStore: any RTSPCooldownStore, cooldown: Duration = .seconds(120),
                makeTransport: @escaping @Sendable (String, UInt16) -> any ScannerTransport = { UDPTransport(host: $0, port: $1) },
                audioConfig: AudioSessionConfig = .init(),
                makeAudioOutput: @escaping @Sendable () -> any AudioOutput = { SilentAudioOutput() },
                makeLineInAudioOutput: (@Sendable () -> any AudioOutput)? = nil,
                reconnectBackoff: [Duration] = [5, 10, 20, 30].map(Duration.seconds),
                restartTiming: ScannerRestartTiming = .init()) {
        self.settings = settings
        self.settingsDirectory = settingsDirectory
        self.recordingsRoot = recordingsRoot
        self.cooldownStore = cooldownStore
        self.cooldown = cooldown
        self.makeTransport = makeTransport
        self.audioConfig = audioConfig
        self.makeAudioOutput = makeAudioOutput
        self.makeLineInAudioOutput = makeLineInAudioOutput ?? makeAudioOutput
        self.reconnectBackoff = reconnectBackoff
        self.restartTiming = restartTiming
    }

    /// `~/Library/Application Support/NoctuleScan/`, shared with the CLI.
    public static var standardSettingsDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("NoctuleScan", isDirectory: true)
    }

    /// The real locations, shared with the `noctule` CLI (AGENTS.md):
    /// `~/Library/Application Support/NoctuleScan/`, `~/Music/Noctule Scan/`, and the cooldown
    /// record at `~/Library/Caches/NoctuleScan/rtsp-cooldown.json`. The app is unsandboxed, so
    /// these are the user's own folders, not a container's. The cooldown path comes from
    /// `FileRTSPCooldownStore.defaultURL`, the CLI's own constant. The caller must pass its real
    /// audio output (no silent default, so the app can't ship mute by accident), and its serial
    /// port listing (no default either: the app passes the system's, `IOKitSerialPortFinder`, which
    /// this library can't name; `applyingOverrides` decides whether it is ever asked). The line-in
    /// pieces are the shell's too (`lineInSources`, `audioInputs`, `makeLineInAudioOutput`); left
    /// out, no station has a line-in.
    public static func standard(makeAudioOutput: @escaping @Sendable () -> any AudioOutput,
                                serialPorts: any SerialPortListing,
                                lineInSources: LineInSourceFactory? = nil,
                                audioInputs: any AudioInputListing = FixedAudioInputListing.empty,
                                makeLineInAudioOutput: (@Sendable () -> any AudioOutput)? = nil) -> SessionEnvironment {
        let settingsDirectory = standardSettingsDirectory
        let recordingsRoot = URL.musicDirectory.appendingPathComponent("Noctule Scan", isDirectory: true)
        var environment = SessionEnvironment(settings: LocalSettingsStore(directory: settingsDirectory),
                                             settingsDirectory: settingsDirectory, recordingsRoot: recordingsRoot,
                                             cooldownStore: FileRTSPCooldownStore(url: FileRTSPCooldownStore.defaultURL),
                                             makeAudioOutput: makeAudioOutput,
                                             makeLineInAudioOutput: makeLineInAudioOutput)
        environment.serialPorts = serialPorts
        environment.lineInSources = lineInSources
        environment.audioInputs = audioInputs
        return environment
    }
}

/// `ScannerRestart.perform`'s waits. The defaults are the CLI's (`noctule restart`); tests shorten them.
public struct ScannerRestartTiming: Sendable, Equatable {
    /// How long to wait for `MDL` to answer again after `MSM,1`.
    public var timeout: Duration
    public var pollInterval: Duration
    /// An answer counts as "back" after this long even if the scanner never went quiet.
    public var silenceGrace: Duration
    public var pollTimeout: Duration

    public init(timeout: Duration = .seconds(90), pollInterval: Duration = .seconds(2),
                silenceGrace: Duration = .seconds(15), pollTimeout: Duration = .seconds(1)) {
        self.timeout = timeout; self.pollInterval = pollInterval
        self.silenceGrace = silenceGrace; self.pollTimeout = pollTimeout
    }
}
