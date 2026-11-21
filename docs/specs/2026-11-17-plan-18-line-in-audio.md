# Plan 18: Line-in audio for USB scanners (core and app) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A USB station whose scanner's headphone jack is cabled into a Mac audio input records
each hit as a WAV, plays live through the Mac's output, and shows a line-in level meter with a
latching CLIP light, in the shared core and the Mac app. The command line is Plan 19.

**Architecture:** A line-in is a second audio source for `StationRunner`, beside the SDS200's
`AudioSession`: a `LineInSource` protocol in `NoctuleKit` yields the same 8 kHz mono
`AudioChunk`s (320 samples each) plus levels and states, so the recorder, hit log, playback tap
and session code take it unchanged. A new `NoctuleAudioCapture` module implements it with one
AVAudioEngine per station (and, for tests and the mocks, a source fed by the mock scanner's new
`--line-out` stream through the same pipeline). The app adds the editor's Audio section, the
meter, the clip warning and the status bar text.

**Tech Stack:** Swift 6.2, Swift Testing, SwiftPM; AVFAudio (AVAudioEngine, AVAudioConverter,
AVAudioApplication) and Core Audio (device listing) in the new module only; SwiftUI in the app.
No new dependency.

**Spec:** `docs/specs/2026-11-17-usb-line-in-audio-design.md` (read it first; § numbers below are
its). Plan 16 is reserved for PR checks, Plan 17 was the SDS100; this is Plan 18, phases 1 and 2
of the design's §9.

## Global Constraints

- Branch `feature/line-in-audio` (exists; the design is committed on it). Tests first, against the
  mocks and fakes; developer and QA per task, QA re-running every test and proving each new test
  with a mutation (dev-workflow memory).
- **No task, test, QA mutation or agent run opens a real audio input.** Never construct
  `EngineLineInSource` against Core Audio in a test, and never call `AVAudioApplication`'s
  permission request from a test: either would show the microphone prompt and record the room.
  Tests use `FakeLineInSource` or `PipeLineInSource` on `MockLineOut`. A QA mutation that removes
  the kill-switch check (Task 1, Task 11) is **forbidden**: test it by asserting the selection,
  never by letting a test reach the system factory.
- Every shell that builds, tests or runs `noctule` or the app exports `NOCTULE_NO_USB_DETECTION=1`
  (which now also turns off audio inputs, §8). The app is launched only with `NOCTULE_SETTINGS_DIR`
  on a temporary directory whose stations are mocks. Never open a `/dev/cu.usbmodem*` path.
- No scanner command is added except the Volume −1 button's single `VOL` step (§2 anti-goals). A
  line-in station never calls the RTSP cooldown store or gate.
- `NoctuleAppCore`, `NoctuleStore` and `NoctuleKit` keep building for iOS with no AVFAudio:
  `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build`.
