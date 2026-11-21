# Favorites quick keys — design

Date: 2026-11-18. Status: **approved by the owner in chat, 2026-11-18**, with the cache rules in §5.4 added at their request. Written after a brainstorm with the owner on 2026-11-18, a
spike on all three of the owner's scanners (§3), and a builder check whose one open question the owner answered (zeros
in a set, §3.3, §5.4) after a second hardware check. **Built** on `feature/quick-keys` (Plan 20,
`2026-11-18-plan-20-quick-keys.md`) against the mocks, not yet merged; §10 says what was built and where it departs from
§5. The hardware session (§7) has not run. The spike ran on throwaway code that was deleted and never committed.

Labels: **(the owner's call)** is a decision the owner made in the brainstorm; **(designer's call)** is a default the
designer chose that the owner hasn't ruled on and can overturn. **[hw]** is a fact seen on the owner's scanners on
2026-11-18 (SDS150 fw 1.01.02 over USB, SDS100 fw 1.26.01 over USB, SDS200 fw 1.26.01 over the network); **[spec]** is
Uniden's *SDS Series Remote Command Specification* V2.00; **[manual]** is the SDS200 and SDS150 owner's manuals (which say
the same); **[assumed]** is something none of them has shown. Everything not labeled is fact about the code or a pointer.
Every name in this document is made up; the owner's list, system and department names stay out of tracked files.

## 1. Why

