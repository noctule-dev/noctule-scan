// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation
import NoctuleKit

/// What a running station reports, in order.
public enum RunnerEvent: Sendable, Equatable {
    case connected(model: String, firmware: String)
    /// A USB station's scanner went away (unplugged, switched off, switched to mass storage);
    /// `hint` says what to do about it. With `resumeAfterDisconnect`, `.connected` follows when
    /// the scanner is back.
    case disconnected(hint: String)
    case audio(AudioSessionState)
    /// A USB station's line-in reported a state (line-in design §5.4): each one its source reports,
    /// in order.
    case lineIn(LineInState)
    case hitStarted(LoggedHit)
    /// A USB station's line-in clipped during this open hit (line-in design §5.3): once per hit, at
    /// its first clip. `audioClipped` is true; the hit is as last reported.
    case clipped(LoggedHit)
    case hitEnded(LoggedHit)
    case recording(RecordingResult)
    case warning(String)
    case stopped
}

public enum StationRunnerError: Error, Equatable {
    /// `start()` was already called.
    case alreadyStarted
    /// `stop()` ran before or during `start()`.
    case stopped
    /// The station has no host to connect to.
    case missingHost
}

/// Runs one station: scanner control (`PSI` pushes), audio (a network station's `AudioSession`, or
/// a USB station's line-in), hit detection, per-transmission recording, and the hit log.
///
/// **Event loop.** One serial consumer. Push updates, audio chunks, the end of the push stream and
/// a 1 s tick are each fed by a small task into one `AsyncStream` of inputs, and one consumer task
/// awaits `handle(_:)` for each in turn. So, although `handle` awaits the hit log (an actor) and
/// the actor is re-entrant there, no two inputs are ever processed at once, and the detector, the
/// recorder (not `Sendable`, owned by this actor) and the log always see events in arrival order.
/// Audio state changes are applied directly: that handler never suspends.
///
/// **Start**, in order: `log.closeDangling`; the retention purge (when `retentionDays` is set:
/// hits that started before now minus that many days, and their files); the transport from
/// `transportFactory` (UDP to the host, or a USB station's serial port); `connect`, `MDL`, `VER`,
/// then `.connected`; `PSI,<ms>` at the model's `ModelProfile.pushInterval` (100 ms on the SDS150
/// and the SDS200, 500 ms otherwise and for a name that is no known model; `pushInterval` in its
/// place when given) with the push keep-alive (see "Push keep-alive"); then,
/// when the station has audio (`hasAudio`), the
/// AudioSession (with `audioConfig`, its cooldown store replaced by `cooldownStore`, and an `MDL`
/// probe on this client when the config has none). An audio start failure, a reconnect cooldown
/// included, is a `.warning`; the station keeps logging without audio. A failure before audio
/// (log, no host or no port, connect, `MDL`, `VER`, `PSI`) stops the runner (`.stopped`, the
/// events stream finishes) and throws; a USB station whose port isn't there at start throws
/// `StationTransportError.scannerNotFound` and does not wait for it. A station with a saved port
/// uses that port or none (it never falls back to a listed one, Plan 8 D1); only a station with
/// no saved port takes the only port the factory lists. The default `transportFactory` lists no
/// ports (`FixedSerialPortListing.empty`), so a runner built without one opens a USB station's
/// configured port or nothing; only the `noctule` shell (`USBDetection`) and the app's shell
/// (`SessionEnvironment.applyingOverrides`, the same rule, from `AppDelegate` through
/// `StationSession`) hand in the system's listing.
///
/// **Audio over the network.** `hasAudio` is true for a network station that saves audio
/// (`saveAudio != .never`) whose scanner, once `MDL` has named a known model, has network audio
/// (`ModelProfile.hasNetworkAudio`). A USB station never has an AudioSession and never calls the
/// cooldown store: its only audio is a line-in (below). Without one it behaves as with save-audio
/// "never": no recording is written. Hit detection and the hit log are the same.
///
/// **A USB station's line-in** (line-in design §5.4). `hasAudio` is true for a USB station with a
/// line-in (`device.lineIn`, then each `replaceLineIn`) and a `lineInSources` factory to make its
/// source, whatever its save-audio rule: that rule governs recordings only, so with "never" the
/// tap and the meter still run. The source is made and started once, after the first `.connected`
/// (where a network station starts its AudioSession), and is neither stopped when the scanner goes
/// away nor started again by a resume: the scanner's absence isn't the line-in's business, and no
/// hit runs while it is away, so nothing is recorded. Its `start()` is never awaited, there or at
/// stop: it can wait on the permission prompt or a slow device for as long as it takes. Its chunks
/// take the AudioSession's path (the consumer, the tap, the recorder, placed at
/// `receivedAt + ModelProfile.lineInAudioOffset`); its levels take the consumer too, which yields
/// each to `liveLevels()` and judges clipping and silence with it (below). Each state it
/// reports is a `.lineIn` event: `.streaming` counts as audio streaming (hits waiting for audio
/// start recording, as above), and any other state as not. `.missing` warns once per missing spell
/// (`lineInMissingMessage`; the source watches for the device and reports `.streaming` when it is
/// back), and `.failed(reason)` and `.denied` warn once per source (the reason itself, or
/// `lineInDeniedMessage`). Hits are logged without audio meanwhile. A source the runner has let go
/// of (replaced, or stopped) reports nothing more.
///
/// **Clipped and silent hits** (line-in design §5.3). A hit is a *line-in hit* when a source is
/// running as it starts; its `audioClipped` is then true or false (in `.hitEnded` and in the log),
/// and nil for any other hit. Levels are placed as chunks are, at `at + lineInAudioOffset`.
/// - A clipped level counts for every open hit that started at or before its time: the first one
///   in a hit marks it clipped and emits `.clipped`; later ones add nothing.
/// - The *idle floor* is the median `rmsDBFS` of the levels of the last 60 s (by their `at`) that
///   fell in no open hit (nor in one skipped while logging was paused). Until there is one, no
///   hit is judged.
/// - Each line-in hit keeps the highest `rmsDBFS` it got. At its end, a hit that ended normally
///   (the detector ended it: `signalLost`, `channelChanged` or `maxLength`), of at least 2 s
///   (`startInstant` to `endInstant`), during which the line-in was `.streaming` throughout, with
///   at least one level, is *silent* when that maximum is under the floor + 15 dB (or is digital
///   silence, −∞), else *loud*. Any other hit (cut short by `stop()`, a scanner disconnect or a
///   push stall; shorter; or with the input missing, failed or stopped at any point) is no
///   evidence either way: it neither counts nor resets. So a stop never raises the warning. A
///   clipped level marks a hit however it ends.
/// - The third silent hit in a row warns `silentLineInMessage`, once; a loud hit resets the count
///   and re-arms the warning.
///
/// **A USB station whose scanner goes away** (SDS150 design §4.5; routine for a handheld). When
/// the push stream of a `usbSerial` station ends (the port closed under it, or the scanner
/// rejected `PSI`), the consumer, in order: ends open hits `stalled` and logs them, as on any push
/// end; disconnects the client, which closes the port and writes nothing to it (`control()` is nil
/// from here); emits `.disconnected(hint:)`, once, in place of the stall warning. The hint is
/// `SerialPort.noneFoundHint` ("Plug the scanner in…") when the station's port no longer resolves
/// (`transportFactory` finds none), and `SerialPort.notSendingUpdatesHint` when it still does (the
/// scanner refused `PSI`, or the subscription was ended, with the cable in). Nothing more is
/// sent, and no stall warning is raised, while the scanner is away.
///
/// **Only a connection that was working is resumed.** If the connection that just ended never
/// delivered a push update (the scanner rejected `PSI`, or the port answered `MDL` and `VER` and
/// then went away before its first push), the runner warns "the scanner isn't sending status
/// updates; not reconnecting by itself" (`notResumingMessage`), once, after `.disconnected`, and
/// does nothing more until `stop()`: no poll, no reopen. That holds for the first connection and
/// for every resumed one, with `resumeAfterDisconnect` on or off. Without it, a scanner that
/// refuses `PSI` over serial would get an open, `MDL`, `VER`, `PSI`, close cycle every poll for as
/// long as it kept refusing: a command loop against hardware. The cost: a scanner unplugged
/// within the first push interval of a connection has to be started again by hand. `willResume`,
/// set before each `.disconnected`, says which case applies.
///
/// Otherwise, with `resumeAfterDisconnect`, a wait task polls every `portPollInterval`. Each poll asks
/// `transportFactory` for the station's port (a `stat` and a port listing; that is all a poll
/// does while there is no port, and nothing is opened or sent). A port that is there is *probed*:
/// opened and asked one `MDL`.
/// - The open is refused because another program has the port (busy): nothing was sent, it isn't
///   a probe, and the next poll tries again, for as long as it takes.
/// - Another scanner answers (`isSameScanner`: a different model, or, when either name isn't a
///   known model, a different name): the port is closed with nothing else sent, a `.warning` says
///   so once per name per wait, and that port is not probed again.
/// - The same scanner answers: it becomes the client; `VER`; a new `HitDetector` anchor;
///   `PSI,<ms>` (the same interval); `.connected` again. If this connection is lost too, the whole cycle
///   repeats.
/// - Anything else is a failed probe: the open failed for another reason, `MDL` went unanswered
///   or couldn't be written, or the same scanner answered `MDL` and then `VER` went unanswered.
///   The port is closed. The next poll probes again, up to `maxProbes` (3) failed probes; after
///   the third the runner warns "the scanner isn't answering; unplug it and plug it in again"
///   (`notAnsweringMessage`), once, and that port is not probed again.
/// - The same scanner answered `MDL` and `VER`, but `PSI` couldn't be written whole: part of it
///   may have reached the scanner, so the port is closed with nothing more sent, the runner gives
///   the same warning at once, and that port is not probed again (no second `PSI` that could
///   subscribe twice).
///
/// **A port is probed a bounded number of times per appearance.** "Not probed again" lasts until
/// the port has *disappeared*: a poll at which the station's port doesn't resolve to that path
/// (nothing found, or another path). Then the record is dropped and the next port to appear
/// starts fresh. So a wrong scanner left plugged in gets one open and one `MDL`, and a port that
/// never answers gets three, not one every poll for as long as it stays: each open toggles the
/// port's control lines on hardware whose reaction to that is unknown. Each wait starts with no
/// record. A port unplugged and plugged in again between two polls isn't seen to disappear (the
/// path is the same), so it keeps its record; whether an SDS150 can come back within the default
/// 1 s poll is unmeasured.
///
/// `MDL` and `VER` are read-only and sent once per probe; no state-changing command is ever
/// resent. With `resumeAfterDisconnect == false` nothing happens after `.disconnected` (and the
/// warning above, when it applies) until `stop()`. A network station's push end is unchanged
/// ("Push stall" below).
///
/// **Hits.** On `.started` (unless logging is paused; see "App hooks"): `log.begin(hit,
/// audioPath: nil)` gives `isNew` (trunk: first sighting of the talkgroup; conventional and weather: not programmed); `record` is `everyTransmission`,
/// `onlyNew` and `isNew`, or never, and false while audio isn't streaming (but see "already on
/// air" below); then `recorder.handle(.started)`; if a file opened, `log.setAudioPath` stores its path at once, so a
/// crash leaves the WAV findable. Every `.updated` goes to the recorder. On `.ended`:
/// `recorder.handle(.ended)`, then `log.end` with the recording's result, which may arrive then or
/// later (from `ingest`, the next `.started`, or `finishAll`), so ended hits wait in a map until
/// it does. An unrecorded hit ends at once with no path. A failed recording logs its `audioError`
/// and the first one also raises a `.warning`.
///
/// **A hit already on air when audio starts** (always so on a weather channel, which transmits
/// continuously): a hit whose `saveAudio` rule says record, but which started before audio first
/// reached `.streaming` (or after it `.failed` or `.stopped`), is marked as waiting for audio.
/// A hit that starts while audio is `.recovering` does **not** wait: `audioStreaming` is cleared
/// only on `.failed` and `.stopped`, so it records at once; its file opens and fills when chunks
/// resume (with no gap for the outage), and if recovery ends in `.failed` the empty file is
/// skipped as too short and the hit is logged with no audio. Each time the AudioSession reaches `.streaming`, an input is queued, and the consumer
/// starts recording every open hit still waiting, as if it had just started: the file is named
/// from the hit's start (the usual name) and `log.setAudioPath` stores its path at once. Such a
/// recording has **no pre-roll** and begins with the first audio received after streaming
/// started; the part of the transmission before that is not in the file. A hit that `saveAudio`
/// leaves unrecorded stays so, and a hit that is already recording is never started again, so a
/// streaming → recovering → streaming cycle during one hit keeps one file.
///
/// **Audio that stops.** Each tick also calls `recorder.closeExpired(now:)`, so an ended hit's
/// recording closes (and its end is logged) about post-roll + 0.5 s after the hit's last active
/// push even when no further chunk arrives. No AudioSession `stallTimeout` is set: whether the
/// scanner's stream is squelch-gated is unmeasured, and a false stall would force a reconnect
/// through the reconnect cooldown (120 s after anything but a clean close).
///
/// **Push stall.** If no push arrives for `stallEnd` (3 s, also passed to the detector), the detector's tick
/// ends the open hit `stalled` and the runner warns "scanner stopped sending updates" (once per
/// stall). If the push stream itself ends (the scanner rejected `PSI`, or the link went), the
/// open hit ends `stalled` through `HitDetector.finish(now:reason:)` and, on a network station,
/// the same warning is raised; audio keeps running until `stop()`. (A USB station reports
/// `.disconnected` instead; see above.)
///
/// **Push keep-alive.** On a USB station, both subscriptions (at start, and each resume after a
/// replug) pass the keep-alive of the model `MDL` named (`PushKeepAlive.forSubscription`: the
/// SDS150's `KAL` every 60 s, or every `keepAliveInterval` when set, for tests), so the scanner
/// doesn't stop pushing after 183 s; the client writes it while that push runs and never after
/// its `PSI,0`. A network station, and a model without one, gets none: nothing on the network
/// path changes. On the real SDS150 `KAL` every 60 s kept the pushes going through an hour of
/// `noctule log` (2026-11-12). A keep-alive write that fails is a `.warning`
/// (`keepAliveFailedMessage`), once per subscription; the client never resends it, so the
/// scanner's pushes may then stop, and the rule below replaces the subscription.
///
/// **A subscription that stops pushing is replaced** (design §13 P). After a pause longer than
/// 183 s (the process stopped, the Mac asleep with the scanner connected), or after a failed
/// keep-alive write, the scanner may have stopped pushing, and whether a late `KAL` starts it
/// again was never tried on hardware; a new `PSI` does. So on each tick, on a `usbSerial` station
/// with `resumeAfterDisconnect` that is connected, whose connection has delivered a push and
/// whose subscription was started with a keep-alive (whether or not a write of it has failed
/// since), once no push has arrived
/// for one keep-alive interval, and never less than `stallEnd` (so a test's short interval can't
/// replace a subscription between two pushes; the stall warning, above, comes first), the runner
/// warns "the scanner stopped sending status updates; subscribing again"
/// (`resubscribingMessage`) and ends the subscription with `client.stopPush()` (`PSI,0`; a
/// failure is ignored). The end of the push stream then takes the path of any push end on a USB
/// station: open hits were already ended by the stall, the port is closed,
/// `.disconnected(hint: SerialPort.notSendingUpdatesHint)` (the port is still there),
/// `willResume`, and the bounded resume opens it, asks `MDL` and `VER`, and sends a fresh `PSI`.
/// It happens once per connection: a resumed connection is replaced only after it has delivered
/// a push of its own, so a scanner that answers but never pushes is not reopened in a loop (the
/// connection that never pushed isn't resumed). If the late `KAL` does start the pushes again,
/// they arrive before the threshold (the first `KAL` goes out one interval after the `PSI`, and
/// the threshold counts from the last push) and nothing is replaced. A network station, and a
/// model without a keep-alive, never resubscribe: they only warn of the stall. Nor does a runner
/// without `resumeAfterDisconnect`, which couldn't subscribe again: ending the subscription would
/// leave a station that is still connected disconnected for good.
///
/// **App hooks.** The app reads the station live through these; none adds a consumer of the
/// AudioSession's chunk stream or the client's push stream.
/// - `liveStatus` gets every push's `ScannerInfo` from the consumer, as it handles the push
///   (`bufferingNewest(1)`), and finishes with `events` at stop.
/// - `liveAudio()` returns a tap the consumer yields each chunk into before the recorder sees it
///   (`bufferingNewest(50)`, so a slow reader loses the oldest chunks, never the recording). It is
///   the runner's own stream: dropping it (its `onTermination` fires `.cancelled`) only ends the
///   tap, never the AudioSession, a recording or the cooldown. A second call finishes the first
///   tap; stop finishes the tap (step 7).
/// - `control()` is the connected `ScannerClient`, nil before `.connected`, while a USB station's
///   scanner is away (from the disconnect until the `.connected` that follows a resume, which
///   brings a new client), and from the moment `stop()` begins. The caller's commands go through
///   the same client as `PSI`.
/// - `setLoggingPaused(true)`: the detector keeps running, so hit boundaries stay right, but a hit
///   that **starts** while paused is skipped entirely: no `log.begin`, no recording, no hit
///   events, and its updates and end are ignored even after resuming. A hit already open when
///   logging pauses finishes normally (logged, and recorded if it was). Display, pushes and audio
///   continue.
/// - `liveLevels()` returns a stream of the line-in's meter readings (`bufferingNewest(1)`), which
///   the consumer yields each into as it handles it. A second call finishes the first; stop
///   finishes it (step 7).
/// - `replaceLineIn(_:)` stops the line-in's source and starts one for another input, or none,
///   without touching the scanner. Before the first `.connected` it only changes the input the
///   start will use; of two calls in flight, the later one's input wins.
/// - `audioRestartHint()` is the AudioSession's `restartHint` while its state is `.failed`
///   (from the runner's `MDL` probe), else nil. `audio.stop()` clears it, so it is nil after stop.
///
/// **Stop** (single-flight, idempotent; concurrent callers share one teardown), in order:
/// 1. stop feeding: a `start()` still in flight is cancelled and awaited, and so is a USB station's
///    wait for its scanner, with any resume attempt in flight (the poll's sleep and the attempt's
///    `MDL` or `VER` end at once; an attempt that hasn't yet seen the same scanner answer closes
///    its port itself, having sent nothing but `MDL`; one that has leaves its client for step 4,
///    so a `PSI` it started is always followed by `PSI,0`). Then the tick stops, the input
///    stream is finished and its consumer awaited (inputs still queued are dropped). The push and
///    chunk feeders are not cancelled: cancelling the chunk stream's consumer would make
///    `AudioSession` stop itself early, out of order. They end when their streams finish below.
/// 2. `detector.finish(now)` (reason `stopped`), forwarded to the recorder;
/// 3. `recorder.finishAll()`, then `log.end` for every hit still waiting;
/// 4. `client.stopPush()` (`PSI,0`; a failure is ignored, and with the link gone it fails at once,
///    so a stop after an unplug never waits), then `client.disconnect()`. While a USB station's
///    scanner is away there is no client, and nothing is sent;
/// 5. `audio.stop()` (TEARDOWN; it honours the reconnect cooldown through its store), or a USB
///    station's line-in source stopped (its `.lineIn(.stopped)` reported), whether or not its
///    start has returned; nothing is torn down on the scanner, and no cooldown is involved;
/// 6. a `.warning` if the AudioSession still lists `unreleasedSessions`;
/// 7. the audio and level taps finish, `.stopped`, and the events and `liveStatus` streams finish.
public actor StationRunner {
    /// Every event, in order. Unbounded; meant for one consumer. Finishes after `.stopped`.
    public nonisolated let events: AsyncStream<RunnerEvent>
    /// Every push's `ScannerInfo`. Keeps only the newest. Finishes with `events`.
    public nonisolated let liveStatus: AsyncStream<ScannerInfo>

    static let stalledMessage = "scanner stopped sending updates"
    /// Raised once per missing spell when the line-in's input isn't there.
    public static func lineInMissingMessage(deviceName: String) -> String {
        "the audio input \"\(deviceName)\" isn't connected; logging without audio"
    }
    /// What the app shows when a hit's line-in clipped (`.clipped`), naming its channel.
    public static func clippedMessage(channel: String) -> String {
        "The audio input clipped during \"\(channel)\". Turn the scanner's volume down a step."
    }
    /// Raised when three line-in hits in a row were silent (see "Clipped and silent hits").
    public static let silentLineInMessage =
        "no audio on the line-in during the last 3 transmissions; check the cable and the scanner's volume"
    /// How many silent hits in a row raise `silentLineInMessage`.
    static let silentHitsToWarn = 3
    /// How far above the idle floor a line-in hit's level must rise to carry audio.
    static let silentMarginDB = 15.0
    /// The shortest hit judged silent or loud.
    static let shortestJudgedHit: Duration = .seconds(2)
    /// The ends of a hit the detector decided on its own; only such a hit is judged silent or loud.
    static let normalEnds: Set<Hit.EndReason> = [.signalLost, .channelChanged, .maxLength]
    /// How far back the idle floor looks.
    static let idleFloorWindow: Duration = .seconds(60)
    /// Raised once per source when the system won't let the app use audio input.
    public static let lineInDeniedMessage =
        "Noctule Scan isn't allowed to use audio input. Allow it in System Settings › Privacy & Security › Microphone."
    /// Raised when a USB subscription that had pushed stops for a keep-alive interval, and is
    /// ended to be replaced by a fresh `PSI` (see "A subscription that stops pushing is replaced").
    static let resubscribingMessage = "the scanner stopped sending status updates; subscribing again"
    /// Raised, once per subscription, when a write of its keep-alive fails.
    static func keepAliveFailedMessage(_ error: any Error) -> String {
        "couldn't send the keep-alive (\(error)); status updates may stop"
    }
    /// Raised when a USB connection ends without ever having delivered a push update.
    static let notResumingMessage = "the scanner isn't sending status updates; not reconnecting by itself"
    /// Raised when a port the wait found has used up its probes without a usable answer.
    static let notAnsweringMessage = "the scanner isn't answering; unplug it and plug it in again"
    /// How many failed probes one appearance of a port gets while a USB station waits.
    static let maxProbes = 3
    /// The detector's `stallEnd`, and how long without a push before the runner warns.
    static let stallEnd: Duration = .seconds(3)
    static let tickInterval: Duration = .seconds(1)

    private enum Input: Sendable {
        case push(PushUpdate)
        case pushEnded
        case chunk(AudioChunk)
        case tick
        /// Audio reached `.streaming`: start recording hits that were waiting for it.
        case audioStreaming
        /// A meter reading from the current line-in source.
        case level(LineInLevel)
    }

    /// What the wait knows about the port it last probed (see "A port is probed a bounded number
    /// of times per appearance").
    private struct PortProbe {
        /// The resolved path the record is about.
        var path: String
        /// Probes of this appearance that got no usable answer.
        var failed = 0
        /// No further probe until the port has disappeared: another scanner answered, or the
        /// probes are used up.
        var leftAlone = false
    }

    /// A USB station's line-in source and the tasks that feed what it reports to the runner.
    private struct RunningLineIn {
        let source: any LineInSource
        let chunkFeeder: Task<Void, Never>
        let levelFeeder: Task<Void, Never>
        let stateFeeder: Task<Void, Never>
    }

    private struct OpenHit {
        /// The hit as last reported (`.started` or `.updated`).
        var hit: Hit
        var record: Bool
        /// `saveAudio` says record, but audio wasn't streaming when the hit started.
        var waitingForAudio: Bool
        var isNew: Bool
        var audioPath: String?
        /// A recording result that arrived before the hit ended (an open or write failure).
        var earlyResult: RecordingResult?
        /// A line-in source was running when the hit started (see "Clipped and silent hits").
        var lineInHit = false
        /// A clipped level counted for this hit.
        var clipped = false
        /// The highest `rmsDBFS` among the levels that counted for this hit; nil: none yet.
        var maxRMS: Double?
        /// The line-in was `.streaming` when the hit started and hasn't left it since.
        var streamingThroughout = false

        /// `audioClipped` for this hit: nil unless it is a line-in hit.
        var audioClipped: Bool? { lineInHit ? clipped : nil }
    }

    private let station: Station
    private let device: StationDeviceSettings
    private let log: HitLog
    private let recordingsRoot: URL
    private let cooldownStore: any RTSPCooldownStore
    private let transportFactory: StationTransportFactory
    private let resumeAfterDisconnect: Bool
    private let portPollInterval: Duration
    private let audioConfig: AudioSessionConfig
    /// In place of the model's push interval (tests); nil keeps the model's.
    private let pushInterval: Duration?
    /// In place of the model's keep-alive interval (tests); nil keeps the model's.
    private let keepAliveInterval: Duration?
    private let eventsContinuation: AsyncStream<RunnerEvent>.Continuation
    private let liveStatusContinuation: AsyncStream<ScannerInfo>.Continuation
    /// The current `liveAudio()` tap, if any.
    private var audioTap: AsyncStream<AudioChunk>.Continuation?
    /// The current `liveLevels()` stream, if any.
    private var levelTap: AsyncStream<LineInLevel>.Continuation?
    /// Makes a USB station's line-in source; nil: no line-in, whatever the device settings say.
    private let lineInSources: LineInSourceFactory?
    /// The input a USB station's line-in listens to (`device.lineIn`, then each `replaceLineIn`);
    /// nil: none. Always nil on a network station.
    private var lineInConfig: LineInConfig?
    /// Set when `start()` reaches the line-in, after the first `.connected`: from then on
    /// `replaceLineIn` stops and starts sources itself.
    private var lineInArmed = false
    /// Counts `replaceLineIn` calls, so that of two in flight only the later starts a source.
    private var lineInGeneration = 0
    private var lineIn: RunningLineIn?
    /// The current missing spell has been warned about.
    private var lineInMissingWarned = false
    /// The current source's `.failed` or `.denied` has been warned about.
    private var lineInFailureWarned = false
    /// Where line-in audio and levels lie against the pushes (`ModelProfile.lineInAudioOffset`).
    private var lineInOffset: Duration = .zero
    /// The `rmsDBFS` of the levels that fell in no open hit, oldest first, over the last
    /// `idleFloorWindow`.
    private var idleLevels: [(at: ContinuousClock.Instant, rms: Double)] = []
    /// Silent line-in hits in a row (see "Clipped and silent hits").
    private var silentHits = 0
    /// `silentLineInMessage` has been raised since the last loud hit.
    private var silentWarned = false
    /// Set once `.connected` is emitted.
    private var connected = false
    private var loggingPaused = false
    /// Hits that started while logging was paused: their updates and end are ignored.
    private var skippedHits: Set<UUID> = []
    private let inputs: AsyncStream<Input>
    private let inputContinuation: AsyncStream<Input>.Continuation

    private var started = false
    private var stopping = false
    private var startTask: Task<Void, any Error>?
    private var stopTask: Task<Void, Never>?
    /// A USB station's wait for its scanner after a disconnect (the polls and resume attempts).
    private var resumeTask: Task<Void, Never>?
    /// What `MDL` answered on the first connection: the scanner a resume must find again.
    private var scannerName: String?
    /// Other scanners already warned about during the current wait.
    private var warnedScanners: Set<String> = []
    /// The port the current wait last probed; nil when none is there, or none was probed yet.
    /// Each wait starts without one.
    private var portProbe: PortProbe?
    /// Whether the current connection has delivered a push update: false until its first push,
    /// and cleared again for each resumed connection. Only a USB connection that has is resumed
    /// by itself.
    private var pushDelivered = false
    /// The keep-alive interval of the current subscription; nil when it has none (a network
    /// station, or a model without one), which is never replaced.
    private var subscriptionKeepAlive: Duration?
    /// The current connection's subscription is being ended to be replaced: set when the runner
    /// sends its `PSI,0`, cleared by the next connection.
    private var resubscribing = false

    private var client: ScannerClient?
    private var audio: AudioSession?
    private var detector: HitDetector?
    private var recorder: TransmissionRecorder?

    private var consumerTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var pushFeeder: Task<Void, Never>?
    private var chunkFeeder: Task<Void, Never>?
    private var statesFeeder: Task<Void, Never>?

    /// Inputs are processed only while this is true (set once the push stream is live, cleared
    /// first thing in `stop()`).
    private var feeding = false
    private var audioStreaming = false
    private var lastPushAt: ContinuousClock.Instant = .now
    private var stallWarned = false
    private var recordingWarned = false
    private var openHits: [UUID: OpenHit] = [:]
    /// Ended hits whose recording result hasn't arrived yet, with their `isNew` and `audioClipped`.
    private var awaitingResult: [UUID: (hit: Hit, isNew: Bool, clipped: Bool?)] = [:]

    public init(station: Station, device: StationDeviceSettings, log: HitLog, recordingsRoot: URL,
                cooldownStore: any RTSPCooldownStore,
                transportFactory: StationTransportFactory = .init(ports: FixedSerialPortListing.empty),
                resumeAfterDisconnect: Bool = true, portPollInterval: Duration = .seconds(1),
                audioConfig: AudioSessionConfig = .init(), pushInterval: Duration? = nil,
                keepAliveInterval: Duration? = nil, lineInSources: LineInSourceFactory? = nil) {
        self.station = station
        self.device = device
        self.log = log
        self.recordingsRoot = recordingsRoot
        self.cooldownStore = cooldownStore
        self.transportFactory = transportFactory
        self.resumeAfterDisconnect = resumeAfterDisconnect
        self.portPollInterval = portPollInterval
        self.audioConfig = audioConfig
        self.pushInterval = pushInterval
        self.keepAliveInterval = keepAliveInterval
        self.lineInSources = lineInSources
        lineInConfig = station.connection.transport == .usbSerial ? device.lineIn : nil
        (events, eventsContinuation) = AsyncStream.makeStream(of: RunnerEvent.self)
        (liveStatus, liveStatusContinuation) = AsyncStream.makeStream(of: ScannerInfo.self, bufferingPolicy: .bufferingNewest(1))
        (inputs, inputContinuation) = AsyncStream.makeStream(of: Input.self)
    }

    /// The folder recordings go to: the device's override, else `recordingsRoot/<station name>`.
    var recordingsFolder: URL {
        if let folder = device.recordingsFolder { return URL(fileURLWithPath: folder, isDirectory: true) }
        return recordingsRoot.appendingPathComponent(RecordingName.sanitizeFolderName(station.name), isDirectory: true)
    }

    /// Whether the runner is going to wait for a USB station's scanner and resume by itself after
    /// its latest `.disconnected`: the connection that ended had delivered a push, and
    /// `resumeAfterDisconnect` is on. Set before that `.disconnected` is emitted, so a consumer of
    /// `events` can read it when the event arrives (`noctule log` exits instead of waiting when it
    /// is false). False before any disconnect.
    public private(set) var willResume = false

    /// Whether this station runs audio: a network station that saves audio and whose scanner has
    /// network audio (see "Audio over the network"; before `MDL` has answered, and for a name that
    /// is no known model, the model doesn't count against it), or a USB station with a line-in and
    /// a factory for its source (see "A USB station's line-in").
    public var hasAudio: Bool {
        if station.connection.transport == .usbSerial { return lineInConfig != nil && lineInSources != nil }
        guard station.connection.transport == .network, station.recording.saveAudio != .never else { return false }
        guard let scannerName, let model = ScannerModel(reported: scannerName) else { return true }
        return ModelProfile.profile(for: model).hasNetworkAudio
    }

    // MARK: App hooks

    /// A tap on the audio chunks the runner receives (see "App hooks" in the type's
    /// documentation). Keeps the newest 50 chunks. A second call finishes the previous tap; after
    /// `stop()` the tap comes back already finished. Dropping a tap never affects the session.
    public func liveAudio() -> AsyncStream<AudioChunk> {
        audioTap?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(50))
        if stopping {
            continuation.finish()
            audioTap = nil
        } else {
            audioTap = continuation
        }
        return stream
    }

    /// The line-in's meter readings (see "App hooks"). Keeps only the newest. A second call
    /// finishes the previous stream; after `stop()` the stream comes back already finished.
    public func liveLevels() -> AsyncStream<LineInLevel> {
        levelTap?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: LineInLevel.self, bufferingPolicy: .bufferingNewest(1))
        if stopping {
            continuation.finish()
            levelTap = nil
        } else {
            levelTap = continuation
        }
        return stream
    }

    /// Stops a USB station's line-in source and starts one for `config`, or none (see "App
    /// hooks"). The scanner is left alone. Does nothing on a network station or once `stop()` has
    /// begun.
    public func replaceLineIn(_ config: LineInConfig?) async {
        guard station.connection.transport == .usbSerial, !stopping else { return }
        lineInConfig = config
        lineInGeneration += 1
        let generation = lineInGeneration
        // Not started yet: the start takes the new input.
        guard lineInArmed else { return }
        if let lineIn { await retire(lineIn) }
        guard !stopping, generation == lineInGeneration, lineIn == nil, let config = lineInConfig else { return }
        startLineIn(config)
    }

    /// The connected scanner client, for the app's own commands; nil before `.connected`, while a
    /// USB station's scanner is away, and once `stop()` has begun.
    public func control() -> ScannerClient? {
        guard connected, !stopping else { return nil }
        return client
    }

    /// Pauses or resumes logging. While paused, a hit that starts is neither logged nor recorded
    /// (and raises no hit events); a hit already open finishes normally.
    public func setLoggingPaused(_ paused: Bool) {
        loggingPaused = paused
    }

    /// The AudioSession's restart hint while audio is `.failed`, else nil (also before audio
    /// starts, with `saveAudio == .never`, and after `stop()`).
    public func audioRestartHint() async -> RestartHint? {
        guard let audio, case .failed = await audio.state else { return nil }
        return await audio.restartHint
    }

    // MARK: Start

    /// Starts the station (see the type's documentation). Throws `alreadyStarted` on a second
    /// call, `stopped` if `stop()` ran first or meanwhile, or the error that stopped it; after a
    /// throw the runner is stopped.
    public func start() async throws {
        guard !started else { throw StationRunnerError.alreadyStarted }
        started = true
        guard !stopping else { throw StationRunnerError.stopped }
        let task = Task { try await self.performStart() }
        startTask = task
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            startTask = nil
        } catch {
            startTask = nil
            let wasStopping = stopping
            await stop()
            throw wasStopping ? StationRunnerError.stopped : error
        }
    }

    private func checkLive() throws {
        if stopping || Task.isCancelled { throw StationRunnerError.stopped }
    }

    private func performStart() async throws {
        let now = Date()
        _ = try await log.closeDangling(now: now)
        if let days = station.recording.retentionDays {
            do {
                let paths = try await log.purge(olderThan: now.addingTimeInterval(-Double(days) * 86_400))
                for path in paths where FileManager.default.fileExists(atPath: path) {
                    try? FileManager.default.removeItem(atPath: path)
                }
            } catch {
                emit(.warning("couldn't remove old hits: \(error)"))
            }
        }
        try checkLive()

        let made: (transport: any ScannerTransport, address: String)
        do {
            made = try transportFactory.make(station.connection, device: device)
        } catch StationTransportError.missingHost {
            throw StationRunnerError.missingHost
        }
        let client = ScannerClient(transport: made.transport)
        self.client = client
        try await client.connect()
        try checkLive()
        let model = try await client.modelInfo().reported
        try checkLive()
        let firmware = try await client.firmwareVersion()
        try checkLive()
        scannerName = model
        connected = true
        emit(.connected(model: model, firmware: firmware))

        detector = makeDetector()
        lineInOffset = recorderAudioOffset(model)
        recorder = TransmissionRecorder(folder: recordingsFolder, audioOffset: lineInOffset,
                                        minimumDuration: .milliseconds(Int64(station.recording.minimumDuration * 1000)))

        let keepAlive = pushKeepAlive(model)
        let pushes = try await client.startPushUpdates(interval: subscriptionInterval(model), keepAlive: keepAlive,
                                                       onKeepAliveFailure: keepAliveFailureHandler())
        try checkLive()
        subscriptionKeepAlive = keepAlive?.interval
        lastPushAt = .now
        feeding = true
        startConsumer()
        feedPushes(pushes)
        let inputs = inputContinuation
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                if Task.isCancelled { break }
                inputs.yield(.tick)
            }
        }

        if station.connection.transport == .usbSerial {
            // A USB station's audio is its line-in, started once, here, after the first connect.
            lineInArmed = true
            if let config = lineInConfig { startLineIn(config) }
            return
        }
        guard hasAudio else { return }
        try await startAudio(host: made.address, client: client)
    }

    /// Where the recorder places chunks against the pushes, for the scanner whose `MDL` said
    /// `reported`: a USB station's audio is a line-in, offset by the model's `lineInAudioOffset`;
    /// RTSP audio, and a name that is no known model, by nothing.
    private func recorderAudioOffset(_ reported: String) -> Duration {
        guard station.connection.transport == .usbSerial, let model = ScannerModel(reported: reported) else { return .zero }
        return ModelProfile.profile(for: model).lineInAudioOffset
    }

    /// How often a subscription asks for pushes, for the scanner whose `MDL` said `reported`: the
    /// model's `ModelProfile.pushInterval`, 500 ms for a name that is no known model, or
    /// `pushInterval` when given.
    private func subscriptionInterval(_ reported: String) -> Duration {
        if let pushInterval { return pushInterval }
        return ScannerModel(reported: reported).map { ModelProfile.profile(for: $0).pushInterval } ?? .milliseconds(500)
    }

    /// The keep-alive a subscription on this station passes, for the scanner whose `MDL` said
    /// `reported` (see "Push keep-alive").
    private func pushKeepAlive(_ reported: String) -> PushKeepAlive? {
        PushKeepAlive.forSubscription(reportedModel: reported, overSerial: station.connection.transport == .usbSerial,
                                      interval: keepAliveInterval)
    }

    /// What a subscription's keep-alive does with a write that failed (the client calls it once,
    /// from the keep-alive's task): a `.warning`.
    private nonisolated func keepAliveFailureHandler() -> @Sendable (any Error) -> Void {
        let events = eventsContinuation
        return { error in events.yield(.warning(Self.keepAliveFailedMessage(error))) }
    }

    /// A detector anchored at now (one per connection).
    private func makeDetector() -> HitDetector {
        HitDetector(anchor: (instant: ContinuousClock.now, date: Date()), stallEnd: Self.stallEnd,
                    maxTransmission: .milliseconds(Int64(station.recording.maxTransmission * 1000)))
    }

    /// Feeds one connection's pushes to the consumer, then the end of its push stream.
    private func feedPushes(_ pushes: AsyncStream<PushUpdate>) {
        let inputs = inputContinuation
        pushFeeder = Task {
            for await update in pushes { inputs.yield(.push(update)) }
            inputs.yield(.pushEnded)
        }
    }

    private func startAudio(host: String, client: ScannerClient) async throws {
        var config = audioConfig
        config.cooldownStore = cooldownStore
        if config.probe == nil {
            // Control-channel only (MDL); never touches the RTSP port.
            config.probe = { (try? await client.modelInfo()) != nil }
        }
        let audio = AudioSession(host: host, rtspPort: station.connection.rtspPort, config: config)
        self.audio = audio
        let states = audio.states
        statesFeeder = Task { [weak self] in
            for await state in states { await self?.audioStateChanged(state) }
        }
        do {
            let chunks = try await audio.start()
            try checkLive()
            audioStreaming = true
            let inputs = inputContinuation
            chunkFeeder = Task {
                for await chunk in chunks { inputs.yield(.chunk(chunk)) }
            }
            inputs.yield(.audioStreaming)
        } catch {
            try checkLive()
            emit(.warning("scanner audio unavailable; logging without audio: \(Self.describeAudioError(error))"))
        }
    }

    // MARK: A USB station's line-in

    /// Makes the line-in's source for `config` and starts it, without waiting for the start (see
    /// "A USB station's line-in"). Nothing without a factory.
    private func startLineIn(_ config: LineInConfig) {
        guard let lineInSources else { return }
        let source = lineInSources(config)
        lineInMissingWarned = false
        lineInFailureWarned = false
        let inputs = inputContinuation
        let chunks = source.chunks, levels = source.levels, states = source.states
        lineIn = RunningLineIn(
            source: source,
            chunkFeeder: Task {
                for await chunk in chunks { inputs.yield(.chunk(chunk)) }
            },
            levelFeeder: Task { [weak self] in
                for await level in levels { await self?.lineInLevel(level, from: source) }
            },
            stateFeeder: Task { [weak self] in
                for await state in states { await self?.lineInStateChanged(state, from: source) }
            })
        // Not awaited: a stop must never wait on a permission prompt or a slow device.
        Task { await source.start() }
    }

    /// Stops a line-in source and waits for what it reported last (its `.stopped`) to be handled;
    /// from then on it is no longer the station's. Its `start()` may still be pending.
    private func retire(_ running: RunningLineIn) async {
        await running.source.stop()
        // `stop()` finished the source's streams: each feeder ends once it has passed on the rest.
        await running.stateFeeder.value
        await running.levelFeeder.value
        await running.chunkFeeder.value
        guard lineIn?.source === running.source else { return }
        lineIn = nil
        audioStreaming = false
    }

    private func lineInLevel(_ level: LineInLevel, from source: any LineInSource) {
        guard lineIn?.source === source else { return }
        inputContinuation.yield(.level(level))
    }

    private func lineInStateChanged(_ state: LineInState, from source: any LineInSource) {
        guard lineIn?.source === source else { return }
        if case .streaming = state {
            audioStreaming = true
            inputContinuation.yield(.audioStreaming)
        } else {
            audioStreaming = false
            // An open hit with the input gone, even for a moment, says nothing about silence.
            for id in openHits.keys { openHits[id]?.streamingThroughout = false }
        }
        emit(.lineIn(state))
        // Any other state ends a missing spell.
        if case .missing = state {} else { lineInMissingWarned = false }
        switch state {
        case .missing(let name):
            guard !lineInMissingWarned else { return }
            lineInMissingWarned = true
            emit(.warning(Self.lineInMissingMessage(deviceName: name)))
        case .denied:
            warnLineInFailure(Self.lineInDeniedMessage)
        case .failed(let reason):
            warnLineInFailure(reason)
        case .starting, .streaming, .stopped:
            break
        }
    }

    private func warnLineInFailure(_ text: String) {
        guard !lineInFailureWarned else { return }
        lineInFailureWarned = true
        emit(.warning(text))
    }

    private static func describeAudioError(_ error: any Error) -> String {
        if case RTSPError.cooldown(let remaining) = error {
            return "the scanner's audio was used moments ago (reconnect cooldown, \(remaining.components.seconds + (remaining.components.attoseconds > 0 ? 1 : 0)) s left)"
        }
        return "\(error)"
    }

    private func startConsumer() {
        let inputs = self.inputs
        consumerTask = Task { [weak self] in
            for await input in inputs {
                guard let self else { return }
                await self.handle(input)
            }
        }
    }

    // MARK: Inputs

    private func handle(_ input: Input) async {
        guard feeding else { return }
        switch input {
        case .push(let update):
            pushDelivered = true
            lastPushAt = max(lastPushAt, update.receivedAt)
            stallWarned = false
            liveStatusContinuation.yield(update.info)
            guard var detector else { return }
            let events = detector.ingest(update)
            self.detector = detector
            await process(events)
        case .pushEnded:
            guard var detector else { return }
            let events = detector.finish(now: .now, reason: .stalled)
            self.detector = detector
            await process(events)
            if station.connection.transport == .usbSerial {
                await scannerWentAway()
            } else {
                warnStalled()
            }
        case .chunk(let chunk):
            audioTap?.yield(chunk)
            guard let recorder else { return }
            await apply(recorder.ingest(chunk))
        case .tick:
            let now = ContinuousClock.now
            if var detector {
                let events = detector.tick(now: now)
                self.detector = detector
                await process(events)
            }
            // Audio may stop arriving (dropped, or squelch-gated): close ended recordings anyway.
            if let recorder { await apply(recorder.closeExpired(now: now)) }
            try? recorder?.flush()
            // Not while a USB station's scanner is away: `.disconnected` already said so.
            if connected, now - lastPushAt >= Self.stallEnd { warnStalled() }
            if let threshold = replaceSubscriptionAfter, connected, now - lastPushAt >= threshold {
                await replaceSubscription()
            }
        case .audioStreaming:
            await recordHitsWaitingForAudio()
        case .level(let level):
            levelTap?.yield(level)
            lineInLevelArrived(level)
        }
    }

    // MARK: Clipped and silent hits

    /// Counts a line-in level for each open hit it falls in (its clip, its level), or else for the
    /// idle floor (see "Clipped and silent hits"). Runs on the consumer.
    private func lineInLevelArrived(_ level: LineInLevel) {
        let at = level.at + lineInOffset
        var inHit = !skippedHits.isEmpty
        for (id, open) in openHits where open.hit.startInstant <= at {
            inHit = true
            guard open.lineInHit else { continue }
            openHits[id]?.maxRMS = max(open.maxRMS ?? -.infinity, level.rmsDBFS)
            guard level.clipped, !open.clipped else { continue }
            openHits[id]?.clipped = true
            emit(.clipped(LoggedHit(hit: open.hit, audioPath: open.audioPath, audioError: nil,
                                    isNew: open.isNew, audioClipped: true)))
        }
        guard !inHit else { return }
        idleLevels.append((level.at, level.rmsDBFS))
        let since = level.at - Self.idleFloorWindow
        if let keep = idleLevels.firstIndex(where: { $0.at >= since }), keep > 0 {
            idleLevels.removeFirst(keep)
        }
    }

    /// The median `rmsDBFS` of `idleLevels`; nil while there are none.
    private var idleFloor: Double? {
        guard !idleLevels.isEmpty else { return nil }
        let sorted = idleLevels.map(\.rms).sorted()
        return sorted[(sorted.count - 1) / 2]
    }

    /// Judges an ended line-in hit silent or loud, and warns at the third silent one in a row
    /// (see "Clipped and silent hits"). A hit that can't be judged changes nothing.
    private func judgeSilence(_ hit: Hit, _ open: OpenHit) {
        guard let reason = hit.endReason, Self.normalEnds.contains(reason), open.lineInHit, open.streamingThroughout,
              let loudest = open.maxRMS, let floor = idleFloor,
              let end = hit.endInstant, end - hit.startInstant >= Self.shortestJudgedHit else { return }
        guard loudest < floor + Self.silentMarginDB || loudest == -.infinity else {
            silentHits = 0
            silentWarned = false
            return
        }
        silentHits += 1
        guard silentHits >= Self.silentHitsToWarn, !silentWarned else { return }
        silentWarned = true
        emit(.warning(Self.silentLineInMessage))
    }

    /// How long without a push before the current subscription is replaced; nil when it isn't
    /// one to replace (see "A subscription that stops pushing is replaced"): not a USB station,
    /// no resume, no keep-alive, no push yet on this connection, or already being replaced.
    private var replaceSubscriptionAfter: Duration? {
        guard station.connection.transport == .usbSerial, resumeAfterDisconnect, pushDelivered, !resubscribing,
              let keepAlive = subscriptionKeepAlive else { return nil }
        return max(keepAlive, Self.stallEnd)
    }

    /// Ends the current subscription (`PSI,0`) so that its push end, handled as any on a USB
    /// station, brings the bounded resume and a fresh `PSI`. Runs on the consumer.
    private func replaceSubscription() async {
        resubscribing = true
        emit(.warning(Self.resubscribingMessage))
        // Finishes the push stream, whatever the write does: `.pushEnded` follows.
        try? await client?.stopPush()
    }

    private func warnStalled() {
        guard !stallWarned else { return }
        stallWarned = true
        emit(.warning(Self.stalledMessage))
    }

    private func audioStateChanged(_ state: AudioSessionState) {
        switch state {
        case .failed, .stopped: audioStreaming = false
        case .streaming:
            audioStreaming = true
            inputContinuation.yield(.audioStreaming)
        default: break
        }
        emit(.audio(state))
    }

    // MARK: A USB scanner that goes away

    /// The push stream of a USB station ended (see the type's documentation). Runs on the
    /// consumer, after the open hits were ended and logged.
    private func scannerWentAway() async {
        connected = false
        let gone = client
        client = nil
        // Closes the port. Nothing is written: the push is already finished, so no `PSI,0`.
        await gone?.disconnect()
        // A stop that began meanwhile is awaiting this consumer: report and start nothing more.
        guard !stopping else { return }
        willResume = pushDelivered && resumeAfterDisconnect
        // Only a port that no longer resolves calls for "plug the scanner in". (`make` opens nothing.)
        let portGone = (try? transportFactory.make(station.connection, device: device)) == nil
        emit(.disconnected(hint: portGone ? SerialPort.noneFoundHint : SerialPort.notSendingUpdatesHint))
        // A connection that never delivered a push isn't reopened: a scanner that refuses `PSI`
        // would otherwise be opened, asked and closed again on every poll.
        guard pushDelivered else {
            emit(.warning(Self.notResumingMessage))
            return
        }
        guard resumeAfterDisconnect else { return }
        warnedScanners = []
        portProbe = nil
        // The wait holds the runner only while a poll runs, never across its sleep: a runner
        // released without `stop()` ends its wait at the next poll, instead of polling (and, when
        // the scanner came back, subscribing with nobody to end it) for as long as the process ran.
        let interval = portPollInterval
        resumeTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return  // stop() cancelled the wait.
                }
                guard let runner = self else { return }
                if await runner.pollForScanner() { return }
            }
        }
    }

    /// One poll of the wait for the scanner: true when the wait is over (the station runs again,
    /// or `stop()` has begun), false to poll again.
    private func pollForScanner() async -> Bool {
        do {
            try checkLive()
            return try await resumeOnce()
        } catch {
            return true  // stop(): `checkLive` threw.
        }
    }

    /// One poll: true once the station is running again, false to keep polling. Throws `stopped`
    /// when `stop()` lands; by then the port is closed again, or the client is in `client` for the
    /// stop to send `PSI,0` to and close.
    private func resumeOnce() async throws -> Bool {
        // While there is no port, nothing is opened and nothing is sent; what was known about
        // the last one no longer applies.
        guard let made = try? transportFactory.make(station.connection, device: device) else {
            portProbe = nil
            return false
        }
        // A port at another path is a new appearance too.
        if portProbe?.path != made.address { portProbe = PortProbe(path: made.address) }
        // Another scanner, or one that used up its probes: left alone until it has gone.
        guard portProbe?.leftAlone != true else { return false }

        let candidate = ScannerClient(transport: made.transport)
        let reported: String
        do {
            try await candidate.connect()
            try checkLive()
            reported = try await candidate.modelInfo().reported
            try checkLive()
        } catch {
            // Busy, no answer, or a stop. Not known to be our scanner: close, sending nothing more.
            await candidate.disconnect()
            try checkLive()
            // A refused open sent nothing and isn't a probe; anything else is.
            if !Self.isBusy(error) { probeFailed() }
            return false
        }
        let first = scannerName ?? reported
        guard Self.isSameScanner(reported, as: first) else {
            await candidate.disconnect()
            try checkLive()
            portProbe?.leftAlone = true
            if warnedScanners.insert(reported).inserted {
                emit(.warning("a different scanner answered (\(reported)); still waiting for the \(first)"))
            }
            return false
        }
        // The same scanner. From here `stop()` finds it in `client`, and ends with `PSI,0`.
        client = candidate
        let firmware: String
        do {
            firmware = try await candidate.firmwareVersion()
            try checkLive()
        } catch {
            try checkLive()
            // `VER` went unanswered: nothing was subscribed, so just close.
            client = nil
            await candidate.disconnect()
            try checkLive()
            probeFailed()
            return false
        }
        detector = makeDetector()
        let pushes: AsyncStream<PushUpdate>
        let keepAlive = pushKeepAlive(reported)
        do {
            pushes = try await candidate.startPushUpdates(interval: subscriptionInterval(reported), keepAlive: keepAlive,
                                                          onKeepAliveFailure: keepAliveFailureHandler())
            try checkLive()
        } catch {
            try checkLive()
            // `PSI` couldn't be written whole, and part of it may be on the wire: close, send
            // nothing more, and leave this port alone until it has gone.
            client = nil
            await candidate.disconnect()
            try checkLive()
            leavePortAlone()
            return false
        }
        lastPushAt = .now
        stallWarned = false
        pushDelivered = false
        subscriptionKeepAlive = keepAlive?.interval
        resubscribing = false
        feedPushes(pushes)
        connected = true
        emit(.connected(model: reported, firmware: firmware))
        return true
    }

    /// Counts a probe that got no usable answer; the last one allowed ends the probing of this
    /// appearance of the port (`leavePortAlone`).
    private func probeFailed() {
        guard portProbe != nil else { return }
        portProbe?.failed += 1
        if let failed = portProbe?.failed, failed >= Self.maxProbes { leavePortAlone() }
    }

    /// Ends the probing of this appearance of the port at once, saying so (`notAnsweringMessage`).
    private func leavePortAlone() {
        guard let probe = portProbe, !probe.leftAlone else { return }
        portProbe?.leftAlone = true
        emit(.warning(Self.notAnsweringMessage))
    }

    /// Whether an open was refused because another program has the port.
    private static func isBusy(_ error: any Error) -> Bool {
        #if os(macOS)
        if case SerialTransportError.busy = error { return true }
        #endif
        return false
    }

    /// Whether a scanner whose `MDL` says `reported` is the one that first said `first`: the same
    /// model when both names are known models (an SDS150 may say `SDS150` or `SDS150GBT`),
    /// otherwise the same name (trimmed, ignoring case).
    static func isSameScanner(_ reported: String, as first: String) -> Bool {
        if let model = ScannerModel(reported: reported), let firstModel = ScannerModel(reported: first) {
            return model == firstModel
        }
        func name(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        return name(reported) == name(first)
    }

    // MARK: Hits

    private func process(_ events: [HitEvent]) async {
        for event in events {
            switch event {
            case .started(let hit):
                if loggingPaused {
                    skippedHits.insert(hit.id)
                } else {
                    await hitStarted(hit)
                }
            case .updated(let hit):
                guard !skippedHits.contains(hit.id) else { continue }
                openHits[hit.id]?.hit = hit
                guard let recorder else { continue }
                await apply(recorder.handle(.updated(hit), record: openHits[hit.id]?.record ?? false))
            case .ended(let hit):
                if skippedHits.remove(hit.id) == nil { await hitEnded(hit) }
            }
        }
    }

    private func hitStarted(_ hit: Hit) async {
        let isNew: Bool
        do {
            isNew = try await log.begin(hit, audioPath: nil)
        } catch {
            emit(.warning("couldn't log a hit: \(error)"))
            isNew = hit.key.talkgroupID == nil ? !hit.programmed : false
        }
        let wanted: Bool
        switch station.recording.saveAudio {
        case .everyTransmission: wanted = true
        case .onlyNew: wanted = isNew
        case .never: wanted = false
        }
        let record = wanted && audioStreaming
        var results: [RecordingResult] = []
        var path: String?
        if let recorder {
            results = recorder.handle(.started(hit), record: record)
            if record { path = recorder.currentPath(for: hit.id) }
        }
        let lineInHit = lineIn != nil
        openHits[hit.id] = OpenHit(hit: hit, record: record, waitingForAudio: wanted && !record,
                                   isNew: isNew, audioPath: path, lineInHit: lineInHit,
                                   streamingThroughout: lineInHit && audioStreaming)
        if let path {
            do { try await log.setAudioPath(id: hit.id, path: path) } catch {
                emit(.warning("couldn't log a recording path: \(error)"))
            }
        }
        emit(.hitStarted(LoggedHit(hit: hit, audioPath: path, audioError: nil, isNew: isNew,
                                   audioClipped: lineInHit ? false : nil)))
        await apply(results)
    }

    /// Starts recording the open hits that `saveAudio` wanted recorded but that started while audio
    /// wasn't streaming (see the type's documentation). No pre-roll: the file starts with the audio
    /// received from streaming onward. Hits already recording, or not to be recorded, are left alone.
    private func recordHitsWaitingForAudio() async {
        guard audioStreaming, let recorder else { return }
        let waiting = openHits.values.filter { $0.waitingForAudio && !$0.record }
            .sorted { $0.hit.startedAt < $1.hit.startedAt }
        for open in waiting {
            let id = open.hit.id
            let results = recorder.handle(.started(open.hit), record: true)
            let path = recorder.currentPath(for: id)
            openHits[id]?.record = true
            openHits[id]?.waitingForAudio = false
            openHits[id]?.audioPath = path
            if let path {
                do { try await log.setAudioPath(id: id, path: path) } catch {
                    emit(.warning("couldn't log a recording path: \(error)"))
                }
            }
            await apply(results)
        }
    }

    private func hitEnded(_ hit: Hit) async {
        guard let open = openHits.removeValue(forKey: hit.id) else { return }
        let results = recorder?.handle(.ended(hit), record: open.record) ?? []
        if !open.record {
            await finalize(hit, isNew: open.isNew, clipped: open.audioClipped, result: nil)
        } else if let early = open.earlyResult {
            await finalize(hit, isNew: open.isNew, clipped: open.audioClipped, result: early)
        } else {
            awaitingResult[hit.id] = (hit, open.isNew, open.audioClipped)
        }
        judgeSilence(hit, open)
        await apply(results)
    }

    /// Routes recording results to their hits: an ended hit is finalized; an open one keeps it
    /// until it ends. Results for unknown hits are dropped.
    private func apply(_ results: [RecordingResult]) async {
        for result in results {
            if let waiting = awaitingResult.removeValue(forKey: result.hitID) {
                await finalize(waiting.hit, isNew: waiting.isNew, clipped: waiting.clipped, result: result)
            } else if openHits[result.hitID] != nil {
                openHits[result.hitID]?.earlyResult = result
            }
        }
    }

    /// Logs an ended hit's end with its recording's result (nil: none) and `audioClipped`, which
    /// `log.end` stores every time (nil for a hit with no line-in).
    private func finalize(_ hit: Hit, isNew: Bool, clipped: Bool?, result: RecordingResult?) async {
        let path = result?.path
        let error = result?.error
        do {
            try await log.end(hit, audioPath: path, audioError: error, audioClipped: clipped)
        } catch {
            emit(.warning("couldn't log the end of a hit: \(error)"))
        }
        if let result {
            emit(.recording(result))
            if let error, !recordingWarned {
                recordingWarned = true
                emit(.warning("recording failed; hits are still logged: \(error)"))
            }
        }
        emit(.hitEnded(LoggedHit(hit: hit, audioPath: path, audioError: error, isNew: isNew, audioClipped: clipped)))
    }

    private func emit(_ event: RunnerEvent) {
        eventsContinuation.yield(event)
    }

    // MARK: Stop

    /// Stops the station (see the type's documentation). Idempotent; concurrent calls share one
    /// teardown and all return when it's done. `PSI,0` and TEARDOWN are always sent (when a
    /// client or audio session exists). Normally `PSI,0` goes first; if stop lands while
    /// `start()` is still inside `audio.start()`, cancelling that start makes the AudioSession
    /// tear itself down first, so TEARDOWN precedes `PSI,0` in that window.
    public func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }
        let task = Task { await self.performStop() }
        stopTask = task
        await task.value
    }

    private func performStop() async {
        stopping = true
        // 1. Stop feeding.
        if let startTask {
            startTask.cancel()
            _ = await startTask.result
        }
        // A USB station's wait for its scanner, and any resume attempt in flight.
        if let resumeTask {
            resumeTask.cancel()
            await resumeTask.value
        }
        feeding = false
        tickTask?.cancel()
        inputContinuation.finish()
        await consumerTask?.value

        // 2-3. End open hits and recordings, then log them.
        if var detector {
            let events = detector.finish(now: .now)
            self.detector = detector
            await process(events)
        }
        if let recorder { await apply(recorder.finishAll()) }
        for (_, waiting) in awaitingResult.sorted(by: { $0.value.hit.startedAt < $1.value.hit.startedAt }) {
            await finalize(waiting.hit, isNew: waiting.isNew, clipped: waiting.clipped, result: nil)
        }
        awaitingResult = [:]

        // 4. PSI,0, then close control.
        if let client {
            try? await client.stopPush()
            await client.disconnect()
        }
        await pushFeeder?.value

        // 5. TEARDOWN, or the line-in's source stopped.
        if let lineIn { await retire(lineIn) }
        if let audio {
            await audio.stop()
            await chunkFeeder?.value
            await statesFeeder?.value
            // 6. Sessions the scanner may still hold.
            let unreleased = await audio.unreleasedSessions
            if !unreleased.isEmpty {
                emit(.warning("the scanner may still hold \(unreleased.count) audio session(s) (\(unreleased.joined(separator: ", "))); restart or power-cycle it if audio doesn't come back"))
            }
        }
        chunkFeeder?.cancel()
        pushFeeder?.cancel()
        statesFeeder?.cancel()

        // 7. Done.
        audioTap?.finish()
        audioTap = nil
        levelTap?.finish()
        levelTap = nil
        emit(.stopped)
        eventsContinuation.finish()
        liveStatusContinuation.finish()
    }
}
