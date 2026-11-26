// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import Observation
import Synchronization
import NoctuleKit
import NoctuleStore

/// Where a `StationSession` is in its life.
public enum SessionPhase: Equatable, Sendable {
    case idle
    /// Another process (or another open of the lock in this one) runs this station.
    case inUse(pid: Int32?)
    /// Another open station in this process uses the same scanner (`SessionRegistry`: the same
    /// network address, or for a USB station the same port, either one automatic): nothing was
    /// opened. The text is `StationSession.scannerInUseMessage(otherStation:)`.
    case scannerInUse(byStation: String)
    /// Waiting out the scanner's RTSP reconnect cooldown; nothing has been sent to the scanner.
    case waitingForCooldown(secondsLeft: Int)
    /// A USB station whose scanner isn't there: not plugged in yet, or gone since. Nothing is open
    /// except, after a disconnect, the runner's bounded wait. `hint` is what to do about it.
    case waitingForScanner(hint: String)
    case connecting
    case connected(model: String, firmware: String)
    /// The start failed; the text is for the user (see `StationSession.noAnswerMessage`).
    case noAnswer(String)
    case stopping
    case stopped
}

/// The scanner's hold levels: an SDS model presses the soft key with that label, the BCD436HP
/// sends `HLD` by index.
public enum HoldLevel: Sendable, CaseIterable {
    case system, department, channel

    /// The soft-key label (`STS`), matched ignoring case and surrounding spaces.
    public var softKeyLabel: String {
        switch self {
        case .system: "SYSTEM"
        case .department: "DEPT"
        case .channel: "CHANNEL"
        }
    }

    /// The level's name in a warning.
    var holdName: String {
        switch self {
        case .system: "system"
        case .department: "department"
        case .channel: "channel"
        }
    }
}

/// One connected station, for the app: a `StationRunner` plus what the window shows (phase,
/// scanner status, the `STS` display, recent hits, warnings) and the playback toggle.
///
/// **Start** (`start()`) **of a network station**, in order: a station with no host ends at once
/// in `.noAnswer(noAddressMessage(stationName:))`, nothing opened; the registry's one session per
/// scanner (`addressConflict`; held → `.scannerInUse(byStation:)`, nothing opened); the
/// per-station lock (`StationLock`; held → `.inUse(pid:)`, nothing opened); the device settings;
/// the hit log at `Stations/<uuid>/hits.sqlite`; the RTSP reconnect cooldown (`RTSPCooldownGate`,
/// unless `saveAudio == .never`; the full `environment.cooldown` after an unclean close, the
/// station's `reconnectCooldownSeconds` clamped to it after a clean one), shown as
/// `.waitingForCooldown(secondsLeft:)` and re-read from the store about once a second, with
/// nothing sent to the scanner; then `.connecting` and `runner.start()`; `.connected` comes from
/// the runner's `.connected` event. Any runner failure (connect, `MDL`, `VER`, `PSI`, the log)
/// ends in `.noAnswer` with `noAnswerMessage(host:port:)`, after the runner has stopped, the log
/// is closed and the lock released. A failure before the runner (lock, settings, log) is
/// `.noAnswer` with its own text.
///
/// **Start of a USB station** (`usbSerial`; SDS150 design §7.2; `StationSession+USB.swift`), in
/// order: the device settings (the saved port, `usbPort`, which is the station's identity for the
/// registry's scanner check); the registry's scanner check and the station lock as above;
/// `.connecting`; the hit log; no cooldown gate and no call on the cooldown store, ever; then the
/// wait for the port: while the transport factory (on `environment.serialPorts`) finds no port
/// for the station, the phase is
/// `.waitingForScanner(hint:)` and the session looks again every `environment.portPollInterval`,
/// opening and sending nothing (a stop ends the wait at once). When the port resolves,
/// `.connecting` and `runner.start()` (the runner on that factory, with
/// `environment.keepAliveInterval`); `.connected` as above. A port that left in between
/// (`.scannerNotFound` from the runner) goes back to the wait; a busy port ends in
/// `.noAnswer(busyPortMessage(_:))`, a scanner that doesn't answer on its port (a client timeout)
/// in `.noAnswer(noAnswerUSBMessage(port:))`, any other failure in
/// `.noAnswer(usbFailureMessage(_:))`; none of them is retried after a wake
/// (`lastFailureWasNoAnswer` stays false), so the session never opens the port again by itself
/// after a failure: only Reconnect, or a start after a wake that stopped a running session, does.
/// A Bluetooth station ends in `.noAnswer(notSupportedHereMessage)` before
/// anything else, and so does a USB station where the factory answers
/// `.notSupportedOnThisDevice` (iOS), after closing what it opened. A USB station has no
/// AudioSession (`audio` stays `.idle`) and never touches the cooldown store or gate; its only
/// audio is a line-in (below), and without one it has none (`hasAudio`): no `liveAudio()` tap, no
/// playback.
///
/// **A USB scanner that goes away** (`.disconnected(hint:)` from the current runner): when the
/// runner will wait and resume (`willResume`), the key queue is stopped (queued keys dropped),
/// the display and battery loops are cancelled and awaited, pending level changes are dropped,
/// `info`, `display` and `battery` become nil, and the phase is `.waitingForScanner(hint:)`
/// (which detaches the menu); recent hits and warnings stay, and the model `MDL` named is kept.
/// The runner's `.connected` then does what it does from `.connecting`. When it won't resume (the connection never
/// delivered a push: a rejected `PSI`), the run is torn down (`runner.stop()`, the log, the lock)
/// and the phase is `.noAnswer(hint)`.
///
/// `start()` runs from `.idle`, `.inUse`, `.scannerInUse`, `.noAnswer` or `.stopped` (a fresh
/// runner each time); a second call while one is in flight waits for it. A call while a stop is
/// in flight waits for that stop first (and gives way to a later stop); one during `suspend()` is
/// left for `resume()`.
///
/// **Live state.** `info` is every push (`runner.liveStatus`). The display loop fetches `STS`
/// through `runner.control()` on `DisplayRefreshPolicy(model:)`'s schedule: at once on connect, then
/// at most once per `ModelProfile.displayRefreshInterval` (100 ms on the SDS150 and the SDS200,
/// their push interval; 1 s on every other model; a significant push change brings it forward), at
/// least every 5 s, and 150 ms after a key reply (`noteKeyReply(at:)`, fed by Task 7's key presses). It never calls
/// `stopPush()` or `disconnect()` on that shared client. On a USB scanner whose profile has
/// `supportsChargeStatus` (the SDS150; never a network station), the battery loop sends one `GCS`
/// through the same client at once on connect and then every `environment.batteryPollInterval`
/// (about once a minute): `battery` is the last reading, kept through one missed read and cleared
/// by a second in a row, and nil in every phase but `.connected`.
///
/// **Audio.** One `runner.liveAudio()` tap per run, consumed here for the whole run (it counts
/// `packets`). `listening` only routes the tap to the `AudioOutput` (a fresh stream per
/// `play`) or stops the output; it never starts or stops the runner or the RTSP session.
///
/// **A USB station's line-in** (line-in design §5.4, §6; `lineInConfig`, from the device settings
/// at start, when the environment has `lineInSources`). The runner makes and starts its source;
/// the session shows its state (`lineIn`, from the runner's `.lineIn` events), plays its chunks
/// through the same tap on `environment.makeLineInAudioOutput`, and reads `runner.liveLevels()`
/// for the meter: `lineInLevel` at most `levelRefreshInterval` apart (30 Hz; the readings between
/// are folded in, their loudest peak and any clip kept), `peakHoldDBFS` (`PeakHold`, 1.5 s), and
/// `clipLatched`, lit by any clipped reading until `clearClip()`. The meter is empty while the
/// input isn't `.streaming`. A hit that clipped (`.clipped`) becomes `clipWarning`, until
/// `dismissClipWarning()`, and its text goes to `environment.onWarning` (not to `warnings`: the
/// window shows it apart, with Volume −1, `stepScannerVolumeDown()`). The relay, the levels and
/// playback start at the run's first `.connected` and run through a wait for the scanner (a
/// resume's `.connected` doesn't start them again); only the run's teardown (a stop, a suspend, a
/// run the runner won't resume) ends them. `lineInChanged(_:)` swaps the input through
/// `runner.replaceLineIn` without touching the scanner. `canListen` is false while the input is
/// `.failed` (the kill-switch's `DisabledLineInSource` among them) or `.denied`.
///
/// **Control** (only while connected; otherwise ignored): `press(_:)` through a `KeyPressQueue`
/// on `runner.control()` (each reply feeds `noteKeyReply`), `setScannerVolume`/`setScannerSquelch`
/// (clamped to the model's range, 250 ms debounce), and `hold(_:)` via the labelled soft key.
/// Menus: `menu` (`MenuModel`) is attached to `runner.control()` on `.connected` and detached on
/// any other phase, before the stop's `PSI,0`; it gets every push, and each menu command's reply
/// (or timeout) brings the display fetch forward like a key reply.
/// After audio `.failed`, `restartHint` is set and nothing else happens: only `reconnect()` or
/// `restartScanner()` (after the user confirms) opens audio again. `suspend()`/`resume()` stop
/// for sleep and start after wake, retrying on `reconnectBackoff` while there is no answer.
///
/// **Stop** (`stop()`): idempotent, safe in every phase and while `start()` is in flight. Its
/// first step, before any await (and the first step of `suspend()`, `reconnect()`, a restart and a
/// failed run's teardown), stops the key queue: keys still queued are dropped, not sent. It
/// interrupts a cooldown wait (no scanner traffic), stops the display and battery loops (awaited,
/// so no `STS` or `GCS` follows the `PSI,0`) and playback, awaits
/// `runner.stop()` (`PSI,0`, TEARDOWN), waits for an in-flight `start()` to unwind, then closes
/// the log and releases the lock. Ends in `.stopped`, except that `.inUse`, `.scannerInUse` and
/// `.noAnswer` stay.
@MainActor @Observable
public final class StationSession {
    /// The station as of the last start, plus later changes the session doesn't need a restart for
    /// (`SessionRegistry.stationsChanged` applies key map and appearance edits through
    /// `applyLiveChanges(_:)`; the reconnect wait too, read at the next start). Name, the rest of
    /// the connection, and recording rules change only with a new session.
    public private(set) var station: Station
    @ObservationIgnored let environment: SessionEnvironment

