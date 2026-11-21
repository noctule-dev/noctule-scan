# Plan 4 — The Mac App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The first-release macOS app: a station picker, a main window per station (scanner view and Mac-style view), live audio, the hit log window, and Settings. It is built on the Plan 1–3 stack, tested against the mock first, and checked on the real SDS200 last.

**Architecture:**
- **`NoctuleAppCore`** (new library) holds every view model and all app logic. It has no SwiftUI, AppKit or AVFAudio imports, only Foundation and Observation, so it is unit-tested against `MockSDS200` and builds for iOS (the future dash app reuses it).
  - `StationSession` is the `@MainActor @Observable` model of one connected station. It wraps one `StationRunner`.
  - `SessionRegistry` keeps one session per station, however many windows show it.
- **`NoctuleScan`** (new executable target) is the SwiftUI/AppKit shell: scenes, views, the app delegate (quit, sleep and wake, signals), and `AudioPlayer` as the `AudioOutput`.
  - `scripts/build-app.sh` wraps it into `build/Noctule Scan.app` with an `Info.plist` and an ad-hoc signature. There is no Xcode project yet.
- **Small additions to the Plan 3 stack:**
  - `StationRunner` exposes live status, a live audio tap, its control client, a logging pause and the audio restart hint.
  - The CLI's cooldown wait moves into NoctuleKit as `RTSPCooldownGate`.
  - A per-station `StationLock` keeps the app and `noctule log` from running the same station at once.

**Tech Stack:** Swift 6.2 tools, SwiftPM, Swift Testing, SwiftUI and AppKit (macOS 26), Observation, AVFAudio (playback only, in `NoctuleAudioPlayback`). No third-party dependencies.

**Spec:** `docs/specs/2026-11-08-noctule-scan-design.md` §6, §7, §8, §9.2, §10, §12. Also `docs/specs/2026-11-08-sds-remote-protocol.md` (§3 key codes, §5 `STS`, §8 open items), `AGENTS.md`, `LESSONS.md`, and the local mockups in `.superpowers/brainstorm/*/content/all-screens.html` (screens 1–5; git-ignored and directional only).

## Global Constraints

- Every Plan 1–3 rule still applies:
  - TEARDOWN on every exit path; `PSI,0` paired with every `PSI` start.
  - **The 120 s RTSP reconnect cooldown**, through `FileRTSPCooldownStore` at `~/Library/Caches/NoctuleScan/rtsp-cooldown.json`, shared with the CLI. Any entry point that starts audio checks the store and waits first (LESSONS 2026-11-08, `log` cooldown).
  - BSD-socket audio.
  - No real hosts, names, frequencies or IDs in tracked files.
- **Scanner commands the app may send:**
  - read-only commands;
  - `KEY,<code>,P`, `VOL,<n>` and `SQL,<n>`, only in direct response to a user action;
  - `MSM,1`, only after a confirmation dialog.
  - Never guessed commands, never `HLD`/`MNU`/`URC`/quick-key sets, never long-press modes.
  - Hardware tests that press keys or set levels need the owner's go-ahead.
- **The app never opens a new audio session on its own after audio `.failed`.** Only the user's Reconnect or Restart scanner does. A new session is opened automatically only at window open and after wake, and always through the cooldown gate.
- **`STS` polling:**
  - at most once per `1 s`, and at least once per `5 s` while connected;
  - also `150 ms` after a key press's reply, and whenever a push changes mode, screen, system, department, channel, talkgroup, or a hold/avoid flag.
  - (GSI at 1/s with audio passed on hardware; STS plus PSI has not been tested; Task 16 measures it.)
