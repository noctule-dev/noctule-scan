# Plan 20: Favorites quick keys — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The station window gets a Quick Keys pop-over that discovers the scanner's Favorites Lists and turns lists,
systems, and departments and sites on and off; `noctule quick-keys` prints the same tree.

**Architecture:** `NoctuleKit` learns `GLT` (lists, systems, departments, sites) and `FQK`/`SQK`/`DQK` (100 states; a
set names one key, 0 everywhere else). Both mocks share one fictional Favorites tree in `ControlCore`. A
`QuickKeysModel` in `NoctuleAppCore`, owned by each `StationSession` like `MenuModel`, loads the keypad first, fills
the trees in the background, caches structure (never states) per station, polls while open, and sends one set per
click. `NoctuleScan` adds the toolbar button, the pop-over and its tear-off panel.

**Tech Stack:** Swift 6.2, Swift Testing, SwiftUI + AppKit (macOS), SwiftPM. No new package.

**Spec:** `docs/specs/2026-11-18-quick-keys-design.md` (owner-approved 2026-11-18; §3 is what the hardware showed, §5
the design). Read it, `AGENTS.md` and `LESSONS.md` first. The protocol facts are also in
`docs/specs/2026-11-08-sds-remote-protocol.md` §5b.

## Global Constraints

- Branch `feature/quick-keys` (exists; the design is committed on it). Strict TDD against the mocks: a failing-test
  commit, then the implementation. Developer and QA per task; QA re-runs every test and proves each new test with a
  mutation in a temporary worktree with its own `--scratch-path`, in the foreground (dev-workflow memory). Commit only
  your own paths (`git add` new files, then `git commit -- <paths>`). Put `.timeLimit(.minutes(1))` on every new suite.
- **No test, QA mutation or agent run sends `FQK`, `SQK` or `DQK` with values to real hardware**, or any command to a
  real scanner. Every shell exports `NOCTULE_NO_USB_DETECTION=1`; `noctule` gets `--serial` only with the mock's path;
  the app is launched only with a temporary `NOCTULE_SETTINGS_DIR` of mock stations (AGENTS.md). A mutation that
  removes the kill-switch is forbidden.
- **A set names one key**: 100 values, `"0"` everywhere but that key (`"1"` off, `"2"` on). A set is never resent; a
  timeout is reported, and only a re-read says what happened. Reads may be retried once after a timeout.
