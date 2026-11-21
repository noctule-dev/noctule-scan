# Plan 19: Line-in audio on the command line — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `noctule` lists audio inputs, gives a new USB station an input, records and warns about a
line-in in `log`, and plays, records and meters a line-in station in `listen --station`.

**Architecture:** A command-line shell over Plan 18's core. `log` passes `StationRunner` the line-in
factory that `LineInDetection.selection(…, app: false)` picks (system, disabled, or the test pipe)
and prints the line-in events; `listen --station` drives a `LineInSource` straight into the existing
player and WAV writer, opening no serial port and taking no station lock. Pure parsing, formatting
and resolution go in `NoctuleCLICore` (unit-tested); `Sources/noctule/` stays the I/O shell.

**Tech Stack:** Swift 6.2, Swift Testing, SwiftPM. `noctule` gains a dependency on
`NoctuleAudioCapture`. No new package.

**Spec:** `docs/specs/2026-11-17-plan-19-line-in-cli-design.md` (the decisions, owner-approved
2026-11-17), which builds §7 and §8 of `docs/specs/2026-11-17-usb-line-in-audio-design.md` (the
authority; §12 there is what Plan 18 built). Read both, AGENTS.md and LESSONS.md first.

## Global Constraints

- Branch `feature/line-in-cli` (exists; the design is committed on it). Tests first against the
  mocks; developer and QA per task, QA re-running every test and proving each new test with a
  mutation in a temporary worktree with its own `--scratch-path`, in the foreground (dev-workflow
  memory). Commit only your own paths (`git commit -- <paths>`).
- **No task, test, QA mutation or agent run opens a real audio input, lists Core Audio devices or
  calls the microphone permission request.** Tests use `NOCTULE_TEST_LINE_IN` on
  `noctule-mock-scanner --serial --line-out`, `FakeLineInSource`, or `FixedAudioInputListing`.
  A mutation that removes the kill-switch check is **forbidden**.
- Every shell exports `NOCTULE_NO_USB_DETECTION=1`; `station`, `log`, `hits` and `listen --station`
  get `--settings-dir` on a temporary directory. Never open a `/dev/cu.usbmodem*` path.
- No scanner command is added. `listen --station` on a line-in station sends nothing to the scanner,
  opens no serial port and takes no station lock. A line-in station never reads or writes the RTSP
  cooldown record.
- `NoctuleKit`, `NoctuleStore`, `NoctuleAppCore` keep building for iOS:
  `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build`.
- Exit codes: `station` usage errors 64 (as today); other parse refusals 2 (as today); runtime
  failures 1; stop signals 128 + signo (130, 143, 129).