    // `internal(set)` (not `private(set)`) where the USB start and disconnect handling in
    // `StationSession+USB.swift` write them; nothing outside this type does.
    public internal(set) var phase: SessionPhase = .idle {
        // The menu and the quick keys follow the scanner only while connected (`detach()`
        // otherwise), and there is a battery reading only while connected.
        didSet {
            if !isConnected {
                // The quick keys first: the menu's detach reports leaving the menu, which an attached
                // quick-keys model would answer with a re-check.
                quickKeys.detach()
                menu.detach()
                if battery != nil { battery = nil }
            }
        }
    }
    public private(set) var audio: AudioSessionState = .idle
    /// The input a USB station's line-in listens to: the device settings' (`StationDeviceSettings
    /// .lineIn`) as of the last start, then each `lineInChanged(_:)`. Nil for a network station, a
    /// USB station without an input, and when the environment has no `lineInSources`.
    public internal(set) var lineInConfig: LineInConfig?
    /// The line-in's state as the runner last reported it; nil while there is no line-in. After a
    /// stop, `.failed` and `.denied` stay (with their warning) until the next start; any other
    /// state becomes `.stopped`.
    public private(set) var lineIn: LineInState?
    /// The meter's reading, at most `levelRefreshInterval` apart; nil while the input isn't
    /// `.streaming`.
    public private(set) var lineInLevel: LineInLevel?
    /// The peak the meter holds (`PeakHold`, 1.5 s), in dBFS; nil with `lineInLevel`.
    public private(set) var peakHoldDBFS: Double?
    /// CLIP: lit by any clipped reading (in a hit or not), until `clearClip()`.
    public private(set) var clipLatched = false
    /// The last hit whose line-in clipped (`RunnerEvent.clipped`), until `dismissClipWarning()`.
    public private(set) var clipWarning: LoggedHit?
    public internal(set) var info: ScannerInfo?
    public internal(set) var display: DisplayModel?
    /// The scanner's battery and charger state from `GCS` (SDS150 design §7.2), read by the battery
    /// loop while connected to a USB scanner whose profile has `supportsChargeStatus`. Nil in every
    /// other phase, for every network station, and after two missed reads in a row.
    public private(set) var battery: ChargeStatus?
    /// The scanner's menu: state and actions (remote menus design §5). Attached on `.connected`
    /// to this run's `runner.control()`, detached on every other phase.
    public let menu: MenuModel
    /// The Favorites quick keys (design §5.4): attached on `.connected` to this run's
    /// `runner.control()` when the connected model's profile `supportsQuickKeys` (never otherwise, so
    /// such a model is never polled), detached on every other phase (its last lists and trees kept,
    /// read-only), and quiesced before the stop's `PSI,0` and through a USB scanner's wait. It gets
    /// every push and `menu`'s in-menu changes. Its cache is `quickKeysCacheURL(...)`. It reads only
    /// while the pop-over has it open.
    public let quickKeys: QuickKeysModel
    /// Newest first, at most `recentHitLimit`; a hit's end replaces its start, by id.
    public private(set) var recentHits: [LoggedHit] = []
    /// The last `warningLimit` runner warnings, oldest first.
    public private(set) var warnings: [String] = []
    /// Audio chunks received this run, whether or not they are played.
    public private(set) var packets = 0
    /// Playback on or off. Never starts or stops the session.
    public var listening = true {
        didSet { if listening != oldValue { listeningChanged() } }
    }
    /// The app's own playback level, 0...1 (not the scanner's volume; that is
    /// `setScannerVolume(_:)`). Forwarded to the audio output, now and whenever playback starts.
    /// Values outside 0...1 are clamped; NaN reads as 0.
    public var appVolume: Float {
        get { appVolumeLevel }
        set {
            appVolumeLevel = newValue.isNaN ? 0 : min(1, max(0, newValue))
            output?.volume = appVolumeLevel
        }
    }
    private var appVolumeLevel: Float = 1
    /// Forwarded to `StationRunner.setLoggingPaused(_:)`.
    public var loggingPaused = false {
        didSet { if loggingPaused != oldValue { forwardLoggingPaused() } }
    }

    public static let recentHitLimit = 50
    /// The meter's refresh: `lineInLevel` is set at most 30 times a second.
    public static let levelRefreshInterval: Duration = .seconds(1) / 30
    public static let warningLimit = 20
    /// How often the display loop re-checks its schedule.
    static let displayTick: Duration = .milliseconds(50)

    /// The Review Focus 5 copy for a station that doesn't answer.
    public static func noAnswerMessage(host: String, port: UInt16) -> String {
        "No answer from \(host):\(port). Check the address, your VPN, and that Noctule Scan is allowed under Privacy & Security › Local Network."
    }

    /// The copy for a station whose scanner another open station in this process already uses.
    public nonisolated static func scannerInUseMessage(otherStation: String) -> String {
        "\(otherStation) is already connected to this scanner."
    }

    /// The copy for a USB station whose port another program holds (`SerialTransportError.busy`).
    public static func busyPortMessage(_ path: String) -> String {
        "\(path) is in use by another program."
    }

    /// The copy for a USB station whose scanner didn't answer on its port (any start failure
    /// other than a busy or missing port).
    public static func noAnswerUSBMessage(port: String) -> String {
        "No answer from the scanner on \(port). Unplug it, plug it in again, and choose Serial Port on its screen."
    }

    /// The copy for a connection this device can't make: Bluetooth anywhere, USB serial on iOS.
    public static let notSupportedHereMessage = "This kind of connection isn't supported on this device yet."

    /// The copy for `restartScanner()` on a station that isn't a network station: `MSM,1` is for the
    /// SDS200 over the network only (SDS150 design §2).
    public static let restartNotSupportedMessage = "Restart isn't supported over USB."

    /// The copy for a station with no host.
    public static func noAddressMessage(stationName: String) -> String {
        "\(stationName) has no address."
    }

    /// The station's quick-key cache (structure only), beside its hit log.
    public static func quickKeysCacheURL(settingsDirectory: URL, stationID: UUID) -> URL {
        hitLogURL(settingsDirectory: settingsDirectory, stationID: stationID)
            .deletingLastPathComponent().appendingPathComponent("quick-keys.json")
    }

    public static func hitLogURL(settingsDirectory: URL, stationID: UUID) -> URL {
        settingsDirectory.appendingPathComponent("Stations", isDirectory: true)
            .appendingPathComponent(stationID.uuidString, isDirectory: true)
            .appendingPathComponent("hits.sqlite")
    }

    // MARK: Run state