- Values (copied from the spec): chunks **320 samples, 16-bit, 8 kHz mono**; meter **−60 to 0
  dBFS**, green to **−12**, yellow to **−3**, red above, target band **−18 to −6 dBFS**, refresh
  **30 Hz** (window ≈ 33 ms), peak hold **1.5 s**; clip = **two or more consecutive samples at or
  within 0.1 dB of full scale** (|x| ≥ **0.98855**); idle floor = median block RMS outside hits
  over the last **60 s**; silent hit = **≥ 2 s** whose block RMS never rises **15 dB** above the
  floor; warn after **3 silent hits in a row**; capture through an **`AVAudioSinkNode`** (a tap
  gave 100 ms buffers on the owner's rig, design §3a); line-in prefill **≈ 60 ms (480 samples)**; device-settings keys
  **`audioInputDevice`, `audioInputName`, `audioInputChannel`** (`left`/`right`/`both`, absent =
  `both`); hit-log schema **version 2**, column **`audio_clipped INTEGER`**; override
  **`NOCTULE_TEST_LINE_IN`**; mock flags **`--line-out PATH`**, **`--line-out-channel
  left|right|both`**, **`--fault line-out-silent`**.
- User-visible copy (exact): warning `the audio input "<name>" isn't connected; logging without
  audio`; `audio input disabled by NOCTULE_NO_USB_DETECTION`; `no audio on the line-in during the
  last 3 transmissions; check the cable and the scanner's volume`; clip warning `The audio input clipped during
  "<channel>". Turn the scanner's volume down a step.`; permission `Noctule Scan isn't allowed to
  use audio input. Allow it in System Settings › Privacy & Security › Microphone.`; status bar
  `Listening · <device>`, `Not listening`, `Line-in not connected`, `Line-in blocked`; editor
  `None (no audio)`, `<name> (not connected)`, `<station> also uses this input (<channel>).`
- No real system, channel or frequency names in tracked files; `RealNamesTests` must pass.
- Update `LESSONS.md` during the work whenever something surprises you.

## Review Focus

1. **The audio interface unplugged mid-hit, then plugged back in.** The hit is still logged, its
   recording closes with what it had, later hits are logged without audio, and audio resumes by
   itself when the device returns. (Task 8, `lineInMissingThenBack`.)
2. **The scanner unplugged while the line-in runs.** Listening and the meter keep going through
   the wait; nothing is recorded (no hit); after the resume, hits record again. (Task 8,
   `lineInSurvivesAScannerDisconnect`; Task 11, `lineInRelaySurvivesTheScannerWait`.)
3. **A stop while the source is still starting** (the permission prompt up, a slow device). The
   stop must return and stop the engine, never wait on the prompt. (Task 6,
   `stopDuringAPendingPermissionReturns`; Task 8, `stopWhileTheSourceIsStarting`.)
4. **A 44.1 kHz device, or a mono device with Left or Right chosen.** Chunks stay 320 samples at
   8 kHz with no drift over time, and a mono device's one channel is used whatever is chosen.
   (Task 3, `fortyFourOneHasNoDrift`, `monoDeviceIgnoresTheChannelChoice`.)
5. **The kill-switch with an input saved in a station.** Nothing in Core Audio is opened or
   listed; the station logs without audio and says why. (Task 1, `killSwitchDisablesLineIn`;
   Task 14, `usbLineInAppUnderTheKillSwitchOpensNoInput`.)

---

### Task 1: Line-in types, device settings and source selection

**Files:**
- Create: `Sources/NoctuleKit/Audio/LineIn/LineIn.swift`
- Modify: `Sources/NoctuleStore/Station.swift` (`StationDeviceSettings`)
- Create: `Sources/NoctuleStore/LineInDetection.swift`
- Test: `Tests/NoctuleKitTests/LineInTypesTests.swift`, `Tests/NoctuleStoreTests/LineInSettingsTests.swift`

**Interfaces:**
- Produces (NoctuleKit):
  - `public enum LineInChannel: String, Codable, Sendable, CaseIterable { case left, right, both }`
  - `public struct LineInConfig: Sendable, Equatable { deviceUID: String; deviceName: String; channel: LineInChannel }`
  - `public struct LineInLevel: Sendable, Equatable { peakDBFS: Double; rmsDBFS: Double; clipped: Bool; at: ContinuousClock.Instant }` (both `-.infinity` for digital silence; the meter draws the peak, silence detection uses the RMS)
  - `public enum LineInState: Sendable, Equatable { case starting, streaming(deviceName: String), missing(deviceName: String), denied, failed(String), stopped }`
  - `public protocol LineInSource: AnyObject, Sendable { var chunks: AsyncStream<AudioChunk> { get }; var levels: AsyncStream<LineInLevel> { get }; var states: AsyncStream<LineInState> { get }; func start() async; func stop() async }` — `start()` returns once the first state is known; a missing device is `.missing`, not a throw; `stop()` finishes all three streams.
  - `public typealias LineInSourceFactory = @Sendable (LineInConfig) -> any LineInSource`
  - `public struct AudioInputDevice: Sendable, Equatable, Identifiable { uid: String; name: String; channelCount: Int }` (`id` is `uid`)
  - `public protocol AudioInputListing: Sendable { func inputs() -> [AudioInputDevice] }`, `public struct FixedAudioInputListing: AudioInputListing` with `static let empty`
  - `public final class DisabledLineInSource: LineInSource` — `init(reason: String)`; `start()` yields `.failed(reason)`, no chunks or levels.
- Produces (NoctuleStore):
  - `StationDeviceSettings.audioInputDevice: String?`, `.audioInputName: String?`, `.audioInputChannel: LineInChannel?` (decoded with `decodeIfPresent`), and `public var lineIn: LineInConfig?` (nil unless `audioInputDevice` is set; channel defaults to `.both`; name defaults to the UID).
  - `public enum LineInSelection: Equatable { case system, disabled(reason: String), testStream(path: String) }`
  - `public enum LineInDetection { public static func selection(environment: [String: String], privateSettings: Bool, app: Bool) -> LineInSelection }` — rules in Step 3.

- [ ] **Step 1: Write the failing tests**

`LineInSettingsTests`: `deviceSettingsRoundTripLineIn` (encode/decode keeps the three keys;
`lineIn == LineInConfig(deviceUID: "UID-1", deviceName: "Fictional Interface", channel: .left)`);
`oldDeviceJSONHasNoLineIn` (a v-current `device.json` without the keys decodes, `lineIn == nil`);
`channelDefaultsToBoth`; `killSwitchDisablesLineIn` (`["NOCTULE_NO_USB_DETECTION": "1"]` →
`.disabled(reason: "audio input disabled by NOCTULE_NO_USB_DETECTION")`, for app and CLI);
`testStreamNeedsKillSwitch` (CLI: `NOCTULE_TEST_LINE_IN` honoured only with the kill-switch, →
`.testStream(path:)`; app: also needs `privateSettings == true`; otherwise `.system` with the
kill-switch unset, `.disabled` with it set); `noVariablesIsSystem`.
`LineInTypesTests`: `disabledSourceReportsItsReason` (states yield `.failed(reason)`, chunks and
levels finish after `stop()`).

- [ ] **Step 2: Run them and see them fail**

Run: `NOCTULE_NO_USB_DETECTION=1 swift test --filter 'LineInSettingsTests|LineInTypesTests'`
Expected: FAIL to compile (types missing).

- [ ] **Step 3: Implement the types, the settings keys and `LineInDetection.selection`**

Selection, in order: kill-switch set and a non-empty `NOCTULE_TEST_LINE_IN` (and, for the app,
`privateSettings`) → `.testStream`; kill-switch set → `.disabled`; otherwise `.system` (the test
variable is ignored without the kill-switch). Add `overrideNotes(_:)` returning
`noctule: test override: NOCTULE_TEST_LINE_IN=<path> (in place of the line-in device)` when it
applies, as `USBDetection.overrideNotes` does.

- [ ] **Step 4: Run them and see them pass**, plus `swift test --filter 'StationTests|SettingsStore'` unchanged.

- [ ] **Step 5: Commit** (`feat: line-in types, device settings and source selection`)

---

### Task 2: The level meter

**Files:**
- Create: `Sources/NoctuleKit/Audio/LineIn/LineInMeter.swift`
- Test: `Tests/NoctuleKitTests/LineInMeterTests.swift`

**Interfaces:**
- Produces: `public struct LineInMeter { public init(sampleRate: Double, windowsPerSecond: Double = 30); public static let clipThreshold: Float = 0.98855; public mutating func ingest(_ samples: UnsafeBufferPointer<Float>, firstSampleAt: ContinuousClock.Instant) -> [LineInLevel] }` — one level per completed window, timed at the window's first sample; a clip run that straddles two `ingest` calls counts.

- [ ] **Step 1: Write the failing tests**

`sineAtHalfScaleIsMinusSix` (48 kHz, 0.5-amplitude 1 kHz sine for 1 s → 30 levels, every
`peakDBFS` within ±0.1 of −6.02 and `rmsDBFS` within ±0.1 of −9.03, none clipped); `oneFullScaleSampleIsNotAClip`; `twoConsecutiveAreAClip`
(two samples at 0.99 → the window containing them is `clipped`); `clipRunAcrossTwoIngests`;
`silenceIsMinusInfinity`; `levelTimesFollowTheSamples` (window n's `at` == first + n × 1/30 s
within 1 ms); `fortyFourOneWindows` (44.1 kHz for 10 s → 300 levels ±1).

- [ ] **Step 2: Run, see them fail** — `swift test --filter LineInMeterTests` (missing type).
- [ ] **Step 3: Implement `LineInMeter`** (window = `sampleRate / windowsPerSecond` samples, fractional carry so 44.1 kHz doesn't drift).
- [ ] **Step 4: Run, see them pass.**
- [ ] **Step 5: Commit** (`feat: line-in level meter with clip detection`)

---

### Task 3: The capture module and its pipeline

**Files:**
- Modify: `Package.swift` — add `.target(name: "NoctuleAudioCapture", dependencies: ["NoctuleKit"], linkerSettings: [.linkedFramework("AVFAudio"), .linkedFramework("CoreAudio", .when(platforms: [.macOS]))])` and `.testTarget(name: "NoctuleAudioCaptureTests", dependencies: ["NoctuleAudioCapture", "NoctuleKit", "NoctuleMockScanner"])`, with a comment like `NoctuleAudioPlayback`'s.
- Create: `Sources/NoctuleAudioCapture/LineInPipeline.swift`
- Test: `Tests/NoctuleAudioCaptureTests/LineInPipelineTests.swift`

**Interfaces:**
- Consumes: Task 1 types, `LineInMeter`, `AudioChunk` (all its fields).
- Produces: `public final class LineInPipeline { public init(inputFormat: AVAudioFormat, channel: LineInChannel, ssrc: UInt32); public func process(_ buffer: AVAudioPCMBuffer, firstSampleAt: ContinuousClock.Instant) -> (chunks: [AudioChunk], levels: [LineInLevel]); public func markDiscontinuity(); public func noteDropped(chunks: Int) }`.
  Order inside `process`: pick the channel (Both = mean of the first two channels; a 1-channel
  format uses its channel whatever is chosen) → meter at the device rate → `AVAudioConverter` to
  8 kHz mono Float → Int16 (clamped) → 320-sample chunks. A chunk's `receivedAt` is the capture
  time of its first sample; `sequence` increments by 1 (wrapping); `ssrc` from init;
  `lostBefore` from `noteDropped`; `discontinuity` true on the first chunk after
  `markDiscontinuity()`.

- [ ] **Step 1: Write the failing tests**

`chunksAre320At8k` (48 kHz stereo, 1 s → 25 chunks of 320, sequences 0…24, chunk n's
`receivedAt` == first + n × 40 ms ± 1 ms); `fortyFourOneHasNoDrift` (44.1 kHz for 60 s → total
samples 480 000 ± 320); `leftAndRightAreSeparate` (left 440 Hz at 0.5, right silent: `.left`
chunks carry the tone, `.right` chunks are all within ±1 of 0); `bothIsTheMean`;
`monoDeviceIgnoresTheChannelChoice` (1-channel format with `.right` → the tone);
`clipMeasuredBeforeConversion` (a square wave at full scale → levels `clipped` even though the
8 kHz output is band-limited); `discontinuityFlagsTheNextChunk`; `droppedChunksSetLostBefore`.

- [ ] **Step 2: Run, see them fail** — `swift test --filter LineInPipelineTests`.
- [ ] **Step 3: Implement `LineInPipeline`.**
- [ ] **Step 4: Run, see them pass**; `swift build` and the iOS build of `NoctuleAppCore` unaffected.
- [ ] **Step 5: Commit** (`feat: NoctuleAudioCapture and the line-in pipeline`)

---

### Task 4: The mock's headphone jack (`--line-out`)

**Files:**
- Create: `Sources/NoctuleMockScanner/MockLineOut.swift`
- Modify: `MockSerialScanner.swift` (init option, start/stop, volume read), `MockScannerArguments.swift` (`--line-out`, `--line-out-channel`, `--fault line-out-silent`, help text), `MockSDS200.swift` (`MockFaults.lineOutSilent: Bool`), `Sources/noctule-mock-scanner/main.swift` (print `line-out=PATH`), `MockPersonality.swift` (type comment: the assumptions)
- Test: `Tests/NoctuleMockScannerTests/MockLineOutTests.swift`, `MockScannerArgumentsTests` (existing file)

**Interfaces:**
- Produces: `public final class MockLineOut: Sendable { public static let sampleRate = 48_000; public static func peak(forVolume volume: Int) -> Float /* min(1, volume / 8) */; public init(path: String, channel: LineInChannel, scenario: MockScenario, clock: MockClock, volume: @escaping @Sendable () -> Int, silent: @escaping @Sendable () -> Bool); public func start() throws; public func stop() }`.
  Wire format: a Unix-domain **stream** socket the mock listens on at `path` (one client at a
  time; a second is refused); interleaved stereo little-endian Float32 frames at 48 kHz, written
  in 20 ms blocks paced by `clock` (real time in the executable). While no client is connected the
  audio is discarded. During a transmission: a sine at its `toneHz`, peak `peak(forVolume:)`,
  values beyond ±1 hard-clipped to ±1 (so volume ≥ 9 clips); between transmissions, white noise
  at RMS −52 dBFS (the owner's rig's idle floor, design §3a), on top of the tone too; with the
  fault: that noise only, throughout. The tone goes on the chosen channel(s); the other is zero.
- `MockSerialScanner.init(..., lineOut: (path: String, channel: LineInChannel)? = nil)`; `--line-out` needs `--serial`.

- [ ] **Step 1: Write the failing tests**

`MockLineOutTests` (real-time `MockClock`, a test client on the socket): `toneDuringATransmission`
(peak ≈ `peak(forVolume: 2)` = 0.25 on the left channel, right all 0, with `channel: .left`);
`hissBetweenTransmissions` (RMS −52 ± 1 dBFS); `volumeNineClips` (samples at exactly ±1 present);
`silentFaultWritesOnlyHiss`; `secondClientIsRefused`; `noClientDiscards` (a client that connects 1 s
in gets audio for the current moment, not a backlog). Arguments: `lineOutNeedsSerial`
(`--line-out` without `--serial` → misuse error), `lineOutChannelParses`, `lineOutSilentFault`.

- [ ] **Step 2: Run, see them fail** — `swift test --filter 'MockLineOutTests|MockScannerArguments'`.
- [ ] **Step 3: Implement**, reading the volume through the serial mock's `ControlCore` so `VOL,n` from a client changes the level at once.
- [ ] **Step 4: Run, see them pass**; `NoctuleMockScannerTests` all pass.
- [ ] **Step 5: Commit** (`feat(mock): --line-out, the serial mock's headphone jack`)

---

### Task 5: `PipeLineInSource`

**Files:**
- Create: `Sources/NoctuleAudioCapture/PipeLineInSource.swift`
- Test: `Tests/NoctuleAudioCaptureTests/PipeLineInSourceTests.swift`

**Interfaces:**
- Consumes: `LineInPipeline`, `MockLineOut` (tests only).
- Produces: `public final class PipeLineInSource: LineInSource { public init(path: String, config: LineInConfig) }` — connects to the socket; `.starting` then `.streaming(deviceName: config.deviceName)` once connected; a socket that isn't there or closes is `.missing(deviceName:)`, retried every 1 s until `stop()` (the reconnect gets `markDiscontinuity()`); frames go through a `LineInPipeline` with a 48 kHz stereo Float32 input format, timed from the read time minus the buffered duration.

- [ ] **Step 1: Write the failing tests**

On a real-time mock clock and a one-transmission scenario: `streamsChunksFromTheMock` (state
`.streaming`, ≥ 20 chunks of 320 in 1 s); `levelsFollowTheMockVolume` (peak ≈ −12 dBFS at
volume 2, `clipped` at volume 9); `missingThenBack` (no socket → `.missing`; start the mock's line
out → `.streaming`, first chunk after it `discontinuity`); `stopFinishesTheStreams`.

- [ ] **Step 2–4: Fail, implement, pass** — `swift test --filter PipeLineInSourceTests`.
- [ ] **Step 5: Commit** (`feat: PipeLineInSource for tests and the mocks`)

---

### Task 6: `EngineLineInSource` and the Core Audio input listing

**Files:**
- Create: `Sources/NoctuleAudioCapture/CoreAudioInputs.swift` (`#if os(macOS)`), `Sources/NoctuleAudioCapture/EngineLineInSource.swift`
- Test: `Tests/NoctuleAudioCaptureTests/EngineLineInSourceTests.swift` (fakes only)

**Interfaces:**
- Produces:
  - `public struct CoreAudioInputs: AudioInputListing` (devices with input streams, by `kAudioDevicePropertyDeviceUID` and name), and `public static func deviceListChanges() -> AsyncStream<Void>` (a `kAudioHardwarePropertyDevices` listener, removed when the stream ends).
  - `public protocol LineInEngine: AnyObject, Sendable { func start(deviceID: AudioDeviceID, onBuffer: @escaping @Sendable (AVAudioPCMBuffer, ContinuousClock.Instant) -> Void) throws -> AVAudioFormat; func stop(); var configurationChanges: AsyncStream<Void> { get } }` — the AVAudioEngine one (`AVLineInEngine`) points the input node at the device (`auAudioUnit.setDeviceID`) and connects it to an **`AVAudioSinkNode`** (never `installTap`, design §3a); the callback copies each block into a preallocated `AVAudioPCMBuffer` and hands it on with its time from `AudioTimeStamp.mHostTime` (mach absolute time, converted to the continuous clock with the offset `mach_continuous_time() − mach_absolute_time()` read at start). The render callback never allocates or locks a contended lock (LESSONS.md 2026-11-08).
  - `public final class EngineLineInSource: LineInSource { public init(config: LineInConfig, inputs: any AudioInputListing, deviceChanges: AsyncStream<Void>, permission: @escaping @Sendable () async -> Bool, makeEngine: @escaping @Sendable () -> any LineInEngine) }` and `public static func system(_ config: LineInConfig) -> EngineLineInSource` (the real listing, `AVAudioApplication.requestRecordPermission`, `AVLineInEngine`).
  - Behaviour: permission first (false → `.denied`, nothing more until a new source); the device is the input with the saved UID, else the only input with the saved name (design §5.1), else `.missing(name)` and wait on `deviceChanges`; present → start the engine → `.streaming(name)`; a configuration change or the device leaving → restart (or `.missing`) with `markDiscontinuity()`, debounced 250 ms; `stop()` stops the engine and returns even while `permission` hasn't answered.

- [ ] **Step 1: Write the failing tests** (a `FakeEngine` that records start/stop and lets the test push buffers; a `FixedAudioInputListing`; a permission closure the test controls)

`deniedNeverStartsTheEngine`; `fallsBackToTheSavedName` (no input has the UID, one has the name → started on it; two have the name → `.missing`); `missingWaitsForTheDevice` (listing empty → `.missing`; listing
gains the UID and a device change is yielded → engine started, `.streaming`);
`deviceLeavingIsMissing`; `configurationChangeRestartsOnce` (three changes within 100 ms → one
restart; next chunk `discontinuity`); `stopDuringAPendingPermissionReturns` (permission never
answers; `stop()` returns within 1 s, engine never started); `buffersBecomeChunks`.

- [ ] **Step 2–4: Fail, implement, pass** — `swift test --filter EngineLineInSourceTests`. No test calls `.system(_:)` or `CoreAudioInputs`.
- [ ] **Step 5: Commit** (`feat: EngineLineInSource on AVAudioEngine, with fakes`)

---

### Task 7: Hit log version 2 (`audio_clipped`)

**Files:**
- Modify: `Sources/NoctuleStore/HitLogSchema.swift` (version 2, `v1 → v2` migration: `ALTER TABLE hits ADD COLUMN audio_clipped INTEGER; PRAGMA user_version = 2`; a new database is v1 then migrated), `HitQueries.swift` (`columns`, `values(_:audioPath:audioError:audioClipped:)`, row decoding, `csvHeader` gains `audio_clipped` last; `1`, `0` or empty), `HitLog.swift` (`LoggedHit.audioClipped: Bool?` with a defaulted init parameter; `end(_:audioPath:audioError:audioClipped: Bool? = nil)`)
- Test: `Tests/NoctuleStoreTests/HitLogTests.swift` (existing)

- [ ] **Step 1: Write the failing tests**: `migratesVersionOneInPlace` (a v1 file with one hit → opens, `user_version` 2, the hit reads back with `audioClipped == nil`); `endStoresClipped`; `csvHasAudioClippedLast`; `newerSchemaStillRefused` (version 3 → `unsupportedSchemaVersion(3)`).
- [ ] **Step 2–4: Fail, implement, pass** — `swift test --filter HitLog`; `hits --csv` integration tests updated for the new last column only.
- [ ] **Step 5: Commit** (`feat: hit log v2 records clipped recordings`)

---

### Task 8: The runner runs a line-in

**Files:**
- Modify: `Sources/NoctuleStore/StationRunner.swift`, `Sources/NoctuleKit/Models/ModelProfile.swift` (`lineInAudioOffset: Duration`, `.zero` for every model until the hardware session)
- Create: `Sources/NoctuleKitTestSupport/FakeLineInSource.swift`
- Test: `Tests/NoctuleStoreTests/StationRunnerLineInTests.swift`

**Interfaces:**
- Consumes: Task 1 types, `MockSerialScanner` (scanner side), `FakeLineInSource`.
- Produces:
  - `StationRunner.init(..., lineInSources: LineInSourceFactory? = nil)` (last parameter).
  - `RunnerEvent.lineIn(LineInState)` (new case).
  - `public func liveLevels() -> AsyncStream<LineInLevel>` (`bufferingNewest(1)`; a second call finishes the first, as `liveAudio()`).
  - `public func replaceLineIn(_ config: LineInConfig?) async` (stops the current source, starts one for `config`, or none).
  - `hasAudio`: network as today, or `.usbSerial` with `device.lineIn != nil` and a factory.
  - `FakeLineInSource`: `init(config:)`, `yield(chunk:)`, `yield(level:)`, `setState(_:)`, `var started: Bool`, `var stopped: Bool`, `var startDelay: Duration?` (a start that takes that long).
- Rules: the source starts after the first `.connected` (in `performStart`, in place of `startAudio` for USB) and is **not** stopped by `scannerWentAway` or restarted by a resume; `.streaming` sets `audioStreaming` and yields `.audioStreaming`; any other state clears it; each state is emitted as `.lineIn`; `.missing` emits the missing warning once per missing spell; `.failed(reason)` and `.denied` emit their warning once; the recorder gets `audioOffset: ModelProfile.lineInAudioOffset` for a line-in station; `stop()` stops the source after `PSI,0` (step 5's place) and never touches `cooldownStore`.

- [ ] **Step 1: Write the failing tests** (SDS150 `MockSerialScanner` behind a link, `FakeLineInSource`, a cooldown store that fails the test if called)

`lineInRecordsAHit` (`saveAudio .everyTransmission`: one hit → a WAV whose sample count matches
the chunks yielded during it plus pre/post-roll; `hitEnded.audioPath` set);
`saveAudioNeverStillStreamsTheTap` (`liveAudio()` receives chunks, no file);
`noLineInConfigIsTodaysBehaviour` (no source created, `hasAudio` false);
`lineInMissingThenBack` (state `.missing` mid-hit → that hit logged with what it had, warning
text exact, next hit no audio; `.streaming` again → next hit recorded);
`lineInSurvivesAScannerDisconnect` (mock `unplug()` then `replug()`: the source is never stopped
or restarted, `liveAudio()` keeps receiving);
`stopWhileTheSourceIsStarting` (`startDelay: .seconds(10)`; `stop()` returns within 2 s,
`stopped == true`, `PSI,0` sent); `neverTouchesTheCooldownStore`;
`replaceLineInSwapsTheSource`; `disabledSourceWarnsOnce` (`DisabledLineInSource`, warning
`audio input disabled by NOCTULE_NO_USB_DETECTION`, hits logged).

- [ ] **Step 2–4: Fail, implement, pass** — `NOCTULE_NO_USB_DETECTION=1 swift test --filter StationRunner` (the existing runner tests must stay green).
- [ ] **Step 5: Commit** (`feat: StationRunner records and taps a USB station's line-in`)

---

### Task 9: Clipped and silent hits

**Files:**
- Modify: `Sources/NoctuleStore/StationRunner.swift`
- Test: `Tests/NoctuleStoreTests/StationRunnerLineInTests.swift`

**Interfaces:**
- Produces: `RunnerEvent.clipped(LoggedHit)`; `public static func clippedMessage(channel: String) -> String` (`The audio input clipped during "<channel>". Turn the scanner's volume down a step.`) and `silentLineInMessage(channel:)`; `LoggedHit.audioClipped` true in `.hitEnded` and in the log for a hit that clipped, false for a line-in hit that didn't, nil without a line-in.
- Rules: levels go through the consumer (new `Input.level(LineInLevel)`); a clipped level counts for each open hit whose `startInstant ≤ level.at + lineInAudioOffset`; `.clipped` once per hit, at the first clip. The idle floor is the median `rmsDBFS` of levels that fall in no open hit, over the last 60 s (none yet: no silence judged). Per open hit keep the max `rmsDBFS`; at its end, a hit ≥ 2 s during which the line-in was `.streaming` throughout is silent when that max < floor + 15 dB, else loud. Three silent hits in a row emit the silent warning once; a loud hit resets the count and re-arms the warning. Hits shorter than 2 s, or during `.missing`, neither count nor reset.

- [ ] **Step 1: Write the failing tests**: `clipDuringAHitMarksIt` (one clipped level mid-hit → one `.clipped`, `audioClipped == true` in the log); `clipBetweenHitsMarksNothing`; `twoClipsOneEvent`; `threeSilentHitsWarnOnce` (floor −52 from idle levels; three 3 s hits at RMS −45 → one warning, a fourth → none); `loudHitReArms` (silent, silent, loud at −20, then three silent → a second warning); `twoSilentHitsDoNotWarn`; `shortHitsDoNotCount` (1.5 s hits between silent ones don't reset or count); `missingDeviceIsNotSilence`; `noFloorYetJudgesNothing`.
- [ ] **Step 2–4: Fail, implement, pass.**
- [ ] **Step 5: Commit** (`feat: flag clipped hits and warn about a silent line-in`)

---

### Task 10: The player: low latency and following the output

**Files:**
- Modify: `Sources/NoctuleAudioPlayback/AudioPlayer.swift`, `JitterBuffer.swift` (only if a prefill parameter is missing)
- Test: `Tests/NoctuleAudioPlaybackTests/AudioPlayerSmokeTests.swift`

**Interfaces:**
- Produces: `AudioPlayer.init(prefillSamples: Int = 1600)`; `public static let lineInPrefillSamples = 480`; `public var engineRestarts: Int`. On `AVAudioEngineConfigurationChange` for its engine during `play`, the player builds and starts a new engine on the current default output, keeps the jitter buffer, and counts the restart; a failed restart ends `play` with `engineStartFailed`.

- [ ] **Step 1: Write the failing tests**: `prefillIsConfigurable` (with 480, playback starts after 480 samples are pushed — via the jitter buffer's state); `configurationChangeRestartsTheEngine` (post the notification with the engine as object → `engineRestarts == 1`, `play` still consuming). Follow the existing smoke tests' guard for machines with no output device.
- [ ] **Step 2–4: Fail, implement, pass** — `swift test --filter NoctuleAudioPlaybackTests`.
- [ ] **Step 5: Commit** (`fix: the player follows output changes; a low-latency prefill`)

---

### Task 11: The session runs a line-in

**Files:**
- Modify: `Sources/NoctuleAppCore/Session/SessionEnvironment.swift` (`lineInSources: LineInSourceFactory?` default nil; `audioInputs: any AudioInputListing` default `.empty`; `makeLineInAudioOutput: @Sendable () -> any AudioOutput` defaulting to `makeAudioOutput`), `SessionEnvironment+Overrides.swift` (apply `LineInDetection.selection(…, app: true)`: `.disabled` → a `DisabledLineInSource` factory and the empty listing; `.testStream(path)` → the empty listing and `lineInTestStream = path` (a new `String?` property) for the app shell to build its factory from in Task 13; notes printed), `StationSession.swift`, `StationSession+USB.swift`, `SessionRegistry.swift`
- Create: `Sources/NoctuleAppCore/Session/PeakHold.swift`
- Test: `Tests/NoctuleAppCoreTests/StationSessionLineInTests.swift`, `SessionEnvironmentOverridesTests.swift`

**Interfaces:**
- Consumes: Task 8's runner API.
- Produces on `StationSession`: `public private(set) var lineInConfig: LineInConfig?` (from the device settings at start); `hasAudio` = network || `lineInConfig != nil`; `public private(set) var lineIn: LineInState?`; `public private(set) var lineInLevel: LineInLevel?` (updated at most 30 Hz); `public private(set) var peakHoldDBFS: Double?` (via `PeakHold`, 1.5 s); `public private(set) var clipLatched: Bool`, `public func clearClip()`; `public private(set) var clipWarning: LoggedHit?`, `public func dismissClipWarning()`; `public func stepScannerVolumeDown()` (one `setScannerVolume(current − 1)`, nothing at 0 or with no reading); `public func lineInChanged(_ config: LineInConfig?) async` (calls `runner.replaceLineIn`, keeps the scanner session).
- `SessionRegistry`: `public func lineInChanged(_ stationID: UUID, to config: LineInConfig?)`; `public func previewLevels(stationID: UUID, config: LineInConfig) -> (levels: AsyncStream<LineInLevel>, cancel: @Sendable () -> Void)` — the open session's levels when it runs that config, else a short-lived source from `environment.lineInSources` (`DisabledLineInSource` levels being none).
- `AppDelegate`'s `standard(...)` call passes the system pieces (Task 13).
- A USB session's `scannerWentAway` path keeps `relayTask`, the levels task and playback running; they end only at a stop or suspend. Playback for a line-in station uses `makeLineInAudioOutput`.

- [ ] **Step 1: Write the failing tests** (`USBRig` with `FakeLineInSource` through `environment.lineInSources`)

`lineInStationHasAudio`; `levelsAndClipLatch` (a clipped level → `clipLatched`; `clearClip()`
clears it; a later unclipped level doesn't); `clipWarningNamesTheHit` (`.clipped` → `clipWarning`
set, `onWarning` gets `clippedMessage`); `volumeDownSendsOneVOL` (mock volume 5 →
`stepScannerVolumeDown()` → the mock's log gains exactly `VOL,4`; at 0 nothing);
`lineInRelaySurvivesTheScannerWait` (unplug: phase `.waitingForScanner`, `packets` keeps rising,
playback not stopped); `lineInChangedKeepsTheScanner` (no second `MDL` or `PSI` in the mock's log,
the fake source swapped); `previewUsesTheRunningSession`; `noCooldownCalls`; overrides:
`killSwitchGivesTheDisabledFactory`, `testStreamNeedsPrivateSettings`; `PeakHold` holds 1.5 s then
falls to the current peak.

- [ ] **Step 2–4: Fail, implement, pass** — `NOCTULE_NO_USB_DETECTION=1 swift test --filter 'NoctuleAppCoreTests'`; the iOS build of `NoctuleAppCore` passes.
- [ ] **Step 5: Commit** (`feat: line-in in the station session`)

---

### Task 12: The station editor's Audio settings

**Files:**
- Modify: `Sources/NoctuleAppCore/Settings/StationEditorModel.swift`
- Test: `Tests/NoctuleAppCoreTests/StationEditorModelTests.swift`

**Interfaces:**
- Produces: `public var audioInputs: [AudioInputDevice]` (refreshed with `refreshPorts()`), `public var audioInput: String?` (UID; nil = None), `public var audioInputChannel: LineInChannel = .both`, `public var audioInputOptions: [(uid: String?, title: String)]` (`None (no audio)`, each present input by name, then a saved one not present as `<name> (not connected)`), `public var sharedInputNote: String?` (`<station> also uses this input (<channel>).` when another station's device settings name the same UID and an overlapping channel: `both` overlaps everything), `public var lineInConfig: LineInConfig?`. `save()` writes the three keys to the device settings with `usbPort` (before the station), clears them for a network station, and the caller (the view) calls `registry.lineInChanged(id, to:)` when they changed. The model's init takes `audioInputs: any AudioInputListing`.

- [ ] **Step 1: Write the failing tests**: `loadsTheSavedInput`; `missingInputShowsNotConnected`; `savesTheInputBeforeTheStation`; `networkStationClearsTheInput`; `sharedInputNoteForOverlap` (left/left → note, left/right → none, both/right → note); `lineInChangeIsReported` (a flag the view reads: `lineInChanged == true` only when a key changed).
- [ ] **Step 2–4: Fail, implement, pass.**
- [ ] **Step 5: Commit** (`feat: the station editor chooses a line-in`)

---

### Task 13: Entitlements, usage string and the system wiring

**Files:**
- Create: `Resources/NoctuleScan.entitlements` (`com.apple.security.device.audio-input` true)
- Modify: `Resources/Info.plist` (`NSMicrophoneUsageDescription`: `Noctule Scan records and plays your scanner's audio from the input its headphone jack is connected to.`), `scripts/build-app.sh` (`codesign --force --options runtime --entitlements Resources/NoctuleScan.entitlements --sign -`; update its header comment), `packaging/notarize.sh` (the `.app` branch passes the same `--entitlements`), `Package.swift` (`NoctuleScan` depends on `NoctuleAudioCapture`), `Sources/NoctuleScan/AppDelegate.swift` (pass `lineInSources: { EngineLineInSource.system($0) }`, `audioInputs: CoreAudioInputs()`, `makeLineInAudioOutput: { AudioPlayer(prefillSamples: AudioPlayer.lineInPrefillSamples) }`; under `.testStream(path)` the factory is `{ PipeLineInSource(path: path, config: $0) }`)
- Test: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift`, `AppIconTests.swift` or a new `AppBundleTests` check

- [ ] **Step 1: Write the failing tests**: `notarizeSignsWithTheEntitlements` (the stub `codesign` sees `--entitlements …/NoctuleScan.entitlements` with `--options runtime`); `buildAppSignsWithTheEntitlements` (`codesign -d --entitlements - "build/Noctule Scan.app"` lists `com.apple.security.device.audio-input`, and `codesign -dv` shows `runtime`); `infoPlistHasMicrophoneUsage`.
- [ ] **Step 2–4: Fail, implement, pass**; then `scripts/build-app.sh` and launch the built app once on the network mock per AGENTS.md (it must start under the hardened runtime; record anything surprising in LESSONS.md).
- [ ] **Step 5: Commit** (`feat: the app may use audio input (entitlement, usage string, wiring)`)

---

### Task 14: The app's line-in UI

**Files:**
- Create: `Sources/NoctuleScan/Scanner/LineInMeterView.swift` (the view and a pure `MeterScale`: `fraction(dBFS:) -> Double` over −60…0, `zone(dBFS:) -> .green|.yellow|.red` with −12 and −3, `band = (-18.0, -6.0)`)
- Modify: `Settings/StationEditorView.swift` (Audio section for USB: input popup, Channel segmented, Line-in level meter from `registry.previewLevels`, the note and `sharedInputNote`; calls `registry.lineInChanged` after a save that changed it), `MacStyle/MacStyleView.swift` (a `Line-in level` row under Volume when `session.lineInConfig != nil`), `Scanner/MacControlsBar.swift` (Listen and app volume shown when `session.hasAudio`; the compact `In` meter and CLIP at the end of the bar in the Scanner view only; the clip warning row with **Volume −1** and dismiss; permission denied adds **Open Privacy Settings** opening `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`), `HitLog/` inspector (shows `Clipped` beside a recording whose `audioClipped == true`), `Scanner/ScannerIndicators.swift` (`static func lineIn(_ state: LineInState?, listening: Bool, deviceName: String) -> StatusIndicator` replacing `noAudioOverUSB` for a line-in station)
- Test: `Tests/NoctuleScanTests/LineInUITests.swift`, `Tests/NoctuleCLIIntegrationTests/AppLifecycleIntegrationTests.swift`

- [ ] **Step 1: Write the failing tests**

`NoctuleScanTests`: `meterScaleFractions` (−60 → 0, −30 → 0.5, 0 → 1, below −60 → 0);
`meterZones` (−12.1 green, −11.9 yellow, −2.9 red); `lineInIndicatorTexts` (streaming + listening
→ `Listening · Fictional Interface`, streaming not listening → `Not listening`, `.missing` →
`Line-in not connected`, `.denied` → `Line-in blocked`); `enablementShowsAudioForLineIn`.
`AppLifecycleIntegrationTests`: `usbLineInAppRecordsAHit` (mock `--model sds150 --serial
--serial-link L --line-out S --verbose`, a USB station saving `L` and a line-in UID, the app with
`NOCTULE_NO_USB_DETECTION=1` and `NOCTULE_TEST_LINE_IN=S`: after a transmission a WAV exists in
`NOCTULE_RECORDINGS_DIR` and the hit log's `audio_path` names it; SIGTERM → exit 0,
`active-subscriptions=0`, `PSI,0` last, no cooldown file); `usbLineInAppUnderTheKillSwitchOpensNoInput`
(same without `NOCTULE_TEST_LINE_IN`: no WAV, stderr has `audio input disabled by
NOCTULE_NO_USB_DETECTION`, exit 0).

- [ ] **Step 2–4: Fail, implement, pass.**
- [ ] **Step 5: Check on the mock with the computer-use tools** (AGENTS.md "Driving the app"; mock with `--line-out`, the app with the overrides above): the editor's Audio section and its meter; the Mac-style `Line-in level` row moving; drag scanner Volume to 9 → CLIP latches and the warning names the hit; **Volume −1** → exactly one `VOL,8` in the mock's log; click CLIP clears it; Listen off → the meter still moves; Scanner view's `In` meter; a hit's recording plays in the hit-log window and the inspector says Clipped. Window screenshots only, under `.superpowers/screenshots/plan-18/`. Quit from the app's menu; `active-subscriptions=0`.
- [ ] **Step 6: Commit** (`feat: the line-in meter, clip warning and status in the app`)

---

### Task 15: Documents

**Files:**
- Modify: `AGENTS.md` (the mock's `--line-out` flags and assumptions; `NOCTULE_TEST_LINE_IN`; the kill-switch now covers audio inputs, saved ones included; **agents never open a real audio input**; a line-in hardware run is the owner's call each time; real line-in recordings are never committed; the entitlement and dev-build re-prompts), `LESSONS.md` (anything learned), `docs/specs/2026-11-17-usb-line-in-audio-design.md` (status line; a new §12 "What was built (Plan 18)" with each departure from §5–§8), `images/screenshots/README.md` only if new screenshots are added for the website (mocks only).
- [ ] **Step 1:** Write them; `swift test --filter RealNamesTests` passes.
- [ ] **Step 2:** Full run: `NOCTULE_NO_USB_DETECTION=1 swift test` and the iOS build. All pass.
- [ ] **Step 3: Commit** (`docs: line-in audio (Plan 18)`)

After Task 15: a whole-branch review, then the owner's hardware session (design §10) with the
SDS150 on the USB Audio Device, each step the owner's call. Plan 19 (command line) follows.
