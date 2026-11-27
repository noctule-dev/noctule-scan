# Plan 24: Services and Range walk the menu — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Scanner view's Services and Range buttons open Select Service Types and Set Range by a checked menu walk, with one button set on all four models (GitHub issue #14).

**Architecture:** The paths are per-model data in `NoctuleKit` (`ModelProfile.menuShortcuts`). `MenuModel.walk(_:)` in `NoctuleAppCore` runs them under the existing action rules (one `perform`, every command through `command(…)` and its `SendPermit`, the re-read after each command as the next step's check). `StationSession` routes the Services and Range keys to the walk instead of `KEY`, and the Scanner view shows both buttons on every model.

**Tech Stack:** Swift 6.2, SwiftUI/AppKit (macOS app only), Swift Testing, `NoctuleMockScanner`.

**Spec:** `docs/specs/2026-11-26-services-range-design.md` (read it with this plan; § references are to it).

## Global Constraints

- Branch `feature/services-range-menus`; every commit `git commit -s`, with the session's `Co-Authored-By` and `Claude-Session` lines; commit only your own paths (`git add <paths>`, never `-A`).
- Every new `.swift` file starts with the two-line SPDX notice (`AGENTS.md` Working rules).
- `NoctuleKit`, `NoctuleStore`, `NoctuleAppCore` must keep building for iOS: `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build`.
- Tests run only against the mocks, in the foreground, with `NOCTULE_NO_USB_DETECTION=1` exported; every new `@Suite` has a `.timeLimit`. No test, script or QA mutation touches `/dev/cu.usbmodem*`, a real station or the owner's settings.
- No real names, frequencies or IDs anywhere; service-type names in the mock are Uniden's generic category names only.
- `KEY,T` and `KEY,R` are never sent by anything in the product (§2 anti-goals).
- A walk sends at most four state-changing commands (enter plus three `MSV`s), each once, never resent (§5.2).
- Nothing in the Mac-style view changes (owner, 2026-11-26); its Services and Range chords do nothing (§5.4).
- QA mutations in a temporary worktree with its own `--scratch-path`; mutations may not remove the kill-switch or point anything at hardware.

## Review Focus

- **A key the user pressed just before clicking Services** (queued, not yet sent): the walk must refuse, not interleave (Task 4 test `walkRefusedWhileKeysQueued`).
- **The session stopping mid-walk** (window closed, sleep): no command after the stop (Task 3 test `detachMidWalkSendsNothingMore`).
- **A double-click on Range**: the second click is refused `.busy`, one walk only (Task 4 test `doubleClickRunsOneWalk`).
- **Func pressed on the keypad, then Services**: nothing sent (Task 3 test `funcPendingSendsNothing`, needing Task 2's Func state on the mock).
- **A saved key map from before this plan** with chords on Services/Range: it still decodes and the chord runs the walk in the Scanner view, and does nothing in the Mac-style view (Task 5 tests `oldKeyMapChordsRunTheWalk`, `macStyleSwallowsShortcutChords`).

---

### Task 1: Paths in the profile; `T` and `R` never sent; `ScannerInfo.functionOn`

**Files:**
- Create: `Sources/NoctuleKit/Models/MenuShortcut.swift`
- Modify: `Sources/NoctuleKit/Models/ScannerModel.swift` (`ModelProfile`: new field, `frontPanelKeys` of all four)
- Modify: `Sources/NoctuleKit/Client/ScannerClient.swift:499` (`press`)
- Modify: `Sources/NoctuleKit/Status/ScannerInfo.swift:180` (`Property`)
- Test: `Tests/NoctuleKitTests/ModelProfileTests.swift`, `Tests/NoctuleKitTests/MenuShortcutTests.swift` (new), the existing `ScannerInfo` and `ScannerClient` test files (find with `grep -l "ScannerInfo(" Tests/NoctuleKitTests`, `grep -l "invalidArgument" Tests/NoctuleKitTests`)

**Interfaces:**
- Produces:
  - `public enum MenuShortcut: String, Sendable, CaseIterable { case serviceTypes, range }` with `public init?(key: FrontPanelKey)` (`.serviceType` → `.serviceTypes`, `.range` → `.range`, else nil) and `public var key: FrontPanelKey`.
  - `public struct MenuStep: Sendable, Equatable { public let screen: String; public let item: String; public init(screen:item:) }`
  - `public struct MenuPath: Sendable, Equatable { public let steps: [MenuStep]; public let destination: String; public static let maxSteps = 3 }`, with `public init(steps:destination:)` that `precondition`s `1...maxSteps`.
  - `MenuPath.serviceTypes` = one step (screen `"Menu"`, item `"Select Service Types"`), destination `"Select Service Types"`; `MenuPath.range` = two steps (`"Menu"` › `"Set Your Location"`, then `"Set Your Location"` › `"Set Range"`), destination `"Set Range"` (§5.3).
  - `ModelProfile.menuShortcuts: [MenuShortcut: MenuPath]`: both paths on all four models.
  - `ModelProfile.frontPanelKeys`: `T` and `R` removed on **every** model (SDS200 included); the handhelds' other removals unchanged.
  - `ScannerClient.press(_:onlyIf:)` throws `ScannerClientError.invalidArgument` for `.serviceType` and `.range`, before anything is sent.
  - `ScannerInfo.functionOn: Bool?` from `Property F` (`"On"`/`"Off"`, the existing `onOff` helper).

- [ ] **Step 1: Write the failing tests**
  - `MenuShortcutTests.pathsAreTheDesignsOnEveryModel`: for each `ScannerModel.allCases`, `profile.menuShortcuts == [.serviceTypes: .serviceTypes, .range: .range]`, and every path's `steps.count <= MenuPath.maxSteps`.
  - `MenuShortcutTests.keysMapToShortcuts`: `MenuShortcut(key: .serviceType) == .serviceTypes`, `MenuShortcut(key: .range) == .range`, `MenuShortcut(key: .zip) == nil`.
  - `ModelProfileTests`: change the three existing `frontPanelKeys` expectations (lines 33, 49–53) so every model lacks `.serviceType` and `.range` (`sds200 == all.subtracting([.serviceType, .range])`, `sds100 == all.subtracting([.serviceType, .range, .squelchPush])`, `sds150` and `bcd436hp` likewise).
  - Client: `pressRefusesServiceTypeAndRange`: on a fake/loopback transport, `press(.serviceType)` and `press(.range)` throw `invalidArgument` and the transport saw no write.
  - `ScannerInfo`: `functionOnReadsPropertyF`: a `GSI` with `<Property F="On" …>` gives `functionOn == true`, `F="Off"` false, missing nil.
- [ ] **Step 2: Run them and see them fail**: `swift test --filter 'MenuShortcutTests|ModelProfileTests|functionOnReadsPropertyF|pressRefusesServiceTypeAndRange'`; expected: compile errors / failures naming the new symbols.
- [ ] **Step 3: Implement** the types, the profile field and key sets, the client guard (message `"the scanner has no \(key.rawValue) key"`), and `functionOn`.
- [ ] **Step 4: Run them and see them pass**, then `swift build` and the iOS build (Global Constraints). Expected: PASS, both builds succeed. Tests elsewhere that pinned Plan 23's per-model keys (`StationSessionControlTests` 730–752, `ScannerViewHelpersTests` 23–34) may now fail: leave them for Tasks 4 and 5, and list them in the commit message.
- [ ] **Step 5: Commit** `feat: menu shortcut paths per model; T and R never sent; GSI's Func state`.

### Task 2: The mock: Select Service Types and Func state

**Files:**
- Modify: `Sources/NoctuleMockScanner/MockMenu.swift` (tree, type comment's assumptions)
- Modify: wherever the mocks build `GSI`/`PSI`'s `Property` line (`Sources/NoctuleMockScanner/MockScreens.swift:100-104`) and handle `KEY` (`grep -n '"KEY"' Sources/NoctuleMockScanner/*.swift`)
- Modify: `AGENTS.md` (the mock's menu tree line under "The network mock")
- Test: `Tests/NoctuleMockScannerTests/` (the `MockMenu` tests: `grep -ln MockMenu Tests/NoctuleMockScannerTests`), `Tests/NoctuleAppCoreTests/MenuModelTests.swift:17` (`topItems`)

**Interfaces:**
- Produces: the tree's top menu gains **Select Service Types**, a `toggleList` placed right after Set Your Location, with toggles `Multi-Dispatch` (On), `Law Dispatch` (On), `Fire Dispatch` (On), `EMS Dispatch` (On), `Custom 1` (On), `Hospital` (Off), `Railroad` (Off). Every personality has it (the tree is shared).
- Produces: the mock's `Property F` is `"On"` after a `KEY,F,P` until the next `KEY` of any code is handled, then `"Off"` (**assumed**, not seen on hardware; add it to the assumptions paragraph). The mock doesn't change what that next key does.

- [ ] **Step 1: Write the failing tests**
  - `MockMenu`: `topMenuListsSelectServiceTypes`: `MSI` on the top menu lists `Select Service Types` with its own `Index`; `MSV,,<that index>` opens a `TypeSelect` screen named `Select Service Types` whose items carry `Value="On|Off"`; `MSV,,<an item>` toggles it.
  - `funcKeyShowsInProperty`: on `MockSDS200` and on `MockSerialScanner` (`.sds150`, `.bcd436hp`): `GSI` has `F="Off"`; after `KEY,F,P` `F="On"`; after one more `KEY` (`KEY,1,P`) `F="Off"`.
  - Update `MenuModelTests.topItems` to `["Set Scan Selection", "Set Your Location", "Select Service Types", "Search for...", "Display Options", "Settings"]` and any other pin of the top menu's items or indexes that now fails (run the suite to find them).
- [ ] **Step 2: Run them and see them fail**: `swift test --filter 'NoctuleMockScannerTests|MenuModelTests'`.
- [ ] **Step 3: Implement** the tree entry and the Func state; update `AGENTS.md`'s mock menu-tree sentence ("an on/off list" → name Select Service Types too) and the Func assumption.
- [ ] **Step 4: Run** `swift test --filter 'NoctuleMockScannerTests|MenuModelTests|BCDMenuModelTests'`; expected PASS.
- [ ] **Step 5: Commit** `feat(mock): Select Service Types on the menu tree; Func shows in GSI`.

### Task 3: `MenuModel.walk(_:)`

**Files:**
- Modify: `Sources/NoctuleAppCore/Menu/MenuModel.swift`
- Test: `Tests/NoctuleAppCoreTests/MenuWalkTests.swift` (new; reuse `withSession`/`Rig` from `SessionTestSupport.swift` for the SDS200 and the private `withMenuModel` pattern of `MenuModelTests.swift:1480` for the serial personalities: copy it into the new file or move it to `SessionTestSupport.swift`)

**Interfaces:**
- Consumes: `MenuPath`, `MenuStep`, `ScannerInfo.functionOn` (Task 1); the mock's tree and Func state (Task 2).
- Produces:
  - `public func walk(_ path: MenuPath) async throws -> MenuContent?` on `MenuModel`.
  - New `MenuActionError` cases: `alreadyInMenu`, `functionPending`, `walkStopped(expected: String, found: String?)` (`expected`: the screen the walk needed; `found`: the title it saw, nil when none).
  - `static func judge(info: ScannerInfo, screen: MenuScreen?, expecting step: MenuStep?, destination: String, previousTitle: String?) -> WalkVerdict` with `enum WalkVerdict: Equatable { case proceed(itemIndex: Int), arrived, stale, mismatch(found: String?) }` (internal; `step == nil` means "judge arrival").

The algorithm (§5.1; the `perform(inMenu: false)` body):
1. `readInfo`; `info.isMenu` → `apply` a snapshot as `refresh()` does, throw `.alreadyInMenu`, nothing sent. `info.functionOn == true` → throw `.functionPending`, nothing sent.
2. Enter through `command(…)` exactly as `enter()` does (`.keys` → `press(.menu)`, `.menuCommands` → `openMenu`).
3. For each step: judge the snapshot that `command(…)` just read. `.stale` (the title is still `previousTitle`) → wait 300 ms, `fetch` once more, judge again; a second `.stale` counts as `.mismatch`. `.mismatch(found)` → `rereadAfterMismatch`, throw `.walkStopped(expected: step.screen, found:)`. `.proceed(i)` → `command(…)` with `setMenuValue(String(i))`.
4. After the last `MSV`: judge arrival on `GSI`'s `menuTitle` (normalised with `breadcrumbTitle`) against `path.destination`, with the same one grace re-read; success returns `content` whatever `MSI` was (list, entry or `.mirrored`).

`command(…)` today returns only `MenuContent?`. Split it so the walk gets the re-read's `Snapshot` (a private variant returning `Snapshot`, which `command` wraps). Its errors pass through unchanged (`.rejected`, `.noAnswer`, `.notConnected`), and they stop the walk. `judge` matches the screen name after `breadcrumbTitle` and the item name trimmed, exactly (case-sensitive), and needs exactly one matching item.

- [ ] **Step 1: Write the failing tests** (each also asserts no `KEY,T`/`KEY,R` in the mock's log, and the count of state-changing commands):
  - `judge` unit tests on parsed `MSI` XML: the top menu with the item → `.proceed(index)`; the item missing → `.mismatch("Menu")`; two items with that name → `.mismatch`; a screen titled `previousTitle` → `.stale`; arrival with `GSI` naming the destination and `MSI` `TypeError` → `.arrived`.
  - `rangeOnTheSDS200SendsTheDesignedWire`: from scanning, `walk(.range)`; the mock's commands from the walk's first `GSI` on are exactly `GSI, KEY,M,P, GSI, MSI, MSV,,<i>, GSI, MSI, MSV,,<j>, GSI, MSI` (ignore `PSI`/`STS`/background reads by filtering on the walk's window if the rig has them; the rig's own reads must not interleave a state-changing command); the result is `.entry` titled `Set Range`; `mock.menuPath` ends in `Set Range`.
  - `servicesOnTheSDS200`: `walk(.serviceTypes)` ends on a `.list` titled `Select Service Types` with two state-changing commands.
  - `rangeOnTheBCD436HPUsesMNU`, `servicesOnTheBCD436HP`: the same wire with `MNU,TOP,` in place of `KEY,M,P`.
  - `rangeOnTheSDS100`, `rangeOnTheSDS150`: reach Set Range.
  - `alreadyInMenuSendsNothing`: enter first, then `walk(.range)` throws `.alreadyInMenu`; no further state-changing command.
  - `funcPendingSendsNothing`: a panel client sends `KEY,F,P`; `walk(.range)` throws `.functionPending`; nothing state-changing sent by the model.
  - `wrongPathStopsWithoutSending`: `walk(MenuPath(steps: [MenuStep(screen: "Menu", item: "Set Your Place")], destination: "Set Range"))` throws `.walkStopped(expected: "Menu", found: "Menu")` after exactly one state-changing command (the enter); the scanner stays in the top menu.
  - `wrongScreenNameStops`: a path whose second step names screen `"Settings"` stops after two commands with `found: "Set Your Location"`.
  - `rejectedMSVStops` (`MockFaults.rejectNext = "MSV"`): throws `.rejected`, no further command.
  - `droppedEnterReplyStops` (`drop-reply` `KEY`) and `droppedMSVRequestStops` (`drop-request` `MSV`): throw `.noAnswer`; that command appears once in the log; nothing after it but reads.
  - `detachMidWalkSendsNothingMore`: `replyDelays["MSV"]` holds the first `MSV`'s reply; detach while it waits; no further `MSV` reaches the mock.
  - `walkIsOneAction`: a `choose`, `back` or second `walk` started during a walk throws `.busy`.
- [ ] **Step 2: Run** `swift test --filter MenuWalkTests`; expected FAIL (missing `walk`).
- [ ] **Step 3: Implement** `walk`, `judge`, the error cases and the `command` split; update `MenuModel`'s type comment ("Actions each send at most one state-changing command … except `walk`", with §5.2's wording).
- [ ] **Step 4: Run** `swift test --filter 'MenuWalkTests|MenuModelTests|BCDMenuModelTests'`; expected PASS. Then the iOS build.
- [ ] **Step 5: Commit** `feat: MenuModel.walk opens a screen by a checked menu walk`.

### Task 4: `StationSession` routes Services and Range to the walk

**Files:**
- Modify: `Sources/NoctuleAppCore/Session/StationSession.swift` (`press`, `startKeyQueue`, new members)
- Create: `Sources/NoctuleAppCore/Menu/MenuShortcutText.swift`
- Test: `Tests/NoctuleAppCoreTests/StationSessionControlTests.swift` (replace the four per-model key tests at 728–752), `Tests/NoctuleAppCoreTests/MenuShortcutTextTests.swift` (new)

**Interfaces:**
- Consumes: `MenuShortcut`, `ModelProfile.menuShortcuts` (Task 1); `MenuModel.walk(_:)` and its errors (Task 3).
- Produces:
  - `public func press(_ key: FrontPanelKey)`: if `MenuShortcut(key:)` is non-nil, calls `startMenuShortcut(_:)` and returns; else as today, and **dropped while a walk runs**.
  - `public func openMenuShortcut(_ shortcut: MenuShortcut) async throws -> MenuContent?`: throws `.notConnected` unless connected; `.busy` while a walk runs or `pendingKeyPresses > 0`; `.walkStopped(expected: shortcut's destination, found: nil)` when the model has no path; else sets `menuShortcutInFlight`, awaits `menu.walk(path)`, clears it on every path.
  - `public func startMenuShortcut(_ shortcut: MenuShortcut)`: the view's entry; runs `openMenuShortcut` in a task and sets `menuShortcutMessage` from `MenuShortcutText.message(for:shortcut:)` on failure (nil on success or when it starts).
  - `public private(set) var menuShortcutInFlight: MenuShortcut?` and `public private(set) var menuShortcutMessage: String?`.
  - `pendingKeyPresses: Int` (internal): +1 when `press` yields a key, −1 when the queue drops it (`enqueue` false) or its send ends (sent, failed, or gate closed). Reset to 0 by `stopKeyQueue()`.
  - `public enum MenuShortcutText { public static func message(for error: MenuActionError, shortcut: MenuShortcut) -> String? }`: `.alreadyInMenu` → `"Already in a menu. Exit it first."`; `.functionPending` → `"Func is on. Press a key to clear it first."`; `.walkStopped(_, found)` → `"Couldn't open \(destination): the scanner showed \(found)."` (or `"…: the scanner didn't show the expected screen."` when nil); `.noAnswer` → `"Couldn't open \(destination): the scanner didn't answer."`; `.rejected` → `"Couldn't open \(destination): the scanner refused a step."`; `.busy` → nil (the keypad is disabled meanwhile); others → `"Couldn't open \(destination)."` (`destination` is `"Set Range"` or `"Select Service Types"`).

- [ ] **Step 1: Write the failing tests**
  - Replace `bcdPressesItsOwnKeysOnly`, `sds100DropsServicesAndSquelchPushKeepsRange`, `sds150DropsRange` and `sds200StillSendsServices` with: `servicesAndRangeWalkOnEveryModel` (parameterised over the four models' rigs: `press(.range)` ends with the mock in Set Range, `press(.serviceType)` in Select Service Types after an exit; neither `KEY,T,P` nor `KEY,R,P` in the log; `PSI,0` last); `handheldsStillDropKeysTheyLack` (`.squelchPush` on the BCD436HP, SDS100, SDS150 sends nothing; `.scrollPush` and `.soft1` on the BCD436HP still send `KEY,^,P`, `KEY,A,P`).
  - `walkRefusedWhileKeysQueued`: hold `KEY` replies (`replyDelays["KEY"]`), `press(.digit1)`, then `openMenuShortcut(.range)` throws `.busy`; no `KEY,M,P`.
  - `keysDroppedDuringAWalk`: hold the first `MSV`'s reply; `press(.digit1)` during the walk; after it ends, no `KEY,1,P` in the log.
  - `doubleClickRunsOneWalk`: `press(.range)` twice back to back; one `KEY,M,P` only.
  - `MenuShortcutTextTests`: each mapping above, verbatim.
- [ ] **Step 2: Run** `swift test --filter 'StationSessionControlTests|MenuShortcutTextTests'`; expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter plus `StationSessionUSBTests`; expected PASS; iOS build.
- [ ] **Step 5: Commit** `feat: Services and Range run the menu walk from the session`.

### Task 5: The Scanner view and the key map

**Files:**
- Modify: `Sources/NoctuleScan/Scanner/KeypadView.swift` (`rows(keys:)`, help text, disabled state)
- Modify: `Sources/NoctuleScan/Scanner/ScannerView.swift:90` (wiring, feedback caption)
- Modify: `Sources/NoctuleScan/Scanner/KeyboardShortcuts.swift:107` (`decide`), `Sources/NoctuleScan/StationContentView.swift:56-62`
- Test: `Tests/NoctuleScanTests/ScannerViewHelpersTests.swift:20-34`, `Tests/NoctuleScanTests/KeyboardMonitorTests.swift`, `Tests/NoctuleStoreTests/` (key-map decoding: `grep -ln resolved Tests/NoctuleStoreTests`)

**Interfaces:**
- Consumes: `MenuShortcut` (Task 1); `session.press`, `menuShortcutInFlight`, `menuShortcutMessage` (Task 4).
- Produces:
  - `KeypadView.rows(keys:)` always keeps `.serviceType` and `.range` (they are menu shortcuts, not keys), so the second row is Zip, Services, Range on every model.
  - `KeypadView` gets `walking: Bool`; the whole keypad is disabled while it is true. The Scanner view passes `session.menuShortcutInFlight != nil`.
  - Help text: Services `"Open Select Service Types"`, Range `"Open Set Range"`.
  - Under the keypad, `session.menuShortcutMessage` in the panel's caption style, cleared after 5 s or by the next click (the builder's layout; it must not move the keypad).
  - `KeyboardShortcuts.decide(…, menuShortcutsAllowed: Bool = true)`: when false and the chord maps to a key with `MenuShortcut(key:) != nil`, `.swallow`. `StationContentView` passes `view == .scanner`.

- [ ] **Step 1: Write the failing tests**
  - `ScannerViewHelpersTests`: replace the per-model assertions with `everyModelShowsZipServicesRange`: for each model, `rows(keys: profile.frontPanelKeys)[1].map(\.key) == [.zip, .serviceType, .range]`; keep the "no empty row" check.
  - `KeyboardMonitorTests.macStyleSwallowsShortcutChords`: a router mapping a chord to `.range`; `decide(..., menuShortcutsAllowed: false) == .swallow`; with `true`, `.press(.range)`; a digit chord with `false` is still `.press`.
  - `oldKeyMapChordsRunTheWalk` (NoctuleStore): a `keyMap` JSON with overrides `{"T": "⌘7", "R": "⌘8"}` decodes and `resolved(for:)` maps `.serviceType` and `.range` to those chords for each model (the session test in Task 4 already shows `press(.range)` runs the walk).
- [ ] **Step 2: Run** `swift test --filter 'ScannerViewHelpersTests|KeyboardMonitorTests|NoctuleStoreTests'`; expected FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same filter; PASS. `scripts/build-app.sh` succeeds.
- [ ] **Step 5: Hand check on the mocks** (the app launch rules in `AGENTS.md`: a temporary `NOCTULE_SETTINGS_DIR` of mock stations, `NOCTULE_NO_USB_DETECTION=1`): on the network mock and on the `bcd436hp` serial mock, click Range, then Exit; Services, then Exit; Func then Services (message shown, nothing sent); the mock's `--verbose` log shows the wire of Task 3 and no `KEY,T`/`KEY,R`; `leaked-sessions=0` / `active-subscriptions=0`. Window screenshots by window id into `.superpowers/screenshots/plan-24/`.
- [ ] **Step 6: Commit** `feat(app): one button set; Services and Range walk the menu from the Scanner view`.

### Task 6: Documents and the full run

**Files:**
- Modify: `AGENTS.md` (Every model: the one-command rule with §5.2's exception, verbatim; "Keys, menus and quick keys": the keypad's one button set, Services/Range walk, `T`/`R` never sent; the BCD436HP bullet "The Scanner view's System, Dept and Channel buttons…" unchanged; the SDS100/SDS150 mock line about `KEY,T`/`KEY,R` answering `NG` kept)
- Modify: `docs/specs/2026-11-10-remote-menus-design.md` (a dated note at §5.4/§5.5 pointing to the walk exception), `docs/specs/2026-11-25-bcd436hp-usb-design.md` (dated notes at §5.3's panel bullet, §5.11 and §7 H6/H11: reversed/changed by this design), `docs/specs/2026-11-08-sds-remote-protocol.md` (the key-sheet finding and `SVC`/`LCR` results, labelled [spec]/[hw])
- Modify: `docs/specs/2026-11-26-services-range-design.md` (a new §10 "What was built": anything that differs from §5, and the rulings made during the build)
- Modify: `LESSONS.md` only if something during the build surprised or cost time

- [ ] **Step 1: Edit the documents** as listed.
- [ ] **Step 2: Full run**: `NOCTULE_NO_USB_DETECTION=1 swift test` (foreground); expected all pass (hardware suites skipped). iOS build. `scripts/build-app.sh`.
- [ ] **Step 3: Repository suites**: `swift test --filter 'RepositoryHygieneTests|RealNamesTests|PrivateWordsTests'`; PASS.
- [ ] **Step 4: Commit** `docs: the menu walk in AGENTS.md and the designs (Plan 24)`.

After Task 6: a whole-branch review, then the owner's hardware session items S1–S3 (design §7), each at the owner's go-ahead.