    /// Set by `stop()`; read by the cooldown wait and the port wait from any thread.
    final class StopFlag: Sendable {
        private let value = Mutex(false)
        var isSet: Bool { value.withLock { $0 } }
        func set() { value.withLock { $0 = true } }
    }

    // Internal, not private, where `StationSession+USB.swift` needs them.
    @ObservationIgnored var stopFlag = StopFlag()
    @ObservationIgnored var lock: StationLock?
    @ObservationIgnored var hitLog: HitLog?
    @ObservationIgnored var runner: StationRunner?
    @ObservationIgnored private var startTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    /// A USB station's teardown after a disconnect the runner won't resume from; `performStop`
    /// awaits it as it does `startTask`.
    @ObservationIgnored var lossTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored var displayTask: Task<Void, Never>?
    /// The battery loop (`GCS`); nil while not connected, and for a station that has none.
    @ObservationIgnored var batteryTask: Task<Void, Never>?
    @ObservationIgnored private var relayTask: Task<Void, Never>?
    /// The line-in's meter loop (`runner.liveLevels()`); nil with `relayTask`, and for a station
    /// without a line-in.
    @ObservationIgnored private var levelsTask: Task<Void, Never>?
    @ObservationIgnored private var peakHold = PeakHold()
    /// Readings not shown yet (folded together), the last time one was, and the task that shows
    /// them when `levelRefreshInterval` has passed.
    @ObservationIgnored private var pendingLevel: LineInLevel?
    @ObservationIgnored private var lastLevelShown: ContinuousClock.Instant?
    @ObservationIgnored private var levelFlush: Task<Void, Never>?
    /// How many times `lineInLevel` was set (tests).
    @ObservationIgnored private(set) var levelPublishes = 0
    /// The meter previews reading this session's levels (`levelPreview()`), by id.
    @ObservationIgnored private var levelListeners: [UUID: AsyncStream<LineInLevel>.Continuation] = [:]
    /// The latest `replaceLineIn`, so input changes reach the runner in order.
    @ObservationIgnored private var lineInSync: Task<Void, Never>?
    @ObservationIgnored private var loggingSync: Task<Void, Never>?
    @ObservationIgnored private var output: (any AudioOutput)?
    @ObservationIgnored private var outputContinuation: AsyncStream<AudioChunk>.Continuation?

    /// Display refresh: the schedule, whether a push changed the screen since the last fetch, and
    /// the last key reply (the seam for Task 7's key presses).
    /// In place of the model's display policy (`DisplayRefreshPolicy(model:)`; tests); nil: the model's.
    @ObservationIgnored var displayPolicy: DisplayRefreshPolicy?
    @ObservationIgnored var displayDirty = false
    @ObservationIgnored var lastKeyReply: ContinuousClock.Instant?

    /// Control: the run's key queue and its in-order feeder, the model from `.connected`, and a
    /// generation per level so only the last value of a burst is sent.
    @ObservationIgnored private var keyInput: AsyncStream<FrontPanelKey>.Continuation?
    // Internal so tests can see the queue is gone (nil) while a USB scanner is away.
    @ObservationIgnored var keyTask: Task<Void, Never>?
    @ObservationIgnored var keyGate: KeyGate?
    /// True while a BCD436HP `HLD` waits for its reply: a second click sends nothing, and
    /// `canHold` is false. Observed, so the controls disable.
    private(set) var holdInFlight = false
    /// Observed (unlike the rest of the run state) because views read `model`, which reads it.
    private var detectedModel: ScannerModel?
    @ObservationIgnored private var levelGenerations: [Level: Int] = [:]

    /// Restart, sleep and wake.
    @ObservationIgnored private var restartTask: Task<RestartOutcome, Never>?
    @ObservationIgnored private var stopRequestedDuringRestart = false
    /// The last `.noAnswer` came from the runner's start (no answer on the network or the port),
    /// not from configuration (no address, the lock, settings, the log). Only those are retried
    /// after wake.
    @ObservationIgnored var lastFailureWasNoAnswer = false
    /// The saved port of the station's device settings, read at the last start (nil: automatic,
    /// or no start yet). The registry's identity for a USB station
    /// (`SessionRegistry.scannerIdentity(of:usbPort:)`).
    @ObservationIgnored private(set) var usbPort: String?
    @ObservationIgnored private var resumeOnWake = false
    /// True while `suspend()` stops the session. A `start()` meanwhile sets the second flag, a
    /// `stop()` the third; the later of the two wins (each clears the other).
    @ObservationIgnored private var suspending = false
    @ObservationIgnored private var startRequestedWhileSuspending = false
    @ObservationIgnored private var stopRequestedWhileSuspending = false
    /// Counts `halt()` calls, so a start waiting out a stop can tell a later stop came in.
    @ObservationIgnored private var haltCount = 0
    /// Counts `stop()` and `suspend()` calls. `reconnect()` and `resume()` capture them before
    /// they wait (for their own halt, or for a restart) and don't start if either moved: a stop
    /// that arrives meanwhile wins, and a sleep leaves the start for the next wake.
    @ObservationIgnored private var stopGeneration = 0
    @ObservationIgnored private var suspendGeneration = 0
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryGeneration = 0

    public init(station: Station, environment: SessionEnvironment) {
        self.station = station
        self.environment = environment
        menu = MenuModel()
        let cacheURL = Self.quickKeysCacheURL(settingsDirectory: environment.settingsDirectory, stationID: station.id)
        quickKeysCacheFound = FileManager.default.fileExists(atPath: cacheURL.path)
        quickKeys = QuickKeysModel(cacheURL: cacheURL, pollInterval: environment.quickKeysPollInterval)
        menu.onCommandReply = { [weak self] in self?.noteMenuCommandReply() }
        menu.onInMenuChanged = { [weak self] inMenu in self?.quickKeys.menuReadChanged(inMenu) }
    }

    /// Whether the window offers the quick keys (the toolbar hides the button when false): the last
    /// connection's answer (`ModelProfile.supportsQuickKeys` of the model `MDL` named, else of the
    /// station's override; an unknown model has none), kept through stops and restarts; before any
    /// connection, the override's; with neither, whether the station has a quick-key cache (written
    /// only by a model that has them), so a USB station waiting for its scanner at launch can show the
    /// cached tree, read-only.
    public var supportsQuickKeys: Bool {
        if let known = quickKeysFromConnection { return known }
        if let override = station.connection.modelOverride { return ModelProfile.profile(for: override).supportsQuickKeys }
        return quickKeysCacheFound
    }

    /// The last `.connected`'s answer for `supportsQuickKeys`; nil before the first.
    private var quickKeysFromConnection: Bool?
    @ObservationIgnored private let quickKeysCacheFound: Bool

    /// True once `SessionRegistry` has let go of this session for good (last release, an edit
    /// that replaced it, deletion, `stopAll`). Terminal: from then on `start()`, `reconnect()`,
    /// `resume()` and `restartScanner()` do nothing, so a session no window or registry entry
    /// holds can never open the scanner again (final review C1).
    public private(set) var isRetired = false

    /// Set by `SessionRegistry`: the name of another session in this process that holds this
    /// station's scanner (`holdsScanner`; `SessionRegistry.scannerIdentity(of:usbPort:)`), or nil.
    /// Checked at the start of every run, in the same main-actor step that takes the station lock
    /// and moves the phase to `.connecting`, so of two sessions on one scanner starting at once
    /// exactly one gets through.
    @ObservationIgnored var addressConflict: (@MainActor (StationSession) -> String?)?

    /// Set by `SessionRegistry`: called each time this session reaches `.connected` from its
    /// current runner (the registry records the station as the last one connected).
    @ObservationIgnored var onConnected: (@MainActor (StationSession) -> Void)?

    /// Whether this session may hold or be about to hold its scanner: waiting for the cooldown,
    /// connecting, connected, stopping, or restarting the scanner.
    var holdsScanner: Bool {
        if isRestarting { return true }
        switch phase {
        case .waitingForCooldown, .waitingForScanner, .connecting, .connected, .stopping: return true
        case .idle, .inUse, .scannerInUse, .noAnswer, .stopped: return false
        }
    }

    /// Whether this station can have audio at all: a network station, or a USB station with a
    /// line-in (`lineInConfig`).
    public var hasAudio: Bool { station.connection.transport == .network || lineInConfig != nil }

    /// Whether Listen and the app volume are offered: the station has audio, and its line-in (if
    /// any) isn't blocked, `.failed` (the kill-switch's `DisabledLineInSource` among them) or
    /// `.denied`. The window shows such a line-in as "Line-in blocked", the reason as help.
    public var canListen: Bool {
        guard hasAudio else { return false }
        switch lineIn {
        case .failed?, .denied?: return false
        default: return true
        }
    }

