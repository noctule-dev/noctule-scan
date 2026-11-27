# Services and Range open their menu screens — design

Status: design, 2026-11-26, for GitHub issue #14. Plan 24 builds it. Labels as in `README.md`:
**(owner)** the owner's decisions, **(designer's call)** defaults the owner hasn't ruled on,
**[hw]** seen on the owner's radios, **[spec]** Uniden's documents, **[assumed]** neither.

## 1. Why

The Scanner view's **Services** and **Range** buttons don't do what their labels say. They send
`KEY,T,P` and `KEY,R,P`. On the SDS200 and the BCD436HP each one opens Quick Key Navigation and
enters `0`, as a digit does [hw, the owner, 2026-11-26]. Plan 23 also removed Services from the
SDS100, SDS150 and BCD436HP panels, and Range from the SDS150's, so the four panels no longer
match. The owner wants each button to open the screen its label names, and the same buttons, in
the same places, doing the same thing, on every model (issue #14).

Why the keys misbehave: Uniden's key sheets have columns for the BCD536HP and the SDS100 (SDS spec
V2.00) or the BCD436HP (BCDx36HP spec V1.05), and **no SDS200 column** [spec]. `T` (Service Type)
is listed only for the BCD536HP. `R` (Range) is listed for all three, but the BCD436HP manual says
"You can also press RANG … (BCD536HP only)", and the owner saw `KEY,R,P` act like a digit on the
BCD436HP [hw]; on the SDS100 it is untried. The SDS200, SDS150 and BCD436HP manuals reach Service
Types with **Func then Zip** and list no Range key [spec]. So `KEY,T` and `KEY,R` name keys these
radios don't have, whatever the sheets say.

## 2. Goals, non-goals, anti-goals

**Goals**

