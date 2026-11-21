# Plan 6 — Remote Menus Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. This repo's workflow (AGENTS.md, Plans 1–5) applies on top: feature branch `feature/plan-6-remote-menus`, strict TDD with a RED commit then a GREEN commit per task, a QA pass per task that re-runs every test and proves new tests with a mutation. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Operate the SDS200's menus from Noctule Scan: mirrored exactly in the Scanner view, and as native Mac lists and text fields in the Mac-style view.

**Architecture:** `NoctuleKit` learns the menu protocol (`ScannerInfo` menu fields, `MSI` → `MenuScreen`, `MSV`). `NoctuleAppCore` gets a UI-free `MenuModel` owned by `StationSession` that holds the current menu and performs every action under the design's safety rules (one user action = one command, re-check before `MSV`, destructive guard, never resend). The Scanner view draws menus from `STS` as it draws any screen; the Mac-style view renders `MenuModel`. The mock scanner gains a small menu tree so all of it is tested on loopback.

**Tech Stack:** Swift 6, SwiftUI + AppKit (macOS app only), Swift Testing, the existing UDP client stack and `MockSDS200`.

**Spec:** `docs/specs/2026-11-10-remote-menus-design.md` (approved by the owner 2026-11-10). §4 of it holds the hardware captures every fixture here is copied from; read it before any task.

## Global Constraints

- **Agents send nothing to the real scanner in this plan** except Task 6's read-only `MSI` hardware test, and only when the owner asks for it. Every other check runs against `MockSDS200` / `noctule-mock-scanner`.
- Only these commands: `KEY,<code>,P`, `STS`, `GSI`/`PSI`, `MSI`, `MSV,,<value>` (reserved field empty). No `MNU`, no `MSB`.
- **One user action sends at most one state-changing command.** Never a key sequence from one action; never an automatic resend of `KEY` or `MSV`. Reads (`STS`, `GSI`, `MSI`) may be retried.
- No state-changing menu command without a user action; nothing in a loop that changes state.
- An input value is never sent if it is empty, longer than `MaxLength`, contains a character outside `EnableKeys`, or contains a comma, CR or LF.
- No real radio names in tracked files: fixtures use the design's sanitized samples and fictional list names (`Lakeview Fire`, `County Roads`, …). `RealNamesTests` must pass.
- `NoctuleKit`, `NoctuleStore`, `NoctuleAppCore` build for iOS: `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build`.
- No SwiftUI `List`, no selectable `Text`, and no sheet/alert in a station window (LESSONS 2026-11-09: sticky first responders; an open sheet blocks quit). Every new focusable control gets `.tracksKeyboardFocus()`.
- Every existing rule still holds: `PSI,0` after `PSI`, TEARDOWN on every exit path, `leakedSessions` empty after each test, the app launched only with `NOCTULE_SETTINGS_DIR` on the mock.
- Update `LESSONS.md` during the work whenever something surprises you.

## Review Focus

Conditions the spec implies but doesn't spell out, most likely first. Each is pinned by a test in the task named.

1. **A double-click, a held Return, or a second click while the first is in flight** → exactly one `MSV` reaches the scanner; the second action fails with `.busy`. (Task 4, `secondActionWhileBusySendsNothing`)
2. **Typed or pasted text with characters the scanner refuses, a comma, or more than `MaxLength`** → the field holds only allowed characters up to the limit; Save is disabled when empty; nothing invalid is ever sent. (Task 4, `sanitizeKeepsOnlyAllowedCharacters`, `setValueRefusesInvalidText`)
3. **The scanner leaves the menu on its own, or someone works the radio's panel, while a confirmation or an entry field is open** → the confirmation/field goes away and nothing is sent; a confirm that arrives late fails with `.menuChanged` or `.notInMenu`. (Task 4, `confirmAfterMenuChangedSendsNothing`; Task 5, `pendingConfirmationClearsWhenContentChanges`)
4. **The session stops or loses the scanner while a menu is open or an action is in flight** → `content` becomes nil, the action throws, and no menu command is sent after `stop()` began. (Task 4, `stopDuringMenuSendsNothingAfter`)
5. **A menu row whose text contains a comma** (a list named `Fire, North`) → `STS` splits on commas, so the mirrored rows are wrong for that screen, but nothing crashes and the Mac-style list (from `MSI`) is still right. (Task 3, `stsWithExtraCommasStillBuildsADisplay`; Task 1, `menuItemNamesKeepCommasAndEntities`)

---

## File map

| File | Responsibility |
|---|---|
| `Sources/NoctuleKit/Status/ScannerInfo.swift` (modify) | `isMenu`, `menuTitle`, `menuIndex`, `menuScreenKind` |
| `Sources/NoctuleKit/Status/MenuScreen.swift` (create) | `MenuScreen`, parsed from `MSI` |
| `Sources/NoctuleKit/Client/ScannerClient.swift` (modify) | `menuScreen()`, `setMenuValue(_:)` |
| `Sources/NoctuleKit/Models/ScannerModel.swift` (modify) | `DestructiveMenuItems`, `ModelProfile.destructiveMenuItems` |
| `Sources/NoctuleMockScanner/MockMenu.swift` (create) | the mock's menu tree, state machine and its `STS`/`GSI`/`MSI` text |
| `Sources/NoctuleMockScanner/MockControlServer.swift`, `MockSDS200.swift`, `MockScannerArguments.swift` (modify) | route `KEY`/`STS`/`GSI`/`PSI`/`MSI`/`MSV` through the menu; drop faults |
| `Sources/NoctuleAppCore/Display/DisplayModel.swift`, `DisplayRefreshPolicy.swift` (modify) | menu rows, underline, soft-key rule; menu refresh timing |
| `Sources/NoctuleAppCore/Menu/MenuModel.swift` (create) | menu state and actions (the later MCP surface) |
| `Sources/NoctuleAppCore/Menu/MenuInput.swift` (create) | input sanitising |
| `Sources/NoctuleAppCore/Session/StationSession.swift` (modify) | owns `menu`, feeds it status, menu-aware display loop |
| `Sources/NoctuleScan/Scanner/DisplayView.swift`, `ScannerIndicators.swift`, `MacControlsBar.swift`, `KeyboardShortcuts.swift` (modify) | no banner, underline, glyph soft keys; Hold/Avoid off in a menu; menu key routing |
| `Sources/NoctuleScan/MacStyle/MacMenuView.swift` (create), `MacStyleView.swift` (modify) | the Mac-style menu |

---

### Task 1: The menu protocol in NoctuleKit