    /// `clipWarning`'s text (`StationRunner.clippedMessage(channel:)`, naming the hit's channel as
    /// the recent hits do), or nil.
    public var clipWarningText: String? {
        clipWarning.map { StationRunner.clippedMessage(channel: Self.channelName($0.hit)) }
    }

    /// A hit's channel name, else "TG <id>", else its frequency, else "Unknown".
    static func channelName(_ hit: Hit) -> String {
        if let channel = hit.channel?.trimmingCharacters(in: .whitespaces), !channel.isEmpty { return channel }
        if let tg = hit.key.talkgroupID, !tg.isEmpty { return "TG \(tg)" }
        if let mhz = hit.key.frequencyMHz { return String(format: "%.4f MHz", mhz) }
        return "Unknown"
    }

    /// Marks the session retired (see `isRetired`); the registry then calls `stop()`. Synchronous,
    /// so a start already waiting on a stop sees it when that stop finishes.
    func markRetired() {
        isRetired = true
        resumeOnWake = false
        cancelRetries()
    }

    /// Takes `edited` as the station if it differs only in what the session doesn't use at run time
    /// (`SessionRegistry.restartRelevant`): the key map, appearance, view choice, saved filters,
    /// counts reset, and the reconnect wait (which the next `start()` reads). Returns false,
    /// changing nothing, if it differs in anything else.
    @discardableResult
    public func applyLiveChanges(_ edited: Station) -> Bool {
        guard SessionRegistry.restartRelevant(edited) == SessionRegistry.restartRelevant(station) else { return false }
        if edited != station { station = edited }
        return true
    }