- **Sets come only from a user's click** (or a test against a mock). Nothing sets on open, on poll or on reconnect.
- The drill-down argument is the parent's `Index`, never its quick key. "Scanning now" matches by `Index`, never by
  `Q_Key` (`GSI`'s `MonitorList Q_Key` is wrong, design §3.4).
- Built-ins dropped when parsing: lists `Index` `4294967295` (Full Database) and `4261412864` (Search with Scan);
  departments and sites `Index` `4294967295` (Unknown).
- `GLT,SITE` is sent only for a system whose `Type` isn't `Conventional`.
- On/off states are never cached or shown from the cache; the keypad (`GLT,FL` + `FQK`) is never from the cache;
  nothing shown from the cache is switchable (design §5.4 cache rules).
- `NoctuleKit`, `NoctuleStore`, `NoctuleAppCore` keep building for iOS:
  `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build`.
- Only fictional names in tracked files; `RealNamesTests` passes. The cache (`Stations/<uuid>/quick-keys.json`) holds
  real names and lives only in the settings directory.
- User-visible copy (exact):
  - Toolbar button: label `Quick Keys`, help `Turn Favorites Lists, systems and departments on and off`.
  - Header switch: `Scan this list`; header detail: `<n> systems, <m> on` (`1 system` singular).
  - Tags: `Not monitored`, `no quick key`, `site`, `Avoided`, `shared`.
  - Help texts: `The scanner doesn't report this key's state.`;
    `Systems S<k> share a quick key, so their departments can't be switched separately here.`;
    `The scanner is in a menu`; `<n> items share quick key D<k>; they switch together.` (`S<k>` for systems).
  - Not-monitored panel line: `Not monitored. Turn it on in Select Lists to Monitor on the scanner or in Sentinel.`
  - Errors (one line at the top): `The scanner didn't confirm the change`, `The scanner isn't answering`.
  - Cached tree: `Checking…`. Read-only row title: `No quick key`.
  - Accessibility: tile `<name>, quick key <n>` (toggle, value on/off); its corner button `Show systems in <name>`.
- `noctule quick-keys` output is exactly the format in Task 4.

## Review Focus

1. **A quick key moved on the radio** (between opens, or while the pop-over is open): a click must never switch
   whatever used to hold that number. (Task 5 `aMovedKeyIsNeverSwitchedFromTheCache`,
   `aKeyMovedWhileOpenIsRecheckedBeforeSwitching`.)
2. **A set whose reply is lost** (the SDS200's one in 12): no resend, the re-read decides, the error line shows.
   (Task 6 `aSetThatTimesOutIsNotResent`.)
3. **A late reply answers the confirming re-read** with another scope's values: dropped by its key pattern, read again
   once, never written anywhere. (Task 6 `aStrayReplyIsDropped`.)
4. **The owner walks the radio into a menu while the pop-over is open, edits Favorites, and leaves**: nothing
   switchable in the menu; on leaving, every tree is rechecked. (Task 6 `inAMenuNothingSwitches`, Task 5
   `leavingAMenuRechecksTheTrees`.)
5. **The USB scanner is unplugged with the pop-over open**: cached tree read-only, no reads while waiting, live again
   after the resume, nothing running after the window closes. (Task 7 `unplugWithThePopoverOpen`.)

---

### Task 1: Quick-key types, `GLT` parsing, and array commands

**Files:**
- Create: `Sources/NoctuleKit/Status/Favorites.swift`
- Modify: `Sources/NoctuleKit/Protocol/ScannerCommand.swift`
- Test: `Tests/NoctuleKitTests/FavoritesTests.swift`, `Tests/NoctuleKitTests/ScannerCommandTests.swift` (existing or new)

**Interfaces:**
- Produces:
  - `public struct FavoritesList: Sendable, Equatable { index: UInt32; name: String; quickKey: Int?; monitored: Bool }`
  - `public struct FavoritesSystem: Sendable, Equatable { index: UInt32; name: String; type: String; quickKey: Int?; avoided: Bool; var isConventional: Bool /* type == "Conventional" */ }`
  - `public struct FavoritesChild: Sendable, Equatable { enum Kind { case department, site }; index: UInt32; name: String; quickKey: Int?; avoided: Bool; kind: Kind }`
  - `public enum QuickKeyState: Int, Sendable { case none = 0, off = 1, on = 2 }`
  - `public struct QuickKeyStates: Sendable, Equatable { init?(fields: [String]) /* exactly 100 of "0"/"1"/"2" */; subscript(key: Int) -> QuickKeyState; var existingKeys: Set<Int>; static func setting(_ key: Int, on: Bool) -> [String] /* 100 strings, "0" but key */ }`
  - `public enum FavoritesXML { static func lists(_ root: XMLNode) throws -> [FavoritesList]; static func systems(_:) throws -> [FavoritesSystem]; static func departments(_:) throws -> [FavoritesChild]; static func sites(_:) throws -> [FavoritesChild] }`, throwing `FavoritesXMLError.unexpectedRoot(String)` for a root other than `GLT`; children of other element names are skipped; `Avoid` other than `Off` is avoided; `Q_Key` `None` or non-numeric is nil; `Monitor` `On` is monitored.
  - `ScannerCommand.init(_ name: String, arguments: [String]) throws` with the variadic initializer's validation.

- [ ] **Step 1: Failing tests** — fixtures are the spike's shapes with fictional names (attribute sets per design §3.1):
  `listsDropTheBuiltIns` (a `GLT` with Full Database, Search with Scan and two lists, `Index` 0 and 2 → two lists,
  `quickKey` 5 and nil, `monitored` true and false); `systemsParseTypeAndAvoid` (`Type="P25 Trunk"`, `Avoid="On"` →
  `avoided`, `isConventional` false); `departmentsDropUnknown` (`Index="4294967295" Name="Unknown"` dropped, a
  `CGroupId` and a `TGroupId` department both parse); `sitesAreSites` (kind `.site`); `wrongRootThrows` (`<MSI>` →
  `.unexpectedRoot("MSI")`); `statesNeedExactly100` (99 or 101 fields, or a `"3"` → nil); `statesExistingKeys`
  (`["2","1","0","2", …0]` → `{0,1,3}`); `settingNamesOneKey` (`setting(3, on: true)` → 100 strings, `[3] == "2"`,
  the other 99 `"0"`; `on: false` → `"1"`); `arrayCommandValidates` (`ScannerCommand("SQK", arguments: ["1","a,b"])`
  throws `invalidArgument("a,b")`; a 101-argument command's `wireBytes` is the comma-joined line ending `\r`).
- [ ] **Step 2: Run, see them fail** — `swift test --filter 'FavoritesTests|ScannerCommandTests'`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see them pass**; the iOS build.
- [ ] **Step 5: Commit** (`feat: quick-key types and GLT parsing`).

---

### Task 2: The mock's Favorites

**Files:**
- Create: `Sources/NoctuleMockScanner/MockFavorites.swift`
- Modify: `Sources/NoctuleMockScanner/MockControlServer.swift` (`ControlCore` answers the commands; `favorites` state)
- Modify: `Sources/NoctuleMockScanner/MockSDS200.swift`, `MockSerialScanner.swift`, `MockScannerArguments.swift` (the set delay; `--no-delays` zeroes it)
- Test: `Tests/NoctuleMockScannerTests/MockFavoritesTests.swift`

**Interfaces:**
- Consumes: Task 1's `ScannerCommand(_:arguments:)` (tests send raw commands with `ScannerClient.send`).
- Produces: `public struct MockFavorites: Sendable, Equatable` (the tree and the states; `static let default`;
  mutable so tests can move keys, rename and remove), `MockSDS200.favorites` / `setFavorites(_:)`,
  `MockSerialScanner.favorites` / `setFavorites(_:)`, `MockControlServer` the same; init parameter
  `quickKeySetDelay: Duration` (default `.milliseconds(800)`) on `MockSDS200.Options`, `MockSerialScanner.init` and
  `MockControlServer.init`, zero under `--no-delays`.
- **`MockFavorites.default`** (fictional; design §5.2 shapes; the `GSI` the mock already sends names list `Index` 1
  with `Q_Key="0"`, system 101, departments 200/201/203, site 301, so "scanning now" lands in list 1 and the wrong
  `GSI` key is reproduced). Each row: `Index` name [`Q_Key`] (attributes), initial state:

  | List | Systems → departments / sites |
  |---|---|
  | 0 "Mock Police" [0] on | 110 "Metro P25" [S0] P25 Trunk on → dept 500 "Patrol" [D0] on, 501 "Detectives" [D1] off; site 610 "Metro Simulcast" [None]. 111 "Metro Backup" [S0] P25 Trunk (shares S0) → dept 510 "Backup Patrol" [D0]. 112 "Metro Conventional" [None] Conventional → dept 520 "Records" [D0] |
  | 1 "Mock Favorites" [7] on | 101 "Riverbend County P25" [S0] P25 Trunk on → Unknown (4294967295), 118 "Road Crews" [None], 200 "Lakeview Fire" [D0] on, 201 "Riverbend Sheriff" [D1] on, 203 "Lakeview Fire Tac" [D0]; site 301 "Riverbend Simulcast" [D0] (D0 shared by two departments and a site). 102 "Mock Simplex" [S1] Conventional on → 400 "Simplex A" [D0] on, 401 "Simplex B" [D1] off |
  | 4 "Mock Fire & EMS" [1] off | 120 "Lakeview City P25" [S0] P25 Trunk on → Unknown, 530 "Fire Dispatch" [None]; sites 620 "North Site" [D0] on, 621 "South Site" [D1] off. 121 "County 800 Trunk" [S1] Motorola off, `Avoid="On"` → site 630 "County Simulcast" [None]. 122 "State Forestry" [S2] Conventional on → 540 "Air Attack" [D2], whose `DQK,1,2` reports all 0 |
  | 6 "Mock Utilities" [3] on | 130 "Water District" [S0] Conventional on → 550 "Field Ops" [D0] on |
  | 8 "Mock Marine" [12] off, `Monitor="Off"` | 140 "Harbor" [S0] Conventional on → 560 "Harbor Ops" [D0] on |
  | 10 "Mock Events" [None] | 150 "Fairgrounds" [S0] Conventional → 570 "Gates" [D0] |
  | 12 "Mock Air" [23] on | 160 "Airport" [S4] Conventional on → 580 "Tower" [D0] on |
  | 14 "Mock Interop" [41] off | 170 "Interop" [None] Conventional → 590 "Calling" [None] |

  `GLT,FL` lists the built-ins first (Full Database, Search with Scan, both `Monitor="Off" Q_Key="None"`).
  Departments of a trunked system start with Unknown. Keys 0,1,3,7,12,23,41: tens 0–9, 10–19, 20–29, 40–49 have
  lists, 30–39 and 50–99 don't.
- Behaviour (each **[assumed]** unless design §3 shows it): `GLT,FL|SYS,<i>|DEPT,<i>|SITE,<i>` reply in the
  personality's XML form, as `MSI` does; an unknown index → an empty `<GLT>`. `FQK` → `FQK,` + 100 values;
  `SQK,<fq>` and `DQK,<fq>,<sq>` likewise, all 0 for a key with nothing behind it; for a shared `SQK` key, `DQK`
  answers the first such system in `GLT` order. A set (`FQK,<100>`, `SQK,<fq>,<100>`, `DQK,<fq>,<sq>,<100>`): exactly
  100 values each `0`–`2`, else `NG`; an `fq`/`sq` with nothing behind it → `NG`; a `0` leaves that key alone; a
  `1`/`2` for a key that doesn't exist is ignored; then `<CMD>,OK`, after `quickKeySetDelay` for `FQK` and `SQK`, at
  once for `DQK` (design §3.3). A set to a shared key changes it for everything holding it. Faults
  (`dropNextReply` and the rest) and `replyDelays` work on these names as on any other.

- [ ] **Step 1: Failing tests** (both mocks for each, `MockSDS200` over `UDPTransport` and `MockSerialScanner` in both
  personalities over `SerialTransport`, a `MockClock.stepped()` clock and `quickKeySetDelay: .zero` unless stated):
  `gltListsTheDefaultTree` (8 lists + 2 built-ins in that order, keys as the table); `gltDrillsDownByIndex`
  (`GLT,SYS,1` → 101, 102; `GLT,DEPT,101` → Unknown, 118, 200, 201, 203; `GLT,SITE,120` → 620, 621);
  `fqkReadsTheStates` (`[0]=="2"`, `[1]=="1"`, `[7]=="2"`, `[9]=="0"`); `aSetChangesOneKeyAndIgnoresZeros`
  (`SQK,7` with `setting(1, on: false)` → `SQK,OK`; `SQK,7` reads `[0]=="2"`, `[1]=="1"`); `aSharedDepartmentKeySwitchesTogether`
  (`DQK,7,0` setting(0,off) → departments 200, 203 and site 301 all off in `favorites`); `badSetsAreRefused` (99
  values; a `"3"`; `SQK,99,…` → `NG`, nothing changed); `theMismatchReportsZeros` (`DQK,1,2` → all `"0"`);
  `listAndSystemSetsWait` (`quickKeySetDelay` 0.8 s: `FQK` set's reply ≥ 0.75 s, `DQK` set's < 0.2 s, real clock);
  `gsiStillNamesListOneWithKeyZero` (the `MonitorList` is `Index="1" Q_Key="0"` while `GLT` says 7);
  `setFavoritesMovesAKey` (move system 102 to `S3`: `GLT,SYS,1` and `SQK,7` follow); `noDelaysZeroesTheSetDelay`
  (`MockScannerArguments` parsing).
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement.** Keep the tree and its command handling in `MockFavorites` (pure: `reply(to name: String,
  args: [String]) -> (text: String, delayed: Bool)?`), so `ControlCore` only routes `GLT`, `FQK`, `SQK`, `DQK` to it.
  Extend `ControlCore`'s doc comment and `MockPersonality`'s assumption list with the **[assumed]** items above.
- [ ] **Step 4: Run, see them pass** — plus every existing `NoctuleMockScannerTests` suite.
- [ ] **Step 5: Commit** (`feat: the mock's fictional Favorites and quick keys`).

---

### Task 3: The client's quick-key calls

**Files:**
- Modify: `Sources/NoctuleKit/Client/ScannerClient.swift`, `Sources/NoctuleKit/Transport/UDPTransport.swift` (`GLT`
  expects XML), `Sources/NoctuleKit/Models/ScannerModel.swift` (`supportsQuickKeys`)
- Test: `Tests/NoctuleKitTests/ScannerClientQuickKeysTests.swift`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces (on `ScannerClient`): `favoritesLists() async throws -> [FavoritesList]`;
  `favoritesSystems(inList index: UInt32) async throws -> [FavoritesSystem]`;
  `favoritesDepartments(inSystem index: UInt32) async throws -> [FavoritesChild]`;
  `favoritesSites(inSystem index: UInt32) async throws -> [FavoritesChild]`;
  `listKeyStates() async throws -> QuickKeyStates`; `systemKeyStates(listKey: Int) async throws -> QuickKeyStates`;
  `departmentKeyStates(listKey: Int, systemKey: Int) async throws -> QuickKeyStates`;
  `setListKey(_ key: Int, on: Bool) async throws`; `setSystemKey(_ key: Int, inList listKey: Int, on: Bool) async throws`;
  `setDepartmentKey(_ key: Int, inList listKey: Int, system systemKey: Int, on: Bool) async throws`.
  A reply of the wrong shape is `ScannerClientError.unexpectedResponse(command:)`; a key outside 0…99 throws
  `.invalidArgument` before anything is sent. `ModelProfile.supportsQuickKeys: Bool` — true for `.sds200`, `.sds150`,
  `.sds100`; false for `.bcd436hp`.

- [ ] **Step 1: Failing tests** against both mocks: `readsTheWholeDefaultTree` (lists, systems of 1, departments and
  sites of 101 and 120, as Task 2's table); `gltAssemblesOverUDP` (`MockSDS200`: `favoritesDepartments(inSystem: 101)`
  succeeds, i.e. `GLT` is expected as XML); `setsNameOneKey` (after `setSystemKey(1, inList: 7, on: true)` the mock's
  log ends with `SQK,7,` + `setting(1, on: true)` joined, and `systemKeyStates(listKey: 7)[1] == .on`);
  `aKeyOutOfRangeSendsNothing` (`setListKey(100, on: true)` throws, the mock's log has no `FQK`);
  `aRejectedSetThrows` (`rejectNext: "DQK"` → `.rejected`); `aSetIsNotRetried` (`dropNextReply: "FQK"`: `setListKey`
  throws `.timeout`, the mock's log holds exactly one `FQK,` set); `profilesSupportQuickKeys`.
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement** (helpers beside `chargeStatus()`; the setters use `expectOK`).
- [ ] **Step 4: Run, see them pass**; the iOS build.
- [ ] **Step 5: Commit** (`feat: ScannerClient reads Favorites and sets one quick key`).

---

### Task 4: `noctule quick-keys`

**Files:**
- Modify: `Sources/NoctuleCLICore/CLIArguments.swift` (`case quickKeys`; `"quick-keys": serial` in the flag table;
  usage line), `Sources/NoctuleCLICore/CLIFormat.swift` (`quickKeys`)
- Create: `Sources/NoctuleCLICore/QuickKeyTreeReader.swift`
- Modify: `Sources/noctule/main.swift` (dispatch beside `.menu`)
- Test: `Tests/NoctuleCLICoreTests/QuickKeysFormatTests.swift`, `Tests/NoctuleCLIIntegrationTests/` (network and
  serial suites)

**Interfaces:**
- Consumes: Task 3.
- Produces: `public struct QuickKeyTree: Sendable, Equatable` (lists with their systems with their children, plus the
  states read: `lists: QuickKeyStates`, `systems: [Int: QuickKeyStates]` by list key, `children: [QuickKeyPair:
  QuickKeyStates]` by list and system key, `public struct QuickKeyPair: Hashable, Sendable { list: Int; system: Int }`) in `NoctuleKit/Status/Favorites.swift`, so Task 5 reuses it;
  `QuickKeyTreeReader.read(using client: ScannerClient) async throws -> QuickKeyTree` (reads only: `GLT,FL`, `FQK`,
  then per keyed list `SQK` and `GLT,SYS`, per system `GLT,DEPT`, `GLT,SITE` unless conventional, `DQK` for a keyed
  system of a keyed list); `CLIFormat.quickKeys(_ tree: QuickKeyTree) -> [String]`.
- **Format** (exact): lists by quick key ascending, then lists without one in `GLT` order; systems, then departments,
  then sites, in `GLT` order; indent 0/2/4 spaces by level. A line is
  `<indent><tag padded to 4>  <state padded to 3>  <name><suffixes>` where tag is `F<k>`/`S<k>`/`D<k>` or `-`; state
  is `on`, `off`, `?` (a key whose state reads 0) or `-` (no key, or a parent without one); suffixes in this order:
  ` (site)`, ` (<GLT Type>)` for a system that isn't Conventional, ` (not monitored)`, ` (avoided)`. Trailing spaces
  trimmed. Example from the mock: `F0    on   Mock Police`, `  S0    on   Metro P25 (P25 Trunk)`,
  `    D1    off  Detectives`, `F12   off  Mock Marine (not monitored)`, `-     -    Mock Events`.

- [ ] **Step 1: Failing tests** — format: `formatsTheMockTree` (a `QuickKeyTree` built from Task 2's table → the lines
  above at their places; `Air Attack` is `    D2    ?    Air Attack`; site `North Site` is
  `    D0    on   North Site (site)`; `County 800 Trunk` ends ` (Motorola) (avoided)`); parse: `quick-keys --serial
  /tmp/x` and `quick-keys --host h` parse, `quick-keys --interval 5` is a usage error (exit 2). Integration:
  `quickKeysOverTheNetwork` (`noctule quick-keys --host 127.0.0.1 --port <udp>` on `noctule-mock-scanner --verbose
  --no-delays` → exit 0, stdout's first line `F0    on   Mock Police`; the mock's log holds `GLT`, `FQK`, `SQK`, `DQK`
  reads only: no `FQK,`/`SQK,<n>,`/`DQK,<n>,<n>,` with 100 values); `quickKeysOverSerial` (the same on
  `--model sds150 --serial --serial-link L` and on `--model sds100`, with the kill-switch and a decoy port listing;
  `active-subscriptions=0`; no `KAL`, `MSM`, `POF`).
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see them pass** — plus `SerialIntegrationTests` and `NoctuleCLIIntegrationTests` unchanged.
- [ ] **Step 5: Commit** (`feat: noctule quick-keys prints the Favorites tree`).

---

### Task 5: `QuickKeysModel` — loading, the cache, and polling

**Files:**
- Create: `Sources/NoctuleAppCore/QuickKeys/QuickKeysModel.swift`, `QuickKeysCache.swift`
- Test: `Tests/NoctuleAppCoreTests/QuickKeysModelLoadingTests.swift`

**Interfaces:**
- Consumes: Tasks 3 and 4 (`QuickKeyTree`, the client calls).
- Produces: `@MainActor @Observable public final class QuickKeysModel` with
  `init(cacheURL: URL?, pollInterval: Duration = .seconds(2))`;
  `attach(control: @escaping @Sendable () async -> ScannerClient?)`, `detach()`, `quiesce() async`,
  `statusArrived(_ info: ScannerInfo)` (as `MenuModel`); `open()`, `close()` (the pop-over or panel shows / hides;
  reads happen only between them); `showList(_ index: UInt32)` (the "n ›");
  published: `lists: [QuickKeyListItem]` (index, name, key, monitored, `state: QuickKeyState?`, `systemCount: Int?`),
  `trees: [UInt32: QuickKeyListTree]` (systems with children, each row with its key, avoided and `state: QuickKeyState?`;
  `freshness: .checking | .loading | .fresh`), `shownList: UInt32?`, `scanning: QuickKeyScanning` (`list`, `system`,
  `child` indexes, each optional), `isScannerAnswering: Bool`, `lastError: String?`.
  `QuickKeysCache`: `load(from: URL) -> [UInt32: QuickKeyListTree]?` (structure only; missing or unreadable → nil),
  `save(_:to:)` (versioned JSON, written after each full read of a list).
- Behaviour (design §5.4): `open()` reads `GLT,FL` and `FQK` and publishes `lists` before anything else; then trees
  from the cache are published with `freshness = .checking` and no states; then lists are read in the background,
  one at a time, the scanning list first, then by key; `showList` of an unread list moves it to the front and marks
  it `.loading`. While open, every `pollInterval`: `FQK`, the shown list's `SQK` and its systems' `DQK`. A poll whose
  `existingKeys` differ from the pattern that scope showed on its first read since the tree loaded re-reads that
  list's structure (`.checking` until done). A read that times out is retried once; two in a row set
  `isScannerAnswering = false` (back to true on the next answer). Leaving a menu (`statusArrived` with
  `isMenu` false after true) marks every tree `.checking` and re-reads them. `close()`, `detach()` stop all reads.
  Matching of `scanning` is by `Index` from `ScannerInfo.monitorList/system/department/site`.

- [ ] **Step 1: Failing tests** (against `MockSDS200` and `MockSerialScanner` on a stepped clock, `quickKeySetDelay:
  .zero`, a short `pollInterval`, a temporary cache file):
  `theKeypadComesFirst` (after `open()`, `lists` is published while no `GLT,SYS` has been sent);
  `scanningListLoadsFirst` (with `statusArrived` naming list 1, the first `GLT,SYS` is `GLT,SYS,1`);
  `showingAListJumpsTheQueue` (`showList(14)` during the background reads → `GLT,SYS,14` is the next `GLT,SYS`);
  `theCacheIsShownCheckingWithoutStates` (a cache from a previous run → trees published at once with `.checking` and
  every `state == nil`); `aMovedKeyIsNeverSwitchedFromTheCache` (cache says system 102 is `S1`; the mock has moved it
  to `S3` → after the re-read the tree says `S3` and, until then, the row is not switchable — Task 6's
  `switchState(for:)` is `.checking`); `aKeyMovedWhileOpenIsRecheckedBeforeSwitching` (while open, `setFavorites`
  moves 102 to `S3` → the next poll of `SQK,7` changes the pattern → the list goes `.checking`, `GLT,SYS,1` is
  re-read, then `S3`); `leavingAMenuRechecksTheTrees` (pushes with `isMenu` true then false → every tree `.checking`,
  `GLT,SYS` re-sent for each read list); `pollsOnlyWhileOpen` (after `close()`, no command for 3 poll intervals);
  `scanningMatchesByIndex` (`ScannerInfo` with `MonitorList Index="1" Q_Key="0"`, system 101, department 200 →
  `scanning` is list 1, system 101, child 200; a site 999 not in the tree → `child` nil, the rest kept);
  `aSilentScannerIsReported` (`dropNextRequest` for two `FQK` → `isScannerAnswering == false`, then true);
  `noSetIsEverSent` (a whole open, background load, poll and close: the mock's log has no set);
  `theCacheHoldsNoStates` (the saved JSON has no `state` key).
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement.** Reads go through the attached client one at a time; never two in flight from this model.
- [ ] **Step 4: Run, see them pass**; the iOS build.
- [ ] **Step 5: Commit** (`feat: QuickKeysModel loads, caches and polls the Favorites`).

---

### Task 6: `QuickKeysModel` — switching

**Files:**
- Modify: `Sources/NoctuleAppCore/QuickKeys/QuickKeysModel.swift`
- Create: `Sources/NoctuleAppCore/QuickKeys/QuickKeyPages.swift` (the tens and keyboard logic, for the view)
- Test: `Tests/NoctuleAppCoreTests/QuickKeysModelSwitchingTests.swift`, `QuickKeyPagesTests.swift`

**Interfaces:**
- Consumes: Task 5.
- Produces:
  - `public enum QuickKeyRow: Hashable { case list(UInt32), system(list: UInt32, system: UInt32), child(list: UInt32, system: UInt32, child: UInt32) }`
  - `public enum QuickKeySwitchState: Equatable { case on, off, unknown /* not read yet */, checking, noQuickKey, unreported, sharedSystemKey(Int), inMenu, unavailable /* not connected */, busy }`
  - `func switchState(for row: QuickKeyRow) -> QuickKeySwitchState`; `func sharing(for row: QuickKeyRow) -> Int` (how
    many rows share its key, 1 if none); `func toggle(_ row: QuickKeyRow) async` (sets `lastError` on `NG` or timeout).
  - `public struct QuickKeyPages { init(lists: [QuickKeyListItem], scanningList: UInt32?); tens: [Ten] /* 10, each: range, listCount, onCount, isEnabled, holdsScanning */; func initialTen() -> Int; func next(after: Int) -> Int?; func previous(before: Int) -> Int? /* skip empty tens */; func slots(inTen: Int) -> [QuickKeyListItem?] /* 10, nil = placeholder */ }`
  - `QuickKeyPages.search(_ text: String, in model: QuickKeysModel) -> QuickKeyRow?` — the first list, system,
    department or site whose name contains `text` (ignoring case) or whose key tag (`F12`, `S3`, `D0`) or number
    equals it; lists before systems before children.
  - `public struct QuickKeyTyping { mutating func type(_ digit: Int, at: ContinuousClock.Instant) -> Int? /* the key to jump to; two digits within 1 s make one number */ }`
- Behaviour (design §5.4): `toggle` asks for the opposite of the shown state; sends the one-key set for its scope
  (list: `setListKey`; system: `setSystemKey(_, inList: listKey)`; child: `setDepartmentKey(_, inList:, system:)`);
  then re-reads the scope and shows what the scanner holds. Refused (nothing sent) unless `switchState` is `.on` or
  `.off`. While a scope's action runs its rows are `.busy` and further toggles on it are refused. A confirming read
  whose `existingKeys` differ from the scope's pattern is dropped and read again once. `NG` or a timeout → `lastError =
  "The scanner didn't confirm the change"`, the re-read's state shown, never resent. `.noQuickKey` for a row (or its
  list or system) without a key; `.unreported` for a key the scope reads as 0; `.sharedSystemKey(k)` for children of a
  system whose key another system in the list shares; `.inMenu` while `statusArrived` says menu; `.unavailable` after
  `detach()`.

- [ ] **Step 1: Failing tests** (both mocks, as Task 5):
  `aTileClickSendsOneSet` (`toggle(.list(4))`, list 4 off → exactly one new `FQK,` set, value `[1]=="2"`, others `"0"`;
  `switchState == .on` after); `aSystemAndAChildSwitch` (`.system(list: 1, system: 102)` → `SQK,7,` set; `.child(list:
  4, system: 120, child: 621)` → `DQK,1,0,` set with `[1]=="2"`); `aRadioChangeIsNeverOverwritten` (the mock turns
  `S1` off in list 7 behind the model's back; `toggle(.system(list: 1, system: 101))` → `S0` off and `S1` still off);
  `aSetThatTimesOutIsNotResent` (`dropNextReply: "SQK"` on the set → one set in the log, `lastError ==
  "The scanner didn't confirm the change"`, the state from the re-read); `aRejectedSetIsReported` (`rejectNext:
  "FQK"`); `aStrayReplyIsDropped` (`replyDelays["DQK"]` longer than the client timeout on a poll of system 101, then a
  toggle under system 102: the late `DQK` reply doesn't become 102's state; the model reads again; 102's row shows the
  mock's value); `busyRefusesASecondClick` (two `toggle` on the same list concurrently → one set); `sharedKeysSwitchTogether`
  (toggle child 200 → 203 and 301 change too; `sharing(for: .child(list: 1, system: 101, child: 200)) == 3`);
  `whatCantBeSwitched` (`.list(10)` `.noQuickKey`; `.child(list: 0, system: 112, child: 520)` `.noQuickKey`;
  `.child(list: 4, system: 122, child: 540)` `.unreported`; `.child(list: 0, system: 110, child: 500)`
  `.sharedSystemKey(0)`; `.list(8)` (not monitored) is `.off` and toggles); `inAMenuNothingSwitches` (a push with
  `isMenu` → every row `.inMenu`, `toggle` sends nothing); `afterDetachNothingSwitches`.
  Pages: `tensFromTheMock` (tens 0, 1, 2, 4 enabled; 3 and 5–9 disabled; ten 0 `onCount` from the states;
  `holdsScanning` on ten 0 for list 1 (key 7)); `nextSkipsEmptyTens` (`next(after: 2) == 4`, `next(after: 4) == nil`);
  `slotsKeepPlaces` (ten 1: slot 2 is list 8 (key 12), the rest nil); `initialTenIsTheScanningOne` (else the first
  enabled); `typingTwoDigits` (`4` then `1` within 1 s → 41; `4`, 1.5 s, `1` → 4 then 1); `searchFindsByNameOrNumber`
  (`"tower"` → `.child(list: 12, system: 160, child: 580)`; `"F12"` and `"12"` → `.list(8)`; `"nothing"` → nil).
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see them pass**; the iOS build.
- [ ] **Step 5: Commit** (`feat: QuickKeysModel switches one key per click`).

---

### Task 7: The session owns the model

**Files:**
- Modify: `Sources/NoctuleAppCore/Session/StationSession.swift` (`public let quickKeys: QuickKeysModel`, created in
  `init` with `cacheURL` `<settingsDirectory>/Stations/<uuid>/quick-keys.json` when the profile `supportsQuickKeys`,
  else no polling; `attach` beside `menu.attach` at `.connected`; `detach` beside `menu.detach`; `statusArrived`
  forwards; `quiesce` in the stop path beside `menu.quiesce()`)
- Test: `Tests/NoctuleAppCoreTests/StationSessionQuickKeysTests.swift` (network rig and `USBRig`)

**Interfaces:**
- Consumes: Tasks 5–6; `SessionEnvironment.settingsDirectory`; `StationLock.lockURL`'s directory layout.
- Produces: `StationSession.quickKeys`; `StationSession.supportsQuickKeys: Bool` (from the connected model's profile;
  the toolbar hides the button when false).

- [ ] **Step 1: Failing tests** — `connectedSessionLoadsTheKeypad` (network mock: start, `quickKeys.open()` → lists
  published); `unplugWithThePopoverOpen` (`USBRig` with `--fault`-style `unplug` while open: trees stay,
  `switchState` `.unavailable`, no command reaches the mock while waiting; after `replug` and `.connected`, reads
  resume; `stop()` → no further command; `activeSubscribers == 0`); `stopLeavesNothingRunning` (open, stop, advance
  past three poll intervals: the mock's log is unchanged); `theCacheFileIsPerStation`; `noCooldownCall` (a USB
  station's quick-key reads never touch the cooldown store).
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see them pass** — plus every `StationSession*` and `SessionRegistry*` suite; the iOS build.
- [ ] **Step 5: Commit** (`feat: each station session owns its quick keys`).

---

### Task 8: The pop-over

**Files:**
- Create: `Sources/NoctuleScan/QuickKeys/QuickKeysPopover.swift` (keypad, tens control, tree panel, search, error
  line), `QuickKeyTile.swift`, `QuickKeyTreePanel.swift`, `QuickKeysPanelController.swift` (the pop-over and its
  tear-off panel)
- Modify: `Sources/NoctuleScan/StationWindow.swift` (toolbar button), `Sources/NoctuleScan/Scanner/KeyboardShortcuts.swift`
  only if the key monitor needs to ignore the panel explicitly
- Test: `Tests/NoctuleScanTests/QuickKeysViewTests.swift`

**Interfaces:**
- Consumes: Tasks 6–7 (`session.quickKeys`, `QuickKeyPages`, `QuickKeyTyping`, `switchState`, `sharing`).
- Produces: the views. The look is the brainstorm's `keypad-tree-v4.html` and `keypad-paging-v2.html`
  (`.superpowers/brainstorm/4882-1795041210/content/`, git-ignored; design §5.5 describes them): blue fill and border
  on, gray off, green ring scanning, white outline with a pointer for the shown list; the tens as a standard segmented
  control with a count per segment and a green ● on the scanning ten; page dots; a two-finger swipe or ‹ › steps
  tens. The search field jumps to `QuickKeyPages.search`'s row (its ten, its list shown). In the tree, systems
  start expanded when the list has three or fewer, else collapsed but for the scanning one. A tile click toggles; its corner `n ›` shows the tree; `.busy` shows a progress look; `.checking` shows
  `Checking…` and disabled switches; `.unknown` shows a neutral tile and switch.
- Pop-over: `open()` on show, `close()` on hide; tear-off keeps the model open until the panel closes; one per
  station window. Keyboard while it has focus: digits through `QuickKeyTyping` jump to the key's ten and highlight
  its tile; Space or Return toggles the highlighted tile; ⌘↓ shows its tree; none of these reach the scanner.

- [ ] **Step 1: Failing tests** (view helpers, `@testable import NoctuleScan`): `tileAccessibility` (label
  `Mock Police, quick key 0`, value on); `cornerButtonLabel` (`Show systems in Mock Police`); `headerDetail`
  (`3 systems, 2 on`; `1 system, 1 on`); `helpTexts` (each exact string from Global Constraints for its
  `QuickKeySwitchState`); `toolbarButtonHiddenWithoutSupport` (`supportsQuickKeys` false → not shown);
  `keysInThePanelNeverReachTheScanner` (the key monitor's decision for an event whose window is the pop-over's or the
  panel's is pass-through).
- [ ] **Step 2: Run, see them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, see them pass**; `scripts/build-app.sh`; `codesign -dv "build/Noctule Scan.app"` still shows
  `runtime`.
- [ ] **Step 5: Commit** (`feat: the Quick Keys pop-over`).

---

### Task 9: Documents, the full run, and the app on the mocks

**Files:**
- Modify: `AGENTS.md` (the quick-key commands: reads are read-only and may go to every model in a hardware run the
  owner asked for; a set with values changes scanner state and needs the owner's go-ahead per action, one per action,
  never resent; the app sends a set only from a click; tests never send one to hardware. `noctule quick-keys` in
  Build and test; the pop-over and its cache file in the Mac app section; the mock's Favorites in the mock section),
  `LESSONS.md` (anything learned), `docs/specs/2026-11-18-quick-keys-design.md` (status: built; a "What was built"
  section for any departure from §5), `docs/specs/2026-11-08-sds-remote-protocol.md` (§5b: nothing new unless found).
- [ ] **Step 1:** Write them; `swift test --filter RealNamesTests`.
- [ ] **Step 2:** Full `NOCTULE_NO_USB_DETECTION=1 swift test` and the iOS build: all pass.
- [ ] **Step 3:** Drive the app on the mocks with computer use (AGENTS.md "Driving the app"): a network station on
  `noctule-mock-scanner --verbose`, and a USB station on `--model sds150 --serial --serial-link` and on
  `--model sds100`, each with a temporary `NOCTULE_SETTINGS_DIR` and `NOCTULE_NO_USB_DETECTION=1`. Check: the keypad
  appears at once and the trees fill in; one tile click, one system and one department switch each put exactly one
  set in the mock's log with only that key non-zero; the tens control skips empty tens; a tear-off panel stays open;
  typing `41` jumps to Mock Interop; entering a menu with `KEY,M,P` from the Scanner view disables every switch and
  leaving it rechecks; quit from the menu bar; the mock ends with `PSI,0`, `leaked-sessions=0` or
  `active-subscriptions=0`, and no `MSM`, `POF` (and on the SDS100 no `KAL`, `GCS`). Screenshots of the app's window
  only, under `.superpowers/screenshots/plan-20/`.
- [ ] **Step 4: Commit** (`docs: Favorites quick keys (Plan 20)`).

After Task 9: a whole-branch review, then the owner's hardware session (design §7) on the SDS200, SDS150 and SDS100,
the owner's call each time.
