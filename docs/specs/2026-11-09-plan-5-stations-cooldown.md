# Plan 5 — Station Flow and a Per-Station Reconnect Cooldown

> **For agentic workers:** execute task by task with a developer subagent and a QA subagent per task (see `AGENTS.md` and the owner's workflow: feature branch, strict TDD with a RED commit then a GREEN commit, QA re-runs every test and command and proves new tests with a mutation).

**Goal:** Two owner requests from 2026-11-09.

1. **Station flow.** After the first-run setup, the Stations window gets in the way: it stays open beside the scanner window. Now it closes once a connect succeeds, the app reopens the last station that *connected*, and the scanner window's status bar offers a way back to Stations and a Disconnect.
2. **Configurable reconnect cooldown.** The fixed 120 s wait before audio can reconnect gets in the owner's way. It becomes a per-station setting, in seconds, valid 0…120.

## Decisions

**The owner's:**
- Stations closes after a successful connect.
- At launch, the app opens the last station that connected successfully.
- The cooldown is externalized: seconds, valid range 0…120.
- Their reasoning: a controlled close followed by a quick reconnect is safe. The SDS200 hangs they've seen came from app crashes and network drops. They test values themselves; no supervised hardware check is needed from us.

**Claude's (told to the owner, not objected to):**
- The setting is per station (`StationConnection.reconnectCooldownSeconds`, default 120). Stations saved before this plan decode as 120.
- **The setting applies only after a clean close.** A clean close is one where this process opened the connection, a session was set up on it, every session it held got a 2xx TEARDOWN reply on that open connection, every request on it got a reply, and `close()` closed it gracefully. Every other close always waits the full 120 s, whatever the setting: crashes (a dead lease), failed or refused connects, a server-closed or failed connection, an unanswered or non-2xx TEARDOWN, any other request that went unanswered (timed out, or abandoned or pre-empted before its reply; an *answered* non-2xx reply such as a keepalive 454 doesn't count), a teardown that needed a reconnect, a connection that never had a session (the "health-check connection" hang in LESSONS.md), a close the file store couldn't record under its lock, and records written by older code.
- **A clean close never hides an unclean one** (QA I1/I2, ruled 2026-11-09; this replaces "the latest close decides"). Each record keeps the latest close of any kind (with its flag) and, separately, the latest unclean close. A connect waits until both the full cooldown has passed since the latest unclean close and the latest close's own wait (the clean value only if it was clean) has passed. A close stamped in the future (the clock stepped back) counts as an unclean close now. Across keys, and between the client's own record and the store, each of the two is the maximum over all of them.
- The full cooldown stays 120 s. Test overrides (`--cooldown-seconds`, `NOCTULE_COOLDOWN_SECONDS`) keep shortening that full value for mock runs only, and the clean-close value is `min(station setting, full)`.
- Changing the setting doesn't restart an open session. The next start reads it.
- Footer: a **Stations** button opens the picker without disconnecting. **Disconnect** closes the station window, which releases the session (`PSI,0`, TEARDOWN) and opens Stations.
- Closing the last station window (red button, ⌘W) also opens Stations, except while the app is quitting.
- The mock gets `--cooldown-after unclean|any` (default `any`, today's behavior). With `unclean`, a close that followed an answered TEARDOWN doesn't arm the hazard. It models the owner's theory, so the app can be tested against it. It is not evidence about the hardware.

## Global constraints

Every Plan 1–4 rule still applies: TEARDOWN on every exit path, `PSI,0` after every `PSI`, BSD-socket audio, no real radio data in tracked files, NoctuleKit, NoctuleStore and NoctuleAppCore build for iOS, and the mock first. Agents never send anything to the real scanner in this plan, and never pick a cooldown below 120 against it. Only the owner sets that.

## Task 1: Clean-close tracking and the cooldown policy (NoctuleKit)

- `RTSPCooldownPolicy` (Sendable, Equatable): `full: Duration` (default `.seconds(120)`) and `afterCleanClose: Duration`, clamped to `0…full`. `static let standard` is 120/120. `func required(afterCleanClose: Bool) -> Duration`.
- `RTSPCooldownEntry` gains `lastCloseClean: Bool` (false when absent) and `lastUncleanClosed: Date?`. `noteClosed(at:clean:)` keeps the later close and its flag (at an equal time, unclean wins), and the later unclean close apart from it. A dead lease resolved by `resolve` is an unclean close.
- `RTSPCooldownStore`:
  - `recordClosed(host:at:clean:)` (the old `recordClosed(host:at:)` becomes an extension that records unclean).
  - `closeHistory(host:) -> RTSPCloseHistory?` (latest close with its flag, latest unclean close) is the protocol requirement. `lastClose(host:) -> RTSPCloseRecord?` (`at` and `clean`) is an extension returning the history's latest close, and `lastClosed(host:)` an extension returning its `at`.
  - `claim(hosts:pid:policy:)` merges the hosts' histories and waits by the rule above. A live lease held by another process still means "full cooldown from now" (an unclean close now).
  - Keep a `claim(hosts:pid:cooldown:)` convenience meaning `policy(full: cooldown, afterCleanClose: cooldown)`, so existing call sites and tests keep their meaning.
- File format: an entry may carry `"lastCloseClean": true` and `"lastUncleanClosed": "<ISO-8601>"`. An absent flag means unclean, so older files and the legacy flat form read as unclean (their `lastClosed` is also their latest unclean close). Both stores. Without the file lock, a close is recorded as unclean whatever the caller passed.
- `RTSPClient`:
  - `reconnectCooldown` becomes `cooldownPolicy` (keep an init taking `reconnectCooldown:`, which means a symmetric policy).
  - It tracks whether the current link qualifies as clean (rules above) and passes that to `closeStream`/`noteClosed`, locally (`localCloses` keeps the same history) and in the store. Dead connections, failed connects and teardown reconnects are unclean.
  - Expose `lastCloseWasClean` for tests.
- `RTSPCooldownGate.remaining(store:host:policy:)`, plus the old `cooldown:` overload as a symmetric policy. `AudioSessionConfig`/`AudioSessionOptions` carry `cooldownPolicy` (keep `reconnectCooldown` as a computed shim if that keeps the diff small). `AudioSession.cooldownRemaining` uses the policy.
- Tests (Swift Testing; `FakeRTSPServer` and `MockSDS200` on loopback):
  - entry and both stores: clean and unclean ordering; equal times; legacy and absent flags read as unclean; dead lease is unclean; file round-trip;
  - claim with policy 120/0: after a clean close it connects at once; after an unclean one it waits 120 s;
  - `RTSPClient`: SETUP→PLAY→close with a 200 TEARDOWN is clean; a 454 or 500 TEARDOWN, a TEARDOWN timeout, no session, a server-closed connection, and a teardown via reconnect are all unclean;
  - the gate and `AudioSession` honor the policy.
- Docs: the type comments that say 120 s is fixed.

## Task 2: The station setting, wired through (NoctuleStore, NoctuleAppCore, CLI)

- `StationConnection.reconnectCooldownSeconds: Int = 120`, decoded tolerantly like the other fields. `Station.validate()` adds `.invalidReconnectCooldown` outside 0…120. Add its text to `StationIssueText`. `SettingsArchive` round-trips it.
- `SessionRegistry.restartRelevant` normalizes it away (no restart on change). `StationSession.applyLiveChanges` takes it into the session's `station` so the next start reads it.
- `SessionEnvironment.cooldown` stays the *full* cooldown (default 120; `NOCTULE_COOLDOWN_SECONDS` still overrides only it, under the same guards). `StationSession.start()` builds `RTSPCooldownPolicy(full: environment.cooldown, afterCleanClose: min(station seconds, full))` and uses it for the gate wait and the runner's audio config. `StationRunner` passes the config's policy through.
- CLI:
  - `station add … [--reconnect-cooldown S]` (an integer 0…120; an error otherwise). `station list` shows `cooldown S s` when it isn't 120.
  - `log` uses the station's setting the same way (its test-only `--cooldown-seconds` still sets the full value).
  - `listen` (no station) gets `--reconnect-cooldown S` (0…120, default 120) for the clean-close value. `--cooldown-seconds` stays test-only, sets the full value, and the clean value is clamped to it.
  - The waiting message is unchanged.
- Tests: validation edges (−1, 0, 120, 121); decoding a station without the key gives 120; the registry doesn't restart on a cooldown-only edit and the next start uses the new value; `StationSession` against `MockSDS200` with 120/0: stop, then start again, connects without waiting after a clean stop, and waits after an unclean one (use the mock's `keepalive=454` or a power cycle to make a close unclean); CLI parsing; `log`/`listen` integration against `noctule-mock-scanner` with `--cooldown-after unclean` (Task 4's flag; if Task 4 isn't done yet, do that flag first).

## Task 3: Station flow in the app (NoctuleAppCore, NoctuleScan)

- **Last station = last connected.** Stop recording `lastStationID` in `SessionRegistry.open`. Record it when a session reaches `.connected` (a registry hook on the session's connected transition, the current runner only, as `handle(.connected)` already checks). The launch route in `StationPickerView.load()` is otherwise unchanged. A station that never connects never becomes the launch station. The CLI `log` keeps its own rule (it records when it runs; leave it).
- **Stations closes after a successful connect.** After Connect (button, double-click, context menu) the picker remembers the station it opened. When that station's session phase becomes `.connected`, the picker closes itself (`dismissWindow(id: AppScene.picker)`). If the user selects or connects another station meanwhile, only the latest connect counts. If the connection fails, Stations stays open. Put the decision in a small testable helper (`PickerAutoClose`) in `NoctuleScan`, unit-tested in `NoctuleScanTests`.
- **Status bar.** At the leading edge of `ScannerStatusBar`, before the connection indicator, add:
  - a **Stations** button (SF Symbol `list.bullet`, borderless, help "Show the Stations window") that opens the picker;
  - a **Disconnect** button (`eject` or `xmark.circle`, borderless, help "Disconnect and show the Stations window") that dismisses this station window and opens the picker.

  Both work in either view. Disconnect needs no confirmation.
- **Closing the last station window opens Stations.** When a station window disappears and no other station window is open, open the picker. Not while the app is quitting (`AppDelegate` already knows it is: expose a flag), and not when the window closed because its station was deleted while the picker is open anyway (opening an already-open `Window` just brings it forward, which is fine).
- Docs: `AGENTS.md`'s app section (scenes, last station, picker closing, footer, cooldown) and the picker's doc comment.
- Tests: `PickerAutoClose`; the registry records the last station only on connect (a station whose start fails isn't recorded); the window-close rule as a pure helper if practical. UI: build the app and take screenshots against the mock (git-ignored `.superpowers/screenshots/plan-5/`), with `NOCTULE_SETTINGS_DIR` set to a temp dir of mock stations.

## Task 4: The mock's `--cooldown-after`, docs and lessons

- `MockSDS200.Options.cooldownAfter: .any | .unclean` and `--cooldown-after any|unclean` on the executable. With `.unclean`, a close that came after a 2xx TEARDOWN on that connection doesn't start the hazard window. Any other close still does. Tests in `NoctuleMockScannerTests`.
- `AGENTS.md`: replace "never shorten the cooldown" with the rule as it now stands. The owner sets a station's clean-close cooldown (0…120). Agents never lower it against the real scanner on their own. Unclean closes always wait 120 s. The test flags are still for the mock only.
- `LESSONS.md`: a dated entry for the owner's decision and the clean/unclean rule, and why "no session" counts as unclean.
- The design spec: a short note in the cooldown section pointing to this plan.

## Final

Run `swift build`, `swift test`, the iOS check, and `scripts/build-app.sh`. Do a whole-branch review. Run a hand check of the app on the mock with `--cooldown-after unclean`, a station cooldown of 0 and the mock's cooldown at 20: connect, Disconnect, connect again (no wait), quit, `leaked-sessions=0`. Then open a PR. The owner checks the real scanner.