**Files:**
- Modify: `Sources/NoctuleKit/Status/ScannerInfo.swift`, `Sources/NoctuleKit/Client/ScannerClient.swift`, `Sources/NoctuleKit/Models/ScannerModel.swift`
- Create: `Sources/NoctuleKit/Status/MenuScreen.swift`
- Test: `Tests/NoctuleKitTests/ScannerInfoTests.swift`, `Tests/NoctuleKitTests/MenuScreenTests.swift` (create), `Tests/NoctuleKitTests/ScannerClientTests.swift`, `Tests/NoctuleKitTests/ScannerModelTests.swift`
- Docs: `docs/specs/2026-11-08-sds-remote-protocol.md`, `LESSONS.md`

**Interfaces — Produces:**

```swift
// ScannerInfo
public enum MenuScreenKind: Sendable, Equatable { case selection, input }
public var isMenu: Bool            // mode or screen contains "menu", any case (today's DisplayModel rule, moved here)
public var menuTitle: String?      // MenuSummary/@name, untrimmed
public var menuIndex: String?      // MenuSummary/@index, opaque
public var menuScreenKind: MenuScreenKind?  // "menu_selection" → .selection, "menu_input" → .input, else nil

// MenuScreen.swift
public struct MenuScreen: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case select, input, location, error, other(String) }
    public struct Item: Sendable, Equatable, Identifiable {
        public var index: Int; public var name: String; public var value: String?
        public var id: Int { index }
    }
    public struct InputRules: Sendable, Equatable {
        public var maxLength: Int?; public var allowedCharacters: String?; public var addedInformation: String?
    }
    public var title: String?          // root @Name, untrimmed
    public var menuIndex: String?      // root @Index, opaque
    public var kind: Kind              // TypeSelect/TypeInput/TypeLocation/TypeError, else .other(raw); absent → .other("")
    public var value: String?          // root @Value (stale on lists after MSV: never used for lists)
    public var selectedIndex: Int?     // root @Selected
    public var items: [Item]           // MenuItem children in order; one without an integer Index is skipped
    public var input: InputRules?      // first MenuInput child
    public var errorText: String?      // MenuErrorMsg/@Text
    public init(xml root: XMLNode) throws   // MenuScreenError.unexpectedRoot(String) unless root.name == "MSI"
}

// ScannerClient
public func menuScreen() async throws -> MenuScreen        // MSI; .unexpectedResponse if not XML or not <MSI>
public func setMenuValue(_ value: String) async throws     // MSV,,<value>; OK or throws (.rejected / .unexpectedResponse / .timeout)

// ScannerModel.swift
public struct DestructiveMenuItems: Sendable, Equatable {
    public var names: Set<String>; public var prefixes: [String]
    public func contains(_ itemName: String) -> Bool   // trimmed, case-insensitive; exact name or prefix
}
// ModelProfile gains: public let destructiveMenuItems: DestructiveMenuItems
```

SDS200 values (all four models share them for now): names `Clear User Data`, `Reset User Settings`, `Stop All Avoiding`, `Set All Lists Off`, `Set All Lists On`; prefixes `Delete`.

- [ ] **Step 1: Write the failing tests.** Fixtures are the design §4.2–4.3 samples verbatim (with the `<Footer No="1" EOT="1"/>` child).
  - `ScannerInfoTests`: `menuTreeReportsTitleIndexAndKind` (`Mode="Menu tree" V_Screen="menu_selection"`, `<MenuSummary name="Set Scan Selection" index="4293063672" />` → `isMenu`, `menuTitle == "Set Scan Selection"`, `menuIndex == "4293063672"`, `menuScreenKind == .selection`, `channel == nil`, `hasActiveChannel == false`); `menuInputKind` (`menu_input` → `.input`); `scanModeIsNotAMenu` (`trunk_scan` → `!isMenu`, all three nil).
  - `MenuScreenTests`: `selectListWithValues` (the Select Lists to Monitor sample: `kind == .select`, `selectedIndex == 0`, `items[2] == Item(index: 2, name: "Lakeview Fire", value: "On")`, `items[0].value == "Off"`); `omittedItemsKeepTheirIndexes` (items 0…7, 9…15 → `items.map(\.index)` has no 8, count 15); `nameInput` (`kind == .input`, `value == "Custom 9"`, `input?.maxLength == 64`, `allowedCharacters` contains `&`, `"`, `'`, `<`, space, and not `é`); `numberInput` (`value == "30.0"`, `maxLength == 5`, `allowedCharacters == "0123456789."`, `addedInformation == "          (mile)"`); `bareError` (`kind == .error`, `items.isEmpty`, `errorText == nil`); `errorWithMessage` (`errorText` starts with `The scanner is in state that you can't remote control.`); `unknownTypeIsKept` (`MenuType="TypeFuture"` → `.other("TypeFuture")`); `footerIsNotAnItem`; `menuItemNamesKeepCommasAndEntities` (`Name="Fire, North &amp; East"` → `"Fire, North & East"`); `wrongRootThrows`.
  - `ScannerClientTests` (same fake-transport style as the `GSI` tests there): `menuScreenSendsMSI` (wire bytes `MSI\r`; reply `MSI,<XML>,` + document → the parsed screen); `setMenuValueSendsReservedFieldEmpty` (wire `MSV,,14\r` and `MSV,,Custom 9\r`; reply `MSV,OK`); `setMenuValueRejected` (`MSV,NG` → `ScannerClientError.rejected`); `setMenuValueRefusesComma` (`"a,b"` → `ScannerCommandError.invalidArgument`, nothing sent).
  - `ScannerModelTests`: `destructiveNamesMatchLoosely` (`" clear user data "`, `"Delete System"`, `"delete"` → true; `"Set All Lists"`, `"Review Avoids"`, `"Undelete"` → false).
- [ ] **Step 2: Run** `swift test --filter NoctuleKitTests` → the new tests fail to compile or fail. Commit RED.
- [ ] **Step 3: Implement** the interfaces above. `DisplayModel.isMenu` keeps working (Task 3 moves it onto `info.isMenu`).
- [ ] **Step 4: Run** `swift test --filter NoctuleKitTests` → all pass.
- [ ] **Step 5: Docs.** Protocol notes: add a "Menus" section with the design §4 findings and samples (`MSI`, `MSV`, the `STS`/`GSI` menu shapes, lost datagrams), move `MSI` into the safe read-only probes, mark open item 2's menu part answered, note `MNU`/`MSB` untried. `LESSONS.md` (Scanner section, dated 2026-11-10): `MSI` describes the whole menu and `MSV,,<value>` acts on the current screen; an action can leave the menu; about 1 UDP command in 12 went unanswered and the unanswered `KEY` had not taken effect, so never resend a state-changing command; `MSI` omits items it can't remote-control and answers `TypeError` on them.
- [ ] **Step 6: Commit GREEN** (`git add Sources/NoctuleKit Tests/NoctuleKitTests docs/specs/2026-11-08-sds-remote-protocol.md LESSONS.md`).