On the SDS scanners a Favorites List, a system inside it, and a department or site inside that can each have a **quick
key**, a number 0–99, and the radio's number keys turn those on and off. The owner forgets what each number is set to, so
they keep a printed cheat sheet beside the radio: one row per list with its number, and the list's systems under it with
theirs. ProScan's Favorites editor shows the same data in a dense table that the owner finds too complex for this.
**(the owner's call)**

The owner wants Noctule Scan to replace the cheat sheet: **discover the Favorites Lists from the scanner, and give a
point-and-click way to turn lists, and their systems and departments, on and off.** The names are what make it useful;
the number is how you reach a list on the radio. **(the owner's call)**

## 2. Goals, non-goals, anti-goals

**Goals.**

1. The app reads the scanner's Favorites Lists, each list's systems, and each system's departments and sites, with their
   names, quick keys and on/off states, from the scanner itself, with nothing to set up. **(the owner's call)**
2. A pop-over in the station window shows the lists as a keypad of quick keys; a click turns a list on or off, and the
   list's systems and departments open in a tree below it, each with its own switch. **(the owner's call)** §5.5.
3. It works the same on the SDS200 over the network and on the SDS150 and SDS100 over USB. **(designer's call)**
4. It never makes the user wait for the whole tree: the keypad shows at once and the rest fills in. **(the owner's call,
   accepting the designer's proposal)** §5.4.
5. `noctule quick-keys` prints the same tree as text, read-only. **(the owner's call, accepting the designer's
   recommendation)** §5.3.

**Non-goals.**

- Editing Favorites Lists: adding, removing, renaming or reordering lists, systems, departments or channels, or assigning
  quick-key numbers. The protocol can't [spec]; that stays with Sentinel, as the original design says.
- Channels (conventional frequencies and talkgroups). They have no quick keys [manual]; turning one off is an Avoid, a
  different mechanism. The tree stops at departments and sites. **(designer's call)** A later fourth level is in §8.
- Changing *Select Lists to Monitor* (the `Monitor` setting). No remote command sets it except driving the menus. The
  pop-over shows it, read-only. **(designer's call)**
- The cheat sheet's colors per list. The scanner doesn't store them. **(designer's call)** Backlog, §8.
- iPad and iPhone views. The model is in shared code (§5.4); the views are Mac only, like the rest of the app.

**Anti-goals** (failure even if it works).

- Having to relearn the radio. The numbers in the app are the radio's numbers, and a tile does what the number key does.
- Looking inside a list changing anything on the scanner.
- A click that hangs the window for seconds, or a switch that claims a state the scanner didn't confirm.
- Overwriting a change made on the radio's own panel a moment earlier.

## 3. What the spike found (2026-11-18)

At the owner's request a throwaway test read the whole tree on each scanner, then, with the owner's go-ahead, flipped one
key at each level and put it back. Each state-changing command was sent once and checked by a read; every scanner ended
as it started. **[hw]** unless marked.

### 3.1 Reading the tree

- `GLT,FL` returns one `<GLT>` document of `<FL Index Name Monitor Q_Key N_Tag>`. `GLT,SYS,<FL Index>` returns
  `<SYS Index Name Type Q_Key Avoid CountyId N_Tag>`; `GLT,DEPT,<SYS Index>` returns `<DEPT Index Name Q_Key Avoid
  TGroupId|CGroupId>`; `GLT,SITE,<SYS Index>` returns `<SITE Index Name Q_Key Avoid SiteId>`. `Q_Key` is a number or
  `None`. The drill-down argument is the parent's `Index`, never its quick key.
- Built-in entries to hide: the lists `Full Database` (`Index="4294967295"`) and `Search with Scan`
  (`Index="4261412864"`), always `Monitor="Off" Q_Key="None"`, and a department `Unknown` (`Index="4294967295"`) at the
  top of most systems' departments.
- Indexes are not contiguous (the owner's lists are 0, 2, 4, …).
- **Every `Index` is unique across the whole tree** [hw, 2026-11-19, read-only, the owner's SDS200 and SDS150]: 12
  lists, 28–29 systems, 141–143 departments and 257 sites, no index repeated, not even between a department and a site
  or between a system and a child; only the built-ins above repeat. So each system belongs to one list and each
  department or site to one system, which is what lets the model refuse a late `GLT` reply landing on another parent's
  read (§10 "Late replies"). `MockFavorites.default` keeps it (`theMockTreesIndexesAreUniqueAcrossKinds`).
- ~~Over USB the existing `SerialResponseAssembler` parsed every `GLT` reply with no change.~~ **Wrong (2026-11-19):**
  every reply parsed, but nobody checked that it was whole. Over USB serial a `GLT` reply comes in pages: every document
  ends with `<Footer No="n" EOT="0|1"/>`, and a long reply is several documents back to back, each its own
  `GLT,<XML>,` line, numbered from 1 with `EOT="1"` on the last only [hw, the SDS150 (fw 1.01.02) and the SDS100
  (fw 1.26.01), read-only `noctule quick-keys` with `NOCTULE_TRACE`]. 17 of 58 replies on the SDS150, and 17 of 57 on
  the SDS100 (74 documents), had more than one page, up to 7, `GLT,FL` included (2 pages); pages held 6–13 elements, so
  the radio pages by size. The assembler stripped the footer and handed on each page as a whole reply, so the client
  took page 1 for the reply and the rest were dropped as unmatched, or answered the next `GLT` read: `noctule
  quick-keys` printed a silently truncated tree (216 and 213 rows against the SDS200's 438), and in the app a
  `GLT,DEPT` received the second page of the `GLT,SITE` before it, the list read failed, and since a failed list is
  read again first, it failed every 2 s and no list behind it loaded. Fixed in §10 ("Paged `GLT` replies"). Over the
  network the spike added `GLT` to the commands `UDPTransport` marks as expecting XML (`UDPTransport.send`, beside
  `GSI`, `MSI` and `PSI`); with that, all 102 replies assembled, and the 2026-11-19 run gave the whole tree (60 reads,
  nothing unmatched): `UDPDatagramAssembler` already put pages together by `No`. Whether the SDS200's pages are
  separate datagrams wasn't looked at.
- Timings with nothing else talking to the scanner (the owner's 11–12 lists, 27–28 systems, about 100 commands):

| | SDS150 | SDS100 | SDS200 |
|---|---|---|---|
| `GLT,FL` + `FQK` (the keypad) | 0.01 s | 0.02 s | 0.07 s |
| one list's tree, median / largest (20 commands) | 0.05 / 0.2 s | 0.11 / 0.3 s | 0.25 / 0.9 s |
| the whole tree | 0.8 s | 1.5 s | 4.2 s |

No UDP command was lost in the SDS200's 102, but about one in 12 usually is (LESSONS.md 2026-11-10), each costing a
command timeout.

### 3.2 Quick-key states

- `FQK` → `FQK,` and 100 values; `SQK,<list key>` → `SQK,` and 100 values; `DQK,<list key>,<system key>` → `DQK,` and
  100 values. Each value is 0 (no such key), 1 (off) or 2 (on) [spec]. **The replies carry only the 100 values**: the
  spec's shape for `SQK` and `DQK` replies, which repeats the list and system keys first, is wrong on all three models.
- `SQK` and `DQK` are addressed by quick-key numbers, not indexes. A list with no quick key has no system-key states the
  protocol can address; nor does a system with no quick key have department-key states.
- Department and site keys share one numbering (`DQK`): in a trunked system the keys are usually on the sites, and on one
  system a department and a site both use D-0. Two departments in one system shared a key. No two systems in a list
  shared a key in the owner's data, but the manual allows it [manual].
- **Unexplained:** in one of the owner's lists, two systems each have a department with a `Q_Key` (2 and 3) in `GLT`, but
  `DQK` for those systems reports all 100 values 0. Identical on all three scanners.
- Each radio has its own on/off states; the owner's lists are the same on all three.

### 3.3 Switching

- `FQK,<100 values>`, `SQK,<list key>,<100 values>` and `DQK,<list key>,<system key>,<100 values>` each answered
  `<CMD>,OK`, and the re-read showed exactly the one changed value.
- **A 0 in a set is ignored** [spec], confirmed for `SQK` on all three models: with the owner's go-ahead, one system key
  was flipped by an `SQK` set carrying 0 for every other key, in a list with four system keys. Only that key changed, the
  other three kept their values, and the restore, also sent with zeros, put it back. So a set can name just the one key
  it changes (§5.4). `FQK` and `DQK` with zeros weren't tried; the spec says the same for both [spec] (§7).
- Time to `OK`: `FQK` and `SQK` 0.75–0.87 s on every model; `DQK` 0.02–0.09 s.
- `GSI` after a flip looked the same as before it: nothing in the status says a key changed.

### 3.4 "Scanning now"

`GSI` (and so every `PSI` push) names the current `MonitorList`, `System`, `Department` and `Site`, each with an `Index`.
**The `Q_Key` that `GSI` gives the `MonitorList` is not the list's quick key**: on all three scanners it said 0 or 1 for a
list whose `GLT` key is 9. The list's and the system's `Index` match `GLT`'s on all three. The department was the
unprogrammed `4294967295` in every snapshot (an unprogrammed talkgroup), so a department match wasn't seen. The site
being received was not among that system's `GLT,SITE` sites on any of the three (by index or by name): the scanner was
on a site outside the Favorites tree. So "scanning now" is matched by `Index`, and a level with no match has no mark.

### 3.5 The SDS100

Its first two tries timed out on `MDL`, port present, nothing else sent; a later try answered everything. The cause wasn't
seen (a screen or menu on the radio, perhaps). The pop-over must cope with a scanner that doesn't answer (§5.4).

## 4. Approaches

1. **Read live from the scanner** with `GLT` and the quick-key commands, keep the last tree per station, switch with
   `FQK`/`SQK`/`DQK`. **Chosen.**
2. Read the Favorites files from the SD card (`f_list.cfg` and `.hpd`). Rejected: FTP is a non-goal, and the handhelds
   expose files only in USB mass-storage mode, which removes the serial port the station uses.
3. A ProScan-style editor. Rejected: the protocol can't edit lists, and the owner found ProScan's view too complex.

Build order **(the owner's call, the designer's recommendation):** (a) the protocol and the mock; (b) `noctule
quick-keys`; (c) the pop-over; (d) the owner's hardware session. The alternative, the pop-over first with no command-line
step, was declined.

## 5. Design

### 5.1 Protocol (`NoctuleKit`)

- **Types** (shared code, no UI): a `FavoritesList` (index, name, quick key or none, monitored), `FavoritesSystem` (index,
  name, type, quick key), and `QuickKeyChild` (index, name, quick key, kind: department or site); `QuickKeyStates`, the
  100 values as `none`/`off`/`on`. Parsed from the `GLT` documents in §3.1, dropping the built-in entries. Unknown
  attributes are kept or ignored, never fatal; a document with an unexpected root is an error.
- **Client calls** on `ScannerClient`: `favoritesLists()`, `systems(inList:)`, `departments(inSystem:)`,
  `sites(inSystem:)`, `listKeyStates()`, `systemKeyStates(listKey:)`, `departmentKeyStates(listKey:systemKey:)`, and
  three setters that each set **one key** to on or off (`setListKey(_:on:)`, `setSystemKey(_:inList:on:)`,
  `setDepartmentKey(_:inList:system:on:)`). A setter sends 100 values that are 0 everywhere but that key (1 or 2), so it
  can never change another key, whatever the client last read (§3.3). **(the owner's call, after the builder check)**
  Reads may be retried after a timeout (they change nothing). **A setter is never retried**; a timeout is reported as
  "unknown" and only a re-read says what happened.
- A setter refuses a key outside 0–99 before anything is sent.
- `ScannerCommand` takes a variable argument list today; a setter needs 100–102 arguments, so it gains an
  array-taking initializer with the same validation. **(designer's call on the shape)**
- `UDPTransport` adds `GLT` to the commands that expect XML (§3.1).
- Model data: `ModelProfile` gains `supportsQuickKeys` (true for the SDS200, SDS150 and SDS100; false for other models, so
  the toolbar button is hidden). **(designer's call)**
- The protocol notes (`2026-11-08-sds-remote-protocol.md`) record §3, sanitized.

### 5.2 The mock

Both mocks (`MockSDS200` over UDP, `MockSerialScanner` in both serial personalities) answer `GLT,FL|SYS|DEPT|SITE` and
`FQK`/`SQK`/`DQK` get and set, from a fictional tree in the scenario data (default scenario: about a dozen lists over keys
0–15 plus a few in the 20s and 40s, so the tens control has empty and full tens). The tree reproduces every shape §3 saw:
the built-in lists and `Unknown` department, non-contiguous indexes, a list with no quick key, a list that isn't
monitored, a system with no quick key, a trunked system whose keys are on its sites, a department and a site sharing a
key, two departments sharing a key, and one system whose departments have `GLT` keys that `DQK` reports as 0 (§3.2). The
`MonitorList` in its `GSI` and pushes gives a `Q_Key` different from the list's (§3.4), so a client that matches by quick
key fails on the mock.

- Sets change the mock's state and answer `OK`; a 0 in a set leaves that key as it was (§3.3); a set with the wrong number
  of values, or for a list or system key that doesn't exist, answers `NG` and changes nothing. `FQK` and `SQK` sets reply after about 0.8 s, `DQK` at once (§3.3),
  unless `--no-delays`. **[assumed]**: the `NG` cases, which weren't tried on hardware.
- The quick keys don't change the scenario's traffic (a list turned off on the mock still "transmits"). **(designer's
  call)** Simulating scan selection is backlog.
- A fault, `--fault drop-reply=FQK` and the rest, works on these commands as on any other. `MockSDS200.quickKeyStates`
  and the serial mock's equivalent show the state to tests; the verbose log shows every `GLT`, get and set.

### 5.3 `noctule quick-keys`

`noctule quick-keys [--host H] [--port P] | --serial [PATH]` (the same addressing as `info`) prints the tree, read-only,
then exits 0:

```
F0   on   Police
  S0   on   Lakeview City P25
    D0   on   Fire Dispatch
    D1   on   EMS Tactical
F1   off  Fire & EMS
  S0   on   County 800 Trunk  (trunk)
    D0   on   Site North  (site)
    D1   off  Site South  (site)
F12  -    Old Event  (no quick key)
     not monitored: Holiday Parade
```

**(designer's call on the exact format; the builder may improve it)** It sends `MDL`, `GLT`, `FQK`, `SQK` and `DQK` reads
only, never a set; over serial it opens and closes the port like `info`. A key whose state the scanner doesn't report
(§3.2) prints `?`. The same refusals as the other read-only commands apply (`--serial` with `--host`, no address).

### 5.4 The model (`NoctuleAppCore`)

A `QuickKeysModel` per station session (`session.quickKeys`), built like `MenuModel`: state and actions, no views, unit
tested against both mocks.

**Loading.** **(the owner's call on the behaviour, the designer's on the mechanics)**

1. Opening the pop-over reads `GLT,FL` and `FQK` first and publishes the keypad (well under 0.1 s on every model, §3.1).
2. The last full tree for the station is kept on disk (`Stations/<uuid>/quick-keys.json`, beside the hit log; it holds
   real names, so it is never in the repo) and shown at once on later opens, under the cache rules below. **(designer's
   call)**
3. The rest is read in the background, one list at a time: the list being scanned first, then in key order. When the
   user opens a list that hasn't been read this session, it jumps the queue; its panel shows a small progress indicator
   until it arrives. What changed since the cached copy updates in place.
4. While the pop-over (or its torn-off panel) is open, the model re-reads `FQK`, the open list's `SQK`, and the `DQK` of
   the open list's systems about every 2 s, so a key pressed on the radio shows up. **(designer's call on 2 s, matching
   the menu refresh)** The tree itself (`GLT`) is re-read on each open, not on the timer.
5. All of this goes through the session's `ScannerClient`, so it queues behind and between the display and other reads
   and never runs two commands at once. Nothing reads while the pop-over is closed.

**The cache can be wrong at any time.** **(the owner's call: the radio's own keys can change what is enabled at any
moment; the designer's on the rules)** The radio's number keys and *Manage Quick Key Status* change states, and its
menus can also edit Favorites (rename, add, remove, assign or move a quick key), as can Sentinel. A set names a key
number, so a click on a stale tree could switch whatever now holds that number. So:

1. **States are never cached.** The cache holds structure only (names, indexes, quick-key numbers, types). On/off comes
   only from reads made since this open; until a scope's states have been read, its rows show no on/off (a neutral
   look) rather than a remembered one.
2. **The keypad is never from the cache.** `GLT,FL` and `FQK` are read on every open before the keypad is shown (§3.1:
   under 0.1 s), so the tiles, their names and their states are always fresh.
3. **Nothing from the cache is switchable.** A list's tree shown from the cache is marked as checking and its switches are
   disabled until that list's `GLT,SYS`, `GLT,DEPT`/`GLT,SITE` and its `SQK`/`DQK` have been read since this open. The
   list's tile (fresh, item 2) works at once.
4. **Changes while open are caught.** A poll whose pattern of existing keys differs from the tree's (a key appeared or
   disappeared, §5.4 Switching item 4) re-reads that scope's structure before anything there is switchable again. When
   the scanner leaves a menu (`session.menu`, or the pushes), every tree is marked as checking and read again, since the
   menus may have edited Favorites. **(designer's call)**
5. Any difference found replaces the cache, which is rewritten after each full read. A cache that can't be read is
   simply no cache.

**Switching.** One click is one action; one action sends at most one set and never resends it (the scanner rules in
`AGENTS.md`).

1. A click asks for the opposite of what the view shows: a blue tile asks for off, a gray one for on.
2. The model sends that one key's set, 0 everywhere else (§5.1). Setting a key to the state it already has is harmless,
   so no read is needed first, and a change made on the radio to any other key is never touched. **(designer's call,
   following the owner's choice of zeros)**
3. It then re-reads the scope (`FQK`, or that list's `SQK`, or that system's `DQK`) and shows what the scanner holds. A
   reply of `NG` or a timeout is reported in the pop-over ("The scanner didn't confirm the change"), with the state from
   the re-read.
4. Replies are matched to requests by command name (`ScannerClient`), so a late reply to an earlier read of the same
   command can answer this re-read with another scope's values. That can only mislead the display, never a write, and
   the next 2 s re-read corrects it. To keep it rare, the confirming re-read and the polls drop a reply whose pattern of
   existing keys (which values are non-zero) differs from the pattern that scope showed on its first read after the tree
   was loaded (not the tree's `Q_Key`s, which can disagree, §3.2), and read again once.
   **(designer's call)** That holds for state replies, whose values never give a set its keys. A late *structure* reply
   (`GLT`) is another matter: the final review (C1) found one putting one system's departments under the next system,
   fresh, so a click there named another department's key. §10 "Late replies" gives the rules that keep it out: a
   `GLT` reply naming an item another parent holds is refused, and no system, department or site switches until every
   list on the keypad has been read since the pop-over opened. And a system's or a department's set first proves its own
   address with `GLT` reads (§10 "The pre-set check"). **(builder's note; the pre-set check is the controller's
   ruling)**
5. While an action runs (about 0.8 s for lists and systems, §3.3), the clicked tile or switch shows a working state and
   further clicks on that scope are refused, not queued. Clicks on other scopes wait for the client's request slot as
   usual. **(designer's call)**

**Shared numbers.** A key number shared by several systems in a list, or several departments and sites in a system, is
one switch on the scanner. Every row with that number changes together, and each such row carries a small "shared"
mark naming how many rows share it. **(designer's call)**

**What can't be switched.** **(designer's call)**

- A list with no quick key, a system with no quick key, and a department or site with no quick key show without a
  switch, labelled "no quick key". The radio scans them whenever their parent is on (and, for a list, whenever it is
  monitored) [manual].
- A key that `GLT` shows but the scanner reports as 0 (§3.2) shows its number with the switch disabled and the help text
  "The scanner doesn't report this key's state."
- A list that isn't monitored but has a quick key keeps a working tile: the key exists and its state is kept, it just has
  no effect until the list is monitored [manual]. The tile shows "Not monitored" and its panel says to turn it on in
  *Select Lists to Monitor* on the radio or in Sentinel. The tens control's "n on" counts the key's state as for any
  list. That `FQK` reports 1 or 2 for such a key, as for any other, is **[assumed]** (the owner's lists were all
  monitored); the mock does so, and §7 checks it if the owner has such a list. **(designer's call)**
- When two or more systems in a list share a system key, `DQK,<list key>,<system key>` can't tell them apart, so the
  department and site switches under those systems are disabled, with the help text "Systems S<n> share a quick key, so
  their departments can't be switched separately here." Their states are still shown. What `DQK` returns for a shared
  system key is **[assumed]** (none in the owner's data); the mock returns the states of the first such system in `GLT`
  order. **(designer's call)**
- A system, department or site whose `GLT` `Avoid` isn't `Off` shows an "Avoided" tag: it doesn't scan whatever its
  switch says. Read-only; changing Avoid is out of scope. **(designer's call)**
- An off list dims its systems, and an off system its departments and sites: their own switches keep their values and
  still work, but nothing under an off parent scans.

**Scanning now** comes from the session's pushes (`ScannerInfo.monitorList`, `.system`, `.department`, `.site`), matched
to the tree by `Index` (§3.4), never by quick key. A level whose `Index` isn't in the tree (an unprogrammed department, a
site outside the Favorites, §3.4) gets no mark; the levels above it keep theirs. **(designer's call)**

**When not to switch.** While the scanner is in a menu (`session.menu.isInMenu`, or the last push says so) every switch
and tile is disabled with the help text "The scanner is in a menu"; reading still works. **(designer's call)** While the
session isn't connected (waiting for a USB scanner, no answer, stopping) the pop-over shows the cached tree, read-only,
with the session's state; it reconnects to live data when the session does. A model without `supportsQuickKeys` has no
model.

### 5.5 The pop-over (`NoctuleScan`)

**(the owner's calls, from the mockups `keypad-tree-v4.html` and `keypad-paging-v2.html` in the brainstorm)**

- **Opening.** A Quick Keys button in the station window's toolbar, in both the Scanner and Mac-style views, opens a
  pop-over. Dragging it away tears it off into a floating panel that stays open until closed. One per station window.
- **The tree belongs to the focused tile (the owner's call, 2026-11-19).** When the focus moves to another list's tile
  (a click, or a typed key), the shown tree closes and the placeholder returns; only `n ›`, ⌘↓ or a search hit opens
  one. Paging the tens keeps it. See §10.
- **The keypad.** One tile per quick key 0–99 in the current ten. A tile shows the number large, the list's name under it
  (two lines, never cut off mid-word where it fits), and in its top-right corner a small "n ›" button with the list's
  number of systems. A key with no list is a faint placeholder, so each number stays in the same spot.
- **Colors.** Blue fill and blue border: on. Gray: off. A green ring: the list being scanned. A white outline with a
  pointer down to the panel: the list whose tree is open. (This is the theme of the owner's screenshot.)
- **Clicks.** Clicking a tile turns that list on or off, like its number key on the radio. Clicking its "n ›" opens the
  list's tree below without changing anything.
- **The tens.** A standard Mac segmented control, 0–9, 10–19 … 90–99, each segment showing how many of its lists are on.
  A ten with no lists is disabled (greyed, not clickable). The ten holding the list being scanned has a green ●. A
  two-finger swipe, or ‹ ›, steps to the next ten that has lists, skipping empty ones, with page dots under the keypad. The
  pop-over opens on the ten holding the list being scanned (else the first with lists).
- **Lists with no quick key** (§5.4) appear after the keypad in a short "No quick key" row, read-only. **(designer's
  call)**
- **The tree.** Under the keypad, a panel for the open list: a header with its key, name, "n systems, m on" and a "Scan
  this list" switch (the same action as clicking the tile); then its systems, each with a disclosure triangle, its S
  number tag, name and switch; under each system its departments and sites, indented with connecting lines, each with its
  D number tag, name, a "site" tag for sites, and switch. A green dot marks the system and department or site being
  scanned. Systems open automatically when the list has three or fewer, else collapsed but for the one being scanned.
  **(designer's call on the last sentence)**
- **Search.** A field at the top finds lists, systems, departments and sites by name or number, jumping to the ten and
  opening the list that holds the match.
- **Keyboard.** Typing a number (e.g. 42) jumps to that key's ten and highlights the tile; Space or Return toggles the
  highlighted tile; ⌘↓ (or Return on the "n ›") opens its tree. While the pop-over or panel has focus, keys go to it, never
  to the scanner (the station window's key monitor acts only for its own key window). **(designer's call)**
- **States.** A working state on a tile or switch during its action; the "Not monitored", "no quick key", "shared" and
  disabled states of §5.4; an error line at the top of the pop-over for a refused or unconfirmed change, and for a
  scanner that isn't answering ("The scanner isn't answering", as the Mac-style menu says).
- **Accessibility.** Each tile is a toggle with the label "<name>, quick key <n>" and value on/off; the "n ›" button is
  "Show systems in <name>".

### 5.6 Documents and agent rules

- `AGENTS.md`: the quick-key commands. **Reads (`GLT`, `FQK`, `SQK`, `DQK` with no values) are read-only and may be sent
  to every model in a hardware run the owner asked for.** **A set (`FQK`/`SQK`/`DQK` with values) changes scanner state:
  each one needs the owner's go-ahead, one per action, never resent**, like `KEY` and `MSV`. The app sends sets only from
  a user's click. Tests never send a set to real hardware.
- `noctule quick-keys` in the Build and test section, and the pop-over in the Mac app section.
- LESSONS.md: the spike's surprises (the spec's reply shape, the `GSI` quick key, the unexplained 0s).

## 6. Tests

Strict TDD on a feature branch, as every plan in this repo.

- **Protocol:** parsing of each `GLT` shape in §3.1 from sanitized fixtures of the real replies (same shapes and
  attribute order, fictional names and indexes), including the built-in entries; the 100-value replies; refusal of bad
  state vectors before sending; a setter that times out is not retried; `GLT` over UDP assembles (fragmented too).
- **Mock:** every shape in §5.2; sets change state; the `NG` cases; the delays; the faults.
- **CLI:** `noctule quick-keys` against both mocks (network and serial, both personalities) in the integration tests, with
  the kill-switch and a decoy port listing as for every serial test; its mock log holds no set.
- **Model:** against `MockSDS200` and `MockSerialScanner`: keypad first, then the background reads in the stated order; the
  open list jumps the queue; the cache is shown and then replaced; nothing from the cache is switchable and no cached
  state is ever shown; a key moved on the radio (the mock's tree edited between opens, and while open) never lets a
  click switch the item that used to hold that number; leaving a menu re-reads the trees; one set per click, naming only the clicked key (every
  other value 0); a click on a key the radio already changed sends the requested value and shows the result; a timeout or `NG` reported and not resent; refused clicks while busy; shared numbers; the
  disabled cases; nothing switchable in a menu; scanning now by index (fails if matched by quick key, thanks to §5.2);
  polling only while open; nothing left running after the pop-over closes or the session stops.
- **App:** the tens control (disabled tens, skipping, opening on the scanning ten), keyboard routing (digits to the
  pop-over, not the scanner), and the views' helpers in `NoctuleScanTests`; then a run of the real app on the mocks driven
  with computer use, every click checked against the mock's verbose log (one set per click).

## 7. Hardware session (the owner's, after the build)

On each of the SDS200, SDS150 and SDS100, the owner's call each time:

1. `noctule quick-keys` (read-only): the tree matches the radio and ProScan.
2. The app on that station: the pop-over opens with the keypad at once; the tree fills in; times noted.
3. One list, one system, and one department or site turned off and on again from the pop-over, each checked on the radio,
   with the others in the same list or system unchanged: the first use of `FQK` and `DQK` sets carrying zeros (§3.3).
4. A key pressed on the radio while the pop-over is open shows within a few seconds.
5. "Scanning now" follows the scan, at list and system level, and at department and site level when the scanner is on a
   programmed department or a site in the tree (§3.4).
6. The torn-off panel stays open while scanning for ten minutes, with nothing else odd in the window's warnings.

## 8. Known limits and backlog

- Channels as a fourth level, switched by Avoid (`GLT,CFREQ`/`GLT,TGID`, `AVD`); the owner hasn't decided between a
  temporary and a permanent avoid.
- Changing *Select Lists to Monitor* through the menus.
- The cheat sheet's colors, set per list in the app.
- The mock simulating scan selection, so a list turned off stops its traffic.
- The unexplained 0 states (§3.2): perhaps a quirk of those systems' programming. Worth a look in Sentinel.
- Printing the cheat sheet from the app.

## 9. Left to the builder

- The exact Swift names and file layout, following `MenuModel` and the session's existing parts.
- How the tear-off is built (an AppKit `NSPopover` with detaching, or a separate panel window); it must behave as §5.5.
- The pop-over's exact sizes and spacing, within the mockups' look.
- The cache file's format and versioning (follow the settings store's pattern: a missing or unreadable file is just no
  cache).
- The `noctule quick-keys` text format's details.

## 10. What was built (Plan 20, 2026-11-18)

On `feature/quick-keys`, test first against the mocks, each task with a developer and a QA pass (mutation runs in a
temporary worktree). Nothing here has run on a real scanner; §7 is the owner's session. The calls below marked
**(builder's call)** were made during the build by the builder or the plan's controller, not by the owner: each is open
to the owner.

- **Swift names (§5.1, §9).** `FavoritesList`, `FavoritesSystem` and `FavoritesChild` (§5.1's `QuickKeyChild`; kind
  `.department` or `.site`), `QuickKeyState` (`none`/`off`/`on`) and `QuickKeyStates` (`existingKeys`, the non-zero
  keys; `setting(_:on:)`, the 100 values of a one-key set), parsed by `FavoritesXML` (`Sources/NoctuleKit/Status/
  Favorites.swift`). The client calls are `favoritesLists()`, `favoritesSystems(inList:)`, `favoritesDepartments(inSystem:)`,
  `favoritesSites(inSystem:)`, `listKeyStates()`, `systemKeyStates(listKey:)`, `departmentKeyStates(listKey:systemKey:)`,
  `setListKey(_:on:)`, `setSystemKey(_:inList:on:)` and `setDepartmentKey(_:inList:system:on:)`; `ScannerCommand(_:arguments:)`
  takes an array. A missing `Avoid` reads as not avoided, any value but `Off` as avoided. The built-ins dropped are the two
  lists and the `Unknown` department (by `Index`); systems and sites keep every index.
- **The mock (§5.2).** `MockFavorites` (`Sources/NoctuleMockScanner/MockFavorites.swift`), the same tree on `MockSDS200`
  and both serial personalities; tests read and replace it with `favorites` and `setFavorites(_:)` (§5.2's
  `quickKeyStates`). Eight lists, seven on keys 0, 1, 3, 7, 12, 23 and 41 and one with none; list `Index` 1 (key 7) is the one `GSI`
  names, with `Q_Key="0"`. **(builder's call)** System 102 has a third department, 402 "Simplex C" (D2, off), so its
  `DQK` pattern {0,1,2} differs from system 101's {0,1} and a stray reply between them can be told apart by pattern
  (§5.4 Switching 4). A list's `Monitor` (`ListRow.monitored`, read-only) is kept apart from its quick-key state (`isOn`,
  what `FQK` reads and sets): a first build conflated them, found from a screenshot of the pop-over. Sets reply after
  `quickKeySetDelay` (800 ms by default for `FQK` and `SQK`, at once for `DQK`; zero under `--no-delays`, on both the
  network and the serial mock). Quick-key states survive `powerCycle()` [assumed]. The [assumed] items are listed in
  `MockFavorites`' and `MockPersonality`'s type comments.
- **`noctule quick-keys` (§5.3).** **(builder's call on the format)** `<tag padded to 4>  <state padded to 3>  <name>`
  indented 0, 2 and 4 spaces (`CLIFormat.quickKeys`): the tag `F<k>`, `S<k>` or `D<k>`, or `-` with no key; the state
  `on`, `off`, `?` (a key the scanner reports as 0) or `-` (no key, or a parent without one); suffixes in parentheses
  (`(P25 Trunk)` for a trunked system's type, `(site)`, `(avoided)`, `(not monitored)` on the list's own line). Lists in
  key order, those without a key last in `GLT` order and **printed without their systems** (`SQK` needs the list's key;
  `QuickKeyTreeReader`). It sends `MDL` first; a model without `supportsQuickKeys`, or one `MDL` doesn't name, prints
  `quick-keys: the <reported model> has no quick keys` on stderr and exits 1 with nothing else sent. Usage errors exit
  64, as for `ports` and `audio-inputs` (the plan said 2). `GLT,SITE` is read only for trunked systems.
- **The model reads unkeyed lists' structure too (§5.4, §5.5). (builder's call)** After the keyed lists, in `GLT` order,
  `GLT,SYS`/`DEPT`/`SITE` for a list or system with no key, but never an `SQK` or `DQK` for it, so the pop-over can show
  its tree read-only.
- **Loading (§5.4).** `QuickKeysModel` (`Sources/NoctuleAppCore/QuickKeys/`) runs one read loop at a time (the session's
  `runner.control()`), sleeping in real time like `MenuModel` (`pollInterval`, 2 s, `SessionEnvironment.
  quickKeysPollInterval`). A `GLT` read that times out is retried once in place, no other read is (see "Late replies"
  below); after a failed read the background reads rest for one interval, and two timeouts in a row mark the scanner
  not answering. The cache is
  `QuickKeysCache` (version 1, structure only, no state or freshness field; anything unreadable is no cache).
- **Late replies (final review C1; the SDS200's residual fixed 2026-11-19 at the owner's request). (builder's call; the
  full-pass rule and the in-place retry are the controller's rulings)** Replies are matched to requests by command name
  only, so a reply that comes after its read gave up answers the next read of that name. The first build retried a
  timed-out read at once, which passed the late reply on: a late `GLT,DEPT,<conventional system>` reply answered the
  next system's `GLT,DEPT`, that system showed the first one's departments as fresh and switchable, and a click on one
  of them sent a `DQK` naming another department's key (found on the serial mock with `StrayReplyTransport`). The
  second build stopped retrying any read in place, which only moved the problem: a reply later than the timeout and the
  rest after it (about 4 s on the SDS200 over UDP) could still land on a read of the same kind for another parent,
  which no content told apart, and every lost datagram in a list read cost that list's whole read again after a rest
  (at the SDS200's usual 1 in 12, a 20-command list read succeeded about 18 % of tries). Now:
  - **Ownership.** Every `Index` in the tree is unique (§3.1, [hw]), so the model knows from what it has read which
    list holds each system and which system holds each department and site. A reply naming an item another parent is
    known to hold **conflicts** and is refused (`checkOwnership`). Within the reading list, for a department or site,
    the first of these that knows the item decides:
    - an earlier system of the read under way, or a system the list's last failed or refused read this open had taken
      (`lastFailedRows`, kept until the list reads; QA C1 of this fix: a late reply for a *later* system of the same
      list landed on the re-read's first `GLT,DEPT`, and that system's own reply then answered the next one, so the two
      systems' departments swapped with nothing in the re-read to tell). These claims are fresh: the reply is the
      stray, and the read fails as any other, with `The scanner's reply to GLT,DEPT belonged to another system.` on its
      tree, through the failure path below (the rest, the first retry first, then last). A stray accepted by a failed
      read can make the next read fail once more against it; the read after that is checked against the failed one's
      systems, so it settles.
    - the list's own known structure (the cache, or a read since re-checked), not yet doubted this open. It may be stale
      (a department moved): the reply is refused with no failure counted and no error, the list read again first after
      the rest, and from then on this open checked against that refused read (its systems and the refused one as read)
      instead of the structure (`doubtedStructure`), so a second read that agrees is taken.
    Then, for any item, every other list's known structure. If that list's claim is fresh (read since this open), the
    reply may be the stray or that list may hold one: this read fails (`… to GLT,SYS belonged to another list.` for a
    system), and that list is re-checked too. If it isn't fresh (the cache, an earlier open, a list re-checked since),
    it may be stale, the radio having been reprogrammed: that list is asked to settle it, **at most once per open** (the
    controller's ruling, QA I1): it is re-checked first and this list read again right after it, after the rest, with
    no failure counted. During that **settle re-read** other lists' claims that aren't fresh don't count, and the ones
    its fresh reply contradicts are dropped from those lists' structures once it succeeds; nothing is skipped after that
    read ends, whatever its outcome. So two lists whose cached claims cross (each now holds what the other's cache
    claims) settle in three reads, and three in a rotation in four, where the first build re-checked them against each
    other for ever. (Round 1 of this fix let a list's claims stop counting for the rest of the open once it had been
    asked; QA found a stray that then went through after a re-check, with a set to the wrong department, NEW-1.) When
    the claiming list is failing to read, or was already asked this open, this read fails instead and goes last. The
    skip in the settle re-read covers every list's claim that isn't fresh, not only the asker's (a rotation needs it;
    the controller kept it in fix round 3, QA's minor). It leaves one window no hold covers: a list B read this open and
    re-checked since (by a conflict or a moved key, not a menu exit), whose read's timeout the in-place retry absorbed
    (so that read's success cleared B's timeout record), can have that read's late reply land on another list's settle
    re-read, where it is accepted and B's claim dropped. The pre-set check is then what stands between it and a set.
    Tests pin both limits of the skip: `theSkipEndsWithTheSettleReRead` (QA R11) and
    `aSettleReReadDoesntSkipAFreshClaim` (QA R12). Each conflict is traced, indexes only: `quickkeys:
    GLT,DEPT for 901 refused: item 700 belongs to 900`.
  - **Tree switches wait for the full pass.** A stray whose true owner hasn't been read yet can't be caught when it
    lands, only when the owner is read (a conflict as above, which then re-checks both lists). So no system,
    department or site switches until every list on the keypad has been read `.fresh` since this open or the last menu
    exit (the menus may have edited Favorites): its rows show their states, `switchState` is `.checkingOtherLists`
    (help `Checking the other lists…`), and the pop-over's status line says `Checking the other lists…`
    (`isCheckingOtherLists`), after an error, the session's state and a menu. Tiles aren't held (their scope, `FQK`, has
    no structure). Afterwards a list re-checked for another reason (a moved key, a conflict) loses its switches only
    for itself; a list that appears on the keypad later is waited for too. A list that keeps failing releases the
    others once it has failed twice in a row. But **a list with a `GLT` read unanswered since its last good read holds
    every tree switch until its own read succeeds**, whether or not it was read this open, and even when the in-place
    retry absorbed the timeout (the controller's rulings, QA I2 and NEW-1): that reply may still be on its way, and
    could land on another list where nothing claims it.
    On the SDS200 the whole tree read in about 4 s in the spike, so that is roughly how long tree switches wait on
    open.
  - **One in-place retry for `GLT` reads** (`GLT,FL`, `GLT,SYS`, `GLT,DEPT`, `GLT,SITE`; `readStructure`): a read that
    times out is sent again at once, then fails as before. A late reply to the first try that answers the retry is
    that scope's own answer, and one that lands on another parent's read is caught by the ownership check. A timeout
    still starts the quiet time (`quietUntil`, one poll interval, across a close and reopen too), which holds the next
    step (the next list, the polls), not the retry. `FQK`, `SQK` and `DQK` reads aren't retried in place: a late one
    can only mislead the display, since no set's keys come from a state, and the pattern check drops one whose
    pattern differs; a poll's failed state read leaves that scope's last states shown. Sets are never retried.
  - `FavoritesXML` refuses a `GLT` document holding another kind (`FavoritesXMLError.unexpectedElement`), so a late
    `DEPT` or `SITE` document can't be taken for a `GLT,SYS` or the keypad's `GLT,FL`, nor a `SYS` document for a
    `GLT,DEPT`.
  - **What is caught:** a late `GLT` reply carrying items whose parent is known: from another list (fresh or cached),
    from an earlier system of the read under way, from the list's last failed read this open, or from the list's own
    cache (once, then a second read must agree); and a stray on a list whose owner hasn't been read yet, when the
    owner is read, with tree switches held meanwhile (also while that owner keeps failing, if a `GLT` of its timed
    out). **What is left to the ownership guard:** a late `GLT` reply with no items (a system with no departments, an
    empty `GLT,SITE`) carries no index, so it can still answer another scope's read of its kind: that scope then shows
    no rows until its next read (the next open, a menu exit or a re-check), and nothing switchable comes of it. A list
    whose cached claim nothing settles (it keeps failing to read) keeps the list now holding that item from loading
    until it reads; the cache keeps that claim meanwhile, across opens. And a late reply from a read that then
    succeeded (its timeout record is cleared when it reads), or from a list that fails only by refusals, can still land
    where nothing claims it once the switches are on. For those, the pre-set check below stands between a stray and a
    set.
  - **The pre-set check (the controller's rulings, 2026-11-19; defence in depth).** A set proves its own address just
    before it is sent (`QuickKeysModel.proveAddress`, in `perform`, after the row is checked again and before the set).
    For an `SQK` set on system S of list L: `GLT,FL` (an `FL` document holding L, with the row's list key), `GLT,SYS,L`
    (a `SYS` document holding S, with its key), `GLT,FL` (a fence: any `FL` document), `GLT,SYS,L` again (S with its
    key, and the same systems as the first), `GLT,FL`. For a `DQK` set on department or site C of S: `GLT,FL`,
    `GLT,SYS,L` as above, then `GLT,DEPT,S` or `GLT,SITE,S` (C's kind; it must hold C with its key and exactly S's known
    fresh children of that kind), `GLT,FL`, the same `GLT,DEPT|SITE,S` again (C with its key, the same children),
    `GLT,FL`. The set is sent only if every reply passes; then the row is checked again and the set goes out as before.
    A reply that doesn't prove it sends nothing, re-checks the list (read again first), and shows `The list changed on
    the scanner; nothing was sent.`; a read unanswered or refused sends nothing and shows `The scanner didn't answer;
    nothing was sent.` (both as the change error, on the status line). These reads don't use the in-place retry. An
    `FQK` set (a tile) needs no check: its address is the list key `GLT,FL` gives, global. The cost: five or six `GLT`
    reads per click, before the set (by §3.1's timings, a fraction of a second on all three).
    - **Why the decisive scope is read twice (fix round 3, QA NEW-2).** Every `Index` is unique across the tree, so a
      reply of the right kind holding the element can only describe it, and the kinds alternate, so a reply out of
      place usually meets a read of another kind. But the first build of the check read the decisive scope once, and
      QA defeated it on its own (the ownership guard and the full-pass hold switched off) two ways: one late reply of
      the true parent's decisive read on that read, with its own reply lost (the fence then got its own `FL`; about 1
      UDP datagram in 12 is lost on the SDS200); and, for a system's set, a pure shift of two (an old `FL`, an old
      `GLT,SYS` of the list that really holds the system, then the check's own first `FL` on the fence). Both sent a set
      that switched another element. The first build's documents said a shift of one or two was always refused: wrong.
    - **What still defeats the check on its own** (the minimum, by the reasoning below). When the row is wrong (the
      element really belongs to another parent T), the real reply to a decisive read doesn't hold the element (or, for
      a child, doesn't equal the known children), so **both decisive reads must be answered by late replies of T's
      decisive read** (`GLT,DEPT|SITE,T`; for a system, `GLT,SYS` of the list that really holds it), each arriving while
      its read is pending and before that read's own reply. And **both own replies must be lost, or arrive only after
      the last fence**: one arriving while the fence or the other decisive read is pending is refused (another kind,
      or no element). The two late replies agree with each other, and the first equals the known children, since the
      wrong row came from such a reply. So: two late replies plus two losses, in that order. Two such late replies are
      exactly what one `GLT` read of T leaves when both its first try and its in-place retry time out, so in practice the
      defeat is one double timeout plus two lost replies (confirmed by probes on the SDS200 mock, fix round 3's re-review). As a pure persistent shift
      (every reply late by the same number of reads, the own replies landing after the check), a shift of k answers
      read i with the reply of read i − k: for a system's set (`FL`, `SYS`, `FL`, `SYS`, `FL`) only k ≥ 4 puts the
      second `SYS`'s own reply past the end without an `FL` read meeting a `SYS` reply, so it needs four outstanding
      replies `FL`, `SYS` (T's list), `FL`, `SYS` (T's list) in that order; for a child's (`FL`, `SYS`, `D`, `FL`, `D`,
      `FL`) only k ≥ 5 works, needing `FL`, `SYS` (the list), `D` of T, `FL`, `D` of T. Those are the replies of an
      earlier check on T's element, all late together. Tests: `theCheckSurvivesOneLateAndOneLostReply`,
      `theSystemCheckSurvivesAShiftOfTwo` (QA's probes, the guards off), `theTwoDecisiveRepliesMustAgree` and
      `theTwoDecisiveChildRepliesMustAgree` (a left-over reply from before a change on the radio on the first read,
      the radio's present answer on the second).
    - Tests: `QuickKeysModelSetCheckTests` (the exact read sequence before each kind of set; another scope's reply at
      each step, of another kind or the right kind without the element, both decisive reads and all three fences
      included; an unanswered or refused read; a key, a system key or a sibling site changed on the radio; and, with
      the ownership guard and the full-pass hold turned off by a test-only switch, QA's C1, NEW-1 and NEW-2 states,
      where the check alone sends nothing).
- **A list that keeps failing (2026-11-19, after the owner's read on the SDS150, before the paged `GLT` fix below; the
  order is the controller's ruling).** One list's `GLT` read failed the same way every time. Its error was set, but the
  next poll's `FQK` succeeded and cleared it, so it showed for under one poll interval and the list then stayed
  `Checking…` with nothing said; and the retry-first rule read that list again before any other, after every rest, so
  no list after it loaded, not even the one the user opened. Any repeatable failure (a reply the client can't parse, a
  firmware quirk) would do the same. Now:
  - A list read's error belongs to that list: `QuickKeyListTree.readError` (nil when `.fresh`), kept until the list
    reads, leaves the keypad, or the pop-over closes or the session goes. The tree shows it under its `Checking…` line,
    `Couldn't read this list: <reason>. Trying again.` (`QuickKeysText.listReadError`), e.g. `Couldn't read this list:
    the scanner refused GLT,SYS. Trying again.` The reasons are sentences, on the tree and on `lastError` alike: `The
    scanner refused <command>.` (an `NG` or `ERR`), `The scanner's reply to <command> couldn't be read.` (anything
    else it answered) and `The scanner didn't answer <command>.`; the first build showed a Swift error's description
    there, which QA caught, and the trace keeps it. `lastError` holds only the
    keypad's, the polls' and the changes' errors (a change's re-read failing included); a poll or keypad read that
    succeeds clears only those, and a list read never clears one. `isScannerAnswering` is unchanged.
  - The first retry after a list's failure still goes before any other list, the shown one included, so the first
    `GLT` after the rest is its own `GLT,SYS` (the C1 rule above). If that retry fails too, the list goes behind every
    other queued list and is read again after them, again and again, each time after the rest, until it reads; a list
    the user opens meanwhile goes ahead of everything else, so it waits at most for the read under way, that one
    retry, and the rests; the retry going first protects that list from a late reply to the failed read (confirmed by
    the controller). A second failure goes last even when a re-check put the list first meanwhile. Only an
    unanswered, refused or unusable read counts (not a missing client, nor a read re-checked meanwhile), and a
    success, a close or a detach resets the count, so a new open or connection starts with the first retry again; a
    menu exit's full re-read puts a list that has failed more than once last too, unless it is the one shown. The cost: past the first retry the next `GLT`
    after a failing list's rest is another list's `GLT,SYS`, so a reply later than the rest could land there (since
    2026-11-19 the ownership check in "Late replies" above refuses one that names another list's items); the
    alternative was a pop-over where nothing past that list ever loads.
  - Tests: `QuickKeysModelFailingListTests`, on both mocks behind a `RefusingTransport` (an `NG`, an unusable reply or
    none in place of one command's reply). `aLateSystemsReplyNeverBecomesAnotherListsSystems` now waits for list 1's error on its tree,
    where it used to read `lastError`.
- **Detached (§5.4 "While the session isn't connected"). (builder's call)** On detach (any phase but `.connected`) the
  model keeps this session's last `lists` and trees in memory, read-only, states dropped and every row `.unavailable`;
  from disk only trees load (the keypad is never from the cache), so a pop-over opened before any connection shows the
  session state and any cached trees, with no keypad. The owner may want cached list names offline; that would be a new
  cache version.
- **`StationSession.supportsQuickKeys`** (the toolbar button) is the profile of the model the last connection's `MDL`
  named, else of the station's `modelOverride`, else whether the station's cache file existed when the session was
  made (only a model with quick keys writes it). An `MDL` that names no known model has none (no `.sds200` fallback,
  unlike `session.model`). A model without them is never attached, so never read.
- **A change whose confirming re-read fails leaves its scope with no state (§5.4 Switching 3). (builder's call)** The
  rows show no on/off and nothing there switches until a later read succeeds; "The scanner didn't confirm the change"
  stays shown (`lastError` prefers it over a read error). The re-read and the polls drop a reply whose pattern differs
  from the scope's baseline, or that isn't 100 values (a set's late `OK`/`NG`), and read once more.
- **Switching.** A click is taken only between loop steps, so a set never goes out between a poll's reads; it is
  evaluated again before sending and dropped (nothing sent) if a menu, a re-check or a detach came between.
  `switchState(for:)` gives each row `.on`, `.off`, `.unknown`, `.checking`, `.noQuickKey`, `.unreported`,
  `.sharedSystemKey(k)`, `.sharedListKey(k)`, `.checkingOtherLists` (since 2026-11-19, "Late replies" above),
  `.inMenu`, `.unavailable` or `.busy`. The model also hears the menu
  model's reads (`MenuModel.onInMenuChanged`), so a menu entered from the app stops switching before the next push says
  so.
- **Lists sharing a quick key (final review I1). (builder's call, open to the owner)** `SQK,<k>` and `DQK,<k>,<s>` are
  addressed by the list's key, so when two lists hold the same key they can't tell the lists apart: the first build let
  a click on one list's system switch the other's (on the mock, which answers from the first list in `GLT` order). Now,
  as for systems sharing a key (§5.4 "What can't be switched"), every system, department and site of such a list is
  `.sharedListKey(k)`: its state is shown, its switch is disabled, and its help text is "Lists F<k> share a quick key,
  so their systems can't be switched separately here." (the wording is the controller's ruling R13; the owner may
  change it). The lists' tiles still switch, together (`FQK` addresses the key; each carries the "shared" mark).
  Whether a radio lets two lists share a key, and what `SQK` then answers, is **[assumed]** (none of the owner's lists
  do).
- **The tens control is custom, not `NSSegmentedControl` (§5.5). (builder's call, kept by the owner on 2026-11-19
  after trying it on the SDS150: "I like the UI"; the owner had asked for a standard Mac segmented control)** It keeps the approved mockup's two-line segments (`0–9` over `n/m on`, `n lists` before the
  states are read, `—` for an empty ten) and disables single tens, which neither `NSSegmentedControl` (one-line labels)
  nor SwiftUI's segmented `Picker` (no per-segment disabling) does. The attached pop-over is translucent (the system
  material on macOS 26), the torn-off panel opaque; the owner kept both on 2026-11-19.
- **The pop-over (§5.5).** An `NSPopover` (`behavior = .transient`) whose `detachableWindow(for:)` is a floating `NSPanel`
  titled `Quick Keys — <station>`, on the same view state (`QuickKeysPanelController`, one per station window; closing
  the station window closes both). An attached `NSPopover`'s keys are addressed to the station window, not to the
  pop-over's window (LESSONS.md 2026-11-18), so the pop-over's monitor takes keys addressed to its parent. **While it is
  attached it swallows every key it doesn't use (builder's call)**: digits, Space, Return and ⌘↓ act on the keypad, ⌘F
  focuses the search, Esc closes it, the app's menu key equivalents (⌘Q, ⌘W, …) pass, and everything else (arrows,
  Tab, letters) goes nowhere, so nothing reaches the station window or the scanner; the Mac-style menu's
  `.keyboardShortcut`s are off meanwhile (`StationShortcuts`, `\.quickKeysPopoverShown`). A torn-off panel takes its own
  window's keys, and a focused control in it keeps Space and Return. Not built from the mockups: the tile's colour
  stripe (backlog's per-list colours) and ← → for the tens; the swipe (one ten per gesture, 30 pt) wasn't tried on a
  trackpad.
- **An app-wide key-monitor fix, with a behaviour change.** No local key monitor in the app had ever consumed a key:
  `{ [weak self] in self?.handle(event) ?? event }` turns a consumed nil back into the event (LESSONS.md 2026-11-18).
  Both monitors now install `monitorBody`, `LocalKeyMonitor.forward(event, to: self?.handle)`. So the station window's
  scanner keys and the Mac-style menu's ↑ ↓ Return Esc are now consumed when pressed, as their documentation always
  said, where before they were also dispatched to the window (a focused control got them too, or the window beeped).
  The Settings key recorder now also stops when its window resigns key, since AppKit runs local monitors in no fixed
  order.
- **Paged `GLT` replies (2026-11-19, after the owner's read on the SDS150; §3.1).** `SerialResponseAssembler` now puts a
  reply's pages together as `UDPDatagramAssembler` always did, through one shared helper, `XMLFragmentSequences`
  (`Sources/NoctuleKit/Protocol/`): a document with a footer is a page, `No="1"` starts that command's sequence, each
  next number continues it, a new `No="1"` replaces an unfinished sequence (so two replies never merge), `EOT="1"`
  hands on one document with every page's elements and no footer; a gap in `No`, a sequence older than 10 s, one over
  4 MB or 256 pages, or a page the assembler loses (cut off by a new document, too big, unparseable) drops that reply
  (the read times out), traced as `serial: dropped <command> pages: <reason>`. Sequences are per command, so a push
  between two pages, footered or not, leaves them alone; a
  document with no footer (`GSI`, `PSI`, `MSI`) is handed on as before. The UDP assembler's behaviour is unchanged.
  **The mocks page `GLT` like the hardware**, on every model (`MockFavorites`): a footer on every `GLT` document, at
  most `gltPageSize` elements a page (4 by default, so `MockFavorites.default` has multi-page replies, `GLT,FL` three;
  `MockSDS200.Options.gltPageSize`, `MockSerialScanner(gltPageSize:)`, `--glt-page-size N`), each page written or sent
  as a datagram of its own. [assumed]: paging by element count (the radio pages by size), and the SDS200's pages each
  being a datagram with its own `GLT,<XML>,` line. Before this the serial mocks sent `GLT` whole with no footer, which
  is why no test caught the truncation.
- **The tree belongs to the focused tile (2026-11-19, after the owner's read on the SDS150; §5.5).** The owner opened a
  list's tree with its `n ›`, clicked another tile, and the tree of the first list stayed under it: the fire/EMS list
  was the one selected, the systems shown were another's. Now whenever the focus moves to a list other than the shown
  one the tree closes (`QuickKeysModel.hideList()`; the panel shows "Choose › on a list to see its systems."), and it
  never opens the new list's tree: only `n ›`, ⌘↓ or a search hit does. A tile click (or Space, Return on the highlighted
  tile) highlights that tile and closes any other list's tree, the toggle itself unchanged (one set); a click on the
  shown list's own tile keeps its tree. A typed key (`4`, `41`) that isn't the shown list's closes it. Paging the tens
  moves no focus and keeps it. The "No quick key" chips show their tree as before and clear the highlight (a list with
  no key has no tile to focus). The rule is `QuickKeysViewState.clicked`, `.typed(_:at:lists:in:)` and `.show`
  (`QuickKeysViewTests`). **Not done:** AppKit keyboard focus moving between tiles with Tab or Full Keyboard Access
  (`.tracksKeyboardFocus()` reports only whether a control has focus, not which tile).
