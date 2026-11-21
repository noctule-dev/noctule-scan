# Plan 3 — Stations, Hit Logging and Storage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stations, each with its own settings and its own hit log, plus a runner that watches a scanner's `PSI` pushes, detects transmissions ("hits"), logs them to a per-station database, and saves each transmission's audio as its own WAV. A `noctule log` / `noctule hits` CLI proves all of this against the mock, then against the real SDS200.

**Architecture:** This builds on Plans 1 and 2.
- **Pure value logic** lives in `NoctuleKit/Hits`: `HitDetector` (push updates → hit events) and `TransmissionRecorder` (audio chunks + hit events → WAV files), both driven by explicit timestamps so they can be tested deterministically.
- **Storage** lives in a new target, `NoctuleStore`:
  - stations and settings as JSON, behind a `SettingsStore` protocol (local now; an iCloud implementation later);
  - the hit log in SQLite through the system `SQLite3` module, which needs no dependency and is available on macOS and iOS.
- **`StationRunner`** (an actor in `NoctuleStore`) wires `ScannerClient`, `AudioSession`, the detector, the recorder and the log together. It guarantees `PSI,0` and TEARDOWN on stop.

**Tech Stack:** Swift 6.4, SwiftPM, Swift Testing, Foundation, `SQLite3` (system library). No third-party dependencies.

**Spec:** `docs/specs/2026-11-08-noctule-scan-design.md` §6 (Stations), §9 (Hit log and recording), §10 (Storage). Also `docs/specs/2026-11-08-sds-remote-protocol.md` (§4 ScannerInfo shapes, §6 audio, §8 open items), `AGENTS.md` and `LESSONS.md`. The Plan 2 final-review recommendations are folded into Tasks 1, 2 and 5.

## Global Constraints

- Every Plan 1 and Plan 2 rule still applies:
  - Scanner commands are read-only, plus the user-confirmed `MSM,1` only.
  - Every `PSI` start is paired with `PSI,0`.
  - TEARDOWN on every exit path.
  - **120 s RTSP reconnect cooldown**, with the file store in the CLI.
  - BSD-socket audio.
  - No real hosts, addresses, recorded radio audio, or real system or talkgroup names in tracked files. Fixtures are fictional. `config/real-names.txt` is checked by `RealNamesTests`.