---

### Task 2: Menus in the mock scanner

**Files:**
- Create: `Sources/NoctuleMockScanner/MockMenu.swift`
- Modify: `Sources/NoctuleMockScanner/MockControlServer.swift`, `MockSDS200.swift`, `MockScannerArguments.swift`
- Test: `Tests/NoctuleMockScannerTests/MockMenuTests.swift` (create), `MockSDS200Tests.swift`, `MockScannerArgumentsTests.swift`
- Docs: `AGENTS.md` (mock section)

**Interfaces — Consumes:** Task 1's `ScannerClient.menuScreen()`, `setMenuValue(_:)`, `ScannerInfo` menu fields.

**Interfaces — Produces:**

```swift
// MockFaults gains (each fires once, then clears itself):
public var dropNextReply: String?     // command name, e.g. "KEY": the command is carried out, its reply is not sent
public var dropNextRequest: String?   // command name: the datagram is logged and otherwise ignored
public var dropCount: Int             // how many matching datagrams the drop fault covers before clearing; default 1
// MockSDS200 gains:
public var isInMenu: Bool { get async }
public var menuPath: [String] { get async }          // titles from the top, [] outside a menu
public var menuActions: [String] { get async }       // every state change the menu carried out, in order, e.g. "toggle Lakeview Fire Off", "set Set Range 31.0", "run Clear User Data"
// CLI: --fault drop-reply=NAME[:N], --fault drop-request=NAME[:N]   (N = dropCount, default 1)
```

The mock's tree (fictional lists; item names otherwise as the firmware's). Indexes are positions; `†` = on the screen (`STS`) but omitted from `MSI`:

```
--- M E N U ---  (title text "       --- M E N U ---")
0 Set Scan Selection
    0 Select Lists to Monitor     on/off list, 12 items: Full Database:Off, Search with Scan:Off,
                                  Lakeview Fire, County Roads, Harbor Patrol, Transit, Airport Ops,
                                  Public Works, Parks, Marine, Rail Yard, Events  (all On)
    1 Set All Lists Off           action
    2 Set All Lists On            action
1 Set Your Location
    0 Set Range                   number input "30.0", MaxLength 5, EnableKeys "0123456789.",
                                  AddedInformation "          (mile)"; saving leaves the menu
2 Search for...
    0 Edit Custom                 title "Select Custom": Custom 0 … Custom 9 (10 items)
        each → 0 Edit Name        text input, MaxLength 64, EnableKeys as design §4.3; saving returns to the bank
3 Analyze †                       inside: System Status, LCN Finder; MSI there = TypeError with the design's message
4 Display Options
    0 Set ID Format (P25/Mot)     pick-one: Decimal Format (current), Hex Format; choosing returns to Display Options
5 Settings
    0 Clear User Data             action
```

Behaviour, each as design §4 records it:
- `KEY,M,P`: outside a menu → enter at the top, highlight 0; inside → up one level (an entry screen is cancelled unchanged); at the top it stays. `KEY,>,P`/`KEY,<,P` move the highlight and wrap; the nine-row window scrolls one row at a time. `KEY,E,P` opens/chooses/toggles/runs the highlighted row. `KEY,L,P` leaves the menu from any depth. Outside a menu `KEY` behaves as today.
- `STS` in a menu: `STS,1111111111,` + ten text/mask pairs + `1,1,0,0,,,0,OFF,3`. Title mask 30 × `_`; highlighted row mask 30 × `*`; on/off rows `name` padded to 26 + `:On `/`:Off`; entry screens as design §4.2 (value line with `*` in column 1; number entry's units on line 5; name entry's line 10 = the byte run `C8 C8 C8 C9 CA CB CC CD CE 20 D8 D0 D9 DA DB DC DD DE DF D0 20 D0 D1 D2 D3 D4 D5 D6 D6 D6`, sent as raw bytes).
- `GSI`/`PSI` in a menu: design §4.2's document (`Mode="Menu tree"`, `V_Screen` by screen kind, `MenuSummary`), with a fixed fictional `index` per screen.
- `MSI`: design §4.3's shapes, one datagram, with the `Footer`. Outside a menu: bare `TypeError`.
- `MSV,,<v>`: on a list, `<v>` must be a listed `Index` (else `MSV,NG`); effect as `E` on that item, and `Selected` becomes that index while the `STS` highlight does **not** move. On an input screen, `<v>` must satisfy `MaxLength`/`EnableKeys` and be non-empty (else `MSV,NG`). Outside a menu, or on the Analyze screens: `MSV,NG`. **Assumptions, to state in the type comment:** every `MSV,NG` case (hardware rejection is untried), and `MSV` on an action item running it without a prompt.
- Digit and `.` keys on the number entry replace the value on the first key and append afterwards; `E` saves. (Assumption; noted.)
- `powerCycle()` and `MSM,1` leave the menu and restore the tree's initial values.