- **Range** opens the menu screen **Set Range**; **Services** opens **Select Service Types**, on
  the SDS200, SDS100, SDS150 and BCD436HP **(owner, issue #14)**.
- **One button set:** every model's Scanner view shows Zip, Services and Range in the SDS200's
  places, each doing the same thing on every model **(owner, issue #14)**. Plan 23's removal of
  Services (all three handhelds) and Range (the SDS150) is reversed.
- Once there, the screen is an ordinary menu screen in both views: Back and Exit work, Service
  Types is an on/off list and Set Range the number entry in the Mac-style view.

**Non-goals**

- **Nothing in the Mac-style view: no button, and its Services and Range chords do nothing
  (owner, 2026-11-26: "keep it for the scanner view for now"; "I'd like to hold off on the mac
  UI").** The owner will design the Mac-style view's next features (such as direct VFO frequency
  entry) from mock designs first. The walk lives in `MenuModel` (shared code), so a Mac-style
  control later only calls it.
- No native service-type or range editor on `SVC`/`LCR` (§4).
- No other menu shortcuts (a general "go to screen" feature); the walk is built for these two
  paths, as data, but nothing else uses it yet.
- No change to the Zip key (`KEY,Z,P`, a real key on all four).

**Anti-goals** (would make it a failure even if the screen opens)

- A command sent on a screen the walk didn't just read and check: the walk must never `MSV` an
  index on the wrong list.
- A resent command, or a command sent after the session stopped or the walk was abandoned.
- Anything sent while the scanner is already in a menu (`MenuModel`'s rule for entering).
- A `KEY,T` or `KEY,R` sent by anything in the product.

## 3. What was found (2026-11-26)

### 3.1 `SVC` and `LCR` [hw]

Both are documented in the SDS spec V2.00 and the BCDx36HP spec V1.05 ("Get/Set Service Type
Settings", "Get/Set Location and range"). A throwaway probe (never committed) sent `MDL`, then one
`SVC` and one `LCR` with no arguments, at the owner's go-ahead (`LESSONS.md` 2026-11-26):

| Radio | `SVC` | `LCR` |
|---|---|---|
| SDS150 (USB) | 47 fields of `0`/`1` | `dd.dddddd`, `-ddd.dddddd`, range `0.0` |
| SDS100 (USB) | 47 fields | same shape, range `20.0` |
| BCD436HP (USB) | 47 fields | same shape, range `20.0` |
| SDS200 (UDP) | `SVC,ERR` | `LCR,ERR` |

### 3.2 Where the screens sit [spec], partly [hw]

The same names on all four, from the manuals and the BCDx36HP menu tree spec V1.07:

- **Set Range:** top menu › **Set Your Location** › **Set Range**. [hw] on the SDS200 (remote menus
  design §4: `MSI Name="Set Range" MenuType="TypeInput"`, and its parent "Set Your Location") and on
  the BCD436HP (BCD design §3.5: Set Range's `TypeInput`). [assumed] on the SDS100 and SDS150 until
  the hardware session (§7).
- **Select Service Types:** an item of the top menu, an on/off list of service types (SDS200 manual
  "Select Service Types: the scanner displays a list of all service types"). [assumed] on all four
  until §7: no radio has been seen showing it through `MSI`.

### 3.3 Known behaviour the walk relies on [hw]

- `KEY,M,P` outside a menu opens the top menu on the SDS models; `MNU,TOP,` on the BCD436HP
  (remote menus design §4; BCD design §3.5).
- `MSV,,<index>` on a submenu item opens it, on both families (protocol notes; BCD design §3.5).
- `MSI` names each screen (`Name`) and lists its items by `Index` and `Name`; the top menu's name is
  a spaced banner (`--- M E N U ---`, normalised by `MenuModel.breadcrumbTitle` to `Menu`).
- About one UDP command in twelve goes unanswered on the SDS200, request or reply alike.
- On the SDS200, saving Set Range leaves the menu altogether (remote menus design §4.6).

## 4. Approaches

1. **Walk the radio's menu (chosen, owner 2026-11-26: "1 is like building a macro and I am ok with
   that").** Enter the menu, then one `MSV` per level, each only after a re-read shows the expected
   screen. The result is the radio's own screen, in both views, with everything the menu code
   already does. Costs: two or three state-changing commands for one click, which needs a change
   to the menu rule (§5.2); and the paths are per-model data that firmware could rename.
2. **Native controls on `SVC` and `LCR`.** One read and one set per change, within today's rule.
   Rejected: the SDS200 answers both `ERR` (§3.1), so the four models couldn't share one button
   set, and an `LCR` set writes the location back with the range (a precision or format slip
   would move the radio's location unseen).
3. **The radios' own keys** (Func then Zip for Service Types). Rejected: two `KEY` presses for one
   click as well, it covers only Services (no radio has a Range key), and whether the screen it
   opens is one `MSI` describes is unknown.

## 5. Design

### 5.1 The walk

A new `MenuModel` action (name the builder's; here `walk(to:)`) takes a destination (Services or
Range) and runs, under `perform`'s rules (connected, not busy, `isBusy` for its whole length,
`lastError` on failure):

0. **Refused before anything is read** (`.busy`, nothing sent) while the session's key queue holds
   or is sending a press (`KeyPressQueue`), **(designer's call)**: a queued `KEY` could otherwise
   land between a step's check and its `MSV`. §5.4 drops new presses for the walk's length.
1. **Read `GSI`.** Unanswered: throw `.noAnswer`, nothing sent. **In a menu: send nothing**, show
   the menu as `refresh()` would, and throw a new error (name the builder's, e.g.
   `.alreadyInMenu`) so the view can say why nothing happened **(issue #14; designer's call for the
   error)**. **Func on** (`GSI`'s `Property F="On"`; `ScannerInfo` gains it): send nothing and
   throw (e.g. `.functionPending`) **(designer's call)**: on the SDS models Func then Menu is a
   different menu. Any other mode (a hold, search, Close Call, weather, Quick Key Navigation) is
   allowed: the step-3 check stops the walk if the enter doesn't land on the top menu.
2. **Enter**: `KEY,M,P` (`navigation == .keys`) or `MNU,TOP,` (`.menuCommands`), exactly as
   `enter()` sends it, through `command(…)` with its `SendPermit`.
3. For each step of the model's path (§5.3), **the re-read that `command(…)` makes after the previous
   command (`GSI`, then `MSI`) is the step's check**; no separate `MSI` is sent
   **(designer's call)**:
   a. That re-read unanswered (`command` throws `.noAnswer`) or garbled: stop.
   b. **Check it is the expected screen:** `MSI` is a select list whose `Name` (normalised as
      `breadcrumbTitle` does) equals the step's expected screen name, holding exactly one item whose
      name (trimmed) equals the step's item name. **One grace re-read (designer's call):** if the
      screen is still the one the previous command was sent on (the radio slow to redraw), wait
      300 ms and read `GSI` and `MSI` once more (read-only) before judging. Anything else: stop.
   c. **Send `MSV,,<that item's Index>`** once, through `command(…)`. Not `OK` (rejected,
      unanswered, withheld, gone): stop.
4. **Arrival** is judged on `GSI`'s menu name (`MenuSummary name`) from the last `MSV`'s re-read
   (with the same one grace re-read): it must equal the destination's screen name. If not: stop.
   `MSI` then decides only how the screen is shown, as for any screen: a list, an entry, or the
   mirrored text (if, say, Select Service Types answers `TypeError` on some model, the walk still
   succeeded and the user sees the mirrored screen) **(designer's call)**.
5. Success returns the destination's `MenuContent`.

So the wire, for Range on an SDS model: `GSI`, `KEY,M,P`, `GSI`, `MSI`, `MSV,,<i>`, `GSI`, `MSI`,
`MSV,,<j>`, `GSI`, `MSI` (plus a `GSI`/`MSI` pair for each grace re-read); on the BCD436HP the same
with `MNU,TOP,`. Services stops one level sooner.

**Stop** means: no further command, one re-read (as `rereadAfterMismatch` does, so both views show
where the scanner is), and throw (a new `MenuActionError` case naming the step reached, or reuse
`.menuChanged` / `.noAnswer` / `.rejected`; the builder's call, but the view must be able to say
"couldn't open Set Range"). **The scanner is left where it stopped (designer's call):** backing out
would be more commands on a screen the walk no longer trusts; both views show the menu, and the
user's Back or Exit works as usual.

Every command of the walk goes through `MenuModel.command(…)`, so each is decided at the request
slot (`SendPermit`): after a detach, a stop or a suspend, nothing more is written. A walk is one
action: `isBusy` holds for all of it, so another menu action is refused (`.busy`) meanwhile, and a
background refresh's result is dropped as for any action.

### 5.2 The menu rule changes (owner, 2026-11-26)

Today: "One action sends at most one state-changing command, and it is never resent"
(`AGENTS.md`; remote menus design §5.4–§5.5). New wording, for `AGENTS.md`, the remote menus design
and `MenuModel`'s comments:

> One action sends at most one state-changing command and never resends it, **except a menu walk**
> (Services and Range in the Scanner view): it enters the menu and opens one item per level, at
> most one command per step and at most four per walk, each sent only after a re-read shows the
> screen and item the walk expects, none resent, and it stops at the first mismatch, refusal or
> lost reply, leaving the scanner where it is.

The four-command ceiling (enter plus three levels) is a guard in code, not in the data: a path
longer than three items is rejected when the profile is built (or by a test over every profile).

### 5.3 Per-model data

`ModelProfile` gains the two paths (names the builder's), e.g.
`menuPaths: [MenuShortcut: [MenuStep]]`, where a step is `(screen: String, item: String)` and the
destination's own screen name ends the path:

| Destination | Steps (screen › item), all four models | Ends on |
|---|---|---|
| Services | `Menu` › `Select Service Types` | `Select Service Types` |
| Range | `Menu` › `Set Your Location`; `Set Your Location` › `Set Range` | `Set Range` |

Identical today on every model [spec], so one shared value; it lives in the profile so a model or
firmware whose names differ changes only its data. A model with no path for a destination shows
the button disabled (none today).

### 5.4 The Scanner view and the key map

- **Buttons.** The keypad's second row is Zip, Services, Range on every model. Services and Range
  are no longer `FrontPanelKey`s sent through `KeyPressQueue`; clicking one calls the walk (through
  `StationSession`, which owns the `MenuModel`). Enabled when the keypad is enabled and no menu
  action is in flight. Zip stays a key, shown where the model has it (all four).
- **`frontPanelKeys`** drops `T` and `R` from the SDS200's set too (no model has them, §1);
  `StationSession.press` already drops a key the model lacks, so nothing can send `KEY,T` or
  `KEY,R`. The SDS200's encoder caption and every other key are unchanged.
- **Key map.** The Services and Range chords run the walk **only while the Scanner view is
  showing**; in the Mac-style view they do nothing **(owner, 2026-11-26: hold off on the Mac UI;
  the owner will work through mock designs for the Mac-style view first, with future features
  such as direct VFO frequency entry in mind)**. Saved key maps keep
  decoding: the stored identifiers for these two rows (today `"T"` and `"R"`) stay readable; how
  they map onto the new actions is the builder's.
- **Keys during a walk (designer's call):** keypad presses and mapped chords are dropped while a
  walk runs (the keypad shows disabled). A key between a walk's `MSI` check and its `MSV` would
  move the screen under it. The radio's own panel can still do that; that window is accepted, as
  `MenuModel`'s other `MSI`-to-`MSV` windows are (remote menus design §5.4).
- **Feedback.** A failed walk shows its message where the Scanner view shows other action errors
  (or a short transient note under the keypad; the builder's call), e.g. "Already in a menu" or
  "Couldn't open Set Range: the scanner showed Settings". On success nothing extra: the screen shows
  the menu.
- Help text: Services "Open Select Service Types", Range "Open Set Range".

### 5.5 The mock

- `MockMenu`'s fictional tree gains **Select Service Types**, an on/off list (`toggleList`) on the
  top menu, with a handful of Uniden's generic service-type names (Multi-Dispatch, Law Dispatch,
  Fire Dispatch, EMS Dispatch, Custom 1; these are Uniden's category names, not real traffic).
  The tree is shared, so every personality has it; Set Your Location › Set Range is already there.
- Tests need a way to make the walk's checks fail: a tree with a renamed item, or a fault that
  moves the menu between an `MSI` and the `MSV` (builder's call; `MockFaults.rejectNext`,
  `dropNextReply`/`dropNextRequest` already cover the refusal and lost-reply stops).
- The SDS200 mock's `KEY,T`/`KEY,R` behaviour is left alone; tests assert they are never sent.
- Mock assumptions list: Select Service Types' place and its `MSI` shape [assumed].

## 6. Tests

`MenuModel` against `MockSDS200` (`.keys`) and `MockSerialScanner` with `.bcd436hp`
(`.menuCommands`), and the SDS100/SDS150 personalities:

- **Each destination reaches its screen** with exactly the wire sequence of §5.1, in order, and no
  other state-changing command (`receivedCommands`, the network mock's verbose log or command record).
- **Already in a menu, or Func on, or a key queued:** nothing state-changing sent.
- **A slow redraw:** the grace re-read lets the walk go on; a second stale read stops it.
- **An arrival `MSI` that is `TypeError`** (`GSI` naming the destination): success, mirrored text.
- **Each stop**, at each step: `GSI` unanswered (nothing sent); the enter's reply dropped
  (`drop-reply`), the enter request dropped (`drop-request`), an `MSV` rejected (`rejectNext`),
  an `MSI` unanswered, a screen with the wrong title, the item missing: the walk sends nothing more,
  never resends, re-reads once, and throws.
- **Detach mid-walk** (a stop while a command waits for the slot): nothing more is written.
- **Busy:** a second walk or a menu action during a walk is refused; a background refresh during
  it doesn't overwrite its result.
- **Ceiling:** every profile's paths are at most three steps.
- `StationSession` / view helpers: the Services and Range buttons on all four models call the walk;
  `KEY,T` and `KEY,R` are never sent by a click or a chord on any model; keys during a walk are
  dropped; a saved key map with the old Services/Range chords still decodes and runs the walk.
- The existing tests that pin Plan 23's per-model keypad (no Services on the handhelds, no Range on
  the SDS150) change to the one button set.
- QA mutations as usual; none may remove a step's check and then run against hardware (all tests
  are on the mocks).

## 7. Hardware session (the owner's, after the build)

Each at the owner's go-ahead, `NOCTULE_TRACE` on, in the app, the Scanner view; results into this
document, the protocol notes and `LESSONS.md`. Folds into Plan 23's session (BCD design §7 H6 and
H11 change: H11's "no Services key, no Range key" becomes "Services and Range open their screens").

- **S1** On each of the SDS200, SDS100, SDS150 and BCD436HP: Services once and Range once, from
  scanning. Trace shows the agreed commands and nothing else; both views show the screen; Back and
  Exit leave it. On Set Range, the Mac-style number entry shows the radio's value (no save needed).
- **S2** Once, on any model: Services while the radio is already in a menu (from its own panel):
  nothing sent.
- **S3** Read Select Service Types' `MSI` once on each model (it happens in S1): record its shape
  in the protocol notes.
- **S4** (added at the build, 2026-11-26) The BCD436HP's top-menu `MenuSummary name` must normalise to
  `Menu`, and on the SDS100 and SDS150 `GSI`'s and `MSI`'s screen names must agree at each step: the
  walk's stricter check (§10) stops otherwise.
- **S5** (added at the build) The click-through the builder could not do: the Scanner view's
  Services and Range buttons, the failed-walk caption, the double-click and a click right after a
  digit, on the mocks (no computer-use tools or screen recording in the build session).

## 8. Documents

- `AGENTS.md`: the menu rule (§5.2) under "Every model" and "Menu action rules"; the Scanner view's
  keypad (one button set; Services and Range walk the menu; `T`/`R` never sent); the mock's tree.
- Remote menus design: a dated note at §5.4–§5.5 pointing here.
- BCD design §5.3, §5.11 and §7: a dated note that §5.11's dropped Services/Range buttons are
  reversed by this design.
- Protocol notes: the key-sheet finding (§1) and `SVC`/`LCR` (§3.1).
- `docs/specs/README.md`: this design under "The app and its menus".

## 9. Left to the builder

Names (the action, the error cases, the path types); how Services and Range leave
`FrontPanelKey` while saved key maps keep decoding; where a failed walk's message shows; how tests
force a mismatch on the mock; whether the walk shares code with `choose(_:on:)`.

## 10. What was built (2026-11-26)

Differences from §5 and rulings made during the build. Those marked (designer's call) or "the
builder's" are not the owner's; the owner's rulings are the walk approach (the §5.2 exception), the
Scanner view only (nothing added to the Mac-style view), and the approval of this design and plan.

- **A stricter step check (designer's call).** A step proceeds only when both `GSI`'s menu title and
  `MSI`'s `Name`, each through `breadcrumbTitle`, equal the expected screen, and `MSI` lists the item
  exactly once; §5.1 3b asks for `MSI` only. It fails closed (stops, sends nothing more), and so
  relies on `GSI`'s and `MSI`'s names agreeing on hardware (§7 S4).
- **`MenuActionError.walkStopped(expected:found:)`.** `expected` is the screen needed at the failing
  step (for example `Menu`), or the destination at arrival; the Scanner view's text always names the
  destination (`MenuShortcutText`). An unanswered `MSI` on a step's new screen is `.walkStopped`, not
  `.noAnswer`. `alreadyInMenu` and `functionPending` stop the walk before anything is sent.
- **`enter()` and the walk share one `sendEnter`** helper (same permit, same request slot).
- **The key-queue refusal (§5.1 step 0) lives in `StationSession`**, not `MenuModel`
  (`pendingKeyPresses`, counted in the run's `KeyGate`: +1 before the yield, -1 exactly once when the
  queue drops the key or its send ends; reset when the gate is dropped). A double-click is refused
  `.busy` by the session (`menuShortcutInFlight`) before `MenuModel`, so it walks once. Other key
  presses (keypad, chords, the Mac controls bar's Avoid, an SDS soft-key Hold through `press`) are
  dropped while a walk runs. A click less than a reply-time after a digit is refused silently
  (busy, so no message).
- **A failed walk's message** (`menuShortcutMessage`) shows in a fixed-height caption under the
  keypad, only while connected, cleared after 5 s or by the next click. The Scanner view shows it
  alone (it never showed `menu.lastError`). `MacMenuView`'s exhaustive error switch gained texts for
  the three new errors; no control or chord was added to the Mac-style view, and Services and Range
  chords are swallowed there.
- **The mock.** Select Service Types sits after Set Your Location (indexes after it shifted by one).
  `Property F` reads On after `KEY,F,P` until any other handled `KEY` (assumed, not seen on hardware).
  Known gap: the BCD436HP mock's hold keys (`KEY,A|B|C,P`) don't clear Func.
- **A walk ending on an `MSI` `TypeError` screen** is covered only by `judge` unit tests; the mock has
  no reachable destination like it.
- **Hand check (Task 5).** The app launched and quit cleanly on the network mock and the BCD436HP
  serial mock (no stray commands, `PSI,0` last, counters 0). The click-through and screenshots were
  not done: the build session had no computer-use tools and no Screen Recording (§7 S5).
- **A known window, accepted for now:** between `startMenuShortcut` and the walk setting
  `menu.isBusy` (one main-actor turn), the BCD436HP Hold controls' `canHold` is still true.