    private var host: String { (station.connection.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Start

    /// Starts the station (see the type's documentation). Returns once connected, failed, or
    /// stopped. Does nothing while stopping, already running, or restarting the scanner
    /// (`isRestarting`; the restart starts the session itself when it succeeds).
    public func start() async {
        guard !isRestarting, !isRetired else { return }
        await beginStart()
    }

    /// `start()` without the restart fence, for the restart's own start.
    ///
    /// A start that arrives while a stop is in flight waits for it, so the two runs never overlap
    /// (a fresh stop flag would otherwise hide the start from that stop, and the new run would
    /// race the old one's teardown for the station lock). One that arrives while `suspend()` is
    /// stopping doesn't start now (the Mac is going to sleep): `resume()` starts it.
    private func beginStart() async {
        guard !isRetired else { return }
        if suspending { requestStartWhileSuspending(); return }
        if let stopTask, startTask == nil {
            let halts = haltCount
            await stopTask.value
            guard !isRetired else { return }
            if suspending { requestStartWhileSuspending(); return }
            guard haltCount == halts else { return }  // a later stop() wins
        }
        if let startTask {
            await startTask.value
            return
        }
        switch phase {
        case .idle, .inUse, .scannerInUse, .noAnswer, .stopped: break
        case .waitingForCooldown, .waitingForScanner, .connecting, .connected, .stopping: return
        }
        stopTask = nil
        stopFlag = StopFlag()
        audio = .idle
        lineIn = nil
        clearMeter()
        info = nil
        display = nil
        packets = 0
        displayDirty = false
        lastKeyReply = nil
        restartHint = nil
        lastRestartFailure = nil
        detectedModel = nil
        lastFailureWasNoAnswer = false
        let task = Task { await self.performStart() }
        startTask = task
        await task.value
        if startTask == task { startTask = nil }
    }

    private func performStart() async {
        switch station.connection.transport {
        case .network: await performNetworkStart()
        case .usbSerial: await performUSBStart()
        case .bluetooth:
            // Nothing opened: no lock, no settings, no transport.
            phase = .noAnswer(Self.notSupportedHereMessage)
        }
    }

    private func performNetworkStart() async {
        let flag = stopFlag
        // Nothing to connect to: say so (not "No answer from :<port>").
        guard !host.isEmpty else {
            phase = .noAnswer(Self.noAddressMessage(stationName: station.name))
            return
        }
        // 1. The registry's scanner check and the station lock.
        guard takeLock() else { return }
        phase = .connecting

        // 2. Device settings.
        guard let device = await readDeviceSettings(flag: flag) else { return }

        // 3. The hit log.
        guard let log = await openHitLog(flag: flag) else { return }

        // 4. The reconnect cooldown: nothing reaches the scanner until it is over. The full value
        // after an unclean close, the station's own (clamped to it) after a clean one.
        let host = self.host
        let policy = station.connection.reconnectCooldownPolicy(full: environment.cooldown)
        if station.recording.saveAudio != .never, !host.isEmpty {
            while let remaining = await RTSPCooldownGate.remaining(store: environment.cooldownStore, host: host,
                                                                   policy: policy) {
                guard !flag.isSet else { return }
                phase = .waitingForCooldown(secondsLeft: Self.wholeSeconds(remaining))
                guard await RTSPCooldownGate.waitOut(min(remaining, .seconds(1)), isInterrupted: { flag.isSet }) else {
                    return
                }
            }
        }
        guard !flag.isSet else { return }

        // 5. The runner.
        phase = .connecting
        var config = environment.audioConfig
        config.cooldownPolicy = policy
        // A network station never resolves a serial port, so its factory lists none.
        let runner = StationRunner(station: station, device: device, log: log,
                                   recordingsRoot: environment.recordingsRoot,
                                   cooldownStore: environment.cooldownStore,
                                   transportFactory: StationTransportFactory(ports: FixedSerialPortListing.empty,
                                                                             makeNetworkTransport: environment.makeTransport),
                                   audioConfig: config)
        self.runner = runner
        startConsumers(runner)
        if loggingPaused { await runner.setLoggingPaused(true) }
        do {
            try await runner.start()
        } catch {
            guard !flag.isSet else { return }
            await teardownRun()
            lastFailureWasNoAnswer = true
            phase = .noAnswer(Self.noAnswerMessage(host: host, port: station.connection.udpPort))
        }
    }

    /// Seconds left, rounded up, so the countdown never shows 0 while waiting.
    private static func wholeSeconds(_ d: Duration) -> Int {
        let c = d.components
        return Int(c.seconds) + (c.attoseconds > 0 ? 1 : 0)
    }

    // MARK: Start steps shared by both kinds of station

    /// One session per scanner in this process (the registry's check), then one runner
    /// per station across processes (`StationLock`): nothing opened if either is held. False, with
    /// the phase set (`.scannerInUse`, `.inUse`, or `.noAnswer` for a lock that can't be made),
    /// when the start must end here.
    func takeLock() -> Bool {
        if let other = addressConflict?(self) {
            phase = .scannerInUse(byStation: other)
            return false
        }
        do {
            lock = try StationLock.acquire(stationID: station.id, settingsDirectory: environment.settingsDirectory)
            return true
        } catch {
            switch error {
            case .inUse(let pid): phase = .inUse(pid: pid)
            case .unavailable(let reason): phase = .noAnswer("Can't open \(station.name): \(reason)")
            }
            return false
        }
    }

    /// The station's device settings, remembering the saved port (`usbPort`). Nil when the start
    /// must end here: a read failure (`.noAnswer`, what was opened closed), or a stop meanwhile
    /// (the stop closes what was opened).
    func readDeviceSettings(flag: StopFlag) async -> StationDeviceSettings? {
        do {
            let device = try await environment.settings.deviceSettings(for: station.id)
            guard !flag.isSet else { return nil }
            usbPort = device.usbPort
            return device
        } catch {
            guard !flag.isSet else { return nil }
            await closeResources()
            phase = .noAnswer("Can't read the settings for \(station.name): \(error)")
            return nil
        }
    }

    /// Opens the hit log at `Stations/<uuid>/hits.sqlite` into `hitLog`. Nil when the start must end
    /// here: a failure (`.noAnswer`, what was opened closed), or a stop meanwhile.
    func openHitLog(flag: StopFlag) async -> HitLog? {
        let logURL = Self.hitLogURL(settingsDirectory: environment.settingsDirectory, stationID: station.id)
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let log = try HitLog(url: logURL)
            hitLog = log
            return log
        } catch {
            guard !flag.isSet else { return nil }  // stop() closes what this opened
            await closeResources()
            phase = .noAnswer("Can't open the hit log at \(logURL.path): \(error)")
            return nil
        }
    }

    // MARK: Runner events

    func startConsumers(_ runner: StationRunner) {
        let events = runner.events
        eventsTask = Task { [weak self] in
            for await event in events {
                // A USB scanner's loss is handled in place, so a `.connected` that follows a quick
                // replug is applied only once the lost connection's loops have ended.
                if case .disconnected(let hint) = event {
                    await self?.scannerWentAway(hint: hint, from: runner)
                } else {
                    self?.handle(event, from: runner)
                }
            }
        }
        let statuses = runner.liveStatus
        statusTask = Task { [weak self] in
            for await status in statuses { self?.statusArrived(status) }
        }
    }

    /// Applies one runner event. `.connected` counts only from `source`, the current runner: one
    /// drained while a failed start tears down (`teardownRun` clears `runner` first) or from a
    /// stale runner never moves the phase or starts the live loops, and neither does one that
    /// arrives after the session was retired (nor does it call `onConnected`). It is taken from
    /// `.connecting` and, a USB scanner back after a disconnect, from `.waitingForScanner`.
    /// `.disconnected` is not applied here but by `scannerWentAway(hint:from:)`, which the events
    /// consumer awaits in place.
    func handle(_ event: RunnerEvent, from source: StationRunner? = nil) {
        switch event {
        case .connected(let model, let firmware):
            // Not once retired: `markRetired()` is synchronous, but the stop flag is set only
            // later, inside the stop's task, so an event can land in between.
            guard let source, let runner, source === runner, !stopFlag.isSet, !isRetired else { return }
            switch phase {
            case .connecting, .waitingForScanner: break
            default: return
            }
            phase = .connected(model: model, firmware: firmware)
            detectedModel = ScannerModel(reported: model)
            startLiveLoops(runner)
            menu.destructiveItems = ModelProfile.profile(for: self.model).destructiveMenuItems
            menu.navigation = ModelProfile.profile(for: self.model).menuNavigation
            menu.attach(control: { await runner.control() })
            let known = detectedModel ?? station.connection.modelOverride
            let hasQuickKeys = known.map { ModelProfile.profile(for: $0).supportsQuickKeys } ?? false
            if quickKeysFromConnection != hasQuickKeys { quickKeysFromConnection = hasQuickKeys }
            // Only a model with quick keys is ever read (and only while the pop-over is open).
            if hasQuickKeys { quickKeys.attach(control: { await runner.control() }) }
            onConnected?(self)
        case .audio(let state):
            // Only the current runner's: a stale runner's last states (drained at teardown) don't count.
            guard let source, let runner, source === runner else { return }
            audio = state
            if case .failed = state { fetchRestartHint(source) }
        case .hitStarted(let hit), .hitEnded(let hit):
            upsert(hit)
        case .warning(let text):
            warnings.append(text)
            environment.onWarning?(station.name, text)
            if warnings.count > Self.warningLimit { warnings.removeFirst(warnings.count - Self.warningLimit) }
        case .lineIn(let state):
            // Only the current runner's, and only while there is a line-in: the `.stopped` of an
            // input taken away (`lineInChanged(nil)`) arrives after it.
            guard let source, let runner, source === runner, lineInConfig != nil else { return }
            lineIn = state
            if case .streaming = state {} else { clearMeter() }
        case .clipped(let hit):
            upsert(hit)
            clipWarning = hit
            if let text = clipWarningText { environment.onWarning?(station.name, text) }
        case .recording, .stopped, .disconnected:
            break
        }
    }

    private func upsert(_ hit: LoggedHit) {
        if let index = recentHits.firstIndex(where: { $0.hit.id == hit.hit.id }) {
            recentHits[index] = hit
        } else {
            recentHits.insert(hit, at: 0)
            if recentHits.count > Self.recentHitLimit { recentHits.removeLast(recentHits.count - Self.recentHitLimit) }
        }
    }

    private func statusArrived(_ status: ScannerInfo) {
        if DisplayRefreshPolicy.significantChange(info, status) { displayDirty = true }
        info = status
        menu.statusArrived(status)
        quickKeys.statusArrived(status)
    }

    /// Records a key press's reply, so the display is fetched `afterKey` later (Task 7).
    func noteKeyReply(at instant: ContinuousClock.Instant = .now) {
        lastKeyReply = instant
    }

    /// Records the reply to a menu command (`MSV`, or a menu action), like `noteKeyReply(at:)`: the
    /// display is re-read promptly.
    func noteMenuCommandReply(at instant: ContinuousClock.Instant = .now) {
        noteKeyReply(at: instant)
    }

    // MARK: Display and audio loops

    private func startLiveLoops(_ runner: StationRunner) {
        startKeyQueue(runner)
        displayTask = Task { [weak self] in await self?.displayLoop(runner) }
        if readsBattery {
            let interval = environment.batteryPollInterval
            batteryTask = Task { [weak self] in await self?.batteryLoop(runner, every: interval) }
        }
        // A station without audio never taps `liveAudio()` and never starts playback.
        guard hasAudio else { return }
        startAudioLoops(runner)
    }

    /// The relay, a line-in's meter loop, and playback (if `listening`). Once per run: a USB
    /// scanner's resume finds them running, since they run through its wait.
    private func startAudioLoops(_ runner: StationRunner) {
        guard relayTask == nil else { return }
        relayTask = Task { [weak self] in
            let tap = await runner.liveAudio()
            for await chunk in tap {
                guard let self else { return }
                self.packets += 1
                self.outputContinuation?.yield(chunk)
            }
        }
        if lineInConfig != nil {
            levelsTask = Task { [weak self] in
                let levels = await runner.liveLevels()
                for await level in levels {
                    guard let self else { return }
                    self.levelArrived(level)
                }
            }
        }
        if listening { startPlayback() }
    }

    /// Ends what `startAudioLoops` started, and empties the meter.
    private func stopAudioLoops() {
        stopPlayback()
        relayTask?.cancel()
        relayTask = nil
        levelsTask?.cancel()
        levelsTask = nil
        clearMeter()
    }

    // MARK: The line-in's meter

    private func levelArrived(_ level: LineInLevel) {
        for listener in levelListeners.values { listener.yield(level) }
        if level.clipped, !clipLatched { clipLatched = true }
        // A reading still in flight when the input stopped streaming isn't shown.
        guard case .streaming = lineIn else { return }
        pendingLevel = pendingLevel.map { Self.fold($0, level) } ?? level
        let now = ContinuousClock.now
        if let last = lastLevelShown, last.duration(to: now) < Self.levelRefreshInterval {
            guard levelFlush == nil else { return }
            let due = last + Self.levelRefreshInterval
            levelFlush = Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                guard !Task.isCancelled, let self else { return }
                self.levelFlush = nil
                self.showLevel()
            }
            return
        }
        levelFlush?.cancel()
        levelFlush = nil
        showLevel()
    }

    /// Two readings as one: the louder peak and RMS, either clip, the later instant.
    private static func fold(_ a: LineInLevel, _ b: LineInLevel) -> LineInLevel {
        LineInLevel(peakDBFS: max(a.peakDBFS, b.peakDBFS), rmsDBFS: max(a.rmsDBFS, b.rmsDBFS),
                    clipped: a.clipped || b.clipped, at: b.at)
    }

    private func showLevel() {
        guard let level = pendingLevel else { return }
        pendingLevel = nil
        lastLevelShown = .now
        levelPublishes += 1
        lineInLevel = level
        peakHoldDBFS = peakHold.update(peak: level.peakDBFS, at: level.at)
    }

    /// Empties the meter (no reading, no peak held); CLIP stays as it is.
    private func clearMeter() {
        levelFlush?.cancel()
        levelFlush = nil
        pendingLevel = nil
        lastLevelShown = nil
        peakHold.reset()
        if lineInLevel != nil { lineInLevel = nil }
        if peakHoldDBFS != nil { peakHoldDBFS = nil }
    }

    /// Puts out CLIP (the user clicked it).
    public func clearClip() {
        clipLatched = false
    }

    /// Dismisses `clipWarning`; CLIP stays lit until `clearClip()`.
    public func dismissClipWarning() {
        clipWarning = nil
    }