- Develop and test against the mock (`NoctuleMockScanner`, `noctule-mock-scanner`) first. Real hardware is used only in Task 10's opt-in check.
- NoctuleKit and NoctuleStore stay iOS-buildable: no AppKit, UIKit or AVFAudio.
- **"New" (design §9.2, owner):**
  - a **frequency not programmed in the scanner** (conventional: `channel.isProgrammed == false`); or
  - a **talkgroup never seen before by this station** (its first hit in the station's log).
- **Recording format (design §9.3):** WAV, 16-bit PCM, 8000 Hz mono. Name: `YYYY-MM-DD HH-MM-SS · TG<id> · <channel>.wav`. For conventional or weather: `YYYY-MM-DD HH-MM-SS · <freq>MHz · <channel>.wav`, with the frequency formatted `%.4f`. Times are local. Skip transmissions shorter than `0.5` s. Keep forever by default.
- **Default locations:**
  - Settings: `~/Library/Application Support/NoctuleScan/`.
  - Per-station hit log: `…/NoctuleScan/Stations/<station-uuid>/hits.sqlite`.
  - Recordings: `~/Music/Noctule Scan/<Station name>/`.
  - Every location is overridable for tests.
- **Synced vs device-only (design §10.2):**
  - Synced, and modelled for CloudKit (Codable, all fields optional or defaulted, UUID ids, no uniqueness constraints): station identity, connection, recording rules, key map, appearance, preferred view, saved filters, counts reset.
  - Device-only: recordings folder path, USB port, Bluetooth pairing id, audio output device.
- The storage location is a global setting with values `local` or `iCloud`. `iCloud` is present but disabled, with "requires an Apple Developer Program membership".
- Commit trailers: `Co-Authored-By: <authoring model> <noreply@anthropic.com>` and a `Claude-Session:` line naming the session.

## Review Focus

1. **`PSI` pushes stop mid-transmission** (scanner hang, VPN drop): the open hit ends `stallEnd` (3 s) after the last update, the WAV is finalized, and nothing hangs. Pinned in Tasks 6 and 9.
2. **Recordings folder unwritable or disk full:** logging continues, the hit is saved with `audioError` set and no file path, and the runner keeps running. Pinned in Task 8.
3. **Channel names unsafe for filenames** (`/`, `:`, control characters, 300 characters, emoji, two hits in the same second): the filenames are sanitized, truncated and unique. Pinned in Task 8.
4. **Audio discontinuities inside a transmission** (lost packets, SSRC change, `AudioSession` recovery): the WAV timing stays correct (gaps are filled with silence) and nothing crashes. Pinned in Tasks 2 and 8.
5. **Crash or kill mid-hit:** on reopen, dangling hits (`endedAt == nil`) are closed as `interrupted`, keeping their already-flushed audio, and the counts stay consistent. Pinned in Task 7.

---

### Task 1: Plan 2 carry-overs and ScannerInfo shapes

**Files:**
- Modify: `Tests/NoctuleKitTests/AudioSessionTests.swift` (fix the StateLog race)
- Modify: `Sources/NoctuleKit/Status/ScannerInfo.swift`
- Create: `Sources/NoctuleKitTestSupport/Fixtures/gsi-wx-sds200-1.26.01.xml` (fictional values)
- Modify: `Tests/NoctuleKitTests/ScannerInfoTests.swift`

**Interfaces:**
- Produces:
  - `ScannerInfo` parses `<WxChannel Index CH_No Freq Mod Hold …>`: `channel` gets a `NamedItem` named `"WX <CH_No>"`, plus `frequencyMHz` and `modulation`.
  - Idle placeholders normalize to nil: a TGID or UID of `"---"` or `"TGID: ---"` after trimming, empty `Name`, and `rssi == -999`.
  - New: `var isWeather: Bool` (`Mode` contains `"WX"`) and `var hasActiveChannel: Bool` (`channel != nil && (talkgroupID != nil || frequencyMHz != nil)`).

- [ ] **Step 1:** RED/GREEN to fix the test race at AudioSessionTests.swift:171, :331 and :485. Await `eventually { rig.states.all.contains(.stopped) }` before counting. RED: add a 30 ms delay to the StateLog consumer so the race shows; GREEN: the fix. Remove the delay in GREEN.
- [ ] **Step 2:** Tests:
  - `parsesWeatherShape`: `channel?.name == "WX 4"`, `frequencyMHz == 162.55`, `modulation == "FM"`, `isWeather`, `hasActiveChannel`.
  - `idlePlaceholdersAreNil`: `TGID=" ---"` and `Name=""` give `talkgroupID == nil`, `department == nil`, `rssi == nil`, `hasActiveChannel == false`.
  - The existing trunk fixture still parses unchanged, and `hasActiveChannel` is true.
  - Use the fictional frequency `162.550`.
- [ ] **Step 3:** RED commit (stubs and tests), then GREEN commit `feat: ScannerInfo weather shape and idle normalization`.

---

### Task 2: Timestamped pushes and audio discontinuities

**Files:**
- Modify: `Sources/NoctuleKit/Client/ScannerClient.swift`
- Modify: `Sources/NoctuleKit/Audio/AudioSession.swift`
- Tests: `ScannerClientTests.swift`, `AudioSessionTests.swift`

**Interfaces:**
- Produces:
  - `struct PushUpdate: Sendable { var info: ScannerInfo; var receivedAt: ContinuousClock.Instant }`.
  - `ScannerClient.startPushUpdates(interval: Duration = .milliseconds(500)) async throws -> AsyncStream<PushUpdate>`. `receivedAt` is stamped in the router the moment the response is routed, before any further hop. `startPush` keeps working as a thin map over it.
  - `AudioChunk` gains `ssrc: UInt32` and `lostBefore: Int`, the number of packets the tracker counted missing immediately before this chunk (`gap(missing:)`), or 0.
  - `AudioStats` gains `droppedChunks: Int`, the chunks the `bufferingNewest(250)` stream discarded. Count them via the yield result `.dropped`.
- [ ] **Step 1:** Tests:
  - `pushUpdatesAreStampedOnArrival`: the simulated transport emits two pushes 100 ms apart; the `receivedAt` difference is within 100 ms ± 30 ms.
  - `chunkReportsGapAndSSRC`: FakeRTPSender skips 2 sequence numbers, so the next chunk has `lostBefore == 2`; after a `changeSSRC()`, `ssrc` differs.
  - `droppedChunksCounted`: don't consume, send 300 packets; `stats.droppedChunks >= 50`.
- [ ] **Step 2:** RED then GREEN (`feat: timestamped PSI pushes; AudioChunk discontinuity info`).

---

### Task 3: Station model

**Files:**
- Create: `Sources/NoctuleStore/Station.swift`
- Modify: `Package.swift` (new target `NoctuleStore` depending on NoctuleKit, linking `sqlite3`; test target `NoctuleStoreTests`)
- Test: `Tests/NoctuleStoreTests/StationTests.swift`

**Interfaces:**
- Produces (all `Codable, Sendable, Equatable`; every stored property defaulted or optional):
  - `struct Station { var id: UUID = UUID(); var name: String = "New Station"; var connection: StationConnection = .init(); var recording: RecordingRules = .init(); var keyMap: KeyMap = .init(); var appearance: Appearance = .init(); var preferredView: PreferredView = .scanner; var savedFilters: [HitFilter] = []; var countsResetAt: Date? = nil }`
  - `struct StationConnection { var transport: TransportKind = .network; var host: String? = nil; var udpPort: UInt16 = 50536; var rtspPort: UInt16 = 554; var modelOverride: ScannerModel? = nil }`. `TransportKind` and `ScannerModel` gain `Codable`.
  - `struct RecordingRules { var saveAudio: SaveAudio = .everyTransmission; var minimumDuration: Double = 0.5; var retentionDays: Int? = nil; var maxTransmission: Double = 300 }`, with `enum SaveAudio: String, Codable { case everyTransmission, onlyNew, never }`.
  - `struct KeyMap { var overrides: [String: String] = [:] }`. Keys are `FrontPanelKey.rawValue`; values are key equivalents such as `"⌘4"`. Add `static func defaults(for: ScannerModel) -> [FrontPanelKey: String]`: digits map to the same digit, `.avoid` to `"a"`, `.function` to `"f"`, `.menu` to `"m"`, `.enterYes` to `"↩"`, `.dotNo` to `"."`, `.scrollLeft`/`.scrollRight` to `"←"`/`"→"`, `.scrollPush` to `"space"`, and soft keys 1–3 to `"F1"`–`"F3"`. Then `func resolved(for: ScannerModel) -> [FrontPanelKey: String]`, which applies the overrides.
  - `struct Appearance { var colorMode: ColorMode = .color; var profileImportedAt: Date? = nil }`, with `enum ColorMode: String, Codable { case color, blackOnWhite, whiteOnBlack }`.
  - `enum PreferredView: String, Codable { case scanner, macStyle }`.
  - `struct HitFilter { var id: UUID = UUID(); var name: String = ""; var onlyNew: Bool = false; var modes: [String] = []; var toneOrCode: String? = nil; var system: String? = nil; var since: Date? = nil; var text: String? = nil }`.
  - `struct StationDeviceSettings { var stationID: UUID; var recordingsFolder: String? = nil; var usbPort: String? = nil; var bluetoothID: String? = nil; var audioOutputDevice: String? = nil }`.
  - `func validate() -> [StationIssue]`, with `enum StationIssue: Equatable { case emptyName, missingHost, invalidMinimumDuration, invalidMaxTransmission }`. A network station needs a host; `minimumDuration` must be in `0...60` and `maxTransmission` in `10...3600`.
- [ ] **Step 1:** Tests:
  - `decodesFromEmptyJSON`: `{}` decodes to the defaults, which shows CloudKit-style tolerance.
  - `roundTrips`.
  - `ignoresUnknownKeys`: a JSON with an extra field still decodes.
  - `keyMapDefaultsCoverEveryKey`: the SDS200 defaults cover all 27 keys.
  - `overridesApply`.
  - `validationFindsIssues`.
- [ ] **Step 2:** RED then GREEN (`feat: Station model (sync-ready) and device settings`).

---

### Task 4: Settings storage (local, iCloud-ready)

**Files:**
- Create: `Sources/NoctuleStore/SettingsStore.swift`, `LocalSettingsStore.swift`, `SettingsArchive.swift`
- Test: `Tests/NoctuleStoreTests/SettingsStoreTests.swift`

**Interfaces:**
- Produces:
  - `protocol SettingsStore: Sendable { func stations() async throws -> [Station]; func save(_ station: Station) async throws; func deleteStation(id: UUID) async throws; func deviceSettings(for id: UUID) async throws -> StationDeviceSettings; func saveDeviceSettings(_ s: StationDeviceSettings) async throws; func lastStationID() async -> UUID?; func setLastStationID(_ id: UUID?) async }`
  - `actor LocalSettingsStore: SettingsStore { init(directory: URL) }`. It writes `stations.json` (synced part only), `device.json` (device-only, never synced) and `app.json` (`lastStationID`, `storageLocation`). Writes are atomic. A corrupt file is moved aside to `<name>.corrupt-<timestamp>` and treated as empty, never as a crash. `deleteStation` also removes that station's device settings.
  - `enum StorageLocation: String, Codable { case local, iCloud }`, with `struct AppSettings { var storageLocation: StorageLocation = .local }` and `static func availableLocations() -> [(StorageLocation, available: Bool, reason: String?)]`. iCloud returns `(false, "requires an Apple Developer Program membership")`.
  - `struct SettingsArchive: Codable { var version: Int = 1; var exportedAt: Date; var stations: [Station] }`, with `static func export(from: any SettingsStore) async throws -> Data` and `static func importing(_ data: Data, into: any SettingsStore, replaceExisting: Bool) async throws -> Int`. An import gives new UUIDs to stations whose id already exists unless `replaceExisting` is set. Device settings are never exported.
- [ ] **Step 1:** Tests:
  - `saveLoadDelete`.
  - `deviceSettingsStayLocal`: `stations.json` contains no `recordingsFolder`.
  - `corruptFileIsQuarantined`: write garbage, load gives `[]`, and a `.corrupt-` file exists.
  - `exportImportRoundTrip`.
  - `importDoesNotClobberWithoutReplace`.
  - `iCloudUnavailable`.
- [ ] **Step 2:** RED then GREEN (`feat: local settings store, export/import, iCloud placeholder`).

---

### Task 5: Cooldown store hardening (crash lease and file lock)

**Files:**
- Modify: `Sources/NoctuleKit/Audio/RTSPCooldownStore.swift`, `RTSPClient.swift`
- Tests: `RTSPClientTests.swift` (or a new `RTSPCooldownStoreTests.swift`)

**Interfaces:**
- Produces:
  - `RTSPCooldownStore` gains `func recordOpened(host: String, at: Date, pid: Int32) async` and `func recordClosed(host:at:)`, which also clears the lease. `lastClosed(host:)` returns a dead lease's discovery time, so if the process that owned a lease no longer exists (`kill(pid, 0)` returns `ESRCH`), it counts as "closed at the moment it was discovered" and forces a full cooldown.
  - `FileRTSPCooldownStore` takes an advisory lock (`flock`) on a sibling `.lock` file around each read-modify-write. Write failures are surfaced through `var lastWriteError: String?`; they are not swallowed silently.
  - `RTSPClient` calls `recordOpened` right after a successful TCP connect.
- [ ] **Step 1:** Tests:
  - `deadLeaseForcesCooldown`: write a lease with the pid of an exited child process (spawn `/usr/bin/true` and wait); `connect()` throws `.cooldown`, and its remaining time is ≥ cooldown − 1 s.
  - `liveLeaseFromOtherProcessBlocks`: a lease with this test's own pid, simulating another live process, blocks `connect()`.
  - `concurrentWritersDontLoseUpdates`: 2 stores on the same file, 50 interleaved writes for 2 hosts, and both hosts are present at the end.
  - `writeFailureIsSurfaced`: point the store at a read-only directory; `lastWriteError != nil`.
- [ ] **Step 2:** RED then GREEN (`feat: cooldown crash lease and cross-process file lock`).

---

### Task 6: HitDetector

**Files:**
- Create: `Sources/NoctuleKit/Hits/Hit.swift`, `HitDetector.swift`
- Test: `Tests/NoctuleKitTests/HitDetectorTests.swift`

**Interfaces:**
- Consumes: `PushUpdate` and `ScannerInfo` (Tasks 1 and 2).
- Produces:
  - `struct HitKey: Hashable, Sendable, Codable { var system: String?; var talkgroupID: String?; var frequencyMHz: Double? }`. Trunk hits key on system plus talkgroup; conventional and weather hits key on frequency.
  - `struct Hit: Sendable, Equatable, Codable { var id: UUID; var key: HitKey; var startedAt: Date; var endedAt: Date?; var startInstant: ContinuousClock.Instant; var endInstant: ContinuousClock.Instant?; var system: String?; var department: String?; var channel: String?; var site: String?; var unitIDs: [String]; var modulation: String?; var toneOrCode: String?; var rssiMax: Int?; var programmed: Bool; var continued: Bool; var endReason: EndReason? }`, with `enum EndReason: String, Codable { case signalLost, channelChanged, stalled, maxLength, stopped, interrupted }`. Encode the instant fields as nil, since they're runtime only.
  - `enum HitEvent: Sendable { case started(Hit), updated(Hit), ended(Hit) }`.
  - `struct HitDetector { init(anchor: (instant: ContinuousClock.Instant, date: Date), endHangover: Duration = .seconds(1), stallEnd: Duration = .seconds(3), maxTransmission: Duration = .seconds(300)); mutating func ingest(_ u: PushUpdate) -> [HitEvent]; mutating func tick(now: ContinuousClock.Instant) -> [HitEvent]; mutating func finish(now: ContinuousClock.Instant) -> [HitEvent] }`.
- Rules:
  - An update is *active* when `info.hasActiveChannel && (info.signalBars ?? 0) > 0`.
  - An active update with no open hit starts one.
  - An active update with the same key updates the hit: extend `endInstant`, add the UID if it's new, and raise `rssiMax`.
  - An active update with a different key ends the open hit (`channelChanged`) and starts a new one.
  - An inactive update, or no update at all, ends the hit `endHangover` after the last active update (`signalLost`). If no updates arrive at all, `tick` ends it after `stallEnd` (`stalled`).
  - A hit reaching `maxTransmission` ends (`maxLength`), and a new hit with the same key starts with `continued = true`.
  - `finish` ends any open hit as `stopped`.
  - `endedAt` and `endInstant` are the last *active* update's time.
  - Dates come from `anchor.date + (instant - anchor.instant)`.
- [ ] **Step 1:** Tests, built from synthetic `PushUpdate`s with fixture-shaped `ScannerInfo` (helper `info(tg:sig:uid:rssi:)`):
  - `startsUpdatesEnds`.
  - `channelChangeSplits`.
  - `hangoverBridgesBriefDropout`: one 500 ms inactive gap stays a single hit.
  - `stallEndsHit` (Review Focus 1): no updates for 3.1 s ends it `stalled`.
  - `maxLengthRollsOver`.
  - `idleUpdatesNeverStartHits`.
  - `weatherKeysOnFrequency`.
  - `unprogrammedFlagCaptured`.
  - `datesFollowAnchor`.
- [ ] **Step 2:** RED then GREEN (`feat: HitDetector`).

---

### Task 7: Hit log (SQLite)

**Files:**
- Create: `Sources/NoctuleStore/HitLog.swift`, `HitLogSchema.swift`, `HitQueries.swift`
- Test: `Tests/NoctuleStoreTests/HitLogTests.swift`

**Interfaces:**
- Consumes: `Hit`, `HitKey`, `HitFilter` and `Station`.
- Produces:
  - `actor HitLog { init(url: URL) throws }`:
    - `func begin(_ hit: Hit) throws`: inserts the row with `endedAt` NULL.
    - `func end(_ hit: Hit, audioPath: String?, audioError: String?) throws`.
    - `func isFirstSighting(_ key: HitKey) throws -> Bool`: true if the key wasn't in `first_seen` before this call. It records the key and uses `INSERT OR IGNORE`.
    - `func transmissions(_ f: HitFilter, limit: Int = 1000) throws -> [LoggedHit]`.
    - `func groups(_ f: HitFilter, countsSince: Date?) throws -> [HitGroup]`.
    - `func deleteHits(ids: [UUID]) throws -> [String]`: returns the audio paths so the caller can remove the files.
    - `func purge(olderThan: Date) throws -> [String]`.
    - `func exportCSV(_ f: HitFilter) throws -> String`.
    - `func sessions() throws -> [(day: Date, count: Int)]`.
    - `func closeDangling(now: Date) throws -> Int`.
  - `struct LoggedHit: Sendable, Equatable { var hit: Hit; var audioPath: String?; var audioError: String?; var isNew: Bool }`.
  - `struct HitGroup: Sendable, Equatable { var key: HitKey; var label: String; var hits: Int; var talkTime: Double; var firstSeen: Date; var lastSeen: Date; var rssiMax: Int?; var programmed: Bool; var isNew: Bool; var modes: [String]; var toneOrCode: String? }`.
- Schema (version 1, `PRAGMA user_version = 1`, WAL mode):
  - `hits(id TEXT PRIMARY KEY, system, department, channel, site, talkgroup_id, frequency_mhz REAL, unit_ids TEXT /* JSON */, modulation, tone_or_code, rssi_max INTEGER, programmed INTEGER, continued INTEGER, started_at REAL, ended_at REAL, end_reason, audio_path, audio_error)`.
  - `first_seen(key TEXT PRIMARY KEY, first_seen_at REAL)`.
  - Indexes on `started_at`, `talkgroup_id` and `frequency_mhz`.
  - The key string is `trunk:<system>|<tg>` or `freq:<%.4f>`.
- **isNew:** for conventional and weather hits, `!programmed`. For trunk hits, whether the hit's `started_at` equals its key's `first_seen_at`. For a group: conventional `!programmed`, and trunk `first_seen_at >= filter.since` (or within the session, when `since` is nil and the group's first hit is in the result). Document the exact rule in the code.
- **Groups:** counts and talk time cover hits with `started_at >= countsSince` (ProScan's "reset counts"). `talkTime = sum(ended_at - started_at)`. Dangling hits are excluded until they're closed.
- **CSV:** RFC 4180 quoting. Header: `started,ended,duration_s,system,department,channel,site,tgid,uids,frequency_mhz,mode,tone_or_code,rssi_max,programmed,new,audio_path`.
- [ ] **Step 1:** Tests, using an in-memory or temp-file database:
  - `beginEndRoundTrip`.
  - `firstSightingOnlyOnce`.
  - `newRules`: a conventional unprogrammed hit is new; a trunk TG's first hit is new and its second isn't; with a filter `since` after its first sighting, the group isn't new.
  - `groupsAggregate`: 3 hits on TG 9 give `hits == 3`, the summed talk time, and first/last.
  - `countsResetRespected`.
  - `filters`: onlyNew, modes, toneOrCode, text over system/channel/tg, and since.
  - `deleteReturnsPaths`.
  - `purgeByAge`.
  - `csvQuoting`: a channel name with a comma and quotes.
  - `danglingClosedAsInterrupted` (Review Focus 5): begin without end, reopen, `closeDangling` gives 1, and the hit's `endReason == .interrupted`.
  - `schemaVersionSet`.
- [ ] **Step 2:** RED then GREEN (`feat: SQLite hit log with new-detection, groups, CSV`).

---

### Task 8: TransmissionRecorder

**Files:**
- Create: `Sources/NoctuleKit/Hits/TransmissionRecorder.swift`, `RecordingName.swift`
- Test: `Tests/NoctuleKitTests/TransmissionRecorderTests.swift`

**Interfaces:**
- Consumes: `AudioChunk` (with `lostBefore` and `ssrc`), `HitEvent`, and `WAVWriter`.
- Produces:
  - `enum RecordingName { static func fileName(for hit: Hit, timeZone: TimeZone = .current) -> String }`. It applies the Global Constraints format. Sanitizing: replace `/ : \ * ? " < > |` and control characters with `-`, collapse whitespace, and trim. The channel part is truncated so the whole name is ≤ 200 UTF-8 bytes. An empty channel gives `Unknown`.
  - `final class TransmissionRecorder { init(folder: URL, preRoll: Duration = .milliseconds(500), postRoll: Duration = .milliseconds(500), audioOffset: Duration = .zero, minimumDuration: Duration = .milliseconds(500)); func ingest(_ chunk: AudioChunk) -> [RecordingResult]; func handle(_ event: HitEvent, record: Bool) -> [RecordingResult]; func flush() throws; func finishAll() -> [RecordingResult] }`, with `struct RecordingResult: Sendable, Equatable { var hitID: UUID; var path: String?; var error: String?; var skippedShort: Bool }`. It's not Sendable, and its owner serializes access.
- Rules:
  - Keep a ring buffer of the last `preRoll` of chunks.
  - On `.started(hit)` with `record == true`, open `folder/<fileName>`, adding ` (2)`, ` (3)` and so on if the name exists (Review Focus 3), and write the pre-roll chunks whose `receivedAt + audioOffset >= hit.startInstant - preRoll`.
  - While a hit is open, append each chunk. Before a chunk with `lostBefore = n`, write `n × 320` zero samples (Review Focus 4). On an SSRC change, write nothing extra.
  - On `.ended(hit)`, keep appending until the first chunk whose `receivedAt + audioOffset > hit.endInstant + postRoll`, then close. If the closed audio is shorter than `minimumDuration`, delete the file and return `skippedShort`.
  - Any file error (open or write) sets the hit's `error`, stops recording that hit, and doesn't throw out of `ingest` or `handle` (Review Focus 2). `flush()` flushes every open writer; the runner calls it every 1 s.
  - Open writers and chunks for different hits never overlap. The detector guarantees one open hit at a time, and the recorder keeps at most one writer plus one in post-roll.
- [ ] **Step 1:** Tests, with synthetic chunks of 320 samples whose `receivedAt` steps 40 ms:
  - `fileNameFormat`: `2026-11-09 14-03-07 · TG9 · Lakeview Fire.wav` in UTC.
  - `conventionalName`.
  - `sanitizesAndTruncates`.
  - `collisionSuffix`.
  - `writesPreRollHitAndPostRoll`: a 1 s hit plus 0.5 s pre-roll and 0.5 s post-roll gives about 2.0 s of samples (±40 ms).
  - `fillsGapsWithSilence`: `lostBefore = 3` gives 960 zero samples at that point.
  - `skipsShortTransmission`.
  - `unwritableFolderReportsError`.
  - `recordFalseWritesNothing`.
- [ ] **Step 2:** RED then GREEN (`feat: per-transmission WAV recorder`).

---

### Task 9: StationRunner

**Files:**
- Create: `Sources/NoctuleStore/StationRunner.swift`
- Test: `Tests/NoctuleStoreTests/StationRunnerTests.swift` (against an in-process `MockSDS200` with its default scenario; `NoctuleStoreTests` depends on NoctuleMockScanner)

**Interfaces:**
- Consumes: Tasks 1–8, `ScannerClient`, `UDPTransport`, `AudioSession`, `FileRTSPCooldownStore` (Task 5) and `MockSDS200`.
- Produces:
  - `actor StationRunner { init(station: Station, device: StationDeviceSettings, log: HitLog, recordingsRoot: URL, cooldownStore: any RTSPCooldownStore, makeTransport: @escaping @Sendable (String, UInt16) -> any ScannerTransport = { UDPTransport(host: $0, port: $1) }, audioConfig: AudioSessionConfig = .init(), pushInterval: Duration = .milliseconds(500)); func start() async throws; func stop() async; var events: AsyncStream<RunnerEvent> { get } }`
  - `enum RunnerEvent: Sendable, Equatable { case connected(model: String, firmware: String), audio(AudioSessionState), hitStarted(LoggedHit), hitEnded(LoggedHit), recording(RecordingResult), warning(String), stopped }`
- Behavior:
  - **On start:**
    - `closeDangling`.
    - `connect` and `modelInfo`.
    - `startPushUpdates`.
    - Start the AudioSession, unless `recording.saveAudio == .never`. A failure to start audio, `.cooldown` included, is a `.warning`, and logging continues without audio.
    - A 1 s tick drives `detector.tick` and `recorder.flush`.
  - **On a hit start:** compute `isNew` via `isFirstSighting` plus the programmed rule, decide `record` from `saveAudio` (`onlyNew` records only new hits), then `log.begin` and `recorder.handle`.
  - **A hit already on air when audio starts** (Task 10b; always the case on a weather channel): when the AudioSession reaches `streaming`, start recording every open hit that `saveAudio` wanted recorded but that began before audio first streamed (or after it failed or stopped). A hit that starts while audio is recovering doesn't wait: it records at once (its file fills when chunks resume, and is skipped as too short if recovery fails). The file is named from the hit's start and `log.setAudioPath` stores its path at once. Such a recording has **no pre-roll**: it begins with the first audio after streaming started. Hits `saveAudio` leaves unrecorded stay so, and a hit already recording is never started again (a recovery mid-hit keeps one file).
  - **On a hit end:** `log.end` with the recorder's result.
  - **Recording folder:** `device.recordingsFolder ?? recordingsRoot/<sanitized station name>`.
  - **Retention:** when `retentionDays` is set, purge hits and files older than that at start.
  - **`stop()`:** single-flight and idempotent. In order: `detector.finish`, then `log.end` for every open hit, `recorder.finishAll`, `client.stopPush` (`PSI,0`), `client.disconnect`, `audio.stop` (TEARDOWN), and the `stopped` event.
  - **PSI stream ends unexpectedly:** detector `finish(stalled)`, a `.warning("scanner stopped sending updates")`, and keep running audio until `stop()`.
- [ ] **Step 1:** Tests against MockSDS200 (short cooldown, an in-memory cooldown store, temp folders, `pushInterval` 100 ms, a scenario with a 1.0 s transmission on a fictional TG and an unprogrammed conventional channel):
  - `logsHitsWithAudio`: after one scenario loop, the log has at least 2 hits, each with an `audioPath` whose WAV exists and has a duration ≥ 1.0 s; the TG hit `isNew` on first sight and not on the second loop.
  - `onlyNewSkipsRepeatAudio`.
  - `stopSendsPSI0AndTeardown`: the mock's received commands end with `PSI,0`, and `leakedSessions == []`.
  - `stallEndsHitAndWarns` (Review Focus 1): mock fault `stallPSIAfter`.
  - `audioUnavailableStillLogs`: the mock has `wedgeAudio`; hits are logged with `audioPath == nil` and a warning is emitted.
  - `unwritableFolderStillLogs` (Review Focus 2).
- [ ] **Step 2:** RED then GREEN (`feat: StationRunner wiring scanner, audio, detector, recorder, log`). Run it 3× plus once with `--sanitize=thread`.

---

### Task 10: CLI (`station`, `log`, `hits`) and hardware check

**Files:**
- Modify: `Sources/NoctuleCLICore/CLIArguments.swift` and a new `StationCLI.swift` (parsing and formatting, unit-tested)
- Create: `Sources/noctule/StationCommand.swift`, `LogCommand.swift`, `HitsCommand.swift`
- Modify: `Package.swift` (noctule depends on NoctuleStore)
- Tests: `Tests/NoctuleCLICoreTests/StationCLITests.swift`, `Tests/NoctuleCLIIntegrationTests/LogIntegrationTests.swift`
- Modify: `AGENTS.md`, `LESSONS.md`

**Interfaces:**
- Produces:
  - `noctule station add --name N --host H [--udp-port P] [--rtsp-port P] [--save-audio every|new|never]`, `noctule station list`, and `noctule station remove --name N`. These use `LocalSettingsStore` at its default location, or `--settings-dir DIR` for tests.
  - `noctule log [--station N] [--seconds S] [--settings-dir DIR] [--recordings DIR] [--cooldown-seconds X --cooldown-store PATH]`:
    - Runs a `StationRunner` and prints one line per event: `HH:MM:SS  + TG9 Lakeview Fire  (new)` on a start, and `HH:MM:SS  - TG9 Lakeview Fire  2.3 s  → <file name>` on an end.
    - Stops on `--seconds`, SIGINT, SIGTERM or SIGHUP, reusing Plan 2's signal handling, always via `runner.stop()`.
    - Exits 0, or 128+signo.
    - Uses the file cooldown store and its lease.
  - `noctule hits [--station N] [--groups] [--new] [--since YYYY-MM-DD] [--csv]` prints a table, or CSV to stdout.
- [ ] **Step 1:** RED/GREEN for parsing and formatting, covering every flag and the exact line formats above.
- [ ] **Step 2:** RED/GREEN integration tests against the `noctule-mock-scanner` subprocess with a short cooldown and temp directories:
  - `stationAddListRemove`.
  - `logRecordsScenarioThenHitsLists`: `log --seconds 6` creates at least 2 WAVs, `hits --groups` shows TG and conventional rows, `hits --new` marks the unprogrammed one, and `hits --csv` has the exact header.
  - `logSigtermStopsCleanly`: exit 143, `leaked-sessions=0`, and the mock log shows `PSI,0`.
- [ ] **Step 3:** **Hardware check.** This is opt-in, and the owner approves each run. The scanner should be scanning a busy system, or on the weather channel, which gives one long hit that rolls over every `maxTransmission`.
  1. Check control once with `MDL` before starting.
  2. `noctule station add --name "Home SDS200" --host <SCANNER_IP from config>`. Remove it afterwards if it was created only for the test.
  3. `noctule log --seconds 120`. Hits print, and the WAVs open in `afinfo`.
  4. `noctule hits --groups`.
  5. Check control once more with `MDL`.
  6. Delete the recordings (real radio audio) and the test station's database after the check. Commit nothing from them.
  7. If anything hangs or wedges, stop and report.
- [ ] **Step 4:** Docs: AGENTS.md (station, log and hits usage) and LESSONS.md. Run the full `swift test`, then commit `docs: station, log, hits usage`.
