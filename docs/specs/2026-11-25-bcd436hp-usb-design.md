# The BCD436HP over USB — design

Date: 2026-11-25. Status: **approved by the owner in chat, 2026-11-25**. Nothing is built yet. The checks in §3 ran on
throwaway edits and a throwaway probe that were reverted and never committed.

Labels: **(the owner's call)** is a decision the owner made in the brainstorm on 2026-11-25;
**(designer's call)** is a default the designer chose that the owner hasn't ruled on and can
overturn. **[hw]** is a fact seen on the owner's BCD436HP (firmware 1.28.24) on 2026-11-25;
**[spec]** is Uniden's *BCDx36HP Remote Command Specification* V1.03 or *BCDx36HP Menu Tree
Specification* V1.07 (both git-ignored in `docs/uniden/`); **[assumed]** is something neither has
shown. Everything not labeled is fact about the code or a pointer.

## 1. Why

The owner has a BCD436HP, the handheld before the SDS series, attached to the Mac by USB in serial
mode beside the SDS150 (its headphone jack is also wired to the USB audio interface). Noctule Scan
supports the SDS200 over the network and the SDS150 and SDS100 over USB serial. The owner wants
the BCD436HP to be **a fully supported radio** in Noctule Scan, as the SDS100 became in Plan 17.
**(the owner's call)**

A read-only spike, then a keep-alive test and a menu check the owner asked for (§3), found that
the BCD436HP speaks the same remote protocol as the SDS handhelds, through the existing decoders,
with the same push lifetime and the SDS100's keep-alive. The differences are small and are
per-model data: the screen (24 columns, no soft-key line), how menus are entered and left, the
`Rssi` value, the destructive menu items, and the commands its spec doesn't list.

## 2. Goals, non-goals, anti-goals

Goals:

1. The BCD436HP works everywhere a USB handheld does: `noctule info|status|display|menu|watch|
   quick-keys --serial`, `noctule log` on a USB station, `listen --station` with a line-in, and the
   app's station window (both views, menus, Quick Keys, the hit log, line-in audio), on the same
   stack as the SDS100 and SDS150.
2. Its pushes never stop on their own: the SDS100's renewal keep-alive (§3.3).
3. Menus use the BCD's own menu commands, `MNU` and `MSB`. **(the owner's call: "if there are
   specific BCD commands those probably should be used instead of the SDS commands")**
4. The Scanner view draws its screen correctly: 24 columns, every line a row, no soft keys.
5. A mock personality that behaves as §3 found, so every feature is tested on the mock first.
6. Hold works from the Mac-style view at system, department and channel level, by `HLD` (§5.3).
7. The Scanner view's panel matches each handheld's real keys and encoder, the SDS100 and SDS150
   included (§5.11). **(the owner's call, 2026-11-25: "let's fix the sds100/sds150")**
8. Its hardware session (§7) closes what §3 couldn't check.

Non-goals:

- The BCD536HP (the base, with Wi-Fi), Bluetooth, iPhone and iPad.
- A BCD436HP-shaped front panel in the Scanner view (§8).
- BCD-only commands beyond `MNU` and `MSB`: `QSH`, `JNT`, `NXT`, `PRV`, `HLD`, `AVD`, `SVC`,
  `JPM`, `DTM`, `AST`, `APR`, `URC`, `BFH`.
- Switching the SDS models to `MNU`/`MSB`, though the SDS spec V2.00 lists both (§8).
- Two radios of the same model told apart (as for the SDS100; SDS100 design §8).

Anti-goals (a failure even if it works):

- Any change in what the SDS200 sends or how its panel and screen draw; any change in what the
  SDS150 or SDS100 send beyond §5.11 (their panel no longer offers keys they don't have).
- Any command its spec doesn't list sent to the BCD436HP by the product: no `KAL`, `GCS`, `MSM` or
  `POF`.
- A menu Exit that can press Avoid on a scanning screen (§5.2 removes the case on this model).
- An RSSI in the hit log in the wrong unit.
- Real names, frequencies or coordinates in a tracked file, fixture or this document.

## 3. What the spike found (2026-11-25)

### 3.1 The USB device [hw] (registry reads only, `ioreg`)

Vendor 0x1965, **product ID 0x001A (the SDS150's and SDS100's)**, device release 0x0100, product
name `BCD436HP Serial Port`, **no USB serial number**, so macOS names the port from the USB
location (`/dev/cu.usbmodem<location>1`) and **the path follows the socket**, as the SDS100's does.
It exists on USB only while Serial is chosen on the radio. `SerialPortInfo.knownModel` already maps
the name's first word to `.bcd436hp` through `ScannerModel(reported:)`.

### 3.2 Read-only commands [hw]

Through `noctule info`, `status`, `display` and `menu` with the existing code: `MDL` → `BCD436HP`,
`VER` → `1.28.24`, `VOL` → 5 and `SQL` → 2 (both answer, though [spec] V1.03's command list
doesn't name them), `GSI` → XML that `ScannerInfo` parsed, `STS` → 38 fields, `MSI` outside a menu
→ the `TypeError` screen. Replies in 0–30 ms. No `unmatched` trace lines.

`GSI` while trunk scanning has the SDS's elements: `MonitorList`, `System`, `Department`, `TGID`,
`UnitID`, `Site`, `SiteFrequency`, `AGC`, `DualWatch`, `Property` (`A_Led Att Backlight Dir F
KeyLock Mute P25Status Rec Rssi SQL Sig VOL`), `ViewDescription`. **`Property` has no `Battery`.**
**`Rssi` is a decimal (`Rssi="1.267"`)** where the SDS sends whole dBm (`-62`, `-999` idle), so
`ScannerInfo`'s integer parse drops it and `noctule status` shows `rssi: -`. Its unit is unknown,
and it doesn't follow the bars: over 1,005 pushes it ran 0.25–1.34 at `Sig=0` and overlapped at
every `Sig` from 1 to 5 (0.47–1.32); during calls about 1.06–1.22. [spec] V1.05's own example
sends `Rssi="0.377"`.

**Volume and squelch (the owner's go-ahead, one set each, restored):** `SQL,16` answered `SQL,OK`
and **set 15**; `VOL,16` answered `VOL,OK` and **set 15**. So both ranges top out at 15 (0–15; the owner confirmed both on the radio's own controls),
and **an out-of-range value is clamped, not refused** (the mocks answer `NG` today).

**Calls** (`PSI,100` for 150 s while the radio scanned): 102 pushes with `isReceiving` true, in the
SDS's trunk-call shape (`Department` with `Name`; `TGID` with `Name`, `TGID`, `SvcType`;
`UnitID` with `Name` and `U_Id`, or empty). Pushes with `Sig` above 0 but no talkgroup (the
control channel during an ID search: `Department` and `TGID` without `Name`, `UnitID` empty) have
no channel, so `isReceiving` is false and no hit starts, as intended. `Mode`/`V_Screen` pairs seen:
`Trunk Scan/trunk_scan`, `Scan Mode/trunk_scan`, `Scan Mode/conventional_scan`,
`Trunk Scan/conventional_scan`, `Menu tree/menu_input` and **`Trunk Scan/menu_input`**. The last
two came while the owner was in the radio's own menu turning on another Favorites list; the mixed
pair is taken to be the moment of entering or leaving it. `ScannerInfo.isMenu` reads either as a
menu, which is right.

### 3.3 Pushes and the keep-alive [hw]

| Run | Sent | Pushes | Interval (median) | Outcome |
|---|---|---|---|---|
| `watch --count 10` | `PSI,500`, `PSI,0` | 10 | 560 ms | passed; no push came in during the `info` that followed |
| lifetime, no keep-alive | `PSI,500`, `PSI,0` | 328 | 562 ms | **pushes stopped 183.3 s after the `PSI`**, port open; `watch` stalled and sent `PSI,0` |
| `watch --interval 100 --count 80` | `PSI,100`, `PSI,0` | 80 | 157 ms (133–174) | passed |
| keep-alive, `PSI,100` renewed every 60 s | `PSI,100` ×5, `PSI,0` | 1720 | 160 ms (52–197) | **passed**: 278 s, longest gap 197 ms; each renewal answered `PSI,OK`, nothing else came back |

The keep-alive run used the product's code path (`watch --serial` with the BCD436HP's profile
given the SDS100's `PushKeepAlive(action: .renewSubscription, interval: .seconds(60))` on a
throwaway edit). [spec] lists no `KAL`; it was never sent.

### 3.4 Quick keys [hw]

With `supportsQuickKeys` turned on for the BCD436HP on a throwaway edit, `noctule quick-keys
--serial` read the whole Favorites tree: 12 lists, 102 commands (`GLT,FL`, `FQK`, `SQK,<k>`,
`GLT,SYS`, `GLT,DEPT`, `GLT,SITE`, `DQK,<k>,<k>`), 102 replies, replies 1–117 ms (median 14), no
timeouts, no `unmatched` lines; 100 values in every `FQK`, `SQK` and `DQK` reply. [spec] documents
`FQK`, `SQK` and `DQK` (reads and sets) and `GLT` in the SDS's forms. **`GLT` replies are paged
like the SDS handhelds'** (a throwaway trace in `XMLFragmentSequences`): `GLT,FL` came as a page
of 13 elements (`EOT="0"`) and one of 1 (`EOT="1"`); a short `GLT,SYS` as one page. No set was
sent.

### 3.5 Menus [hw]

- **`MNU,<MENU_ID>,`** ([spec]: `MNU,[MENU_ID],[INDEX]`, `INDEX` empty for the menus without one)
  answered `MNU,OK` and opened each menu: `TOP`, `MONITOR_LIST`, `SRCH_OPT`, `CC`, `CC_BAND`, `WX`,
  `SETTINGS`, `BRDCST_SCREEN`.
- **`MSB,,RETURN_PREVOUS_MODE`** (sic, [spec]) answered `MSB,OK` and left menu mode every time
  (about a dozen); `MSI` then answered `TypeError` and `GSI` the scan screen. **`MSB,,`** (empty
  level) went back one level, from a pick-one list, a number entry and a location entry, without
  choosing or saving anything. **`MSB` outside a menu answers `MSB,NG`.**
- **`MSV,,<index>`** on an item [spec] V1.07 shows as a submenu, picked by exact name, opened it.
  Only submenu items were selected (never a setting value, an action or an on/off item).
- **`MSI`** has the SDS's shape and the existing `MenuScreen` decoder read every screen:
  - `TypeSelect`: `<MSI Name Index MenuType="TypeSelect" Value Selected>` with
    `<MenuItem Index Name [Value]>` children; items it can't remote-control are left out (indexes
    skip, as on the SDS); on a pick-one setting `Selected` is the current value; on an on/off list
    each `MenuItem` has `Value="On|Off"`.
  - `TypeInput` (Set Range): `<MenuInput AddedInformation="          (mile)" EnableKeys="0123456789."
    MaxLength="5">`, as on the SDS.
  - **`TypeLocation`** (Set Manual Location → Input Latitude), the first seen on any unit:
    `<MenuLocation EnableKeys="0123456789.-" IsLatitude="1" MaxLength="10">`, the root `Value`
    holding the radio's coordinates.
  - Name entry (a custom search bank's Edit Name): `<MenuInput EnableKeys="ABC…xyz1234567890[\]^_`…"
    MaxLength="64">`, the SDS's.
  - **`<Footer No="1" EOT="1"/>`** on every `MSI` reply, in a menu or not, as on the SDS (the
    assembler strips it before the decoder sees it).
- **`GSI` in a menu** is the SDS's: `Mode="Menu tree" V_Screen="menu_selection"`, `MenuSummary`
  (`name`, `index`), empty `ViewDescription`.
- **`KEY` with the SDS's codes** (the owner's go-ahead, one press each, never resent, a re-read
  after each): `KEY,M,P` outside a menu opened the top menu; `KEY,>,P` and `KEY,<,P` moved the
  highlight down and back (`MSI`'s `Selected` followed it); `KEY,E,P` on Set Scan Selection opened
  that submenu; `KEY,L,P` inside a submenu left the menu entirely, back to scanning; **`KEY,M,P`
  inside a menu went back one level** (Adjust Key Beep → Settings → the top menu). Every one
  answered `KEY,OK`.

### 3.5a Keys and Hold [hw], [spec] V1.05

[spec] V1.05's key-code sheet (missing from V1.03) gives the BCD436HP: `M` Menu, `F` Func, `L`
Avoid, `0`–`9`, `.` No, `E` Yes, `>` `<` `^` the rotary knob, `V` **Backlight** (the volume knob's
push), `Y` Replay, **`A` System, `B` Dept, `C` Channel** (dedicated keys, not soft keys; the owner:
"there are distinct buttons on the bcd for system, dept, and channel"), `Z` Zip, `R` Range; **no
`Q`** (squelch push) and **no `T`** (Service Type).

Hold, pressed remotely (the owner's go-ahead; hold state read from `GSI` after each step, the radio
left with nothing held), matching the owner's manual:

| Key | Sent | Result |
|---|---|---|
| System | `KEY,A,P` once | no hold after 0.4 s; **System `Hold="On"` once the 2 s "System Pause" had passed** |
| System | `KEY,A,P` twice, back to back (both answered within 56 ms) | **System hold released** (a double-press) |
| Department | `KEY,B,P` twice, back to back (95 ms) | Department `Hold="On"` |
| Department | `KEY,B,P` twice, back to back (76 ms) | released |
| Channel | `KEY,C,P` once | TGID `Hold="On"`, `Mode="Trunk Scan Hold"` |
| Channel | `KEY,C,P` once | released, `Mode="Trunk Scan"` |

So on the BCD436HP **System and Department hold and release with a double-press** (a single press
pauses 2 s, then holds), and **Channel holds and releases with a single press**. A System or
Department hold doesn't change `Mode`; only the element's `Hold` attribute shows it. Two `KEY`
commands written back to back count as a double-press.

**`HLD` (the owner's go-ahead; one command per step, hold state from `GSI` 1 s and 3 s later).**
Its arguments are on the "tkd and 1st,2nd opt" sheet, missing from both BCDx36HP PDFs but printed
in the SDS spec V2.00 (page 14), which was built from the BCDx36HP V1.05 [spec]: `HLD,SYS,<System
Index>,`; `HLD,DEPT,<Department Index>,<parent System Index>` (the parent needed only for the
virtual "Unknown" department of an ID search, otherwise blank or given); `HLD,SITE,<Site Index>,`;
`HLD,CFREQ,<ConvFrequency Index>,`; `HLD,TGID,<TGID Index>,` (ID scan); `HLD,STGID,<TGID>,<Site
Index>` (ID search). The indexes are `GSI`'s.

| Sent | Result |
|---|---|
| `HLD,SYS,<i>,` | `HLD,OK`; **System `Hold="On"` within 1 s**, no pause |
| the same again | `HLD,OK`; **released** (scanning moved on) |
| `HLD,DEPT,<i>,<sys>` | `HLD,OK`; Department `Hold="On"` |
| the same again | released |
| `HLD,TGID,<i>,` (during a call) | `HLD,OK`; TGID `Hold="On"`, `Mode="Trunk Scan Hold"` |
| the same again | released, `Mode="Trunk Scan"` |

The owner watched the radio's screen during these and saw it hold the system, the department and
the channel each time (2026-11-25). So **`HLD` is a toggle by index, one command each way**, at
every level tried. Not tried: `CFREQ`,
`STGID`, `SITE`.

### 3.6 The screen (`STS`) [hw]

`STS,[DSP_FORM],[Ln_CHAR],[Ln_MODE]…,[7 × RSV],[BK_COLOR],[BK_DIMMER]` as on the SDS, so
`DisplayStatus` parses it unchanged. Differences:

- **Lines are 24 columns** (the SDS's are 30).
- **The scan screen has 14 lines and no soft-key line**: form `00110110110000`, masks `_` on some
  lines. **Icon glyph bytes appear on it** (2 non-ASCII bytes on line 1 and 4 on line 5 while a
  call was on air; none while idle). The trailing fields change with the screen
  (`1,1,0,0,,,0,OFF,0` idle; `1,0,0,0,,,5,OFF,0` on a call).
- **A menu screen is the SDS's form at 24 columns**: 10 lines, form `1111111111`, title masked `_`,
  highlighted row `*`, other masks empty. Number and location entries: line 1 the title, line 2
  the value (mask 24 columns long, unlike the SDS's single cursor `*`), the units on line 5, lines
  6–10 blank; no soft-key line. A name entry: line 2 the name with a one-column cursor mask (the
  SDS's form), **4 glyph bytes on line 6** (the cursor arrows of [spec] V1.07's "4 ← cursor → 6"),
  lines 7–10 blank; no soft-key line.
- `STS` shows items `MSI` leaves out (as on the SDS).

### 3.7 What [spec] lists

V1.03: `MDL VER KEY QSH STS JNT NXT PRV FQK SQK DQK PSI GSI GLT HLD AVD SVC JPM DTM AST APR URC BFH
MNU MSI MSV MSB`. Not listed: `VOL`, `SQL` (they answer anyway), **`KAL`, `GCS`, `MSM`, `POF`**.
V1.05 (2018, also in `docs/uniden/`) adds the key-code sheet; `HLD`'s argument sheet ("tkd and
1st,2nd opt") is in neither PDF.

## 4. Approaches

1. **One stack; the BCD436HP is a fourth `ModelProfile`, its differences data. Chosen (the
   designer's recommendation; the owner chose the menu commands within it).** The Plan 17 shape:
   profile values, a mock personality, hardware checks, a hardware session. New per-model data:
   the menu navigation (§5.2), the screen layout (§5.3), the `Rssi` reading (§5.4), the destructive
   items (§5.5). `AGENTS.md` requires model knowledge in `ModelProfile`, not branches.
2. **BCD-specific handlers** (its own display model and menu model). The spike found one protocol;
   a second set of handlers would duplicate the SDS's and drift from them. Dropped.
3. **Turn it on and stop** (flip `supportsQuickKeys`, give it the keep-alive). Cheap, but the
   Scanner view would draw its bottom line as three soft-key labels and cut the screen at 30
   columns' width, the hit log would hold no RSSI, menus would Exit with an Avoid press, and
   nothing would be tested against a mock. Dropped.

Within 1, for menus: the SDS's `KEY` presses work on the BCD (§3.5, and [spec] V1.05's key sheet
gives the same codes), but `MNU` and `MSB` are the BCD's own menu commands and ran cleanly.
**`MNU`/`MSB` chosen (the owner's call: "if there are specific BCD commands those probably should
be used").**

## 5. Design

### 5.1 The BCD436HP's profile

`ModelProfile.profile(for: .bcd436hp)` becomes:

| Field | Value | Source |
|---|---|---|
| `volumeRange`, `squelchRange` | 0–15, 0–15 | [hw]: `VOL,16` and `SQL,16` set 15 (§3.2), and **the owner confirmed 0–15 for both on the radio's own controls (2026-11-25)**; today `nil`. The product already sends only values inside the range, so the radio's clamping never comes into play |
| `transports` | USB serial | unchanged |
| `destructiveMenuItems` | `.bcd436hp` (§5.5) | [spec] V1.07 |
| `hasNetworkAudio`, `supportsRemoteRestart`, `supportsChargeStatus` | false | `GCS` and `MSM` aren't in [spec] |
| `supportsQuickKeys` | **true** | [hw] reads (§3.4); sets [spec], §7 H7 |
| `usbProductIDs` | 0x001A | [hw] (shared; §5.6) |
| `pushKeepAlive` | renew the subscription every 60 s | [hw] (§3.3) |
| `pushInterval` | 100 ms | [hw]: a push about every 160 ms |
| `displayRefreshInterval` | 100 ms | **(designer's call)**, as the other handhelds; `STS` beside `PSI,100` not run on it (§7 H6) |
| `lineInAudioOffset` | zero | **[assumed]**; §7 H9 measures |
| `menuNavigation` (new) | the menu commands (§5.2) | **(the owner's call)** |
| `display` (new) | 24 columns, no soft-key line (§5.3) | [hw]; no soft keys (the owner) |
| `rssiReading` (new) | none until its unit is known (§5.4) | **(designer's call)** |
| `protocolVerifiedOnHardware` | false until the owner rules after §7 | |

After this, a name that is no known model is the only thing left at 500 ms pushes, 1 s screen
reads and no keep-alive. Tests that use the BCD436HP to mean "a model without a keep-alive", "the
old rate" or "no quick keys" move to an unknown name (`ModelProfileTests`,
`DisplayRefreshPolicyTests`, `KeepAliveCLITests`, `StationRunnerUSBTests`, `SerialIntegrationTests`,
the quick-keys refusal tests).

### 5.2 Menus: the BCD's commands

A new per-model value says how `MenuModel` enters, goes back and leaves a menu (names are the
builder's):

| Action | SDS models (unchanged) | BCD436HP |
|---|---|---|
| Enter (`enter()`) | `KEY,M,P` | `MNU,TOP,` |
| Back (`back()`) | `KEY,M,P` | `MSB,,` |
| Exit (`exit()`) | `KEY,L,P` | `MSB,,RETURN_PREVOUS_MODE` |

- Every rule of `MenuModel` holds unchanged (remote menus design §5.4–§5.5; `AGENTS.md`): `enter()`
  reads `GSI` first and sends only if not in a menu; `exit()` reads `GSI` first and sends only if
  still in one; **one action sends at most one of these and never resends it**, not even after a
  timeout; only a re-read says whether it took effect; actions are refused while another is in
  flight; a command still waiting for the request slot when the model detaches writes nothing
  (`SendPermit`, `onlyIf:`). `MNU` and `MSB` change scanner state and are treated as `KEY` is.
- `ScannerClient` gains the three sends, each with `onlyIf:` (names the builder's). `MSB,NG` is a
  rejection like any `NG` (`ScannerClientError.rejected`); after it `MenuModel` re-reads, as after
  any failed action.
- Choosing, toggling and saving stay `MSV,,<value>` after the `MSI` re-check, as on the SDS.
- **Why it matters beyond the owner's preference:** on the SDS an Exit whose `GSI` read was answered
  but stale could, in the accepted residual window, press `KEY,L,P` on a scanning screen, which
  is Avoid. `MSB` outside a menu is only refused (`MSB,NG`, [hw]). On this model that window
  closes.
- **The Scanner view still sends `KEY`** for its keypad and knob (`KeyPressQueue`), with [spec]
  V1.05's codes (§3.5a); `M`, `E`, `<`, `>`, `L`, `A`, `B` and `C` are also [hw]. In a menu its
  Menu key sends `KEY,M,P`, which goes back one level on the BCD too [hw].
- The Mac-style view's menu (`MacMenuView`) is unchanged: `MSI`'s shapes are the SDS's (§3.5). A
  `TypeLocation` screen keeps the mirrored-text fallback it has on the SDS (remote menus design
  §5); a native location entry is backlog (§8).
- The menu refresh reads (`GSI`, `MSI` about every 2 s while in a menu) are unchanged.

### 5.3 The screen

A per-model display layout (names the builder's) with two values: **columns** (30 for the SDS
models, 24 for the BCD436HP) and **whether the screen has a soft-key line** (yes for the SDS
models on the scan screen and on entry screens, as today; **no for the BCD436HP on any screen**: it has no soft keys, **(the owner, 2026-11-25: "there are no soft keys on the bcd")**, and its `STS` showed no soft-key line [hw]).

- `DisplayModel(status:info:)` takes the layout. With no soft-key line every `STS` line is a row
  and `softKeys` is empty, on every screen. The SDS rules are unchanged (lists: every line a row;
  scan and entry screens: the last line is the soft keys).
- `DisplayView` sizes the screen from the layout's columns and the rows it is given (today
  `columns = 30` and `screenHeight = 318` are fixed). The 14-line scan screen with its mix of
  large and small lines must fit without clipping; how it is scaled is the builder's.
- **The soft-key buttons are hidden, not disabled, for a model without soft keys (the owner's
  call, 2026-11-25: hide them or disable them; designer's pick: hide).** Disabled buttons would
  say the feature exists and is unavailable for now; the BCD has no such keys. Both rows go: the
  three under the Scanner view's screen (`DisplayView.softKeys`) and the three under the Mac-style
  view's mirrored screen (`MacMenuView`). In the Mac-style view the layout closes up; in the
  Scanner view the BCD's own System, Dept and Channel buttons take that place (Hold, below).
- `CLIFormat.display` (`noctule display`) prints soft keys only for a model with a soft-key line;
  for the BCD it prints every line. `display` sends `STS` only, so it learns the model from an
  `MDL` it sends first on a serial link (**designer's call**: one read-only `MDL` added to
  `display --serial`; over the network nothing changes).
- `DisplayRefreshPolicy` is unchanged (`displayRefreshInterval` from the profile).
- The keyboard shortcuts for soft keys (`KeyRouting`, the key map) stay, but on a BCD station a
  soft-key chord is not pressed (no `KEY,A|B|C`: the radio has no soft keys, as the owner
  said). The key-map editor keeps its Soft key 1–3 rows: a station's model is known only once
  `MDL` answers. **(designer's call)**
- **Hold.** On the SDS the Mac-style view's System, Department and Channel hold controls press the
  soft key labelled `SYSTEM`, `DEPT` or `CHANNEL` on the current screen (`StationSession.hold`,
  `canHold`). **On the BCD436HP they send `HLD` by index** (§3.5a), as per-model data (names the
  builder's): one command per action, never resent, the same command to hold and to release.
  - The target is the item the user was shown: its index from the latest `GSI` or push
    (`ScannerInfo`'s `NamedItem.index`). System: `HLD,SYS,<System Index>,`. Department:
    `HLD,DEPT,<Department Index>,<System Index>` (the parent always given; [spec] allows it).
    Channel: `HLD,TGID,<TGID Index>,` on a trunked channel, `HLD,CFREQ,<ConvFrequency Index>,` on a
    conventional one. **[assumed] for `CFREQ`** (documented, not tried). An ID-search talkgroup
    (`STGID`) is not sent until §7 H6 shows how one looks in `GSI`; until then the Channel control
    is disabled when the scanner is in an ID search **(designer's call)**.
  - `canHold(level)` on the BCD: connected, `GSI` doesn't report a menu, and the latest `GSI` or
    push has that level's element with an index. The hold state shown comes from that element's
    `Hold` attribute, not from `Mode` (a System or Department hold leaves `Mode` alone).
  - After an `HLD` (answered, refused or unanswered) the model re-reads `GSI`; that read decides
    the state shown. An unanswered `HLD` is never resent: it may have toggled.
  - The Channel key (`KEY,C,P`) also toggles a channel hold, but System and Department keys need a
    double-press (§3.5a), so the Mac-style controls use `HLD` at every level, one way for all.
- **The Scanner view's panel is per model (designer's call).** For the BCD436HP: its System, Dept
  and Channel buttons where the soft keys would be (each click one `KEY,<code>,P`, exactly as on the
  radio, so a double-click is a double-press, as the radio's own panel works); no Services key (`T`) and no squelch-knob push
  (`Q`), which it doesn't have; the volume knob's push (`V`) labelled Backlight. The rest is the
  SDS200 panel as today. These are real keys on the radio, unlike the soft keys. The key map's
  chords for keys a model lacks send nothing on that model.

### 5.4 `Rssi`

The SDS's `Rssi` is whole dBm, and the hit log stores `rssiMax` as dBm. The BCD's `1.267` is in a
unit nobody has identified. **(designer's call)** A per-model rule (the profile's `rssiReading`)
says how `Rssi` is read: SDS models as today; the BCD436HP **not read** (`ScannerInfo.rssi` nil), so
`status`, `watch`, the Mac-style view and the hit log show it as missing, as they do for the idle
`-999`. Over 1,005 pushes it didn't follow the bars (§3.2), so no conversion is attempted; one
found later is a later change. `Sig` (the bars, what hit detection reads) is
unaffected.

### 5.5 Destructive menu items

`DestructiveMenuItems.bcd436hp`, from [spec] V1.07's tree **(designer's call)**: the SDS's names
(`Clear User Data`, `Reset User Settings`, `Stop All Avoiding`, `Set All Lists Off`,
`Set All Lists On`) plus `Clear All ID Avoids` and `Reset to Factory`, with the prefixes `Delete`
and `Initialize`. The UI asks inline before sending any of them, as on the SDS (`MenuModel`,
`isDestructive`); Cancel sends nothing. Over-asking (an `Initialize…` setting that isn't an action)
is accepted; under-asking is not.

### 5.6 Three handhelds on one USB identity

`SerialPortInfo.knownModel` already reads the product name first, so `noctule ports` shows
`BCD436HP`; a 0x001A port with no product name stays `unknown model`. Nothing else about ports
changes. In use (for `AGENTS.md`): with any two of the three plugged in, every USB station needs a
saved port; an Automatic USB station conflicts with every other USB station; the BCD436HP's saved
port must be picked again when its cable moves to another socket.

### 5.7 The mock

A fourth personality, `MockPersonality.bcd436hp`: `noctule-mock-scanner --model bcd436hp
--serial` (serial only, like the SDS100; `MockSerialScanner(personality: .bcd436hp)` in tests).

| Behaviour | Value | Source |
|---|---|---|
| `MDL` | `MDL,BCD436HP` | [hw] |
| `VER` | `VER,Version 1.28.24` | `1.28.24` [hw]; the `Version ` prefix **[assumed]** (the SDS form) |
| `VOL`, `SQL` | 0–15; **out of range clamped to 0 or 15 and answered `OK`** | [hw] (§3.2) |
| XML | the SDS150's serial form; `MSI` with `<Footer No="1" EOT="1"/>` | `MSI` [hw]; the rest [assumed] |
| `GLT` | paged with footers like the other mocks (`--glt-page-size`) | [hw] (13 a page seen) |
| `KAL`, `GCS` | `ERR`, nothing else | **[assumed]** (not in [spec]; never sent by the product) |
| `MSM,1` | `MSM,NG` | **[assumed]**, never sent |
| Push lifetime | the SDS100's rule: stop 183 s after the latest `PSI`; a `PSI` while subscribed restarts it | stop at 183.3 s and the renewal [hw]; "every `PSI` restarts the full count" [assumed] |
| `MNU,TOP,` | opens the mock's top menu, `MNU,OK`; any other `MENU_ID` `MNU,NG` | `TOP` [hw]; the `NG` **[assumed]** (the product sends only `TOP`) |
| `MSB,,` / `MSB,,RETURN_PREVOUS_MODE` | back one level / leave the menu, `MSB,OK`; outside a menu `MSB,NG` | [hw] |
| `KEY,L,P` / `KEY,M,P` in a menu | leaves the menu entirely / back one level | [hw] |
| `KEY,A,P` / `KEY,B,P` (System / Dept) | one press: hold that level after a 2 s pause (on the mock's clock); two presses within the double-press window: hold at once, or release a hold | [hw]; the window's length **[assumed]** (0.5 s; the real one is at least 95 ms) |
| `KEY,C,P` (Channel) | one press holds or releases the channel; `Mode` gains ` Hold` | [hw] |
| `HLD,SYS\|DEPT\|TGID\|CFREQ,<index>,[<parent>]` | toggles that item's `Hold` at once, `HLD,OK`; an index the mock doesn't know `HLD,NG` | toggle for `SYS`, `DEPT`, `TGID` [hw]; `CFREQ` and the `NG` **[assumed]** |
| `KEY,T,P`, `KEY,Q,P` | `KEY,NG` | **[assumed]** (keys it hasn't got) |
| `STS` | 24 columns; scan screen 14 lines, form `00110110110000`, no soft-key line, icon glyph bytes on lines 1 and 5 during a transmission; menu and entry screens 10 lines, `_` title, `*` row, a name entry's cursor glyphs on line 6 | [hw] shapes; the glyph byte values **[assumed]** (counted, not read); the mock's own fictional text |
| `GSI` | `Property` `Rssi` a decimal (e.g. `0.812`), no `Battery`; a System or Department hold sets that element's `Hold="On"` and leaves `Mode` | [hw] |
| Idle between transmissions | the trunk idle form (`IdleForm.trunkSite`) | [hw] (an ID search) |
| Menus, scenarios, faults, unplug/replug, conventional and trunk transmissions, the Favorites tree, `--line-out` | the other serial mocks' | **[assumed]** |

The SDS personalities don't answer `MNU` or `MSB` (`ERR`) **[assumed]**, so a client that sent them
to an SDS model would fail on the mock first. `MockPersonality`'s and `MockSerialScanner`'s type
comments list the assumptions above. Following LESSONS.md 2026-11-12, the assumption a product
path leans on gets its pessimistic twin tested: renewals dropped (`--fault drop-request=PSI`) still
recover through the replace rule (Plan 8 D6).

### 5.8 What the user sees

- **Command line.** `ports` shows `BCD436HP`. `info --serial` prints model, firmware, volume and
  squelch, no battery line. `status` shows `rssi: -`. `display --serial` prints the 14 lines and no
  soft keys. `quick-keys --serial` prints its tree. `watch --serial` and `log` keep its pushes
  going past three minutes. No new messages.
- **The app.** A BCD436HP station behaves as an SDS100 station does: no battery, no audio unless
  a line-in is set, knobs and sliders 0–15, the waiting banner, the resume, Quick Keys, menus in
  both views, Hold. The Scanner view shows a 24-column screen with no soft keys, and its own
  System, Dept and Channel buttons. No new text.

### 5.9 Hardware checks in the test suite

As for the SDS100 (SDS100 design §5.6), opt-in, skipped while `NOCTULE_NO_USB_DETECTION` is set,
`MDL` must name `BCD436HP` else nothing more is sent, port `SCANNER_SERIAL_BCD436HP` from
`config/dev-scanner.env` exactly as written, else the one Uniden port whose product name names the
BCD436HP (`config/dev-scanner.env.example` gains the key):

- `NOCTULE_BCD436HP_HARDWARE_TESTS=1`: the read-only suite (`MDL`, `VER`, `VOL`, `SQL`, `GSI`,
  `STS`, one each; prints the `STS` form and line widths, never text, and `GSI` `Property`'s
  attribute names) and the quiet-port check.
- `NOCTULE_BCD436HP_PUSH_TEST=1`: the push suite.
- `NOCTULE_BCD436HP_KEEPALIVE_TEST=1`: `PSI,100` renewed as `PSI,100` every 60 s, held 240 s,
  failing on any `unexpected` line (the SDS100's `KeepAliveAtTheProductRate`).
- None sends `KAL`, `GCS`, `KEY`, `MSV`, `MNU`, `MSB`, `MSM` or `POF`. Each runs against the mock
  in every `swift test`, pinning what it sends.

### 5.10 Documents and agent rules

- **`AGENTS.md`**: the BCD436HP in the introduction's list; "Two handhelds share a USB identity"
  becomes three; the "What the hardware does" facts of §3; under "USB handhelds", its rules:
  probe read-only by default (`MDL`, `VER`, `VOL`/`SQL` with no argument, `GSI`, `STS`, `MSI`, the
  quick-key reads); **`MNU` and `MSB` change scanner state** (the go-ahead each time, one per
  action, never resent; the product sends them only from `MenuModel`); **`HLD` changes scanner
  state** (a toggle: the go-ahead each time, one per action, never resent; the product sends it
  only from the Hold controls); **never `KAL`, `GCS`,
  `MSM,1` or `POF`** (not in its spec); its keep-alive is the renewal; the mock's BCD436HP mode
  and its assumptions; the hardware-test variables.
- **`AGENTS.local.md`** (git-ignored): "The owner's BCD436HP", beside the SDS100's.
- **Protocol notes** (`2026-11-08-sds-remote-protocol.md`): the BCD436HP's rows marked
  [hw, BCD436HP]; `MNU`, `MSB` and `HLD` added (in both specs; tried only on the BCD), with
  `HLD`'s argument table; the first `TypeLocation` shape.
- **`docs/uniden/README.md`**: the BCDx36HP Remote Command Specification V1.03 and V1.05, the Menu
  Tree Specification V1.07 and the BCD436HP owner's manual, and where to get them.
- **`docs/specs/README.md`**: this design and its plan.
- **`LESSONS.md`**: the 2026-11-25 entry, written during the spike.

### 5.11 The handhelds' panel and encoder (the SDS100 and SDS150 too)

The SDS100, SDS150 and BCD436HP have one multifunction encoder on top: turning it scrolls, one
press makes turning set volume, Func then a press makes it set squelch **(the owner, 2026-11-25;
SDS150 owner's manual: "Press FUNCTION then tap scroll to display the squelch level")**. Its press
is `^`. None of them has a squelch-knob push (`Q`) or a Service Type key (`T`). Today the Scanner
view gives the SDS100 and SDS150 the SDS200's whole panel, so their Services button and squelch
knob push send codes the radios don't have, and their scroll knob's push reads "Func".

| Model | Keys it lacks | Encoder push caption | Source |
|---|---|---|---|
| SDS200 | none | Func (unchanged) | |
| SDS100 | `T`, `Q` | Vol | [spec] SDS V2.00 key sheet: `T` and `Q` "(none)", `V` Backlight |
| SDS150 | `T`, `Q`, `R` | Vol | SDS150 owner's manual: ZIP/SERVICES is one key (Func then Zip for Services), no Range key listed, Power/Light taps the backlight; that it has no `R` and that `V` is its Power/Light tap are **[assumed]** until §7 H11 |
| BCD436HP | `T`, `Q` | Vol | [spec] BCDx36HP V1.05 key sheet |

- Per-model data (`ModelProfile`): the keys the model has, and the encoder push's caption. The
  Scanner view's keypad leaves out a key the model lacks (the row closes up), the squelch knob has
  no push without `Q`, and the SCROLL knob's push keeps sending `^`, captioned per model, with the
  help text "Press: volume. Func, then press: squelch." on the handhelds.
- `StationSession.press(_:)` drops a key the model lacks, so a key-map chord for one sends nothing.
- The VOL and SQL knobs keep setting the level directly (`VOL,<n>`, `SQL,<n>`) on every model.
- The SDS handhelds' soft keys, menus and Hold are unchanged.

## 6. Tests

Written first, against the mock, per task. At least:

- `ModelProfile`: the BCD436HP's values; the moved "no keep-alive / old rate / no quick keys" cases.
- `MenuModel` on the BCD mock: `enter()` sends `MNU,TOP,` only when `GSI` says not in a menu;
  `back()` sends `MSB,,`; `exit()` sends `MSB,,RETURN_PREVOUS_MODE` only when `GSI` says in a menu;
  never a `KEY,L,P`; one command per action, never resent after a dropped reply
  (`--fault drop-reply=MSB`, `drop-request=MNU`); `MSB,NG` is reported and followed by a re-read;
  a command waiting for the slot when the model detaches writes nothing. The SDS models' tests pass
  unchanged and their mocks' logs hold no `MNU` or `MSB`.
- `DisplayModel` and `DisplayView` helpers: the BCD's scan, list and entry screens give every line
  as a row and no soft keys; no soft-key buttons in either view for the BCD (hidden, not
  disabled), three for the SDS models; the SDS's unchanged; 24 columns lay out without clipping;
  the BCD's panel has System, Dept and Channel, no Services key and a Backlight knob push.
- `ScannerInfo`: the BCD's decimal `Rssi` gives nil; the SDS's unchanged.
- Hold on the BCD mock: each level sends one `HLD` with the index from the latest `GSI`/push
  (`SYS`; `DEPT` with its parent; `TGID` or `CFREQ` by the channel element), and the same command
  releases; never resent after a dropped reply (`drop-reply=HLD`); the `GSI` re-read decides the
  shown state; `canHold` false in a menu, without that level's element, and for Channel in an ID
  search; no `KEY` sent by the Mac-style Hold controls; the SDS models' Hold unchanged (soft key by
  label).
- Volume and squelch on the BCD mock: the sliders and knobs never send a value outside 0–15.
- `CLIFormat.display` for both layouts; `display --serial` sends `MDL` then `STS`.
- Destructive items: each BCD name and prefix asks first; Cancel sends nothing.
- The mock: `MockPersonalityTests` pins the BCD's bytes (`MDL`, `VER`, 24-column `STS`, `MSI`
  with its footer, `Rssi`, `MNU`/`MSB` answers, the hold keys, `VOL`/`SQL` clamping, `KAL`/`GCS`
  `ERR`); the parser's
  `--model bcd436hp` rules.
- `StationRunner`/`StationSession` on the BCD mock: pushes past the lifetime with renewals, no
  `KAL`, `GCS`, `MSM` or `POF`; D6 when renewals are dropped; unplug and replug; `PSI,0` last.
- `QuickKeysModel` on the BCD mock: reads and a set, as for the SDS mocks.
- `SerialIntegrationTests` and `AppLifecycleIntegrationTests`: `ports`, `info`, `display`, `watch`,
  `log` and `quick-keys` against `noctule-mock-scanner --model bcd436hp --serial`, one app launch
  on it (and one with a menu entered and left), with the usual end-of-run checks.
- The panel per model (§5.11): each model's key set and caption; the SDS100 and SDS150 sessions
  drop `T` and `Q` (and the SDS150 `R`); the SDS200's panel and presses unchanged.
- `RealNamesTests` and `PrivateWordsTests` pass; the iOS build of `NoctuleAppCore` builds.

## 7. Hardware session (the owner's, after the build)

Each item at the owner's go-ahead; results into this document, the protocol notes and
`LESSONS.md`. `NOCTULE_TRACE` on throughout.

- **H1** The read-only suite and the quiet-port check (before and after the rest).
- **H2** The push suite and the keep-alive suite (240 s at `PSI,100`).
- **H3** An hour of `noctule log` on a BCD436HP station: no stall, no `subscribing again`.
- **H4** `noctule quick-keys --serial`: the tree prints, no `unmatched` or `dropped` trace lines.
- **H5** The app, half an hour or more: both views; a menu entered and left from the Mac-style view
  (`MNU,TOP,` and `MSB,,RETURN_PREVOUS_MODE` in the trace), Back once (`MSB,,`), and three minutes
  in a menu (renewals past the push lifetime, `MSI` answering); the 24-column screen and the
  14-line scan screen; an unplug and replug; quit (`PSI,0` last).
- **H6** In the app: Hold at each level from the Mac-style view, on and off, on a trunked and a
  conventional system (`HLD,CFREQ`); one `GSI` during an ID search, to settle `STGID` (§5.3); the Scanner view's keys once each (Func, Zip, Range, Replay, Backlight,
  the digits); a `VOL` and an `SQL` step; a name entry opened and backed out of; `STS` at 100 ms
  beside `PSI,100` for some minutes.
- **H7** One Quick Keys set from the pop-over (a tile off and on again), and one system set.
- **H8** A conventional hit and a trunked hit in the hit log, with the fields a hit should have.
- **H9** Line-in on the owner's rig (the jack is wired to the USB audio interface): recordings
  line up with the hits (`lineInAudioOffset`), and the level at the radio's volume.
- **H10** The BCD436HP and an SDS handheld at once: two stations, each with a saved port.
- **H11** On the SDS150 and the SDS100 (the owner's, in the app): the panel shows no Services key
  and no squelch push, the SDS150 no Range key (the owner confirms it has none), the scroll knob's
  push sets volume as on the radio, and the light key toggles the backlight.

After the session the owner rules whether the BCD436HP is verified, and
`protocolVerifiedOnHardware` follows.

## 8. Known limits and backlog

- **The Scanner view keeps the SDS200's panel shape** around the BCD436HP's screen, with its own
  keys (§5.3). A panel drawn like the BCD436HP is backlog.
- **No RSSI** for the BCD436HP until its unit is known (§5.4); [spec]'s own `GSI` example sends
  `Rssi="0.377"`, so a decimal is its normal form.
- **Hold on an ID-search talkgroup** (`HLD,STGID`) waits for H6 (§5.3).
- **`HLD` on the SDS models:** in the SDS spec V2.00 with the same arguments, never tried there;
  it would hold by index instead of by soft-key label. A later, owner-gated change.
- **No battery reading:** no `GCS` in [spec] and no `Battery` in `GSI` (§3.2).
- **`MNU`/`MSB` on the SDS models:** in the SDS spec V2.00 too and never tried there; they would
  close the same Exit-presses-Avoid window. A later, owner-gated change.
- **A native location entry** in the Mac-style view (`TypeLocation` is now seen on hardware).
- **The BCD's other menu IDs** (`MNU,SETTINGS,` and the rest) as shortcuts in the app.
- **Its saved port follows the socket**, and two radios of one model can't be told apart
  (SDS100 design §8).

## 9. Left to the builder

Type, case and method names (the menu navigation kind, the display layout, the `Rssi` rule, the
`ScannerClient` sends); how `DisplayView` scales the 14-line screen; the mock's fictional screen
text; whether the handheld hardware-check file is split or renamed; the wording of comments and
of the `AGENTS.md` sections within the rules above; task order, provided the mock personality and
its tests come before any product path that uses them.