- [ ] **Step 1: Write the failing tests** (`MockMenuTests`, through `ScannerClient` over `UDPTransport` like `MockSDS200Tests`; add a small `withMock { mock, client in … }` helper to `TestSupport.swift` that starts the mock, connects a client, and stops both in every path).
  - `menuKeyEntersAndAvoidLeaves`: `press(.menu)` → `scannerInfo().isMenu`, `menuTitle == "       --- M E N U ---"`; `press(.avoid)` → `!isMenu`, and the next `scannerInfo()` has a channel again when the scenario is mid-transmission.
  - `stsListScreenMatchesHardwareShape`: top menu `displayStatus()` → 10 lines, every `sizeFlag == "1"`, `lines[0].highlightMask == String(repeating: "_", count: 30)`, `lines[1].text == "Set Scan Selection            "`, `lines[1].highlightMask == String(repeating: "*", count: 30)`, `lines[4].text == "Analyze                       "`, `trailing == ["1","1","0","0","","","0","OFF","3"]`.
  - `scrollWrapsAndWindowScrollsByOne`: in Select Lists to Monitor, 9 × `.scrollRight` → rows 2…10 of the list shown, highlight on the last row; 3 more → wraps to the first.
  - `msiListsEveryItemAndOmitsAnalyze`: top `menuScreen()` → names `["Set Scan Selection","Set Your Location","Search for...","Display Options","Settings"]`, indexes `[0,1,2,4,5]`.
  - `msvOpensSubmenuAndPicksValue`: `setMenuValue("4")`, `("0")`, `("1")` → `menuPath == ["       --- M E N U ---","Display Options"]`, reopening shows `selectedIndex == 1`, `menuActions.last == "set Set ID Format (P25/Mot) Hex Format"`.
  - `msvTogglesOnOffItemAndStays`: in Select Lists to Monitor `setMenuValue("11")` → `items[11].value == "Off"`, `selectedIndex == 11`, title unchanged, and `displayStatus().lines[1].highlightMask` still all `*` (highlight didn't move).
  - `msvSetsNameAndReturnsToParent`; `msvSetsRangeAndLeavesTheMenu` (`!isInMenu` afterwards; reopening shows `"31.0"`).
  - `entryScreensMatchHardwareShape`: Set Range → `menuScreenKind == .input`, `lines[1].text` starts `30.0`, `lines[1].highlightMask` is `*` + 29 spaces, `lines[4].text == "          (mile)              "`, `lines[9].text` blank; Edit Name → `lines[9].text.count == 30` and contains no ASCII letter.
  - `menuCancelsEntryUnchanged`; `analyzeAnswersTypeError` (`kind == .error`, `errorText` non-nil; `scannerInfo().menuScreenKind == .selection`); `msiOutsideMenuIsBareError`.
  - `msvRejections`: outside a menu, index 3 at the top (Analyze), index 99, `"12.5.5.5"` (8 characters, over `MaxLength` 5) on Set Range, `"é"` on Edit Name → each throws `.rejected`, and `menuActions` unchanged.
  - `actionItemsRun`: `setMenuValue` on Clear User Data → `menuActions.last == "run Clear User Data"`.
  - `dropNextReplyStillActs`: faults `dropNextReply: "KEY"`; `press(.scrollRight)` throws `.timeout`; the highlight moved; the fault cleared (next press answers).
  - `dropNextRequestDoesNothing`: `dropNextRequest: "MSV"`; `setMenuValue("0")` throws `.timeout`; `menuPath` unchanged.
  - `psiPushesMenuStateAndNoHits`: with a push running, enter the menu during a transmission → pushes report `isMenu` and `hasActiveChannel == false`.
  - `MockScannerArgumentsTests`: `--fault drop-reply=KEY`, `drop-request=MSV` and `drop-request=MSI:2` parse; an empty name or a count below 1 is an error.
- [ ] **Step 2: Run** `swift test --filter NoctuleMockScannerTests` → new tests fail. Commit RED.
- [ ] **Step 3: Implement.** `MockMenu` is a value type holding the tree, the path, per-screen highlight and window top, and the action log, with `mutating func key(_:) -> Bool`, `mutating func setValue(_:) -> Bool`, `func statusFields() -> Data`, `func scannerInfoXML() -> String`, `func msiXML() -> String`; `ControlCore.handle` consults it before today's cases. The `STS` reply must be built as bytes (the glyph row isn't UTF-8).
- [ ] **Step 4: Run** `swift test --filter NoctuleMockScannerTests` → all pass, including the untouched hazard and fault tests.
- [ ] **Step 5: Docs.** AGENTS.md mock section: the mock speaks `MSI`/`MSV` and has a menu tree; the two new faults; which menu behaviours are assumptions.
- [ ] **Step 6: Commit GREEN.**

---

### Task 3: Menus on the mirrored display (Scanner view)

**Files:**
- Modify: `Sources/NoctuleAppCore/Display/DisplayModel.swift`, `DisplayRefreshPolicy.swift`, `Sources/NoctuleAppCore/Session/StationSession.swift` (display loop only), `Sources/NoctuleScan/Scanner/DisplayView.swift`, `ScannerIndicators.swift`
- Test: `Tests/NoctuleAppCoreTests/DisplayModelTests.swift`, `DisplayRefreshPolicyTests.swift`, `StationSessionControlTests.swift`, `Tests/NoctuleScanTests/ScannerViewHelpersTests.swift`

**Interfaces — Consumes:** `ScannerInfo.isMenu`, `menuScreenKind`; the mock's menus.

**Interfaces — Produces:**

```swift
// DisplaySegment gains:
public var underlined: Bool                      // mask character "_" ; init(text:highlighted:underlined: = false)
// DisplayModel: isMenu == info?.isMenu ?? false.
//   Soft-key row rule: not a menu → last line (today). Menu + .input → last line. Menu otherwise → none: every line is a row, softKeys == [].
// SoftKey gains:
public var isGlyph: Bool                         // the label has no printable ASCII; label is then ""
// For an input screen the soft-key row is split by column ranges 0..<9, 10..<20, 21..<30 (the scan screen's mask widths),
// so three keys exist even when the labels are glyphs or blank; a blank group gives label "" and isGlyph == false.
// DisplayRefreshPolicy gains:
public var menuMinInterval: Duration = .milliseconds(200)
public var menuIdleInterval: Duration = .seconds(2)
public func nextFetch(lastFetch:lastKeyReply:changed:now:inMenu: Bool) -> ContinuousClock.Instant
//   inMenu: earliest = lastFetch + menuMinInterval; a change or a key reply since lastFetch → max(reply + afterKey, earliest) (a change with no reply → earliest); else lastFetch + menuIdleInterval.
//   !inMenu: exactly today's result. The old four-argument overload stays and means inMenu: false.
// DisplayRefreshPolicy.significantChange also returns true when menuTitle, menuIndex or menuScreenKind differ.
// StationSession (internal, for Task 4):
func noteMenuCommandReply(at: ContinuousClock.Instant = .now)   // same effect as noteKeyReply: the display is re-read promptly
```