- User-visible copy (exact):
  - `audio-inputs` line: `<UID>  <name>  <n> ch`; none: `No audio inputs found.`
  - `station add` refusals: `--audio-input needs --usb`, `--audio-channel needs --audio-input`,
    `no audio input named "<x>"; run noctule audio-inputs`, `"<x>" names more than one audio input (<UID1>, <UID2>); give its ID`.
    A value that matches nothing and is passed under the kill-switch (no inputs listed) is saved as a
    UID with the note `station: saved "<x>" as an audio input ID (no inputs are listed)`.
  - `station add` success adds `, line-in <name> (<channel>)` to its line; `station list` shows
    `line-in <name> (<channel>)` after the port.
  - `log`: `audio: line-in <name> (<channel>)` (once, after the first connect, in place of
    `log: no audio over USB`); clip: `warning: the audio input clipped during "<channel>"; turn the scanner's volume down`;
    permission: `warning: this terminal isn't allowed to use audio input. Allow it in System Settings › Privacy & Security › Microphone.`
    The runner's other line-in warnings print as `warning: <text>` unchanged.
  - `listen --station`: `audio: line-in <name> (<channel>)` when streaming,
    `audio: line-in "<name>" isn't connected; waiting` when missing, `listen: <name> has no audio input`
    (USB station without one, exit 1), `listen: --station can't be combined with --host or --rtsp-port` (exit 2),
    `listen: --meter needs a line-in station` (exit 2). Meter line:
    `line-in ▇▇▇▇▇▇▇····|···· peak −9 dBFS` plus ` CLIP` while latched (3 s); 20 cells over −60…0 dBFS,
    `|` at −6 dBFS (the target band's top), `▇` filled, `·` empty, `peak −∞` for digital silence.
    Redrawn in place (`\r`, no newline) about every 100 ms when stderr is a terminal, one line a
    second otherwise.
- `NOCTULE_TEST_LINE_IN` is honoured by `noctule` only with the kill-switch set, and prints
  `noctule: test override: NOCTULE_TEST_LINE_IN=<path> (in place of the line-in device)` to stderr.
- No real system, channel or frequency names in tracked files; `RealNamesTests` passes.

## Review Focus

1. **The input is unplugged during `listen --station`, then plugged back.** `listen` keeps running,
   says it is waiting, and plays and records again by itself when it returns. (Task 5,
   `listenWaitsForAMissingInput`.)
2. **`listen --station` while `log` runs on the same station.** `listen` must not report the station
   as open in another process, nor open the serial port. (Task 5, `listenTakesNoStationLock`.)
3. **stderr is not a terminal** (piped to a file or `less`): no `\r` redraws, one meter line a
   second. (Task 4, `meterRateFollowsTheTerminal`; Task 5, `meterPipedIsOneLineASecond`.)
4. **The kill-switch with an input saved in a station.** `log` warns
   `audio input disabled by NOCTULE_NO_USB_DETECTION` and logs without audio; `listen --station`
   exits 1 with that reason; nothing in Core Audio is touched. (Task 3, `logUnderTheKillSwitchWarns`;
   Task 5, `listenUnderTheKillSwitchExits1`.)
5. **An input name that matches two inputs, or none.** Refused with the copy above, nothing saved.
   (Task 2, `resolveAudioInput*`.)

---

### Task 1: `noctule audio-inputs` and the command line's line-in pieces

**Files:**
- Modify: `Package.swift` (`noctule` depends on `NoctuleAudioCapture`)
- Modify: `Sources/NoctuleCLICore/CLIArguments.swift` (`case audioInputs`; usage line)
- Modify: `Sources/NoctuleCLICore/CLIFormat.swift` (input line, empty line)
- Create: `Sources/noctule/LineInSupport.swift` (the shell's factory and listing)
- Create: `Sources/noctule/AudioInputsCommand.swift`
- Modify: `Sources/noctule/main.swift` (dispatch; print override notes)
- Test: `Tests/NoctuleCLICoreTests/` (parse and format), `Tests/NoctuleCLIIntegrationTests/SerialIntegrationTests.swift` (or a new `LineInCLIIntegrationTests.swift`)

**Interfaces:**
- Produces (NoctuleCLICore): `CLICommand.audioInputs`; `CLIFormat.audioInputLine(_ device: AudioInputDevice) -> String`; `CLIFormat.noAudioInputsLine = "No audio inputs found."`.
- Produces (shell): `enum LineInSupport { static func selection(environment: [String: String]) -> LineInSelection; static func factory(for selection: LineInSelection) -> LineInSourceFactory; static func listing(for selection: LineInSelection) -> any AudioInputListing }` — `.system` → `EngineLineInSource.system($0)` and `CoreAudioInputs()`; `.disabled(reason)` → `DisabledLineInSource(reason:)` and `FixedAudioInputListing.empty`; `.testStream(path)` → `PipeLineInSource(path:config:)` and the empty listing. Uses `LineInDetection.selection(environment:privateSettings: false, app: false)`.

- [ ] **Step 1: Failing tests** — parse: `["audio-inputs"]` → `.audioInputs`; `audio-inputs --host x` → parse error exit 2. Format: `audioInputLine(AudioInputDevice(uid: "UID-1", name: "Fictional Interface", channelCount: 2))` == `"UID-1  Fictional Interface  2 ch"`. Integration (`audioInputsUnderTheKillSwitchListsNone`): `noctule audio-inputs` with `NOCTULE_NO_USB_DETECTION=1` prints exactly `No audio inputs found.`, exit 0.
- [ ] **Step 2: Run, see them fail** — `NOCTULE_NO_USB_DETECTION=1 swift test --filter 'CLIArguments|CLIFormat|AudioInputs'`.
- [ ] **Step 3: Implement.** `main.swift` prints `LineInDetection.overrideNotes(…, app: false)` to stderr once per run for `audio-inputs`, `station`, `log` and `listen` (as it does `USBDetection.overrideNotes`).
- [ ] **Step 4: Run, see them pass**; `swift build`.
- [ ] **Step 5: Commit** (`feat: noctule audio-inputs`).

---

### Task 2: `station add --audio-input` / `--audio-channel` and `station list`

**Files:**
- Modify: `Sources/NoctuleCLICore/CLIArguments.swift` (`StationAddOptions.audioInput: String?`, `.audioChannel: LineInChannel?`; parsing and the refusals)
- Modify: `Sources/NoctuleCLICore/StationCLI.swift` (resolution, the device-settings write, `add` and `list` text)
- Modify: `Sources/noctule/StationCommand.swift` (pass `LineInSupport.listing`)
- Test: `Tests/NoctuleCLICoreTests/StationCLITests.swift` (existing), integration suite of Task 1

**Interfaces:**
- Consumes: Task 1's `LineInSupport.listing(for:)`; `StationDeviceSettings.audioInputDevice/audioInputName/audioInputChannel` (Plan 18).
- Produces: `public enum AudioInputResolution: Equatable { case input(uid: String, name: String), savedAsID(String), notFound(String), ambiguous(String, uids: [String]) }`; `StationCLI.resolveAudioInput(_ value: String, inputs: [AudioInputDevice], listingAvailable: Bool) -> AudioInputResolution` — a present UID wins; else exactly one name match; several → `.ambiguous`; none → `.savedAsID(value)` when `listingAvailable` is false (kill-switch), else `.notFound`.

- [ ] **Step 1: Failing tests** — `resolveAudioInputByUID`, `resolveAudioInputByName`, `resolveAudioInputAmbiguous` (two inputs named "Fictional Interface" → `.ambiguous` with both UIDs), `resolveAudioInputNotFound`, `resolveAudioInputUnderTheKillSwitchSavesTheID`; parse: `--audio-input` without `--usb` → exit 64 `--audio-input needs --usb`; `--audio-channel` without `--audio-input` → 64; `--audio-channel middle` → 64; `stationAddSavesTheInputBeforeTheStation` (the device settings carry UID, name, channel before `stations.json` gains the station — follow the existing `usbPort` ordering test); `stationListShowsTheLineIn` (`line-in Fictional Interface (left)`). Integration (`stationAddUnderTheKillSwitchSavesAnID`): `station add --settings-dir D --name L --usb --serial-port P --audio-input UID-9 --audio-channel right` → exit 0, the note line on stderr, `device.json` holds `"audioInputDevice" : "UID-9"`.
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement.** Absent `--audio-channel` saves no channel key (reads as `both`). The name saved is the input's name, or the value itself for `.savedAsID`.
- [ ] **Step 4: Run, see them pass** — plus the existing `StationCLI` and station integration tests unchanged.
- [ ] **Step 5: Commit** (`feat: station add gives a USB station an audio input`).

---

### Task 3: `noctule log` records a line-in

**Files:**
- Modify: `Sources/noctule/LogCommand.swift` (pass `lineInSources: LineInSupport.factory(for:)` to `StationRunner`; the `audio: line-in …` line in place of `noAudioOverUSBLine` when `device.lineIn != nil`)
- Modify: `Sources/NoctuleCLICore/StationCLI.swift` (`eventOutput` for `.clipped` and the denied warning; `lineInLine(_ config: LineInConfig) -> String`)
- Test: `Tests/NoctuleCLICoreTests/StationCLITests.swift`, the integration suite (`LogIntegrationTests` or the Task 1 suite)

**Interfaces:**
- Consumes: `StationRunner.init(…, lineInSources:)`, `RunnerEvent.clipped(LoggedHit)`, `RunnerEvent.lineIn(LineInState)`, `RunnerEvent.warning(String)`, `StationRunner.lineInDeniedMessage` (Plan 18); Task 1's `LineInSupport`.
- Produces: `StationCLI.lineInLine(_:)` (`audio: line-in <name> (<channel>)`), `StationCLI.clippedLine(_ hit: LoggedHit) -> String`, `StationCLI.terminalDeniedLine`.

- [ ] **Step 1: Failing tests** — unit: `eventOutput(.clipped(hit))` → `.stderr("warning: the audio input clipped during \"Fictional Channel\"; turn the scanner's volume down")`; `eventOutput(.warning(StationRunner.lineInDeniedMessage))` → the terminal copy; `.lineIn(_)` still prints nothing; `lineInLine` for left/right/both. Integration on `noctule-mock-scanner --model sds150 --serial --serial-link L --line-out S --verbose` with a one-transmission scenario and a station saving `L` and a line-in: `logRecordsALineInHit` (`NOCTULE_TEST_LINE_IN=S`, `--seconds` past the transmission → stderr has `audio: line-in`, not `no audio over USB`; the end line has `→ <file>.wav`; the WAV is in `--recordings`; no cooldown file; the mock's log ends `PSI,0`, `active-subscriptions=0`); `logUnderTheKillSwitchWarns` (no `NOCTULE_TEST_LINE_IN` → `warning: audio input disabled by NOCTULE_NO_USB_DETECTION`, end line without `→`, no WAV, exit 0).
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see them pass** — plus `SerialIntegrationTests` and `LogIntegrationTests` unchanged.
- [ ] **Step 5: Commit** (`feat: noctule log records a USB station's line-in`).

---

### Task 4: The text meter

**Files:**
- Move: `Sources/NoctuleAppCore/Session/PeakHold.swift` → `Sources/NoctuleKit/Audio/LineIn/PeakHold.swift` (unchanged API; the app imports it from NoctuleKit)
- Create: `Sources/NoctuleCLICore/LineInTextMeter.swift`
- Test: `Tests/NoctuleCLICoreTests/LineInTextMeterTests.swift`

**Interfaces:**
- Produces: `public struct LineInTextMeter { public static let cells = 20; public static let clipLatch: Duration = .seconds(3); public init(); public mutating func update(_ level: LineInLevel); public func line(at now: ContinuousClock.Instant) -> String; public static func redrawInterval(isTerminal: Bool) -> Duration /* 100 ms or 1 s */ }` — keeps a `PeakHold` and the latch time of the last clipped level.

- [ ] **Step 1: Failing tests** — `meterLineAtMinus9` (a level peaking −9 dBFS → the exact line with 17 filled cells, `|` at the −6 position, `peak −9 dBFS`); `meterSilence` (`-infinity` → no filled cells, `peak −∞`); `meterClipLatchesThreeSeconds` (a clipped level → ` CLIP` until 3 s after it, then gone); `meterPeakHoldsOneAndAHalfSeconds`; `meterRateFollowsTheTerminal` (100 ms vs 1 s). App tests for `PeakHold` still pass after the move.
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement.** Cell k (0…19) is filled when the peak reaches −60 + 3(k+1) dBFS; the `|` sits between cells 17 and 18 (−6 dBFS).
- [ ] **Step 4: Run, see them pass**; the iOS build of `NoctuleAppCore`.
- [ ] **Step 5: Commit** (`feat: a text meter for the line-in`).

---

### Task 5: `noctule listen --station`

**Files:**
- Modify: `Sources/NoctuleCLICore/CLIArguments.swift` (`listen` takes `--station N`, `--meter`, `--settings-dir`; the two refusals)
- Create: `Sources/noctule/LineInListen.swift` (the line-in path)
- Modify: `Sources/noctule/ListenCommand.swift` (`--station` on a network station: its host, RTSP port and reconnect wait; dispatch to `LineInListen` for a line-in station)
- Modify: `Sources/noctule/main.swift`
- Test: `Tests/NoctuleCLICoreTests/` (parse), the integration suite

**Interfaces:**
- Consumes: Tasks 1 and 4; `AudioPlayer(prefillSamples: AudioPlayer.lineInPrefillSamples)`; the existing `ListenRecorder`/`WAVWriter`, `ListenControl` signal handling; `StationCLI.station(named:in:)`.
- Produces: `enum LineInListen { static func run(station: Station, config: LineInConfig, source: any LineInSource, options: ListenOptions, meter: Bool) async -> Int32 }`.

- [ ] **Step 1: Failing tests** — parse: `listen --station X --host h` → exit 2 with the copy; `listen --meter` without `--station` → exit 2 `listen: --meter needs a line-in station`. Integration on the mock's `--line-out` with `NOCTULE_TEST_LINE_IN`:
  `listenRecordsALineIn` (`--seconds 3 --no-play --record out.wav` → exit 0, stderr has `audio: line-in`, out.wav holds 3 s ± 0.5 s at 8 kHz, the mock's log has no command from this run);
  `listenTakesNoStationLock` (a `log` on the same station running → `listen --station` doesn't print `is open in another Noctule Scan process` and opens no serial port);
  `listenWaitsForAMissingInput` (start before the mock exists → `isn't connected; waiting`; start the mock → `audio: line-in` and samples recorded);
  `meterPipedIsOneLineASecond` (`--meter --seconds 3` with stderr to a pipe → 2–4 meter lines, no `\r`);
  `listenUnderTheKillSwitchExits1` (no `NOCTULE_TEST_LINE_IN` → exit 1, `audio input disabled by NOCTULE_NO_USB_DETECTION`);
  `listenStopsOnSIGINT` (exit 130, WAV closed and readable);
  `listenStationWithoutAnInputExits1` (USB station without input → `listen: <name> has no audio input`);
  `listenStationPicksTheNetworkAddress` (a network station on the network mock → listen connects to its host and RTSP port; the existing cooldown rules hold with a private `--cooldown-store`).
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement.** No `StationLock`, no `StationTransportFactory`, no cooldown store on the line-in path. `--seconds`, `--no-play`, `--record` and the exit codes as today's `listen`.
- [ ] **Step 4: Run, see them pass** — plus every existing `listen` integration test unchanged.
- [ ] **Step 5: Commit** (`feat: noctule listen --station plays and meters a line-in`).

---

### Task 6: Documents and the full run

**Files:**
- Modify: `AGENTS.md` (Build and test: `audio-inputs`; `station add --audio-input/--audio-channel`; `log` on a line-in station; `listen --station` and `--meter`; `NOCTULE_TEST_LINE_IN` now honoured by `noctule`; on the command line the microphone permission belongs to the terminal app), `LESSONS.md` (anything learned), `docs/specs/2026-11-17-usb-line-in-audio-design.md` (status line: Plan 19 built; §12 entries for any departure from §7), `docs/specs/2026-11-17-plan-19-line-in-cli-design.md` (status).
- [ ] **Step 1:** Write them; `swift test --filter RealNamesTests`.
- [ ] **Step 2:** Full `NOCTULE_NO_USB_DETECTION=1 swift test` and the iOS build: all pass.
- [ ] **Step 3: Commit** (`docs: line-in on the command line (Plan 19)`).

After Task 6: a whole-branch review, then the owner's hand check of `noctule listen --station <sds150 station> --meter` and `noctule log` on the rig (the owner's call; agents never run them against the real input).