    /// The line-in's readings as they arrive, every one, for a meter beside the window's (the
    /// station editor's, through `SessionRegistry.previewLevels`). `cancel` ends the stream.
    func levelPreview() -> (levels: AsyncStream<LineInLevel>, cancel: @Sendable () -> Void) {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: LineInLevel.self, bufferingPolicy: .bufferingNewest(8))
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.levelListeners[id] = nil }
        }
        levelListeners[id] = continuation
        return (stream, { continuation.finish() })
    }

    /// Whether this session's meter loop runs `config` now (the preview can read it).
    func runsLineIn(_ config: LineInConfig) -> Bool {
        levelsTask != nil && lineInConfig == config
    }

    /// The station's input changed (the editor saved another, or none): the runner's source is
    /// replaced (`runner.replaceLineIn`) and the scanner left alone; the relay, meter and playback
    /// start if the station now has a line-in and the run is past its first `.connected`, and end
    /// if it has none. Without a run, only `lineInConfig` changes (the next start reads the device
    /// settings anyway). Nothing for a network station.
    public func lineInChanged(_ config: LineInConfig?) async {
        guard station.connection.transport == .usbSerial else { return }
        let effective = environment.lineInSources == nil ? nil : config
        lineInConfig = effective
        guard let runner else { return }
        if effective == nil {
            stopAudioLoops()
            lineIn = nil
        } else if isConnected || isWaitingForScanner {
            startAudioLoops(runner)
        }
        await replaceLineIn(on: runner, with: effective)
    }

    /// `runner.replaceLineIn(config)`, after any earlier one this session made: of two changes in
    /// quick succession, the later input is the one the runner keeps.
    func replaceLineIn(on runner: StationRunner, with config: LineInConfig?) async {
        let previous = lineInSync
        let task = Task {
            await previous?.value
            await runner.replaceLineIn(config)
        }
        lineInSync = task
        await task.value
    }

    var isWaitingForScanner: Bool {
        if case .waitingForScanner = phase { return true }
        return false
    }

    private func displayLoop(_ runner: StationRunner) async {
        var lastFetch: ContinuousClock.Instant?
        while !Task.isCancelled {
            let now = ContinuousClock.now
            let policy = displayPolicy ?? DisplayRefreshPolicy(model: model)
            let next = policy.nextFetch(lastFetch: lastFetch, lastKeyReply: lastKeyReply,
                                        changed: displayDirty, now: now, inMenu: info?.isMenu ?? false)
            if next > now {
                try? await Task.sleep(for: min(now.duration(to: next), Self.displayTick))
                continue
            }
            // The runner's shared client: STS only, never stopPush()/disconnect().
            guard let client = await runner.control(), !Task.isCancelled else { return }
            displayDirty = false
            lastFetch = .now
            do {
                let status = try await client.displayStatus()
                guard !Task.isCancelled else { return }
                // The layout follows the model once `MDL` names it (`detectedModel` is set before this
                // loop starts), so a screen is never built with the wrong layout.
                display = DisplayModel(status: status, info: info, layout: ModelProfile.profile(for: model).display)
            } catch {
                // A missed or garbled reply: the next scheduled fetch tries again.
            }
        }
    }

    /// Whether this run reads the battery: a USB scanner (never a network one) whose model's
    /// profile has `supportsChargeStatus`.
    private var readsBattery: Bool {
        station.connection.transport == .usbSerial && ModelProfile.profile(for: model).supportsChargeStatus
    }

    /// One `GCS` at once, then one every `interval`, through the runner's shared client (`GCS`
    /// only, never `stopPush()`/`disconnect()`). A missed or garbled reply keeps the last reading;
    /// a second in a row clears it; the next good one sets it again.
    private func batteryLoop(_ runner: StationRunner, every interval: Duration) async {
        var missed = 0
        while !Task.isCancelled {
            guard let client = await runner.control(), !Task.isCancelled else { return }
            do {
                let status = try await client.chargeStatus()
                guard !Task.isCancelled, isConnected else { return }
                missed = 0
                battery = status
            } catch {
                guard !Task.isCancelled, isConnected else { return }
                missed += 1
                if missed >= 2 { battery = nil }
            }
            try? await Task.sleep(for: interval)
        }
    }

    /// Cancels the battery loop and waits for it to end, so no `GCS` follows (a `PSI,0`, or a port
    /// that is gone).
    func stopBatteryLoop() async {
        batteryTask?.cancel()
        await batteryTask?.value
        batteryTask = nil
    }

    private func listeningChanged() {
        if listening {
            // A line-in plays on through a wait for the scanner, as its relay runs on.
            if isConnected || isWaitingForScanner, relayTask != nil { startPlayback() }
        } else {
            stopPlayback()
        }
    }

    private func startPlayback() {
        guard outputContinuation == nil else { return }
        let output = self.output ?? (station.connection.transport == .usbSerial
            ? environment.makeLineInAudioOutput() : environment.makeAudioOutput())
        self.output = output
        output.volume = appVolumeLevel
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(50))
        outputContinuation = continuation
        Task { [weak self] in
            do {
                try await output.play(stream)
            } catch {
                self?.handle(.warning("playback failed: \(error)"))
            }
        }
    }

    private func stopPlayback() {
        guard let continuation = outputContinuation else { return }
        continuation.finish()
        outputContinuation = nil
        output?.stop()
    }

    private func forwardLoggingPaused() {
        guard let runner else { return }
        let paused = loggingPaused
        let previous = loggingSync
        // Chained, so quick toggles reach the runner in order.
        loggingSync = Task {
            await previous?.value
            await runner.setLoggingPaused(paused)
        }
    }

    // MARK: Control

    /// Presses beyond this many pending (the one in flight included) are dropped (Review Focus 4).
    public static let maxQueuedKeys = 8
    /// Volume and squelch: only the last value of a burst within this window is sent.
    static let levelDebounce: Duration = .milliseconds(250)
    /// `levelDebounce`, per session; tests lengthen it to widen their timing margins.
    @ObservationIgnored var levelDebounceInterval: Duration = StationSession.levelDebounce

    /// What `runner.audioRestartHint()` said when audio became `.failed` this run; nil otherwise.
    /// The session never reconnects or restarts on its own: the UI offers Reconnect, or Restart
    /// scanner (after its confirmation dialog) when this is `.canRestart`.
    public private(set) var restartHint: RestartHint?

    /// The outcome of this run's last `restartScanner()` when it failed (`.notAccepted` other than
    /// a cancellation by stop, or `.didNotComeBack`); nil otherwise, and cleared by the next start.
    /// While set, the UI says the restart failed and offers only Reconnect (or a power cycle).
    public private(set) var lastRestartFailure: RestartOutcome?

    private enum Level { case volume, squelch }

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// The model `MDL` last reported (kept through a USB station's wait for its scanner; cleared
    /// by the next start), else the station's override, else SDS200.
    public var model: ScannerModel { detectedModel ?? station.connection.modelOverride ?? .sds200 }

    /// Presses a front-panel key (`KEY,<code>,P`) through the run's `KeyPressQueue`, in order, one
    /// at a time. Ignored unless connected; dropped while `maxQueuedKeys` are pending.
    public func press(_ key: FrontPanelKey) {
        guard isConnected, let keyInput else { return }
        keyInput.yield(key)
    }

    /// Sets the scanner's volume (`VOL,<n>`), clamped to the model's range, 250 ms after the last
    /// call of a burst. Ignored unless connected, or if the model has no volume range.
    public func setScannerVolume(_ value: Int) { setLevel(.volume, value) }

    /// Volume −1 (line-in design §6.3): one step down from the volume the scanner last reported,
    /// through `setScannerVolume(_:)` (so one `VOL`, as one slider notch). Nothing at the bottom of
    /// the model's range, with no reading, or unless connected.
    public func stepScannerVolumeDown() {
        guard isConnected, let current = info?.volume,
              let range = ModelProfile.profile(for: model).volumeRange, current > range.lowerBound else { return }
        setScannerVolume(current - 1)
    }

    /// Sets the scanner's squelch (`SQL,<n>`), like `setScannerVolume(_:)`.
    public func setScannerSquelch(_ value: Int) { setLevel(.squelch, value) }

    /// Holds the system, department or channel on the display. An SDS model presses the soft key
    /// carrying the level's label (`KEY`); the BCD436HP, which has no soft keys, sends one
    /// `HLD,<level>,<index>,` for the element the last push shows (design §3.5a): never resent,
    /// refused while another `HLD` is in flight, withheld once the session's stop begins, and with
    /// no extra `GSI` after it (the next push shows the hold). Does nothing when `canHold(level)`
    /// is false.
    public func hold(_ level: HoldLevel) {
        switch ModelProfile.profile(for: model).holdMethod {
        case .softKeyLabel:
            guard isConnected, let key = Self.holdKey(level, display: display) else { return }
            press(key)
        case .holdCommand:
            guard canHold(level), let target = Self.holdTarget(level, info: info), let gate = keyGate else { return }
            holdInFlight = true
            Task { [weak self] in
                // Only the run that set the flag clears it: a reconnect's run has its own gate.
                defer { if let self, self.keyGate === gate || self.keyGate == nil { self.holdInFlight = false } }
                guard let runner = self?.runner, let client = await runner.control() else { return }
                do {
                    try await client.hold(target, onlyIf: { gate.isOpen })
                } catch ScannerClientError.withheld {
                } catch {
                    // A stop closing the transport under the reply is not a failed hold.
                    guard gate.isOpen else { return }
                    self?.handle(.warning("couldn't hold the \(level.holdName): \(error)"))
                }
            }
        }
    }

    /// True while connected and the level can be held: an SDS model's display has a soft key with
    /// the level's label; on the BCD436HP, no `HLD` is in flight and the last push names the
    /// element (`holdTarget`).
    public func canHold(_ level: HoldLevel) -> Bool {
        guard isConnected else { return false }
        switch ModelProfile.profile(for: model).holdMethod {
        case .softKeyLabel: return Self.holdKey(level, display: display) != nil
        case .holdCommand: return !holdInFlight && keyGate != nil && Self.holdTarget(level, info: info) != nil
        }
    }

    /// The `HLD` target for a level on the scanner's last push: nil with no push, in a menu, with
    /// the element or its index missing, for an unprogrammed index (an idle talkgroup of 4294967295
    /// is never sent), or for a channel that is neither a `TGID` nor a `ConvFrequency`.
    static func holdTarget(_ level: HoldLevel, info: ScannerInfo?) -> HoldTarget? {
        guard let info, !info.isMenu, let system = info.system, let systemIndex = system.index,
              system.isProgrammed else { return nil }
        switch level {
        case .system:
            return .system(index: systemIndex)
        case .department:
            guard let index = info.department?.index, info.department?.isProgrammed == true else { return nil }
            return .department(index: index, system: systemIndex)
        case .channel:
            guard let channel = info.channel, let index = channel.index, channel.isProgrammed else { return nil }
            if info.raw.child("TGID") != nil { return .trunkChannel(index: index) }
            if info.raw.child("ConvFrequency") != nil { return .conventionalChannel(index: index) }
            return nil
        }
    }

    static func holdKey(_ level: HoldLevel, display: DisplayModel?) -> FrontPanelKey? {
        display?.softKey(labelled: level.softKeyLabel)
    }

    /// Closed when a stop begins: the run's queued keys are dropped, not sent.
    final class KeyGate: Sendable {
        private let open = Mutex(true)
        var isOpen: Bool { open.withLock { $0 } }
        func close() { open.withLock { $0 = false } }
    }

    private func startKeyQueue(_ runner: StationRunner) {
        let gate = KeyGate()
        keyGate = gate
        let queue = KeyPressQueue(maxQueued: Self.maxQueuedKeys) { [weak self] key in
            // The runner's shared client (nil once runner.stop() begins), and only while the gate
            // is open: it closes as the session's stop begins, before any of the stop's awaits.
            guard gate.isOpen, let client = await runner.control(), gate.isOpen else {
                throw ScannerClientError.notConnected
            }
            try await client.press(key)
            let replied = ContinuousClock.now
            await self?.noteKeyReply(at: replied)
        }
        let (keys, input) = AsyncStream.makeStream(of: FrontPanelKey.self)
        keyInput = input
        // One feeder, so presses reach the queue in the order they were made.
        keyTask = Task {
            for await key in keys { _ = await queue.enqueue(key) }
        }
    }

    /// Closes the gate (keys still queued are dropped) and ends the feeder. Synchronous, so it can
    /// be a stop's first step.
    func stopKeyQueue() {
        holdInFlight = false
        keyGate?.close()
        keyGate = nil
        keyInput?.finish()
        keyInput = nil
        keyTask?.cancel()
        keyTask = nil
    }

    private func setLevel(_ level: Level, _ value: Int) {
        guard isConnected, let runner else { return }
        let profile = ModelProfile.profile(for: model)
        guard let range = level == .volume ? profile.volumeRange : profile.squelchRange else { return }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let generation = (levelGenerations[level] ?? 0) + 1
        levelGenerations[level] = generation
        let debounce = levelDebounceInterval
        Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard let self, self.levelGenerations[level] == generation, self.isConnected,
                  self.runner === runner, let client = await runner.control() else { return }
            do {
                switch level {
                case .volume: try await client.setVolume(clamped)
                case .squelch: try await client.setSquelch(clamped)
                }
            } catch {
                self.handle(.warning("couldn't set the scanner's \(level == .volume ? "volume" : "squelch") to \(clamped): \(error)"))
            }
        }
    }

    /// Drops any level change still waiting out its debounce.
    func cancelPendingLevels() {
        for level in [Level.volume, .squelch] { levelGenerations[level, default: 0] += 1 }
    }

    private func fetchRestartHint(_ runner: StationRunner) {
        Task { [weak self] in
            let hint = await runner.audioRestartHint()
            guard let self, self.runner === runner, case .failed = self.audio else { return }
            self.restartHint = hint
        }
    }

    // MARK: Reconnect and restart

    /// Stops, then starts again through the cooldown gate (so it waits out the cooldown first:
    /// the station's clean-close wait after a clean stop, 120 s otherwise).
    /// Does nothing while `isRestarting` or once retired. A `stop()` (or the registry retiring the
    /// session) while the reconnect's own stop is in flight wins: the reconnect doesn't start. A
    /// `suspend()` meanwhile leaves the start for the wake.
    public func reconnect() async {
        guard !isRestarting, !isRetired else { return }
        let stops = stopGeneration, suspends = suspendGeneration
        await halt()
        guard stopGeneration == stops, !isRetired else { return }
        guard suspendGeneration == suspends else {
            if suspending { requestStartWhileSuspending() } else { resumeOnWake = true }
            return
        }
        await start()
    }

    /// Restarts the scanner. **Call only after the user confirmed the restart dialog.** Stops the
    /// session (`PSI,0`, TEARDOWN, the close recorded in the cooldown store), sends `MSM,1` through
    /// `ScannerRestart.perform` on a fresh client (connected here, disconnected after), and on
    /// `.restarted` (which cleared the cooldown record) starts again. Any other outcome leaves the
    /// session stopped with a warning; nothing is retried. A `stop()` during the restart keeps the
    /// session stopped: a `stop()` or `suspend()` before `MSM,1` goes out cancels the restart
    /// (`.notAccepted(restartCancelledReason)`, nothing sent), and one after it keeps the session
    /// from starting. Concurrent calls share one restart. While it runs, `isRestarting` is true and
    /// `start()` and `reconnect()` do nothing.
    ///
    /// Called on an idle or stopped session it still sends `MSM,1` and then starts the session.
    /// The UI offers it only when `restartHint == .canRestart`, after its confirmation dialog.
    ///
    /// A station that isn't a network station is refused at once, with nothing stopped, built or
    /// sent (`.notAccepted(restartNotSupportedMessage)`, and a warning): `MSM,1` is approved for
    /// the SDS200 over the network only, never for a USB scanner (SDS150 design §2).
    public func restartScanner() async -> RestartOutcome {
        if let restartTask { return await restartTask.value }
        guard !isRetired else { return .notAccepted(Self.restartCancelledReason) }
        stopRequestedDuringRestart = false
        isRestarting = true
        // The bookkeeping ends inside the task, so every waiter on its value (this call, a
        // concurrent restart, resume()) sees isRestarting false when it resumes.
        let task = Task { () -> RestartOutcome in
            let outcome = await self.performRestart()
            self.restartTask = nil
            self.isRestarting = false
            return outcome
        }
        restartTask = task
        return await task.value
    }

    /// The reason `restartScanner()` gives when a stop cancelled it before `MSM,1`.
    public static let restartCancelledReason = "stopped before the restart was sent"

    /// True while `restartScanner()` runs (stopping, `MSM,1`, waiting for the scanner, starting).
    public private(set) var isRestarting = false

    private func performRestart() async -> RestartOutcome {
        guard station.connection.transport == .network else {
            handle(.warning(Self.restartNotSupportedMessage))
            return .notAccepted(Self.restartNotSupportedMessage)
        }
        let host = self.host
        let port = station.connection.udpPort
        await halt()
        // A stop() or suspend() that came in before or during the halt cancels the restart.
        guard !stopRequestedDuringRestart else { return .notAccepted(Self.restartCancelledReason) }
        guard !host.isEmpty else {
            let reason = Self.noAddressMessage(stationName: station.name)
            handle(.warning(reason))
            return .notAccepted(reason)
        }
        let make = environment.makeTransport
        let timing = environment.restartTiming
        let client = ScannerClient(transport: make(host, port))
        let outcome: RestartOutcome
        do {
            try await client.connect()
            outcome = await ScannerRestart.perform(
                client: client, host: host, port: port, cooldownStore: environment.cooldownStore,
                timeout: timing.timeout, pollInterval: timing.pollInterval, silenceGrace: timing.silenceGrace,
                pollTimeout: timing.pollTimeout, makeTransport: { make(host, port) })
        } catch {
            outcome = .notAccepted(String(describing: error))
        }
        await client.disconnect()
        switch outcome {
        case .restarted:
            if !stopRequestedDuringRestart, !isRetired { await beginStart() }
        case .notAccepted(let reason):
            lastRestartFailure = outcome
            handle(.warning("The scanner didn't accept the restart: \(reason)"))
        case .didNotComeBack:
            lastRestartFailure = outcome
            handle(.warning("The scanner didn't answer after the restart. If it stays silent, power-cycle it."))
        }
        return outcome
    }

    // MARK: Sleep and wake

    /// Before sleep: stops the session (`PSI,0`, TEARDOWN), remembering whether it was running
    /// (waiting for the cooldown or for a USB scanner, connecting, connected, retrying after a
    /// wake, restarting, or a `start()` in flight whose task hasn't moved the phase yet).
    /// A restart in flight finishes but doesn't start the session; `resume()` does.
    public func suspend() async {
        var wasRunning: Bool
        switch phase {
        case .waitingForCooldown, .waitingForScanner, .connecting, .connected: wasRunning = true
        default: wasRunning = retryTask != nil
        }
        if startTask != nil { wasRunning = true }
        if restartTask != nil {
            wasRunning = true
            stopRequestedDuringRestart = true
        }
        suspendGeneration += 1
        suspending = true
        startRequestedWhileSuspending = false
        stopRequestedWhileSuspending = false
        await halt()
        suspending = false
        // Keep an earlier suspend's "was running": a second sleep after a dark wake (no resume in
        // between) finds the session already stopped, and must not make the full wake forget it.
        // A stop() during this suspend wins over both (only stop() and resume() clear the flag).
        resumeOnWake = (resumeOnWake || wasRunning || startRequestedWhileSuspending) && !stopRequestedWhileSuspending
    }

    private func requestStartWhileSuspending() {
        startRequestedWhileSuspending = true
        stopRequestedWhileSuspending = false
    }

    /// After wake: starts again if `suspend()` stopped a running session, through the cooldown gate
    /// (a wake within the reconnect wait of the TEARDOWN waits, with the countdown: the station's
    /// value after a clean close, 120 s otherwise). If that start ends in
    /// `.noAnswer` (the network isn't up yet), retries on `reconnectBackoff` (5, 10, 20, 30 s, then
    /// the last value repeating) until connected or `stop()`/`suspend()`; the phase stays
    /// `.noAnswer` between attempts. Returns after the first attempt; the retries run on their own.
    /// Nothing touches RTSP before `MDL` answers: the runner connects audio only after `MDL`, `VER`
    /// and `PSI`.
    ///
    /// Only a no-answer from a network station's runner start is retried; a configuration failure
    /// (no address, the lock, settings, the hit log) stays as it is, and so does every failure of
    /// a USB station (each retry would open its port again; design §13 Z). A restart still in
    /// flight is awaited first;
    /// a `stop()` meanwhile wins, and a `suspend()` meanwhile leaves the start for the next wake.
    public func resume() async {
        guard resumeOnWake, !isRetired else { return }
        resumeOnWake = false
        if let restartTask {
            let stops = stopGeneration, suspends = suspendGeneration
            _ = await restartTask.value
            guard stopGeneration == stops, suspendGeneration == suspends, !isRetired else { return }
        }
        await start()
        if shouldRetry { startRetries() }
    }

    private var shouldRetry: Bool {
        guard lastFailureWasNoAnswer, case .noAnswer = phase else { return false }
        return true
    }

    private func startRetries() {
        cancelRetries()
        retryGeneration += 1
        let generation = retryGeneration
        let backoff = environment.reconnectBackoff
        retryTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                let delay = backoff.isEmpty ? Duration.seconds(30) : backoff[min(attempt, backoff.count - 1)]
                attempt += 1
                do { try await Task.sleep(for: delay) } catch { break }
                guard let self, !Task.isCancelled, self.shouldRetry else { break }
                await self.start()
                guard self.shouldRetry else { break }
            }
            guard let self, self.retryGeneration == generation else { return }
            self.retryTask = nil
        }
    }

    private func cancelRetries() {
        retryTask?.cancel()
        retryTask = nil
        retryGeneration += 1
    }

    // MARK: Stop

    /// Stops the station (see the type's documentation). Idempotent; concurrent callers share one
    /// teardown and all return when it's done.
    public func stop() async {
        stopGeneration += 1
        resumeOnWake = false
        if suspending {
            stopRequestedWhileSuspending = true
            startRequestedWhileSuspending = false
        }
        stopRequestedDuringRestart = true
        await halt()
    }

    /// `stop()` without forgetting a wake or a restart in flight: ends retries, then the shared
    /// single-flight teardown.
    private func halt() async {
        // First, before any await: no queued key goes out once a stop has begun, nor a quick-key set or a menu
        // command still waiting for the client's request slot (detaching revokes their permits; `performStop`'s
        // phase change, a task hop later, would detach them again). The quick keys first, as in `phase`.
        stopKeyQueue()
        quickKeys.detach()
        menu.detach()
        haltCount += 1
        cancelRetries()
        if let stopTask {
            await stopTask.value
            return
        }
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
    }

    private func performStop() async {
        stopFlag.set()
        switch phase {
        case .waitingForCooldown, .waitingForScanner, .connecting, .connected: phase = .stopping
        case .idle, .inUse, .scannerInUse, .noAnswer, .stopping, .stopped: break
        }
        await teardownRun()
        // A start in flight sees the flag (or the runner's cancellation) and unwinds without
        // opening anything; then close whatever it had opened. A USB station's teardown after a
        // lost scanner is awaited the same way.
        if let startTask { await startTask.value }
        if let lossTask { await lossTask.value }
        await teardownRun()
        switch phase {
        case .inUse, .scannerInUse, .noAnswer: break
        default: phase = .stopped
        }
    }

    /// Stops the loops and playback, then the runner (`PSI,0`, TEARDOWN), drains its streams, and
    /// closes the log and the lock. Safe to call more than once.
    func teardownRun() async {
        await teardownRunner()
        await closeResources()
    }

    /// `teardownRun()` without closing the log and the lock: the runner is gone, the station is
    /// still held (a USB station's port left between its resolution and the runner's start).
    func teardownRunner() async {
        stopKeyQueue()  // first (a failed start comes here without halt())
        displayTask?.cancel()
        batteryTask?.cancel()
        await displayTask?.value  // so no STS follows PSI,0
        displayTask = nil
        await stopBatteryLoop()  // nor a GCS
        quickKeys.detach()
        await quickKeys.quiesce()  // nor a quick-key read (a read under way finishes first)
        menu.detach()
        await menu.quiesce()  // nor a menu read
        cancelPendingLevels()
        stopPlayback()
        relayTask?.cancel()
        relayTask = nil
        levelsTask?.cancel()
        levelsTask = nil
        // Not current any more before its last events drain, so a late `.connected` is ignored.
        let runner = self.runner
        self.runner = nil
        if let runner {
            await runner.stop()
            await eventsTask?.value
            await statusTask?.value
            // Its final `.audio(.stopped)` was drained after it stopped being current; apply it
            // here. A `.failed` stays visible (with its hint) until the next start.
            switch audio {
            case .idle, .failed, .stopped: break
            case .starting, .streaming, .recovering: audio = .stopped
            }
            // Its line-in's `.stopped` too; a `.failed` or `.denied` stays, as audio's does.
            switch lineIn {
            case nil, .failed?, .denied?, .stopped?: break
            case .starting?, .streaming?, .missing?: lineIn = .stopped
            }
        }
        clearMeter()
        eventsTask = nil
        statusTask = nil
    }

    func closeResources() async {
        let log = hitLog
        hitLog = nil
        await log?.close()
        lock?.release()
        lock = nil
    }
}
