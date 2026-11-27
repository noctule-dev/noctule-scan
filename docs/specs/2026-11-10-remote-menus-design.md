# Remote menus — design

Date: 2026-11-10
Status: Built in Plan 6 (`docs/specs/2026-11-10-plan-6-remote-menus.md`). Owner hand checks pending.

Labels: **(owner)** marks what the owner decided in the brainstorm; **(designer's call)** marks a default the owner hasn't ruled on and can overturn.

## 1. Why

Noctule Scan can show the SDS200's scanning display, forward every front-panel key, and play its audio. It cannot show the scanner's menus: when the scanner enters one, the app covers the display with "Scanner is in a menu — use the scanner or press Menu to exit" (design §7.4 left menus out of the MVP). The owner sometimes needs the menus, for example to change which Favorites Lists are scanned, and has to walk to the radio or start ProScan.

ProScan's remote menus copy the radio: spin a knob to move, push it to accept. The owner calls that clunky. Their view of the two station views **(owner)**:

- The **Scanner view** is for people who already know how to work the radio. There, copying the radio is right.
- The **Mac-style view** should lower the effort of a device that is hard to learn: real Mac lists, typing, clicking.

Menu operations must be a clean, UI-free set of actions in shared code (§6), so that other front ends than the Mac app's views can drive them.

## 2. Goals, non-goals, anti-goals

Goals:

1. In the Scanner view, the mirrored display shows every menu screen as the radio shows it, and the existing knobs, keys and keyboard shortcuts operate it. **(owner)**
2. In the Mac-style view, while the scanner is in a menu, the menu takes over the view's main area as native Mac controls. **(owner, mockup option A)**
3. In the Mac-style view, names and numbers are typed on the Mac keyboard, not dialled character by character. **(owner, "if feasible"; the hardware trial in §4 showed it is)**
4. The Mac-style view asks "are you sure?" before the most destructive menu items. **(owner)**
5. Menu operations are shared, platform-neutral code that a later MCP module (and iPad/iPhone) can call without any view. **(designer's call, from the owner's MCP plan and the repo's shared-code rule)**
6. The mock scanner has menus, so all of this is tested on the mock before the real scanner (AGENTS.md rule).

Non-goals (this round):

- A Favorites Lists overview (what each list holds, its quick keys). The owner has ideas for a later request. **(owner)**
- The MCP module itself. **(owner)**
- Building or editing Favorites Lists; the owner uses Sentinel for that. The menus that do it are still reachable, but nothing here is designed around them.
- Models other than the SDS200, and transports other than UDP.
- A Mac-native version of the screens the scanner doesn't describe as data (Analyze, Customize, waterfall, discovery; §4.3). They work in the Scanner view only.

Anti-goals (it would be a failure even if it "works"):

- A menu that moves twice, or saves a value twice, because the app resent a command whose reply was lost (§4.5).
- Any command sent to the scanner that the user didn't cause. Entering, leaving and changing menus happens only on a user action; reading the screen (`STS`, `GSI`/`PSI`, `MSI`) is the only automatic traffic.
- The Mac-style view knowing the menu tree. It renders what the scanner describes; the only per-model menu knowledge is the short destructive-items list (§5.4).
- Showing a stale channel display as if it were live while the scanner sits in a menu. Scanning stops in a menu, and the UI says so. **(owner)**

## 3. What exists today

- Every `FrontPanelKey`, Menu included, is already sent with `KEY,<code>,P` (`ScannerClient.press`, `KeyPressQueue`, `StationSession.press`).
- `StationSession` polls `STS` under `DisplayRefreshPolicy` (150 ms after a key reply, but at most one fetch per second, at least one per 5 s) and builds a `DisplayModel` (rows with highlighted segments, three soft keys from the last `STS` line, `isMenu` when `Mode` or `V_Screen` contains "menu").
- `DisplayView` (Scanner view) draws the rows, or the menu banner when `isMenu`.
- `MacStyleView` shows breadcrumb, headline, chips, `MacControlsBar`, and volume/squelch sliders. It has no notion of a menu.
- `MockSDS200` has no menus: no menu screens in `STS`, no menu mode in `GSI`/`PSI`, no `MSI`/`MSV`.

## 4. What the scanner does (hardware findings, 2026-11-10, fw 1.26.01)

All from owner-approved probes of the owner's SDS200 over UDP, no audio session open. Names below are sanitized; menu item names are the firmware's own. The same facts go into `docs/specs/2026-11-08-sds-remote-protocol.md` and `LESSONS.md` as part of this work.

### 4.1 Keys

`KEY,M,P` enters the menu from scan mode and goes up one level inside it (from an entry screen it cancels without saving). `KEY,>,P` / `KEY,<,P` move the highlight down / up and wrap around at the ends. `KEY,E,P` opens or accepts the highlighted row. `KEY,L,P` (Avoid) leaves the menu from any depth, and scanning resumes. Each is acknowledged `KEY,OK`.

### 4.2 `GSI` / `PSI` and `STS` in a menu

`ScannerInfo` in a menu has no channel elements:

```xml
<ScannerInfo Mode="Menu tree" V_Screen="menu_selection">
  <MenuSummary name="Set Scan Selection" index="4293063672" />
  <ViewDescription>
  </ViewDescription>
</ScannerInfo>
```

`V_Screen` is `menu_selection` on list screens and `menu_input` on entry screens.

`STS` in a menu is ten lines, every size flag `1`: a title line and nine rows. There is **no soft-key line** on list screens.

```
STS,1111111111,
Set Scan Selection            ,______________________________,
Manage Quick Key Status       ,******************************,
Set Nationwide Systems        ,                              ,
Select Lists to Monitor       ,                              ,
Set All Lists Off             ,                              ,
Set All Lists On              ,                              ,
(four blank rows, blank masks)
1,1,0,0,,,0,OFF,3
```

- The title's mask is `_` in every column: a new mask character (underline). The highlighted row's mask is `*` in every column.
- On/off lists put the state in the row text: `Lakeview Fire             :On `.
- Lists longer than nine rows scroll one row at a time; nothing marks "more below".
- Entry screens (`menu_input`) are also ten lines, flags `1111111111`, same trailing fields. `GSI` is the same shape as above with `V_Screen="menu_input"` and the entry's title in `MenuSummary` (`name="Edit Name"`, `name="Set Range"`).
  - Number entry (Set Range): line 1 title with the `_` mask; line 2 `30.0` padded to 30 columns, mask `*` in column 1 only (the cursor); lines 3–4 blank; line 5 `          (mile)              `; lines 6–10 blank with blank masks. **Line 10 is blank: no soft keys are shown.**
  - Name entry (Edit Name): line 1 title; line 2 the name padded to 30 columns, mask `*` in column 1 only; lines 3–9 blank; **line 10 is a soft-key row of icon glyph bytes** with a blank mask: `C8 C8 C8 C9 CA CB CC CD CE 20 D8 D0 D9 DA DB DC DD DE DF D0 20 D0 D1 D2 D3 D4 D5 D6 D6 D6` (groups of 9, 10 and 9 bytes separated by a space, the same widths as the scan screen's soft-key mask). The bytes aren't valid UTF-8, so they decode to replacement characters; what the three icons mean isn't identified.
  - So on an entry screen line 10 is always the soft-key row; it may be blank.

The raw captures hold real names and are not in the repo. The Uniden Remote Command Specification isn't in the repo either; what §4.3–4.4 says about it comes from the `sds200` library's research notes (`docs/advanced-protocol-research.md` in its sdist), and everything marked as tried was observed on the owner's scanner. Anything a parser or the mock needs that isn't written in this section must come from a new owner-gated capture (§4.6), not from a guess.

### 4.3 `MSI`: the current menu screen as data

`MSI` (documented in Uniden's Remote Command Specification V1.02 and V2.00; read-only) answers in one datagram here:

```xml
MSI,<XML>,
<?xml version="1.0" encoding="utf-8"?>
<MSI Name="Select Lists to Monitor" Index="4293063468" MenuType="TypeSelect" Value="Full Database             :Off" Selected="0" >
  <MenuItem Name="Full Database" Index="0" Value="Off" />
  <MenuItem Name="Search with Scan" Index="1" Value="Off" />
  <MenuItem Name="Lakeview Fire" Index="2" Value="On" />
  …every item, not only the nine on screen…
  <Footer No="1" EOT="1"/>
</MSI>
```

```xml
<MSI Name="Edit Name" Index="4293064052" MenuType="TypeInput" Value="Custom 9" >
  <MenuInput MaxLength="64" EnableKeys="ABC…XYZabc…xyz1234567890[\]^_`{|}~!&quot;#$%&amp;&apos;()*+,-./:;&lt;=&gt;?@ " />
  <Footer No="1" EOT="1"/>
</MSI>
```

A number entry (Set Range) describes itself the same way, with the units line as `AddedInformation`:

```xml
<MSI Name="Set Range" Index="4293050176" MenuType="TypeInput" Value="30.0" >
  <MenuInput MaxLength="5" AddedInformation="          (mile)" EnableKeys="0123456789." />
  <Footer No="1" EOT="1"/>
</MSI>
```

`TypeError` is what `MSI` answers when it has no menu to describe. Outside a menu (scanning) it is bare; on a menu screen the protocol doesn't cover (inside Analyze, whose `STS` is an ordinary two-item list and whose `GSI` says `menu_selection`) it carries a message:

```xml
<MSI MenuType="TypeError" >
  <Footer No="1" EOT="1"/>
</MSI>

<MSI MenuType="TypeError" >
  <MenuErrorMsg Text="The scanner is in state that you can&apos;t remote control.&#xD;Please goto scan mode to remote control." ScanButton="1"  />
  <Footer No="1" EOT="1"/>
</MSI>
```

So `TypeError` while `GSI` reports a menu means "show the mirrored text"; it is not, as far as seen, how confirm prompts arrive.

- `MenuType` seen: `TypeSelect`, `TypeInput`, `TypeError`. Documented but not yet seen: `TypeLocation` (`<MenuLocation MaxLength EnableKeys IsLatitude>`).
- `Selected` is the highlighted item's `Index`; for a pick-one setting it opens on the current value.
- `MenuItem/@Value` is present only where items have a state (On/Off).
- **`MSI` omits some items**: the main menu's "Analyze" (index 8), Display Options' "Customize" (index 1) and Set Your Location's "Auto Locate" (index 1) are on the screen but not in the XML; the remaining items keep their true indexes (…7, 9, 10…). These open screens the menu protocol doesn't describe.

### 4.4 `MSV`: choose an item or set a value

`MSV,,<value>` (documented form `MSV,[RSV],[VALUE]`; the reserved field left empty) replies `MSV,OK`:

- On a `TypeSelect` screen, `<value>` is an item `Index`. It behaves like moving to that item and pressing E: a submenu opens; a pick-one setting is set and the scanner returns to the parent menu. Tried: main menu → Display Options (14) → Set ID Format (2) → Hex (1), confirmed with `MSI` (`Selected="1"`), restored with 0.
- On a `TypeInput` screen, `<value>` is the whole text. It is **saved at once** and the scanner returns to the parent menu. Tried: a custom search bank's name changed and restored.
- On an on/off list, `<value>` is the item `Index` and it **toggles that item and stays on the list**. Tried on Select Lists to Monitor: item 13 On → Off → On, each confirmed with `MSI` (`MenuItem/@Value`, and `Selected="13"`). Two oddities: the root `Value` attribute kept the first row's text, and the radio's own screen (`STS`) kept its highlight on row 1, so after an `MSV` the mirrored screen and `MSI` can disagree about the highlight. Use `MenuItem/@Value` and `Selected`, not the root `Value`, on lists.
- Number entry works like name entry: Set Range 30.0 → 31.0 → 30.0, each confirmed by reopening it. **After saving the range the scanner left the menu altogether and resumed scanning.** An action can land anywhere, including out of the menu; only a re-read says where.
- The spec says commas inside an input value are sent as tabs. Not tried.

Not yet tried on hardware: `TypeLocation`, what a "Confirm?" prompt looks like in `STS`/`GSI`/`MSI`, an `MSV` the scanner rejects (bad index, text too long or with a character outside `EnableKeys`), and a comma in an input value. See §4.6.

`MSB` (documented "menu back") and `MNU` (open a menu by id) are not used: untried, and keys already do the job.

### 4.5 Lost datagrams

During the probes about 1 command in 12 got no reply within 2 s (four read replies and one `KEY`, of roughly 60). The unanswered `KEY` had **not** taken effect. We can't tell a lost request from a lost reply.

### 4.6 Rule for what isn't verified yet

The Mac-style view uses a native control only for a case that has been verified on hardware and recorded here. Every unverified case shows the mirrored scanner text (§5.3's fallback), where each user action is exactly one key. **The app never turns one user action into a sequence of keys** (for example scrolling to a row and pressing E, or typing digits then E): with replies lost at the rate of §4.5 and no automatic resend, a dropped key would act on the wrong row or save a wrong value **(designer's call)**.

Verified as of 2026-11-10: lists (submenus, pick-one settings, on/off items), name entry, number entry. Still unverified, so mirrored text for now: location entry, confirm prompts. The app never sends an input value containing a comma, or one that breaks `MaxLength`/`EnableKeys`, so the untried rejection and comma cases can't arise from the UI; a non-OK reply is still handled (§5.5). Filling the remaining gaps is an optional, owner-gated hardware task in the plan, not a precondition for the rest.

## 5. What gets built

### 5.1 Both views: knowing the scanner is in a menu

The scanner is "in a menu" when `ScannerInfo.mode` is `Menu tree` (keep the existing loose "contains menu" test). `ScannerInfo` learns `MenuSummary` (name, index) and exposes whether the screen is a list or an entry screen from `V_Screen`.

While in a menu the session refreshes faster than the scanning policy allows: the screen is re-read promptly after every menu action's reply, without the one-per-second floor, and at a slow idle rate otherwise so that changes made on the radio's own panel show up. Exact intervals are the builder's, within "a held scroll key feels live" and "no more than a few requests per second sustained" **(designer's call)**. As built: in a menu `STS` is read 150 ms after a key or menu command reply, never sooner than 200 ms after the last read, every 2 s otherwise, and a key reply never puts the next read more than 400 ms after the last one: key repeat answers faster than 150 ms, so without that cap a held scroll key deferred every read until it was released **(designer's call, made during the build)**. Outside a menu, `DisplayRefreshPolicy` is unchanged.

Hit logging and audio need no change: in a menu there is no channel, so no hits; audio keeps streaming.

### 5.2 Scanner view

- The menu banner goes; `DisplayView` draws menu screens from `STS` like any other screen.
- `DisplayModel` no longer assumes the last `STS` line is the soft-key row. In a menu, a list screen has no soft keys (all ten lines are rows); an entry screen's last line is the soft-key row, which may be blank (§4.2). Outside a menu, behaviour is unchanged.
- The `_` mask draws as an underline (the title). `*` stays reverse video.
- Icon-glyph soft keys (name entry) can't be labelled; the three soft-key buttons stay enabled and show a neutral placeholder so they can still be pressed **(designer's call)**.
- Keys, knobs and keyboard shortcuts work as today. No app confirmations here: the Scanner view behaves like the radio **(designer's call)**.

### 5.3 Mac-style view

While the scanner is in a menu, the menu replaces the view's main content (breadcrumb, headline, chips). The shared controls that still make sense stay available; the builder decides which of `MacControlsBar`'s controls to disable in a menu (Hold and Avoid must not be offered: Avoid exits the menu on the scanner). The channel display returns when the scanner leaves the menu, whoever caused that.

Entering: a **Menu** button in the Mac-style view (placement is the builder's) sends the Menu key **(designer's call)**. If the menu is entered from the radio's own panel, the view switches by itself.

List screens (`TypeSelect`):

- A native list of every `MenuItem`, in order, scrolling locally. Items with a `Value` show it trailing (On emphasised). The row matching `Selected` starts selected.
- Title large, with a breadcrumb of the titles the app has seen on the way down. The app can only know the path it watched; if it joins a menu mid-way the breadcrumb starts at the current title **(designer's call)**.
- ↑/↓ move the local selection (no scanner traffic). Return, double-click, or the default button opens/chooses/toggles the selected row with `MSV,,<index>`. Esc and **Back** send Menu (one level up). **Exit Menu** sends Avoid.
- After every action the app reads `MSI` again and redraws from it. It never assumes what an action did.
- A line states: "Scanning is paused while the scanner is in a menu." **(owner's reason for option A)**
- Because `MSI` omits some items (§4.3), the list is not always the whole screen. The view notes that more items are available in the Scanner view when the `STS` rows show an item `MSI` lacks, where that can be told cheaply; otherwise a standing hint is enough **(designer's call)**.

Entry screens (`TypeInput`):

- A normal text field pre-filled with `Value`, limited to `MaxLength` and to the characters in `EnableKeys` (others are refused as typed). Return/**Save** sends the whole text with `MSV,,<text>`; Esc/**Cancel** sends Menu. Nothing reaches the scanner until Save.
- Numbers use the same field (verified, §4.4); `AddedInformation`, trimmed, is shown beside it as the unit.
- The field takes keyboard focus, so the scanner-key monitor must stand aside (`.tracksKeyboardFocus()`, LESSONS 2026-11-09). The list must not reintroduce the sticky-first-responder problem recorded there (no SwiftUI `List` unless the monitor's rule is revisited).

Everything else — `TypeLocation`, `TypeError` while `GSI` reports a menu (§4.3), an `MSI` that fails to parse, or `MSI` unanswered — shows the **mirrored scanner text** (the same rows the Scanner view draws) inside the Mac-style menu area, with Back, Exit Menu, ↑/↓ (scroll keys), Return (E) and the soft keys working as keys **(owner agreed to the fallback)**. Two refinements **(designer's call, made during the build)**: an input screen is an entry field only when its rules give both `MaxLength` and `EnableKeys`, the shape verified on hardware; one without either is unverified (§4.6) and shows the mirrored text. And an `MSI` that goes unanswered while `GSI` still reports the screen the current list or entry was read on (same title, menu index and screen kind) keeps that list or entry, with the user's selection or draft, and says the scanner isn't answering (§5.5); the mirrored text is for a screen with no list or entry read yet, or an `MSI` answered with something else. At about one lost datagram in twelve, falling back on every unanswered refresh threw away a half-typed name every few minutes.

While the Mac-style view shows and the scanner is in a menu, the station window's keyboard shortcuts never press a scanner key: ↑ ↓ Return Esc are the menu's, and every other mapped key is swallowed, also in the moments when the menu area isn't ready to take keys (before the first read, or while pushes stall) **(designer's call, made during the build)**. A raw Return there would be the Enter key with no destructive check.


> **Note, 2026-11-26 (Plan 24):** §5.4 and §5.5's "one action, one state-changing command, never resent" gets one exception, the menu walk behind the Scanner view's Services and Range buttons: at most four commands, one per step, each only after a re-read proves the screen and item, none resent, stopping at the first mismatch, refusal or lost reply. Wording and what was built: `2026-11-26-services-range-design.md` §5.2, §10. The Mac-style view is unchanged.
### 5.4 "Are you sure?" (Mac-style view only)

Before sending the action for a destructive item, the Mac-style view shows a confirmation naming the item; Cancel sends nothing. Which items count is per-model data in `ModelProfile` (AGENTS.md: model knowledge lives in data), matched on the item's name, ignoring case and surrounding spaces. The SDS200 list **(designer's call; the owner asked for "super destructive" items and didn't enumerate them)**:

- `Clear User Data`, `Reset User Settings`
- any item whose name starts with `Delete`
- `Stop All Avoiding`
- `Set All Lists Off`, `Set All Lists On`

How strong the guarantee is **(designer's call)**:

- `MSV,,<index>` acts on whatever screen the scanner is on *now*, which may not be the screen the app last drew (someone used the radio's panel; an earlier action took effect but its reply was lost; a late reply was matched to a newer request). So immediately before every `MSV` the app reads `MSI` again and sends only if the menu's `Index`, the item's `Index` and the item's `Name` still match what the user acted on; otherwise it sends nothing, redraws, and says the menu changed. Actions are refused while another action (including its re-check and re-read) is in flight; background refresh reads don't block actions, but their results are discarded when an action has started meanwhile **(designer's call, made during the build)**. For a value saved on an entry screen, the entry's `Value` must also still be the one the user edited: a value changed on the radio, or by an earlier save whose reply was lost, is "the menu changed", and the field starts again from the new value **(designer's call, made during the build)**. **Exit Menu** sends Avoid, which outside a menu avoids the channel being scanned, so it reads `GSI` first and sends nothing if the scanner has already left the menu (or if that read goes unanswered) **(designer's call, made during the build)**. This costs one extra round trip per action and leaves a small window that can't be closed; that is accepted. Also accepted **(designer's call, made during the build)**: replies are matched to requests by command name, so a late reply to an earlier `MSI` read can answer a later one, and the same kind of window exists between the fresh `STS` and `KEY,E,P` of an Enter on a mirrored screen.
- The destructive check lives in the shared action, not only in the view: the action refuses a destructive item unless its caller passes an explicit confirmation. For a mirrored Enter, `MenuModel.press(_:confirmedDestructive:confirmedItemName:)` reads a fresh `STS` first, and a confirmed Enter is sent only if the highlighted row is still the confirmed name (`.menuChanged` otherwise; an unanswered `STS` sends nothing) **(designer's call, made during the build)**. The Mac-style view passes it after the user confirms; the later MCP module will have to do the same.
- In the mirrored-text fallback inside the Mac-style view, Return on a highlighted row whose text matches the destructive list asks first too.
- The Scanner view is exempt (§5.2): it sends keys exactly as the radio's panel would.

The confirmation must not be a sheet that blocks quitting (LESSONS 2026-11-09: an open sheet makes AppKit refuse `terminate`); an inline confirmation in the menu area is the safe shape **(designer's call)**.

### 5.5 Lost replies

A menu command (`KEY`, `MSV`) that gets no reply is **never resent automatically**. The app re-reads the screen (`MSI`/`STS`, which are safe to retry) and shows what the scanner now says; the user repeats the action if it didn't take. An unanswered read is retried a small bounded number of times, then the menu area shows a "scanner isn't answering" state consistent with how the session already reports control failures. When only the `MSI` went unanswered and `GSI` still shows the same screen, the list or entry already shown stays (§5.3), and an action whose re-read ended that way reports that the scanner didn't answer **(designer's call, made during the build)**.

`MSV` replies other than `MSV,OK` are shown as a short error in the menu area, and the screen is re-read.

## 6. Shared code and the mock

Protocol and model (`NoctuleKit`): `ScannerInfo` menu fields; a menu-screen model parsed from `MSI` (title, kind, value, selected index, items with index/name/value, input rules, and the raw type string for kinds we don't model); `ScannerClient` calls for `MSI` and `MSV`; `DisplayStatus`/mask handling for `_`. `MSI` must go through the existing XML reassembly (`UDPDatagramAssembler`); it carried a `Footer No="1" EOT="1"` even as one datagram.

App logic (`NoctuleAppCore`, must keep building for iOS): the menu state and actions on `StationSession` (or a type it owns) — current menu screen, enter, open/choose item, set value, back, exit, with the refresh and lost-reply rules of §5.1 and §5.5 — plus the destructive-item check. Views call these; they hold no protocol logic. This is the surface the later MCP module will call, so each action should be usable and testable without a view, and should report its outcome (the new screen, or the failure) to its caller.

Mock (`NoctuleMockScanner`): a small fictional menu tree covering each screen kind — nested lists (one longer than nine rows), an on/off list, a pick-one setting, a name entry and a number entry, an item present in `STS` but omitted from `MSI`, and one destructive-named item — answering `KEY` (M, E, <, >, L, digits), `STS`, `GSI`/`PSI`, `MSI` and `MSV` in the shapes of §4, with scenario traffic paused while in the menu. A fault that drops the next reply (and one that drops the next request) lets tests cover §5.5. The mock states where it assumes rather than copies hardware (for example `MSV` on an on/off item), as it already does for `MSM,1`.

CLI: none required. A read-only `noctule menu` that prints the current menu from `MSI` would be a cheap aid for hardware checks; the builder may add it.

## 7. Constraints

- Mock first, real scanner second; no audio session is needed for menu checks on hardware.
- On the owner's scanner: `MSI` is read-only and joins the safe probes. `KEY` presses and `MSV` change scanner state: every hardware check that sends them needs the owner's go-ahead, restores anything it changes, and never confirms a destructive item. The owner approved the 2026-11-10 probes for that session only.
- No guessed commands: only `KEY`, `STS`, `GSI`/`PSI`, `MSI`, `MSV,,<value>` as observed in §4.
- No real names in tracked files: fixtures and samples use fictional list names; raw captures stay out of the repo.
- No automatic menu traffic beyond reads; nothing in a loop that changes state.
- Swift/SwiftUI; shared code free of Mac-only UI; update `LESSONS.md`, the protocol notes, design §7.4 and AGENTS.md as the work lands.

## 8. Left to the builder

Type and file names; refresh intervals; exact layout, wording and button placement within the mockups' intent (`.superpowers/brainstorm/…/mac-menu-layout.html`, `mac-menu-v2.html`, git-ignored); which Mac controls stay enabled in a menu; how the breadcrumb is kept; retry counts; the mock's menu tree; whether to add `noctule menu`; task order. The hardware checks listed in §4.4 are part of the plan, each gated on the owner.