- **NoctuleKit, NoctuleStore and NoctuleAppCore build for iOS:** no AppKit, UIKit, SwiftUI or AVFAudio. Check with `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build`. That also covers Store and Kit, which closes the Plan 3 follow-up.
- **The app is unsandboxed for now (designer's call):**
  - A sandboxed app would get a container path for the cooldown store and stop sharing it with the CLI. That is unsafe for the scanner.
  - Sandboxing needs an app-group store and is a follow-up.
  - Don't add sandbox-only assumptions either: keep all paths injectable.
- **Bundle:**
  - `CFBundleIdentifier` `org.noctulescan.NoctuleScan`, display name `Noctule Scan`, `LSMinimumSystemVersion` 26.0.
  - `NSLocalNetworkUsageDescription`: "Noctule Scan connects to your scanner on the local network or over your VPN."
  - No Uniden names or marks in the name, icon or copy.
- **Copy (exact strings):**
  - menu banner: "Scanner is in a menu — use the scanner or press Menu to exit";
  - audio failure: "Scanner audio isn't responding";
  - restart dialog: "Restart the scanner at <host>?" with buttons "Restart" and "Cancel", and the note "Whether a restart revives a stuck audio server is unverified; if audio stays off, power-cycle the scanner.";
  - iCloud row: disabled, "requires an Apple Developer Program membership";
  - station in use: "<name> is open in another Noctule Scan process (pid <n>)."
- **Designer's calls in this plan:**
  - The Mac "Hold" control is a menu (System / Department / Channel). Each item presses the soft key whose `STS` label, trimmed and uppercased, is `SYSTEM`, `DEPT` or `CHANNEL`; an item is disabled when no soft key carries its label.
  - The Mac "Record" control is the app's **Logging** toggle (pause or resume logging and recording). The scanner's own Replay/Record key stays on the keypad.
  - Factory display colors are the builder's choice, recorded in `DisplayPalette`.
  - LAN auto-discovery is deferred: the protocol has no known discovery, and broadcasting to unknown devices is untested. The picker takes a manual address.
- Commit trailers: `Co-Authored-By: <authoring model> <noreply@anthropic.com>` and a `Claude-Session:` line naming the session.

## Review Focus

1. **Quitting, closing the last window, sleep, or SIGTERM/SIGHUP while audio streams:** every session stops through `runner.stop()` (`PSI,0`, TEARDOWN) before the process exits or the Mac sleeps. Quit waits at most `15 s`. Pinned in Tasks 8 and 11 (mock `leaked-sessions=0`).
2. **Two windows on one station, or the app and `noctule log` on one station:** one runner per station per process, and a second process is refused with the "in use" copy, not given a second RTSP session. Pinned in Tasks 2 and 8.
3. **Wake from sleep within 120 s of the TEARDOWN, or with the network not yet up:** the session waits out the cooldown and shows the countdown. It then retries control with backoff, `5, 10, 20, 30, 30…` s, and never touches 554 until `MDL` answers. Pinned in Task 7.
4. **Fast key input** (held arrow key, trackpad scroll on the knob, key repeat): presses are sent one at a time. While more than `8` are queued, further presses are dropped, so the UDP channel is never flooded. Pinned in Task 5.
5. **Local Network permission denied, or a wrong address:** connect fails within the command timeout, and the picker and window say "No answer from <host>:<port>. Check the address, your VPN, and that Noctule Scan is allowed under Privacy & Security › Local Network." They never hang. Pinned in Tasks 6 and 10.

---

### Task 1: Package layout and the shared cooldown gate

**Files:**
- Modify: `Package.swift`
  - libraries `NoctuleStore` and `NoctuleAppCore` (products);
  - target `NoctuleAppCore` (deps NoctuleKit, NoctuleStore);
  - test target `NoctuleAppCoreTests` (deps NoctuleAppCore, NoctuleMockScanner, NoctuleKitTestSupport).
- Create: `Sources/NoctuleKit/Audio/RTSPCooldownGate.swift`
- Create: `Sources/NoctuleAppCore/AppCore.swift` (a placeholder so the target builds)
- Delete: `Sources/noctule/CooldownWait.swift`. Update `ListenCommand.swift` and `LogCommand.swift` to use the gate.
- Test: `Tests/NoctuleKitTests/RTSPCooldownGateTests.swift`

**Interfaces:**
- Produces:
  - `public enum RTSPCooldownGate`, with the current `CooldownWait` bodies moved over unchanged:
    - `static func remaining(store: any RTSPCooldownStore, host: String, cooldown: Duration) async -> Duration?`
    - `static func waitOut(_ d: Duration, isInterrupted: @Sendable () -> Bool) async -> Bool`
  - `xcodebuild -scheme NoctuleAppCore` exists.
- [ ] **Step 1:** Tests:
  - `remainingIsNilWithoutRecord`;
  - `remainingCountsLatestKey`: two keys closed 30 s and 100 s ago, cooldown 120 s, gives ≈ 90 s ± 1;
  - `waitOutStopsWhenInterrupted`;
  - `zeroCooldownIsNil`.
- [ ] **Step 2:** RED (stubs), then GREEN. Then `swift test --filter "Cooldown|LogIntegration|ListenIntegration"` passes, and `xcodebuild -list` shows `NoctuleAppCore` and `NoctuleStore`.
- [ ] **Step 3:** Run `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build` and get `BUILD SUCCEEDED`. Update `AGENTS.md` and LESSONS (scheme names). Commit `feat: NoctuleAppCore target; cooldown gate moves into NoctuleKit`.

---

### Task 2: Per-station lock

**Files:**
- Create: `Sources/NoctuleStore/StationLock.swift`
- Modify: `Sources/noctule/LogCommand.swift`, `Sources/NoctuleCLICore/StationCLI.swift` (message)
- Test: `Tests/NoctuleStoreTests/StationLockTests.swift`, `Tests/NoctuleCLIIntegrationTests/LogIntegrationTests.swift`

**Interfaces:**
- Produces:
  - `public final class StationLock: Sendable`
  - `static func acquire(stationID: UUID, settingsDirectory: URL) throws(StationLockError) -> StationLock`. It takes a non-blocking `flock(LOCK_EX|LOCK_NB)` on `Stations/<uuid>/runner.lock`, after writing its pid into the file.
  - `func release()`. `deinit` releases too.
  - `enum StationLockError: Error, Equatable { case inUse(pid: Int32?), unavailable(String) }`
  - `noctule log` takes the lock before the cooldown wait. On `inUse` it prints `log: <name> is open in another Noctule Scan process (pid <n>)` and exits 1, with no scanner traffic.
- [ ] **Step 1:** Tests:
  - `secondAcquireIsInUse`: same process, second fd; `inUse(pid: getpid())`;
  - `releaseFreesIt`;
  - `lockDiesWithProcess`: a child process takes it and is killed, then acquire succeeds;
  - `unwritableDirectoryIsUnavailable`;
  - integration `secondLogOnSameStationRefused`: two `noctule log` runs against the mock; the second exits 1 with that line, and the mock's log shows one `PSI`.
- [ ] **Step 2:** RED, then GREEN. Commit `feat: per-station runner lock shared by the app and noctule log`.

---

### Task 3: StationRunner hooks for the app

**Files:**
- Modify: `Sources/NoctuleStore/StationRunner.swift`
- Test: `Tests/NoctuleStoreTests/StationRunnerTests.swift`

**Interfaces:**
- Produces (on `StationRunner`):
  - `nonisolated let liveStatus: AsyncStream<ScannerInfo>`: every push's info, `bufferingNewest(1)`. It finishes with `events`.
  - `func liveAudio() -> AsyncStream<AudioChunk>`: a tap on the chunks the runner already receives, `bufferingNewest(50)`. A second call finishes the previous tap. Dropping a tap never affects the session, recording or the cooldown.
  - `func control() -> ScannerClient?`: the connected client, nil before `.connected` and after stop.
  - `func setLoggingPaused(_ paused: Bool)`. While paused, new hits are neither logged nor recorded. An open hit finishes normally. Display, pushes and audio continue.
  - `func audioRestartHint() async -> RestartHint?`: the AudioSession's hint while audio is `.failed`, else nil.
- [ ] **Step 1:** Tests, against `MockSDS200` as in the existing runner tests:
  - `liveStatusCarriesPushes`;
  - `droppingAudioTapKeepsSession`: take a tap, drop it, then a hit still records and `leakedSessions` is empty at stop;
  - `controlIsNilAfterStop`;
  - `pausedLoggingSkipsHits`: a scenario transmission while paused gives no row and no WAV; after resuming, the next one is logged;
  - `restartHintOnWedgedAudio`: `wedge-audio` fault gives `.failed`, and the hint is non-nil.
- [ ] **Step 2:** RED, then GREEN. Commit `feat: StationRunner live status, audio tap, control client and logging pause`.

---

### Task 4: The display model

**Files:**
- Create: `Sources/NoctuleAppCore/Display/DisplayModel.swift`, `DisplayPalette.swift`
- Test: `Tests/NoctuleAppCoreTests/DisplayModelTests.swift` (uses `sts-trunk-sds200-1.24.00.txt` and the mock's `MockScreens.display`)

**Interfaces:**
- Consumes: `DisplayStatus` (`lines`, `trailing`, `softKeyLabels`), `ScannerInfo`, `ColorMode`, `ScannerModel`.
- Produces:
  - `struct DisplayModel: Equatable, Sendable { var rows: [DisplayRow]; var softKeys: [SoftKey]; var isMenu: Bool }`, built with `init(status: DisplayStatus, info: ScannerInfo?)`.
  - `struct DisplayRow: Equatable, Sendable { var segments: [DisplaySegment]; var large: Bool }`. `large` is the line's `sizeFlag == "1"` (`DisplayStatus` already splits the `STS` flag map per line).
  - `struct DisplaySegment: Equatable, Sendable { var text: String; var highlighted: Bool }`. Runs of equal mask state: mask `*` means highlighted. The soft-key row is excluded from `rows`.
  - `struct SoftKey: Equatable, Sendable { var key: FrontPanelKey; var label: String }`: `soft1`…`soft3`, trimmed labels.
  - `func softKey(labelled: String) -> FrontPanelKey?`: case-insensitive, trimmed.
  - `isMenu` is true when `info.mode` or `info.screen` contains "menu", case-insensitive.
  - Icon glyphs outside printable ASCII become `"·"`.
  - `struct RGB: Equatable, Sendable { var r, g, b: Double }`
  - `struct DisplayPalette: Equatable, Sendable { var background, text, highlightBackground, highlightText: RGB }`, with `static func factory(model: ScannerModel, mode: ColorMode) -> DisplayPalette`. `blackOnWhite` and `whiteOnBlack` are exact black and white; `color` is the builder's choice.
- [ ] **Step 1:** Tests:
  - `fixtureRowsAndSoftKeys`: the fixture's soft keys are `SYSTEM`, `DEPT`, `CHANNEL` on `soft1`–`soft3`;
  - `largeRowsFollowFlagMap`: `"00001010100000000"` makes rows 4, 6 and 8 large;
  - `maskSplitsSegments`;
  - `menuDetectedFromInfo`;
  - `softKeyLookupIgnoresCaseAndSpaces`;
  - `nonASCIIGlyphsReplaced`;
  - `monochromePalettesAreExact`.
- [ ] **Step 2:** RED, then GREEN. Commit `feat: display model from STS with factory palettes`.

---

### Task 5: Keyboard map, key queue, and display refresh policy

**Files:**
- Create: `Sources/NoctuleAppCore/Input/KeyChord.swift`, `KeyboardRouter.swift`, `KeyPressQueue.swift`, `Sources/NoctuleAppCore/Display/DisplayRefreshPolicy.swift`
- Test: `Tests/NoctuleAppCoreTests/KeyboardTests.swift`, `KeyPressQueueTests.swift`, `DisplayRefreshPolicyTests.swift`

**Interfaces:**
- Consumes: `KeyMap.resolved(for:) -> [FrontPanelKey: String]`, `ScannerClient.press(_:)`.
- Produces:
  - `struct KeyChord: Hashable, Sendable { var key: String; var modifiers: Set<KeyModifier> }`
    - `enum KeyModifier: String, CaseIterable, Sendable { case command = "⌘", option = "⌥", control = "⌃", shift = "⇧" }`
    - `init?(_ text: String)` parses the `KeyMap` strings: `"a"`, `"F1"`, `"space"`, `"←"`, `"↩"`, `"⌘4"`.
    - `var display: String` gives the text back.
  - `struct KeyboardRouter { init(map: [FrontPanelKey: String]); func key(for: KeyChord) -> FrontPanelKey?; var conflicts: [KeyChord: [FrontPanelKey]] }`
  - `actor KeyPressQueue { init(maxQueued: Int = 8, send: @escaping @Sendable (FrontPanelKey) async throws -> Void); func enqueue(_ k: FrontPanelKey) -> Bool; func drain() async }`. It sends one press at a time, in order. `enqueue` returns false and drops the press while 8 are waiting. A failed send is reported through `var lastError: String?` and doesn't stop the queue.
  - `struct DisplayRefreshPolicy { var minInterval: Duration = .seconds(1); var maxInterval: Duration = .seconds(5); var afterKey: Duration = .milliseconds(150) }`
    - `func nextFetch(lastFetch: ContinuousClock.Instant?, lastKeyReply: ContinuousClock.Instant?, changed: Bool, now: ContinuousClock.Instant) -> ContinuousClock.Instant`
    - `static func significantChange(_ a: ScannerInfo?, _ b: ScannerInfo) -> Bool`: mode, screen, system, department or channel name, talkgroup, or any `hold`/`avoid` flag.
- [ ] **Step 1:** Tests:
  - `parsesAndFormatsEveryDefault`: every SDS200 default round-trips;
  - `rejectsGarbage`: `""`, `"⌘"`, `"ab"`;
  - `routerFindsOverride`;
  - `conflictsReported`;
  - `queueSendsInOrderOneAtATime`: the fake send records its max concurrency, which must be 1;
  - `queueDropsBeyondEight`: a blocked send plus 10 enqueues gives 8 accepted and 2 false;
  - `queueSurvivesSendError`;
  - `policyRespectsMinInterval`;
  - `policyForcesMaxInterval`;
  - `policyAfterKeyReply`: a key reply 150 ms ago, but the last fetch only 0.5 s ago, still waits until 1 s;
  - `significantChangeIgnoresRSSI`.
- [ ] **Step 2:** RED, then GREEN. Commit `feat: key chords, router, rate-limited key queue, display refresh policy`.

---

### Task 6: StationSession — connect, live state, stop

**Files:**
- Create: `Sources/NoctuleAppCore/Session/StationSession.swift`, `SessionEnvironment.swift`, `AudioOutput.swift`
- Test: `Tests/NoctuleAppCoreTests/StationSessionTests.swift`

**Interfaces:**
- Consumes:
  - `StationRunner` (Task 3), `StationLock` (Task 2), `RTSPCooldownGate` (Task 1);
  - `DisplayModel` and `DisplayRefreshPolicy` (Tasks 4 and 5);
  - `HitLog(url:)`, `SettingsStore`.
- Produces:
  - `protocol AudioOutput: AnyObject, Sendable { func play(_ chunks: AsyncStream<AudioChunk>) async throws; func stop(); var volume: Float { get set } }`
  - `struct SessionEnvironment: Sendable`, with fields:
    - `settings: any SettingsStore`;
    - `settingsDirectory: URL`;
    - `recordingsRoot: URL`;
    - `cooldownStore: any RTSPCooldownStore`;
    - `cooldown: Duration = .seconds(120)`;
    - `makeTransport`;
    - `audioConfig: AudioSessionConfig`;
    - `makeAudioOutput: @Sendable () -> any AudioOutput`;
    - `reconnectBackoff: [Duration] = [5, 10, 20, 30].map(Duration.seconds)`.

    It also provides `static func standard() -> SessionEnvironment`, which uses the real paths from AGENTS.md.
  - `@MainActor @Observable final class StationSession`:
    - `init(station: Station, environment: SessionEnvironment)`
    - `private(set) var phase: SessionPhase`, with `enum SessionPhase: Equatable { case idle, inUse(pid: Int32?), waitingForCooldown(secondsLeft: Int), connecting, connected(model: String, firmware: String), noAnswer(String), stopping, stopped }`
    - `private(set) var audio: AudioSessionState`
    - `private(set) var info: ScannerInfo?`
    - `private(set) var display: DisplayModel?`
    - `private(set) var recentHits: [LoggedHit]`: newest first, at most 50, updated on `hitStarted` and `hitEnded` by id;
    - `private(set) var warnings: [String]`: the last 20;
    - `var listening: Bool`: playback on or off, never the session;
    - `var loggingPaused: Bool`
    - `func start() async`: takes the lock, waits out the gate (counting down `secondsLeft` once a second), opens the HitLog, then starts the runner. A failure before `.connected` becomes `.noAnswer` with the Review Focus 5 copy.
    - `func stop() async`: idempotent; awaits `runner.stop()`, then closes the log and releases the lock.
  - The display loop fetches `STS` through `runner.control()` on `DisplayRefreshPolicy`'s schedule.
- [ ] **Step 1:** Tests, against `MockSDS200` with a short cooldown, a temp settings directory and a fake `AudioOutput` that counts chunks:
  - `connectsAndShowsLiveState`: `.connected("SDS200", …)`, `info` set, `display?.softKeys.count == 3`;
  - `stopTearsDownAndReleases`: after stop, `leakedSessions` is empty, the lock is free, and the mock saw `PSI,0`;
  - `waitsOutCooldownFirst`: with a recent close recorded, the phase passes through `.waitingForCooldown` and the mock sees no traffic until it ends;
  - `secondProcessLockGivesInUse`: lock held by another fd;
  - `noAnswerOnDeadHost`: a closed UDP port gives `.noAnswer` within 3 s, with the exact copy;
  - `listeningTogglesPlaybackOnly`: chunks reach the fake while listening, none after it is turned off, and the session's packet count keeps rising;
  - `stsRateBounded`: over 5 s connected with the scenario changing, the mock's `STS` count is between 1 and 6;
  - `recentHitsCappedAt50`.
- [ ] **Step 2:** RED, then GREEN. Commit `feat: StationSession connect, live status, display refresh, stop`.

---

### Task 7: StationSession — control, audio failure, restart, sleep and wake

**Files:**
- Modify: `Sources/NoctuleAppCore/Session/StationSession.swift`
- Test: `Tests/NoctuleAppCoreTests/StationSessionControlTests.swift`

**Interfaces:**
- Produces (on `StationSession`):
  - `func press(_ key: FrontPanelKey)`: through a `KeyPressQueue` on `runner.control()`.
  - `func setScannerVolume(_ v: Int)` and `func setScannerSquelch(_ v: Int)`: clamped to the `ModelProfile` range, debounced `250 ms` (last value wins).
  - `func hold(_ level: HoldLevel)`, with `enum HoldLevel { case system, department, channel }`. It presses `display?.softKey(labelled:)` for `"SYSTEM"`, `"DEPT"` or `"CHANNEL"`. `func canHold(_:) -> Bool` says whether it can.
  - `private(set) var restartHint: RestartHint?`: set when audio becomes `.failed`.
  - `func reconnect() async`: stop, then start (through the gate).
  - `func restartScanner() async -> RestartOutcome`: stop, then `ScannerRestart.perform` on a fresh client, then start. The UI calls it only after its dialog.
  - `func suspend() async` (sleep): stop, remembering that it was running.
  - `func resume() async` (wake): start if it was running. While `.noAnswer`, it retries on `reconnectBackoff`, the last value repeating, until connected or stopped.
- [ ] **Step 1:** Tests:
  - `keysReachMock`: `press(.digit4)` gives the mock `KEY,4,P`;
  - `volumeDebouncedAndClamped`: 5 calls within 100 ms ending at 40 give one `VOL,29`;
  - `holdUsesLabelledSoftKey`: `hold(.department)` sends `KEY,B,P` on the mock screen;
  - `holdDisabledWithoutLabel`;
  - `audioFailureSetsHintAndDoesNotReconnect`: `wedge-audio` gives `.failed` and a hint; after 3 s the mock has seen exactly one SETUP;
  - `restartRecovers`: wedge, `restartScanner()`, then `.restarted` and audio `.streaming` again, with `leakedSessions` empty;
  - `wakeWithinCooldownWaits`: `suspend`, then `resume` at once, passes through `.waitingForCooldown`;
  - `wakeRetriesUntilScannerAnswers`: the mock not answering for 2 retries, then answering, ends `.connected`, and no RTSP connection happens before the first `MDL` reply.
- [ ] **Step 2:** RED, then GREEN. Commit `feat: session control, audio-failure restart flow, sleep and wake`.

---

### Task 8: SessionRegistry and app lifecycle

**Files:**
- Create: `Sources/NoctuleAppCore/Session/SessionRegistry.swift`
- Test: `Tests/NoctuleAppCoreTests/SessionRegistryTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class SessionRegistry`, with:
  - `init(environment: SessionEnvironment)`
  - `func open(_ station: Station) -> StationSession`: shared and refcounted by station id; the first open starts it.
  - `func release(_ id: UUID) async`: the last release stops it.
  - `func stopAll(deadline: Duration = .seconds(15)) async -> Bool`: false if the deadline passed.
  - `func suspendAll() async` and `func resumeAll() async`
  - `func stationsChanged(_ stations: [Station])`: a renamed or edited open station restarts its session; a deleted one stops.
  - `open` calls `settings.setLastStationID`.
- [ ] **Step 1:** Tests:
  - `twoOpensShareOneRunner`: the mock sees one `PSI` subscription;
  - `lastReleaseStops`;
  - `stopAllStopsEverySession`: two mocks, both with `leakedSessions` empty;
  - `stopAllHonoursDeadline`: a session whose stop hangs (`wedge-control`) returns false within 15 s ± 1;
  - `editRestartsSession`;
  - `openRecordsLastStation`.
- [ ] **Step 2:** RED, then GREEN. Commit `feat: session registry with shared sessions and orderly stopAll`.

---

### Task 9: Hit log model

**Files:**
- Create: `Sources/NoctuleAppCore/HitLog/HitLogModel.swift`
- Test: `Tests/NoctuleAppCoreTests/HitLogModelTests.swift`

**Interfaces:**
- Consumes: `HitLog.transmissions`, `groups(_:countsSince:)`, `sessions()`, `deleteHits(ids:)`, `exportCSV`; `Station.savedFilters` and `countsResetAt`; `StationSession.recentHits` changes.
- Produces: `@MainActor @Observable final class HitLogModel`, with:
  - `init(station: Station, log: HitLog, settings: any SettingsStore, trash: @escaping @Sendable (URL) throws -> Void)`
  - `var layout: HitLogLayout` (`.groups` is the default, or `.transmissions`)
  - `var filter: HitFilter`
  - `var searchText: String`: mapped to `filter.text`, debounced `300 ms`;
  - `var selectedSession: Date?`
  - `private(set) var groups: [HitGroup]` and `private(set) var transmissions: [LoggedHit]`
  - `var selection: Set<String>`
  - `func reload() async`
  - `func transmissions(for group: HitGroup) async -> [LoggedHit]`: for the inspector, oldest first, for "play all in order";
  - `func unitsSeen(in group: HitGroup) async -> [String]`
  - `func delete(_ ids: [UUID]) async throws`: moves each returned file to the Trash, ignoring missing files;
  - `func exportCSV() async throws -> String`
  - `func resetCounts() async throws`: sets and saves `countsResetAt = now`;
  - `func saveFilter(named: String) async throws` and `func deleteFilter(_ id: UUID) async throws`
  - `func hitsChanged()`: debounced `500 ms` reload, called by the window when the session's hits change.
- [ ] **Step 1:** Tests, with a temp `HitLog` seeded with fictional hits:
  - `groupsByDefault`;
  - `toggleShowsTransmissions`;
  - `searchFilters`;
  - `sessionSelectsDay`;
  - `deleteTrashesFiles`: a fake trash records URLs, and a missing file doesn't throw;
  - `resetCountsPersists`;
  - `savedFilterRoundTrips`;
  - `unitsSeenUnion`;
  - `inspectorOldestFirst`.
- [ ] **Step 2:** RED, then GREEN. Commit `feat: hit log view model`.

---

### Task 10: Station editor and Settings models

**Files:**
- Create: `Sources/NoctuleAppCore/Settings/StationEditorModel.swift`, `AppSettingsModel.swift`
- Test: `Tests/NoctuleAppCoreTests/StationEditorModelTests.swift`, `AppSettingsModelTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class StationEditorModel`:
    - `init(station: Station?, settings: any SettingsStore, makeTransport:)`
    - `var draft: Station`
    - `var issues: [String]`: `validate()` plus a case-insensitive duplicate-name check, with the CLI's wording;
    - `func testConnection() async -> ConnectionTest`, with `enum ConnectionTest: Equatable { case ok(model: String, firmware: String), noAnswer(String), failed(String) }`. It sends `MDL` and `VER` only, never PSI or RTSP; the copy is from Review Focus 5. A detected model goes into `detectedModel`, and `draft.connection.modelOverride` stays the user's choice;
    - `func save() async throws -> Station`
    - `var keyConflicts: [KeyChord: [FrontPanelKey]]`, through `KeyboardRouter`.
  - `@MainActor @Observable final class AppSettingsModel`:
    - `var locations: [StorageLocationAvailability]`
    - `func exportSettings() async throws -> Data` and `func importSettings(_ d: Data, replaceExisting: Bool) async throws -> Int`, through `SettingsArchive`.
- [ ] **Step 1:** Tests:
  - `duplicateNameRejected`;
  - `testConnectionAgainstMock`: `.ok("SDS200", …)`, and the mock log holds only `MDL` and `VER`;
  - `testConnectionNoAnswer`;
  - `saveValidates`;
  - `keyConflictShown`;
  - `iCloudListedDisabled`;
  - `exportImportRoundTrip`.
- [ ] **Step 2:** RED, then GREEN. Commit `feat: station editor and app settings models`.

---

### Task 11: App shell, bundle, and lifecycle wiring

**Files:**
- Modify: `Package.swift`: executable target `NoctuleScan` (deps NoctuleAppCore, NoctuleAudioPlayback, NoctuleStore, NoctuleKit); product `.executable(name: "NoctuleScan", targets: ["NoctuleScan"])`.
- Create: `Sources/NoctuleScan/NoctuleScanApp.swift`, `AppDelegate.swift`, `AudioPlayer+AudioOutput.swift`, `StationWindow.swift` (placeholder content), `StationPickerView.swift` (list and connect only)
- Create: `scripts/build-app.sh`, `Resources/Info.plist`
- Test: `Tests/NoctuleCLIIntegrationTests/AppLifecycleIntegrationTests.swift`

**Interfaces:**
- Consumes: `SessionRegistry` (Task 8).
- Produces:
  - Scenes:
    - `Window("Stations", id: "picker")`;
    - `WindowGroup(for: UUID.self)`, one station per window, `registry.open` on appear and `release` on disappear;
    - `Settings`.
  - Launch opens the last station's window if it still exists, else the picker.
  - `AppDelegate`:
    - `applicationShouldTerminate` returns `.terminateLater`, awaits `registry.stopAll()`, then `reply(true)`;
    - `NSWorkspace.willSleepNotification` triggers `suspendAll`, and `didWakeNotification` triggers `resumeAll`;
    - SIGTERM and SIGHUP go through a `DispatchSource` built in a nonisolated function (LESSONS: main-actor globals) to `NSApp.terminate`;
    - `signal(SIGPIPE, SIG_IGN)`.
  - Environment variables `NOCTULE_SETTINGS_DIR`, `NOCTULE_RECORDINGS_DIR`, `NOCTULE_COOLDOWN_STORE` and `NOCTULE_COOLDOWN_SECONDS` override the paths, **for tests against the mock only** (same rule as the CLI flags).
  - `scripts/build-app.sh [debug|release]` runs `swift build`, assembles `build/Noctule Scan.app/Contents/{MacOS,Resources,Info.plist}`, and runs `codesign --force --sign -`.
- [ ] **Step 1:** Integration tests (subprocess, with bounded polling per LESSONS; the app binary is launched directly with the env overrides and a pre-seeded settings directory whose last station points at `noctule-mock-scanner`):
  - `appTearsDownOnSIGTERM`;
  - `appTearsDownOnSIGHUP`.

  Each launches, waits until the mock logs `PLAY`, sends the signal, and then checks that the mock's stderr shows TEARDOWN, `PSI,0` and `leaked-sessions=0`, and that the app exits within 15 s.
- [ ] **Step 2:** RED, then GREEN. `scripts/build-app.sh` succeeds and `codesign -dv "build/Noctule Scan.app"` shows the identifier. Add `build/` to `.gitignore`. Commit `feat: Mac app shell, bundle script, quit/sleep/signal teardown`.

---

### Task 12: Scanner view

**Files:**
- Create: `Sources/NoctuleScan/Scanner/ScannerView.swift`, `DisplayView.swift`, `KeypadView.swift`, `KnobView.swift`, `MacControlsBar.swift`, `RecentHitsList.swift`, `KeyboardShortcuts.swift`
- Modify: `StationWindow.swift`

**Interfaces:**
- Consumes: `StationSession` (Tasks 6 and 7), `DisplayModel`/`DisplayPalette`, `KeyboardRouter`.
- Produces: `ScannerView(session:)`, laid out like the SDS200 per design §7.1:
  - **Display:** `DisplayView` draws `rows` in a monospaced font, large rows at about 1.6×, highlighted segments in reverse video from the palette, and a soft-key row under the display as three buttons (`soft1`–`soft3`). The menu banner copy goes over the display when `isMenu`.
  - **Knobs:**
    - Volume/Light knob: scroll or drag changes the scanner volume; a click presses `volumePush`.
    - Squelch/Menu knob: scroll or drag changes the squelch; a click presses `squelchPush`.
    - Scroll knob: each scroll step presses `scrollLeft` or `scrollRight` through the queue; a click presses `scrollPush`.
  - **Keypad:** the 27 `FrontPanelKey`s, with second-function captions (SRCH1–3, ATT, DIM, WX, IFX).
  - **Mac controls:** Hold menu (with `canHold`), Avoid, Listen toggle, Logging toggle, app volume, phase/audio/logging indicators, and the "Scanner audio isn't responding" banner with Reconnect and Restart scanner (`confirmationDialog` with the exact copy).
  - **Recent hits:** a list (channel, TG/frequency, time, `New` badge) whose "Open Hit Log" opens the Task 14 window.
  - **Keyboard:** `KeyboardShortcuts` installs an `NSEvent` local key-down monitor while the window is key. It routes `KeyChord` through `KeyboardRouter` to `session.press`, and ignores events while a text field is first responder.
- [ ] **Step 1:** Build with `swift build`. Launch through `scripts/build-app.sh` against `noctule-mock-scanner --scenario default` (env overrides; a station on 127.0.0.1).
- [ ] **Step 2:** Use the `run` skill to screenshot the window while connected, mid-transmission, and with the mock's `--fault wedge-audio` (banner showing). Check that typing `4` sends `KEY,4,P` (mock `--verbose`).
- [ ] **Step 3:** Quit with ⌘Q; the mock prints `leaked-sessions=0`. Commit `feat: scanner view with display, knobs, keypad, Mac controls, shortcuts`.

---

### Task 13: Mac-style view and the view toggle

**Files:**
- Create: `Sources/NoctuleScan/MacStyle/MacStyleView.swift`, `InfoChips.swift`
- Modify: `StationWindow.swift` (a toolbar segmented control that persists `station.preferredView` through the settings store)

**Interfaces:**
- Consumes: `StationSession.info`, `recentHits`, and the control methods.
- Produces: `MacStyleView(session:)`, per design §7.2:
  - a large channel name;
  - a `system › department` breadcrumb;
  - chips for mode, TGID, UID, NAC/tone (`toneOrCode`), frequency (`%.4f MHz`) and RSSI (`dBm`), each hidden when nil;
  - the Hold, Avoid, Listen and Logging buttons;
  - scanner volume and squelch sliders;
  - an "Active now" row (the open hit) above the recent list.
- [ ] **Step 1:** Screenshot both views against the mock, mid-transmission and idle (chips hidden). Check that toggling the view, then closing and reopening the window, keeps the choice.
- [ ] **Step 2:** Commit `feat: Mac-style view and persisted view toggle`.

---

### Task 14: Hit log window

**Files:**
- Create: `Sources/NoctuleScan/HitLog/HitLogWindow.swift`, `HitTable.swift`, `HitInspector.swift`, `WAVPlayback.swift`

**Interfaces:**
- Consumes: `HitLogModel` (Task 9).
- Produces: `WindowGroup("Hit Log", id: "hitlog", for: UUID.self)`, laid out per design §9.2:
  - **Sidebar:** sessions by date and saved filters ("Only new" built in).
  - **Table:**
    - In group layout the columns are TGID, Frequency, Tone/NAC/CC, Mode, RSSI, UID, Hits, Talk time, First, Last, and System › Dept › Channel.
    - In transmission layout, Duration replaces Hits/Talk time/First/Last.
    - Columns are sortable, reorderable and resizable (`TableColumnCustomization`, persisted with `@SceneStorage`).
    - New rows get a visible `New` badge.
  - **Inspector:** details, units seen, and the transmissions, each with play (`AVAudioPlayer` in `WAVPlayback`; "no audio: <error>" when `audioPath` is nil). Also "Play all in order" (sequential) and "Show in Finder" (`NSWorkspace.activateFileViewerSelecting`).
  - **Toolbar:** Logging pause (bound to the session when open), Export CSV (`NSSavePanel`), Reset counts (confirmation), `.searchable`, and Delete (confirmation: "Delete N rows and move their recordings to the Trash?").
- [ ] **Step 1:** Run the mock for 2 minutes, then screenshot both layouts and the inspector. Play one WAV, export CSV, and check that the file opens and has a header row. Delete one row and check that its WAV is in the Trash.
- [ ] **Step 2:** Commit `feat: hit log window`.

---

### Task 15: Station picker, editor, and Settings views

**Files:**
- Modify: `StationPickerView.swift`
- Create: `Sources/NoctuleScan/Settings/StationEditorView.swift`, `KeyMapEditor.swift`, `SettingsView.swift`

**Interfaces:**
- Consumes: `StationEditorModel`, `AppSettingsModel` (Task 10).
- Produces:
  - **Picker** (design §12.1):
    - stations, the last used one marked;
    - Add, Edit and Delete (confirmation; the hit log and recordings are kept);
    - Connect.
    - USB and Bluetooth transport rows are visible but disabled ("not supported yet").
  - **Editor:**
    - name, host, UDP and RTSP ports;
    - Test connection, with the result inline;
    - a detected model with an override picker.
  - **Settings, Station tab:**
    - Save audio (every / only new / never), minimum length, retention (forever or N days), recordings folder (`NSOpenPanel`, stored in `StationDeviceSettings`), and the format, shown fixed as "WAV, 16-bit, 8 kHz mono";
    - display color mode (`station.appearance.colorMode`: Color, Black on White, White on Black);
    - the key map editor: a row per key, a recorder field, conflicts in red, and "Reset to model defaults".
  - **Settings, General tab:**
    - the storage location (iCloud disabled with its copy);
    - Export Settings and Import Settings (with a replace-existing choice).
- [ ] **Step 1:** Against the mock:
  - add a station, test it (ok), and test a wrong port ("No answer…" within 3 s);
  - edit the name while connected; the window title updates and the session restarts after the cooldown;
  - change a key binding and check it takes effect;
  - export, delete the station, import, and check it is back.

  Screenshot each screen.
- [ ] **Step 2:** Commit `feat: station picker, editor, key map editor, settings`.

---

### Task 16: Docs, end-to-end mock run, and the hardware check

**Files:**
- Modify: `AGENTS.md` (the app, `scripts/build-app.sh`, env overrides, the iOS scheme), `LESSONS.md` (what this plan taught), `docs/specs/2026-11-08-sds-remote-protocol.md` (STS and PSI findings)
- Create: `ACKNOWLEDGMENTS.md` if it doesn't exist yet (the `sds200` library, MIT)

- [ ] **Step 1:** Run the full suite: `swift test` passes; `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build` gives `BUILD SUCCEEDED`; `RealNamesTests` passes.
- [ ] **Step 2:** Run the app against the mock for 30 minutes (Listen on, logging on, one sleep/wake via `pmset sleepnow`, then ⌘Q). The mock must show `leaked-sessions=0`, every cooldown must be honored (check the mock's `--verbose` timestamps for RTSP connects ≥ 120 s apart), and there must be no crash.
- [ ] **Step 3: PENDING (owner-run, not done by an agent).** The result goes in protocol notes §8.9 (`STS` polling with `PSI`), which still says it hasn't been run. **Owner-run hardware check.** Ask the owner first, and list what will be sent: `KEY` presses (`4`, scroll, a soft key), and `VOL`/`SQL` sets that are then restored to their prior values. Run on the real SDS200:
  - 10 minutes connected with audio, with the STS rate as in the Global Constraints;
  - one quit;
  - after 120 s, one reopen;
  - `MDL` answers at the end.

  Record the STS-with-PSI result and the firmware in the protocol notes §8. Delete the recordings and the hit log from the check (they are real radio traffic). If audio wedges, stop and tell the owner.
- [ ] **Step 4:** Commit `docs: Plan 4 app docs, lessons, hardware findings`.

**Owner hand checks.** The agent's shell has no Accessibility permission, so it can't type, click, scroll or drag in the running app, and Step 2 skipped `pmset sleepnow` (it would sleep the owner's Mac). The owner checks these by hand, against the mock first (AGENTS.md, "To run it on the mock by hand"):
- typing scanner keys on the station window (digits, Menu, the soft keys, arrow keys for Scroll, a held arrow key), and that typing in a text field or a focused control doesn't press scanner keys;
- the knobs: wheel and trackpad scroll and drag on VOL, SQL and Scroll, one step per notch, and the knob pushes;
- the Hold menu (System / Department / Channel, each disabled when no soft key carries its label);
- the Restart scanner confirmation dialog (exact copy, Restart and Cancel; Cancel sends nothing);
- the menu banner ("Scanner is in a menu — use the scanner or press Menu to exit") on entering and leaving a menu;
- the cooldown countdown and the connecting placeholders while a station opens;
- the hit log table: dragging, sorting and hiding columns, and that the layout persists across window reopen and relaunch, in both layouts;
- the save and open panels (Export CSV…, Export Settings…, Import Settings…, the recordings folder);
- Show in Finder from the hit log;
- a lid-close sleep and wake with a station streaming from the mock: the mock should log `PSI,0` and TEARDOWN before the Mac sleeps, and after the wake the session waits out the cooldown and reconnects once (the IOKit sleep path has never run on a real sleep).