- [ ] **Step 1: Write the failing tests.**
  - `DisplayModelTests`: `menuListHasNoSoftKeyRow` (the design §4.2 list `STS` + menu info → `rows.count == 10`, `softKeys.isEmpty`, `rows[1].segments == [DisplaySegment(text: "Manage Quick Key Status       ", highlighted: true)]`); `titleMaskUnderlines` (`rows[0].segments.first?.underlined == true`, `highlighted == false`); `inputScreenKeepsSoftKeyRow` (name-entry `STS` with the glyph bytes decoded as U+FFFD + `menu_input` info → `rows.count == 9`, `softKeys.count == 3`, all `isGlyph`, labels empty; cursor: `rows[1].segments[0] == DisplaySegment(text: "C", highlighted: true)`); `numberEntryHasThreeBlankSoftKeys`; `scanScreenUnchanged` (existing fixture: same rows and soft keys as before, `isGlyph == false`); `stsWithExtraCommasStillBuildsADisplay` (a list `STS` whose row 3 text holds a comma, so the reply has two extra fields: `DisplayStatus(fields:)` doesn't throw and `DisplayModel` has 10 rows). Update the three existing `isMenu` tests to the moved rule (same expectations).
  - `DisplayRefreshPolicyTests`: `menuKeyReplyFetchesWithoutTheOneSecondFloor` (lastFetch = t, reply at t+0.3 s, `inMenu: true` → t+0.45 s; same inputs `inMenu: false` → t+1 s); `menuNeverFasterThanMenuMinInterval` (reply at t+0.01 s → t+0.2 s); `menuIdleRefreshesEveryTwoSeconds`; `menuTitleChangeIsSignificant`; `fourArgumentOverloadMatchesNotInMenu`.
  - `StationSessionControlTests` (mock): `menuScreenIsMirrored` — connected session, `session.press(.menu)` → within 2 s `session.display?.isMenu == true`, `rows.count == 10`, first row text contains `M E N U`; `session.press(.scrollRight)` → within 1 s the highlighted row is row 2; `session.press(.avoid)` → `display?.isMenu == false`. `unansweredKeyIsNotResent` — fault `dropNextRequest: "KEY"`, `press(.scrollRight)`, wait 3 s → the mock's `receivedCommands` holds exactly one `KEY,>,P` since the press, and the highlight didn't move.
  - `ScannerViewHelpersTests`: replace the `menuBanner` copy test with `softKeyTitle` (below).
- [ ] **Step 2: Run** `swift test --filter "NoctuleAppCoreTests|NoctuleScanTests"` → new tests fail. Commit RED.
- [ ] **Step 3: Implement.** The display loop passes `inMenu: info?.isMenu ?? false`. `DisplayView`: delete `menuBanner` and `ScannerCopy.menuBanner`; draw rows whenever a display exists; underlined segments get `.underline()`; soft keys use `static func softKeyTitle(_ key: SoftKey?) -> String` → `"•"` for a glyph key, the capitalised label otherwise, `" "` when nil or blank; glyph keys' accessibility label and help stay `"Soft key N"`.
- [ ] **Step 4: Run** `swift test --filter "NoctuleAppCoreTests|NoctuleScanTests"` and the iOS build → pass.
- [ ] **Step 5: Commit GREEN.**

---

### Task 4: `MenuModel` — menu state and actions (NoctuleAppCore)

**Files:**
- Create: `Sources/NoctuleAppCore/Menu/MenuModel.swift`, `Sources/NoctuleAppCore/Menu/MenuInput.swift`
- Modify: `Sources/NoctuleAppCore/Session/StationSession.swift`
- Test: `Tests/NoctuleAppCoreTests/MenuModelTests.swift` (create), `MenuInputTests.swift` (create), `SessionTestSupport.swift`

**Interfaces — Consumes:** Tasks 1–3 (`ScannerClient.menuScreen/setMenuValue/press/scannerInfo`, `MenuScreen`, `DestructiveMenuItems`, mock menus and drop faults, `noteMenuCommandReply`).

**Interfaces — Produces:**

```swift
public enum MenuContent: Equatable, Sendable {
    case list(MenuScreen)        // kind .select with at least one item
    case entry(MenuScreen)       // kind .input with input rules
    case mirrored                // anything else while the scanner is in a menu: draw session.display
}
public enum MenuActionError: Error, Equatable, Sendable {
    case notConnected, notInMenu, busy
    case menuChanged                       // the re-check before MSV didn't match; nothing was sent
    case needsConfirmation(itemName: String)   // destructive item without confirmedDestructive; nothing was sent
    case invalidValue                      // empty, too long, a disallowed character, a comma/CR/LF; nothing was sent
    case rejected(String)                  // the scanner answered something other than OK
    case noAnswer                          // a command or the reads around it went unanswered; state was re-read where possible
}
public enum MenuInput {
    public static func sanitize(_ text: String, rules: MenuScreen.InputRules) -> String   // drops disallowed chars, commas, CR/LF; truncates to maxLength
    public static func isValid(_ text: String, rules: MenuScreen.InputRules) -> Bool     // non-empty and unchanged by sanitize
}
@MainActor @Observable public final class MenuModel {
    public private(set) var content: MenuContent?      // nil = the scanner is not in a menu (or not connected)
    public private(set) var breadcrumb: [String]       // trimmed titles seen on the way down; ends with the current title
    public private(set) var isBusy: Bool               // an action or its re-read is in flight
    public private(set) var lastError: MenuActionError? // of the latest action; cleared when the next one starts
    public var isInMenu: Bool { content != nil }

    // Every action returns the content after it (nil = the scanner left the menu) or throws MenuActionError.
    @discardableResult public func enter() async throws -> MenuContent?                          // KEY M; throws nothing if already in a menu (re-reads)
    @discardableResult public func choose(_ item: MenuScreen.Item, on screen: MenuScreen,
                                          confirmedDestructive: Bool = false) async throws -> MenuContent?
    @discardableResult public func setValue(_ text: String, on screen: MenuScreen) async throws -> MenuContent?
    @discardableResult public func back() async throws -> MenuContent?                           // KEY M (also cancels an entry)
    @discardableResult public func exit() async throws -> MenuContent?                           // KEY L
    @discardableResult public func press(_ key: FrontPanelKey,
                                         confirmedDestructive: Bool = false) async throws -> MenuContent?   // mirrored screens
    @discardableResult public func refresh() async throws -> MenuContent?                        // reads only
    public func isDestructive(_ itemName: String) -> Bool
}
// StationSession gains:  public let menu: MenuModel
```

Rules the implementation must follow (design §4.6, §5.3–5.5):

- **State source.** `content` is nil unless the session is `.connected` and the latest `ScannerInfo.isMenu`. On entering a menu, on a change of `menuTitle`/`menuIndex`/`menuScreenKind` in a push, after every action, and every `refreshInterval` (2 s, internal constant) while in a menu and idle, read `MSI` and map: `.select` with items → `.list`; `.input` with rules → `.entry`; everything else, a parse failure, or `MSI` unanswered after 2 tries → `.mirrored`.
- **Breadcrumb.** Trimmed titles. A new title appends; a title already in the path truncates back to it; leaving the menu clears it; joining mid-menu starts at the current title. The top menu's title shows as `Menu`.
- **Every action**: throws `.notConnected` unless connected; `.notInMenu` unless in a menu (`enter` excepted: it requires *not* being in one, and simply refreshes if already in); `.busy` if `isBusy`. Sets `isBusy` for its whole duration, including the re-read.
- **`choose`**: `.needsConfirmation` first if `isDestructive(item.name) && !confirmedDestructive`. Then read `MSI` and require `kind == .select`, same `menuIndex` as `screen`, and an item with the same `index` **and** `name`; otherwise `.menuChanged` (and `content` updates to what was read). Then one `MSV,,<index>`.
- **`setValue`**: `.invalidValue` unless `MenuInput.isValid(text, rules:)`. Then read `MSI` and require `kind == .input` and the same `menuIndex`; otherwise `.menuChanged`. Then one `MSV,,<text>`.
- **`press`** (for `.mirrored` content): `.needsConfirmation(itemName:)` when `key == .enterYes`, `!confirmedDestructive`, and the highlighted row of `session.display` (the row with a fully highlighted segment; an on/off suffix `:On`/`:Off` stripped; trimmed) is destructive. Then one `KEY`.
- **After the one command**: OK → re-read (`GSI` then, if still in a menu, `MSI`), call `session.noteMenuCommandReply()`, return the new content. A non-OK reply → re-read, throw `.rejected`. No reply → **do not resend**; re-read; throw `.noAnswer`. If the re-read itself goes unanswered, `content` stays as it was and the periodic refresh keeps trying.
- **Session lifecycle**: `stop()`, `suspend()`, a failed session, or a restart clear `content` and `breadcrumb`, cancel the refresh loop, and make in-flight actions throw `.notConnected` without sending anything further. `MenuModel` reaches the client only through the runner's `control()` (nil once stop begins), like the key queue.
- Menu keys from the Scanner view keep going through `StationSession.press` and the `KeyPressQueue`, unchanged.

- [ ] **Step 1: Write the failing tests.** `MenuModelTests` run a connected `StationSession` on `MockSDS200` (existing `SessionTestSupport` helpers; add `func menuCommands(_ mock:) async -> [String]` returning the mock's received `KEY`/`MSV`/`MSI` commands since a mark).
  - `enterShowsTheTopList`: `enter()` → `.list`, 5 items, `breadcrumb == ["Menu"]`; `session.menu.isInMenu`.
  - `chooseOpensSubmenuWithOneMSV`: choose "Display Options" → `.list` titled `Display Options`; commands since the mark are `MSI`, `MSV,,4`, then reads only; `breadcrumb == ["Menu", "Display Options"]`.
  - `toggleUpdatesTheItem`: in Select Lists to Monitor choose `Lakeview Fire` → returned list has it `Off`; `mock.menuActions.last == "toggle Lakeview Fire Off"`.
  - `setValueSavesAName`; `setRangeLeavesTheMenu` (returns nil; `content == nil`; `breadcrumb.isEmpty`).
  - `backAndExit`: `back()` from Display Options → top list, `breadcrumb == ["Menu"]`; `exit()` → nil.
  - `panelUseIsFollowed`: a second, raw `ScannerClient` on the mock (standing in for the radio's panel) presses `.menu` while the model is idle and not in a menu → within 3 s `content` is `.list`; then the raw client presses `.scrollRight` twice and `.enterYes` → within 3 s the model shows `Search for...`.
  - `analyzeIsMirrored`: raw client opens Analyze → `content == .mirrored`; `press(.menu)` on the model → back to `.list`.
  - `destructiveNeedsConfirmation`: choose `Clear User Data` → throws `.needsConfirmation(itemName: "Clear User Data")`, no `MSV` sent, `menuActions` unchanged; with `confirmedDestructive: true` → `menuActions.last == "run Clear User Data"`.
  - `mirroredEnterOnDestructiveRowNeedsConfirmation`: unit-level, with a `DisplayModel` whose highlighted row is `Set All Lists Off` → `press(.enterYes)` throws `.needsConfirmation`; `press(.scrollRight)` doesn't.
  - `confirmAfterMenuChangedSendsNothing`: hold a `screen`/`item` from Settings; the raw client presses `.menu` (back to top); `choose(item, on: screen, confirmedDestructive: true)` → `.menuChanged`, no `MSV`, `content` is the top list.
  - `sameIndexDifferentNameIsMenuChanged`: a `screen` from Display Options and its item 0, while the scanner is on Settings (same index 0, other name and menu index) → `.menuChanged`.
  - `secondActionWhileBusySendsNothing`: start `choose` (mock reply delay 300 ms via `Options.replyDelays["MSV"]`), call `choose` again at once → the second throws `.busy`; exactly one `MSV` received.
  - `lostReplyIsNotResent`: `dropNextReply: "MSV"`, toggle `Transit` → throws `.noAnswer`; exactly one `MSV` received; `content` shows `Transit` `Off` (the re-read saw it).
  - `lostRequestIsNotResent`: `dropNextRequest: "MSV"` → `.noAnswer`; one `MSV`; `Transit` still `On`.
  - `rejectedValueSurfaces`: bypass validation with a `screen` whose rules allow 10 chars for Set Range, value `"12.5.5.5"` → `.rejected`; content re-read.
  - `setValueRefusesInvalidText`: `""`, 6 characters, `"12a"`, `"1,2"` on Set Range → each `.invalidValue`, zero commands sent.
  - `msiUnansweredFallsBackToMirrored`: `dropNextRequest: "MSI", dropCount: 2` set just before entering → `.mirrored`; a later refresh → `.list`.
  - `stopDuringMenuSendsNothingAfter`: in a menu with a `choose` delayed 300 ms, `await session.stop()` → the action throws; `content == nil`; after the stop's `PSI,0` the mock received no `KEY`/`MSV`; `leakedSessions` empty. (The scanner is left in its menu: stopping must not send Avoid.)
  - `notConnectedAndNotInMenuErrors`.
  - `MenuInputTests`: `sanitizeKeepsOnlyAllowedCharacters` (`"Fire, é North\n"` with the name rules → `"Fire  North"`); `sanitizeTruncates` (70 chars → 64); `numbersOnly` (`"3x1.0"` → `"31.0"`); `emptyIsInvalid`; `nilRulesAllowAnythingButCommaAndNewlines`.
- [ ] **Step 2: Run** `swift test --filter NoctuleAppCoreTests` → new tests fail. Commit RED.
- [ ] **Step 3: Implement** `MenuInput`, `MenuModel`, and the session wiring: `StationSession` creates `menu` in its init, forwards each status (`statusArrived`) and phase change to it, and hands it the runner's `control()` on connect.
- [ ] **Step 4: Run** `swift test --filter NoctuleAppCoreTests`, then the full `swift test`, then the iOS build → pass.
- [ ] **Step 5: Commit GREEN.**

---

### Task 5: The Mac-style menu

**Files:**
- Create: `Sources/NoctuleScan/MacStyle/MacMenuView.swift`
- Modify: `Sources/NoctuleScan/MacStyle/MacStyleView.swift`, `Sources/NoctuleScan/Scanner/MacControlsBar.swift`, `Sources/NoctuleScan/Scanner/KeyboardShortcuts.swift`
- Test: `Tests/NoctuleScanTests/MacMenuTests.swift` (create), `KeyboardMonitorTests.swift`, `MacStyleTests.swift`

**Interfaces — Consumes:** `StationSession.menu` (`MenuModel`, `MenuContent`, `MenuActionError`), `MenuInput`, `DisplayModel` rows.

**Interfaces — Produces (view logic, all unit-tested without a window):**

```swift
enum MacMenuCommand: Equatable { case moveUp, moveDown, activate, back }
/// Per-window: set while the Mac-style menu is on screen and no text field has focus. The key monitor asks it first.
@MainActor final class MacMenuKeys { var handler: ((MacMenuCommand) -> Void)?; var isActive: Bool { handler != nil } }
// KeyRouting.Decision gains: case menu(MacMenuCommand)
// KeyRouting.decide gains a parameter `macMenuActive: Bool` (default false). When true and !focusElsewhere:
//   ↑ → .menu(.moveUp), ↓ → .menu(.moveDown), Return/Enter → .menu(.activate), Esc → .menu(.back) (repeats allowed for ↑/↓ only, others swallowed);
//   any other chord the key map maps to a scanner key → .swallow; unmapped chords and menu key equivalents → .pass.
@MainActor @Observable final class MacMenuState {
    var selection: Int?                      // item index selected locally; set from screen.selectedIndex when the screen changes
    var draft: String                        // entry text; set from screen.value when the screen changes
    var pendingConfirmation: PendingConfirmation?   // cleared whenever MenuModel.content changes
    struct PendingConfirmation: Equatable { var itemName: String; var item: MenuScreen.Item?; var screen: MenuScreen? }
    func sync(with content: MenuContent?)
    func move(_ delta: Int, in screen: MenuScreen)     // clamps, no wrap
}
enum MacMenuText {
    static func title(_ content: MenuContent?, breadcrumb: [String]) -> String
    static func breadcrumbText(_ breadcrumb: [String]) -> String?        // "Menu › Display Options"; nil for a single element
    static func activateTitle(_ item: MenuScreen.Item?) -> String        // "Toggle" when the item has a value, else "Open"
    static func unit(_ rules: MenuScreen.InputRules) -> String?          // addedInformation trimmed; nil when blank
    static func counter(_ draft: String, rules: MenuScreen.InputRules) -> String?   // "8 of 64 characters"
    static func confirmationMessage(itemName: String) -> String          // "“Clear User Data” can't be undone from here. Send it to the scanner?"
    static func errorMessage(_ error: MenuActionError) -> String?
    static let pausedNote = "Scanning is paused while the scanner is in a menu."
    static let mirroredNote = "The scanner doesn't describe this screen. It is shown as the scanner draws it."
}
```

Error copy (exact): `.menuChanged` → `The menu changed on the scanner. Nothing was sent.`; `.noAnswer` → `The scanner didn't answer. Check the menu before trying again.`; `.rejected` → `The scanner refused that.`; `.invalidValue` → `That value isn't allowed here.`; `.busy`, `.needsConfirmation`, `.notInMenu`, `.notConnected` → nil.

Layout (mockups: `.superpowers/brainstorm/31942-1794329564/content/mac-menu-v2.html` and `mac-menu-layout.html` option A; git-ignored, on the owner's Mac):

- `MacStyleView`: when `session.menu.isInMenu`, `MacMenuView` replaces the breadcrumb/headline/chips block; the divider, `MacControlsBar` and the Scanner group box stay below. When not in a menu, a **Menu** button (`Label("Menu", systemImage: "list.bullet")`, `.tracksKeyboardFocus()`, enabled only when connected) sits at the leading end of the row above the divider and calls `menu.enter()`.
- `MacControlsBar`: Hold and Avoid are disabled while `session.menu.isInMenu` (in both views; the Scanner view's keypad Avoid still works).
- `MacMenuView`, `.list`: breadcrumb text, large title, then a bordered `ScrollView` + `LazyVStack` of rows (name leading; value trailing, `On` emphasised; the selected row in accent colour; scrolls the selection into view). Click selects; double-click activates. Footer: **Back**, **Exit Menu**, the default button titled by `activateTitle`, a key hint, and `pausedNote`. A standing hint under the list: `Some items appear only in the Scanner view.` when the mirrored display has more non-blank rows than the list has items and the list has fewer than 9 items; never otherwise.
- `.entry`: title, a `TextField` bound through `MenuInput.sanitize` (focused on appear, `.tracksKeyboardFocus()`), `unit`, `counter`; **Cancel** (`menu.back()`), **Save** (default; disabled unless `MenuInput.isValid`). Return in the field saves; Esc cancels.
- `.mirrored`: the display's rows in the monospaced style of `DisplayView` (reuse its row drawing by extracting it into a shared `DisplayRowsView`), `mirroredNote`, three soft-key buttons, **Back**, **Exit Menu**; `MacMenuCommand`s map to `menu.press(.scrollLeft)`, `.scrollRight`, `.enterYes`, and `menu.back()`.
- Confirmation: when an action throws `.needsConfirmation`, the footer is replaced inline by `confirmationMessage`, **Cancel** (default, Esc) and a destructive-role **Send to Scanner** that repeats the action with `confirmedDestructive: true`. Not a sheet, not an alert.
- While `menu.isBusy`, rows and buttons are disabled; `errorMessage(menu.lastError)` shows as one line above the footer.

- [ ] **Step 1: Write the failing tests.**
  - `KeyboardMonitorTests`: `macMenuTakesArrowsReturnAndEscape` (each chord → the `.menu` decision with `macMenuActive: true`, and today's decision with `false`); `macMenuSwallowsOtherScannerKeys` (a chord mapped to `.avoid` → `.swallow`); `macMenuPassesMenuEquivalentsAndUnmapped` (⌘Q, an unmapped chord → `.pass`); `textFieldFocusWins` (`focusElsewhere: true` → `.pass` for Return and Esc); `onlyArrowsRepeatInMacMenu`.
  - `MacMenuTests`: `selectionFollowsTheScannerOnNewScreen` (`sync` with `selectedIndex: 13` → `selection == 13`; a re-read of the *same* menu index keeps a locally moved selection unless the item is gone); `moveClampsAtEnds`; `moveSkipsNothingAcrossIndexGaps` (items 7, 9: down from 7 → 9); `draftFollowsNewEntryScreen`; `pendingConfirmationClearsWhenContentChanges`; `activateTitles`; `breadcrumbTextJoins`; `unitTrims` (`"          (mile)"` → `"(mile)"`); `counterText`; `errorMessages` (the four strings above, exact); `standingHintRule`.
  - `MacStyleTests`: `holdAndAvoidDisabledInMenu` (the bar's enablement helper, given `inMenu: true`).
- [ ] **Step 2: Run** `swift test --filter NoctuleScanTests` → new tests fail. Commit RED.
- [ ] **Step 3: Implement** the views and wiring. The station window owns one `MacMenuKeys`; `MacMenuView` sets its handler on appear (and clears it on disappear and while the entry field has focus); the key monitor passes `macMenuActive: keys.isActive` to `KeyRouting.decide` and calls the handler for `.menu`.
- [ ] **Step 4: Run** `swift test --filter NoctuleScanTests`, then `scripts/build-app.sh` → pass, builds.
- [ ] **Step 5: Hand run on the mock** (AGENTS.md "To run it on the mock by hand"; `NOCTULE_SETTINGS_DIR` set). This shell can't click, so check what can be seen without input: launch, confirm via `--verbose` that the app sends no `KEY`/`MSV` on its own, send `KEY,M,P` to the mock from a second UDP client (`nc -u`), and confirm in the mock log that the app starts reading `MSI` and reads `STS` at the menu rate; then `KEY,L,P` and confirm `MSI` reads stop. Quit; `leaked-sessions=0`.
- [ ] **Step 6: Commit GREEN.**

---

### Task 6: Lifecycle check, documentation, and the owner's hand checks

**Files:**
- Modify: `Tests/NoctuleCLIIntegrationTests/AppLifecycleIntegrationTests.swift`, `Tests/NoctuleKitTests/HardwareTests.swift`, `AGENTS.md`, `docs/specs/2026-11-08-noctule-scan-design.md` (§3 non-goals line, §7.4), `docs/specs/2026-11-10-remote-menus-design.md` (status line), `LESSONS.md`
- Create: nothing

**Interfaces — Consumes:** everything above.

- [ ] **Step 1: Write the failing tests.**
  - `AppLifecycleIntegrationTests.quitWhileScannerIsInAMenu`: launch the app on the mock as the existing tests do; after `PLAY`, a UDP client sends `KEY,M,P` to the mock; wait until the mock log shows an `MSI` from the app; SIGTERM → exit 0 within 15 s, TEARDOWN and `PSI,0` seen, `leaked-sessions=0`, and **no `KEY` or `MSV` from the app** anywhere in the mock's log.
  - `HardwareTests.menuDescriptionOutsideAMenuIsAnError` (opt-in, `NOCTULE_HARDWARE_TESTS=1`, read-only): `GSI` first; if `isMenu` the test records an issue "scanner is in a menu; skipped" and sends nothing more; otherwise one `MSI` → `kind == .error`. It never sends `KEY` or `MSV`.
- [ ] **Step 2: Run** `swift test --filter AppLifecycleIntegrationTests` → the new test fails only if something is wrong (it may pass at once: say so in the commit; it is a regression guard). Commit.
- [ ] **Step 3: Docs.**
  - AGENTS.md: `MSI` joins the read-only probe list; `MSV` and menu `KEY` presses change scanner state and need the owner's go-ahead each time; the "never one action → several commands, never resend" rule; the station-window paragraph gains the Scanner-view menu mirroring and the Mac-style menu (`MacMenuView`, `MenuModel`, Menu button, Hold/Avoid disabled in a menu, inline confirmation for destructive items); the mock's menus and faults (if Task 2 didn't finish it); `NoctuleAppCore` list gains `MenuModel`.
  - Design doc: §3's "Rendering the scanner's menu system…" non-goal and §7.4's "Out of scope for the MVP" paragraph point to the remote-menus design as done. Remote-menus design: status → "Built in Plan 6".
  - Append to this plan an **Owner hand checks** section (below) and keep it current.
- [ ] **Step 4: Run** the full suite: `swift build`, `swift test`, the iOS build, `scripts/build-app.sh && codesign -dv "build/Noctule Scan.app"`. All pass; `RealNamesTests` passes.
- [ ] **Step 5: Commit.** Then use superpowers:finishing-a-development-branch.

**Owner hand checks** (this shell can't synthesize input; each is run by the owner on the mock first, then, at their choice, on the real scanner):

1. Scanner view: Menu knob push opens the menu on the mirrored screen; the title is underlined; the ninth row is a row, not a soft key; the Scroll knob moves the highlight without lag; E/Yes opens; Menu goes back; Avoid exits.
2. Mac-style: the Menu button opens the list; ↑ ↓ Return Esc, click and double-click work; a long list scrolls natively; toggling a list in Select Lists to Monitor flips its On/Off.
3. Mac-style entry: Edit Name accepts typing, refuses characters the scanner doesn't allow, Save and Esc behave; Set Range saves and the view returns to the channel display.
4. Clear User Data (on the **mock only**) asks first; Cancel sends nothing (mock `--verbose` log).
5. Pressing Menu on the radio's own panel switches the Mac-style view to the menu within about two seconds; Avoid on the panel brings the channel display back.
6. Analyze (Scanner view works; Mac-style shows the mirrored text with its note).
7. Real scanner only, optional, each needing the owner's go-ahead: what a "Confirm?" prompt and a location entry look like in `STS`/`GSI`/`MSI`; record sanitized results in the protocol notes and design §4.

Found by QA, which can't send input to the app; all mock-first:

8. Tab to Back (or use Full Keyboard Access onto any button), then hold Return on an on/off list: the item toggles once.
9. Entry field: a refused character never appears; a paste is cut to the limit; ⌘Z and ⇧⌘Z after a refused character behave and nothing is logged; a dead key or input method composes and commits; Return saves once and Esc cancels once, also when held; after a refused save the field still has focus.
10. After visiting an entry screen, ↑ ↓ ↩ Esc reach the list again; a click selects, a double-click sends once.
11. Mirrored fallback (Analyze on the mock, or the mock's Set Scan Selection driven from the Scanner view): Enter on a destructive row asks; moving the highlight on the radio's panel while the confirmation is up, then Send to Scanner, sends nothing and says the menu changed.
12. Scanner view: whether the title's underline should span the whole row or only the text (today: only the text).
13. Looks: the entry field in the real window (rounded bezel, unit beside it, counter below); whether action rows such as Clear User Data should say "Open" on the default button; whether a highlight moved on the radio's panel should move the Mac list's selection on the same screen (today it doesn't).
14. At launch with a last station set, whether the Stations picker window should also be on screen (QA saw both; this may predate Plan 6).

---

## Self-review notes

- Spec coverage: §5.1 → Tasks 1, 3, 4; §5.2 → Task 3; §5.3 → Tasks 4, 5; §5.4 → Tasks 1, 4, 5; §5.5 → Tasks 3, 4; §6 → Tasks 1, 2, 4; §7 → Global Constraints and Task 6. The optional `noctule menu` CLI is not built (YAGNI); the remaining hardware gaps are hand check 7.
- The design leaves "Yes/No buttons for confirm prompts" out; so does this plan.
