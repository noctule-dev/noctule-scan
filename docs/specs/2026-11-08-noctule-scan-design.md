# Noctule Scan — Design

Date: 2026-11-08
Status: Approved 2026-11-08

Labels used below: **(owner)** = decided by the project owner; **(designer's call)** = a default chosen during design that the owner hasn't explicitly confirmed.

## 1. What this is and why

Noctule Scan is a computer-aided radio scanner app for the Apple ecosystem: macOS first, then iPad and iPhone. It replaces ProScan, a Windows-only app the owner currently uses with a Uniden SDS200, for the subset of ProScan features the owner actually uses. **(owner)**

The owner owns four Uniden scanners: SDS200, SDS150, SDS100, BCD436HP. The SDS200 is the first target. **(owner)**

Primary use: on the owner's MacBook, at home or away from home over a VPN into the home network. **(owner)**

Future use: a "headless" truck setup, with an iPad or iPhone in a dash holder as the only screen and an SDS200 or SDS150 hidden under the seat. **(owner)** The first release does not build this, but the design must not block it.

It is built as a product others can use, not a personal script **(owner)** (§11).

The owner is an experienced scanner user who knows the physical scanner controls. Their skills should carry over without relearning. **(owner)**

### Key uses of the hit log

Scouting and system discovery: e.g. parking on a trunking control channel and collecting NACs/color codes and talkgroups, then using recorded audio to judge what kind of traffic each talkgroup carries. **(owner)** The owner indicated there are other uses but did not enumerate them. The log should be general-purpose, not built only for this one workflow.

## 2. Goals for the first release

Runs on macOS, connects to an SDS200 over the network (home LAN or VPN), and does four things **(owner)**:

1. **Scanner-like UI** — the main window shows a display that looks like the scanner's own display.
2. **Remote control** — full control of the scanner from the app.
3. **Remote audio** — listen to the scanner's received audio live.
4. **Hit logging** — log every hit and save its audio to a file.

## 3. Non-goals for the first release

- iPad and iPhone apps (the architecture must support them; see §11). **(owner: Mac first)**
- USB/serial and Bluetooth connections (the connection abstraction must support them; see §5). **(designer's call on ordering)**
- iCloud storage (hooks only; see §10). **(owner)**
- Editing scanner programming (Favorites Lists, profiles, database). That stays with Sentinel. **(designer's call)**
- Rendering the scanner's menu system, pop-ups, and prompts. The first release is an MVP; full menu support is not required. **(owner)** See §7.4 for what "remote control" covers. Menus were built later: see `2026-11-10-remote-menus-design.md` (done in Plan 6).
- Moving or copying hit-log rows into the scanner's programming (ProScan's "Move/Copy to DB"). **(owner)**
- FTP integration with the scanner's SD card, including reading `profile.cfg` colors and Favorites files. **(owner)**
- Any relay server or cloud service. The app always talks directly to a scanner. **(owner: remote = VPN)**
- The rest of ProScan's feature set beyond the four goals.

## 4. Anti-goals (would make this a failure even if it works)

- Having to relearn how to operate the scanner. Physical button habits must transfer. **(owner)**
- A Windows-style UI. The hit log in particular must use modern Mac app styling, not a clone of ProScan's look. **(owner)**
- A display that doesn't match the user's actual scanner, e.g. ignoring the user's display customizations. **(owner: "read the scanner to then render the app UI")** The MVP meets this for field items and text, but not yet for colors (§7.3, §14).

## 5. Scanners and connections

### 5.1 Connection abstraction **(owner)**

All scanner communication goes through a transport abstraction so that network, USB/serial, and Bluetooth are interchangeable beneath the rest of the app.

| Scanner | Network | USB/serial | Bluetooth |
|---|---|---|---|
| SDS200 | Yes (Ethernet) — **first release** | Yes | No |
| SDS150 | No | Yes | Yes (BLE, used by Uniden's U/AWARE app) |
| SDS100 | No | Yes | No |
| BCD436HP | No | Yes | No |

Release order **(designer's call)**: SDS200 network → USB/serial on Mac (opens SDS100/SDS150/436HP) → SDS150 Bluetooth.

Notes:
- Per the SDS150 manual, Bluetooth carries both control and received audio, but only to the U/AWARE app; the protocol is **not publicly documented**. Supporting it likely requires reverse engineering. Treat as a later, research-dependent stage.
- iPhone apps generally cannot open USB serial to these scanners. On iOS, the SDS200 (network) and SDS150 (Bluetooth) are the realistic direct targets; SDS100 and 436HP are likely Mac-only.

### 5.2 SDS200 network protocol

Details are in [`2026-11-08-sds-remote-protocol.md`](2026-11-08-sds-remote-protocol.md). They come from the open-source `sds200` library (MIT) and read-only probes of the owner's SDS200 (fw 1.24.00). Confirmed on the owner's hardware:

- Control over UDP 50536, with the same command set as USB serial. `MDL` and `VER` handle detection.
- `GSI`/`PSI` return `ScannerInfo` XML with everything the display and hit log need. `PSI,<ms>` pushes updates continuously.
- `STS` returns the scanner's actual display text, including the owner's chosen field items and soft-key labels.
- `KEY,<code>,P` presses any front-panel key or turns the scroll knob.
- Audio uses RTSP at `rtsp://<host>/au:scanner.au`, carrying G.711 µ-law at 8 kHz over RTP.
- An FTP server on the SD card provides `profile.cfg` (display colors) and the Favorites files. Not used in the first release **(owner)**.
- The protocol is unauthenticated, so it must stay on the LAN or VPN.

The owner's SDS200 is available for development **(owner)**. Its address lives in local, git-ignored configuration: `config/dev-scanner.env` (template: `config/dev-scanner.env.example`). Never commit real hosts or addresses. Probes are read-only unless the owner approves otherwise. Use them to capture real traffic early, both for the open items in the protocol notes (§8) and to feed a simulated scanner for tests.

### 5.3 Scanner identification **(owner)**

On connect, the app asks the scanner for its model and firmware and selects the matching model profile (supported commands, keypad, display items). The user can override the model manually.

## 6. Stations

A **Station** is one scanner plus everything the app knows about it, e.g. "Home SDS200", "Truck SDS150". **(owner: segment by scanner; name "Station" is designer's call to avoid colliding with Uniden's "Profile")**

Per station **(owner, except where marked)**:
- Connection: type, address/port, model (detected or overridden).
- Hit log, sessions, saved filters.
- Recordings folder (default `…/Noctule Scan/<Station name>/`) **(designer's call)**.
- Recording rules (e.g. every transmission vs. only new, per §9.2) **(designer's call)**.
- Keyboard shortcuts / key map. Each model ships a default key map matching its own keypad; each station can customize it. **(owner)**
- Appearance — derived from the scanner's own display customization (§7.3). **(owner)**
- Preferred main view (scanner view or Mac-style view) **(designer's call)**.

Global (not per station): the storage location switch (local / iCloud). Nothing else. **(owner)**

Behavior **(designer's call)**: the app reopens the last-used station. Each main window shows one station; multiple windows may show multiple stations at once.

## 7. Main window

Mockups from the design session are in `.superpowers/brainstorm/*/content/all-screens.html` (screens 1–6). They are rough sketches, not final visual design.

### 7.1 Scanner view (default) **(owner: option B)**

- The scanner's display, rendered to look like that scanner's real display (§7.3).
- The scanner's physical controls, laid out like the real unit, so button habits transfer **(owner)**. For SDS200: Volume/Light knob, Squelch/Menu knob, Scroll knob (push = Func), three soft keys under the display, keypad (Func, Avoid, Zip/Services, 0–9 with second functions SRCH1–3/ATT/DIM/WX/IFX, ./No, E/Yes, Replay/Record). Multi-key sequences behave as on the scanner (e.g. Func then 4 = attenuator; Avoid twice = permanent avoid) — achieved by forwarding key presses to the scanner, not by reimplementing scanner logic **(designer's call)**.
- Mac-native controls around it: Hold, Avoid, Record buttons; volume and squelch sliders; listening and logging indicators **(owner: "Mac controls"; specific set is designer's call)**.
- A recent-hits list that opens the full hit log.
- Keyboard shortcuts per the station's key map.

### 7.2 Mac-style view (alternate) **(owner: option C, switchable)**

Same information in a modern Mac layout: large channel name, system › department breadcrumb, digital details as chips (mode, TGID, UID, NAC, frequency, RSSI), common action buttons, volume/squelch, and an "active now / recent" list. Toggle in the window toolbar. This view is the starting point for the future iPad dash layout **(designer's call)**.

### 7.3 Display rendering from the scanner's customization **(owner)**

The SDS200 and SDS150 manuals (in `docs/uniden/`, sections "Customizing the Display" and "Available Items") define the display model the app must support. One renderer serves both models, driven by per-model data:

- **Screens:** Simple Conventional, Simple Trunk, Detail Conventional, Detail Trunk, Search/Close Call, Weather, Tone-Out. Search/Weather/Tone-Out share a layout; only Search allows item changes. SDS150 adds a Waterfall screen with its own colors.
- **Fields per screen:** top option rows (Option 1–8, Sig, Batt, Key, DIR, Func), Info areas 1–3, Option C 1–2, System/Department/Channel name areas each with an option line plus Avoid/Hold indicators (Simple mode: names are 24×2; Detail: 24×1), Option A/B rows, a 10-slot icon row, three soft-key labels.
- **Per field:** item shown, text color, background color. Some fields are color-only.
- **Item catalog and size classes:** each item may appear only in certain field sizes (Huge 22, Large 16/14, Short 5 char). Use the manuals' tables. SDS150 adds battery voltage/current/temperature and a Bluetooth icon.
- **Display-wide:** Color / Black-on-White / White-on-Black; Simple vs. Detail toggle.

**Source of the customization:**
1. **Field items and live text:** from `STS`, which reflects the owner's chosen items as the scanner draws them. **(MVP)**
2. **Colors:** the model's factory-default colors in the MVP, plus the scanner's Color / Black-on-White / White-on-Black mode if it's reported. Reading the owner's colors from `profile.cfg` (over FTP, or from a copied file) is deferred, because FTP integration is out of scope for now. **(owner: no FTP for now; color fallback is designer's call)**

The live content of fields comes from the scanner's status reports during operation.

### 7.4 Scope of remote control in the MVP

The owner accepts that the first release won't support all of the scanner's menus. **(owner)**

In scope **(designer's call on the exact list)**: scanning, Hold and Avoid at the system, department, and channel level, scroll and resume, volume, squelch, attenuator, record, and toggling Favorites List quick keys. These are things the status reports and key commands can drive while the display stays on a scanning screen.

Out of scope for the MVP (since done: rendering the scanner's menus is built, see `2026-11-10-remote-menus-design.md`): rendering Menu mode, Func-prompted number entry, and other menu screens. Keypad presses that would enter a menu are still forwarded to the scanner. If the scanner reports that it's in a menu, the app displays a plain "Scanner is in a menu — use the scanner or press Menu to exit" state rather than a rendered menu **(designer's call)**. `STS` already returns menu screens as text lines with highlight masks, so showing menus as plain text is a cheap stretch goal.

## 8. Audio

- Live audio from the scanner's network stream on the Mac, with app volume control and a listening indicator **(owner: remote audio)**.
- Scanner volume/squelch (the scanner's own settings) are controlled separately via the knobs/sliders **(designer's call)**.

### 8.1 Audio resilience **(owner)**

Owner's experience with ProScan: after a network glitch, the SDS200's audio stops and doesn't come back until the scanner is power-cycled. ProScan detects the dropout and offers to restart the scanner, which suggests a remote restart command exists. Requirements:

- **Always end RTSP sessions gracefully.** Send `TEARDOWN` when audio stops, the station disconnects, the app quits, or the Mac sleeps. This also applies to every development and test run: tests must tear down in all exit paths, including failures. A leaked session may wedge the scanner's audio server.
- **Keep the session alive** with periodic RTSP `GET_PARAMETER` (the `sds200` library uses 15 s) **(designer's call on interval)**.
- **Detect dropouts:** RTP stops arriving while the session should be live, keepalives fail, or `PSI` reports an active transmission with no audio. Whether RTP flows continuously or only while squelch is open must be verified first (protocol notes §8).
- **Recover in steps:**
  1. Tear down the old session (best effort), then set up a new one, with backoff.
  2. If that fails, show a clear "Scanner audio isn't responding" state. Control and logging keep working; hits are logged without audio and marked as such.
  3. Offer **Restart scanner** if a remote restart command is confirmed, with explicit user confirmation. Otherwise, tell the user to power-cycle the scanner.
- **Reconnect cooldown.** A quick RTSP reconnect hung the SDS200's audio server (protocol notes §6), so every connection waits 120 s after the previous close. Since Plan 5 (`docs/specs/2026-11-09-plan-5-stations-cooldown.md`), the wait after a *clean* close is a per-station setting (0–120 s, the owner's); every other close (a crash, a dropped connection, an unanswered request) still waits 120 s.
- **Finding the restart command is a research task.** It isn't in the `sds200` library or the public spec found so far. Approaches: capture ProScan's traffic to the SDS200 with Wireshark during its restart prompt, or check newer Uniden spec revisions. Never send guessed commands to the owner's scanner; a wrong one could change settings.

## 9. Hit log and recording

Modeled on ProScan's hit logger columns, presented with modern Mac styling **(owner)**.

### 9.1 What each hit captures

Time, frequency, mode (FM, NFM, AM, P25, DMR, NXDN, etc.) **(owner)**, system, department/group, channel name, site, talkgroup ID, unit ID (when reported), tone/NAC/color code/RAN, RSSI, duration. Plus the audio file.

### 9.2 Layout **(owner: ProScan content, Mac styling; specifics designer's call)**

- Default: one row per talkgroup (or per frequency for conventional), with hit count, total talk time, first/last heard — as in ProScan.
- Toggle: one row per transmission (replaces ProScan's "Each Transmission New Row").
- Columns: TGID, Frequency, Tone/NAC/CC, Mode, RSSI, UID, Hits, Talk time, First, Last, System › Dept › Channel. Sortable, reorderable, resizable.
- **New** is marked visibly **(owner)**:
  - a **frequency not programmed in the scanner**: the scanner reports it with an unprogrammed index (`Index="4294967295"`; see the protocol notes §4), or
  - a **talkgroup never seen before** by this station: its first appearance in the station's hit log.
  - Each row records when it was first seen, so "new since" filters work too **(designer's call)**.
- Selecting a row shows an inspector: details, units seen, list of its transmissions each with a play button, "play all in order", "show in Finder".
- Sidebar: sessions (by date) and saved filters (only new, by mode, by NAC, etc.).
- Toolbar: pause logging, export (CSV), reset counts, search, delete rows.

ProScan's "Move/Copy selected rows to DB" is not in the first release. **(owner)**

### 9.3 Recording

- Logging and recording happen whenever the app is connected to the station's scanner. It is not a 24/7 recorder unless the Mac is left running. **(designer's call, consistent with Mac-first)**
- One audio file per transmission, segmented on hit boundaries reported by the scanner **(designer's call)**. A file normally starts 0.5 s before the hit (pre-roll). A transmission already on air when audio starts (always so on a weather channel) is recorded from the moment audio starts streaming, with no pre-roll **(designer's call)**.
- Format: **WAV, 16-bit PCM, 8 kHz mono** **(owner)**. The scanner sends G.711 µ-law, and expanding µ-law to 16-bit PCM is lossless, so the file is exactly what the scanner sent. Don't transcode to a lossy format, which would degrade weak or garbled transmissions. AAC `.m4a` may be offered later as an "export for sharing" option, not as the recording format **(designer's call)**.
- Other defaults **(designer's call, adjustable in Settings)**: name `YYYY-MM-DD HH-MM-SS · TG<id> · <channel>.wav`; skip transmissions shorter than 0.5 s; keep forever.
- Settings screen: log on/off, save audio (every transmission / only new, using the definition in §9.2), folder, format, minimum length, retention.

## 10. Storage

### 10.1 First release: local only **(owner)**

The owner does not have an Apple Developer Program membership, so iCloud is not available yet.

- Settings and stations: local storage.
- Hit log: local database per station.
- Audio: files in the station's recordings folder.
- **Export / Import settings** to a file (backup, moving between Macs) **(designer's call)**.

### 10.2 iCloud hooks **(owner)**

- All persistence goes through one storage interface with a local implementation now; an iCloud implementation can be added later without changing the rest of the app.
- Synced data (stations and their settings, key maps, filters) is modeled to satisfy iCloud/CloudKit constraints from the start so enabling sync needs no migration.
- Device-only data is separated now: recording folder path, USB port, Bluetooth pairing, audio output device.
- Hit logs and audio stay device-local by default even once iCloud exists; optionally the recordings folder can live in iCloud Drive **(designer's call)**.
- Settings shows the storage choice; the iCloud option is present but disabled with an explanation until available. Switching to iCloud uploads current data; switching back keeps a local copy.

## 11. Architecture constraints

- Swift and SwiftUI **(owner: Swift or C++; designer recommends Swift throughout, since nothing here needs C++)**.
- Scanner protocol, transports, station model, logging, and storage live in shared code with no Mac-only UI dependencies, so iPad/iPhone apps reuse them **(owner: iPad dash later)**.
- Model-specific knowledge (commands, keypad/key map defaults, display layout and item catalog) is data/profiles per scanner model, not branches scattered through the code **(owner: detect or specify model)**.
- **Built as a product** others can use **(owner)**:
  - Nothing owner-specific is hard-coded (hosts, names, paths).
  - Model profiles tolerate firmware versions other than the owner's 1.24.00, and unknown XML attributes and elements are ignored, not treated as fatal.
  - Third-party code and protocol knowledge keep their licenses; the `sds200` library is MIT, and attribution goes in an acknowledgments file.
  - No Uniden logos or trademarks in the app's branding. The scanner view reproduces the scanner's control layout for usability, not Uniden's branding **(designer's call)**.
  - Distribution: signed, notarized DMGs from GitHub Releases (Plans 12–15); the code is open source under Apache 2.0 (Plan 21, 2026-11-20). The app should stay compatible with the App Sandbox (outgoing network and USB entitlements) so the App Store remains possible **(designer's call)**.
- Without a paid developer account the Mac app runs normally with a free Apple ID; iOS builds expire after 7 days. Membership becomes necessary for the truck setup and for iCloud.

## 12. Screens in the first release

1. **Connect / station picker** — auto-discovered SDS200s on the LAN, manual address (for VPN), detected model with override, station name, test/connect. USB and Bluetooth visible but disabled.
2. **Main window — scanner view** (§7.1).
3. **Main window — Mac-style view** (§7.2).
4. **Hit log** (§9.2).
5. **Settings** — per-station logging/recording, key map; global storage switch.

Later: 6. **iPad/iPhone dash mode** — large tap targets, built from the Mac-style view.

## 13. Left to the builder

- Exact visual design, colors, spacing, iconography (sketches are directional only).
- Database technology for the hit log and settings, within §10's constraints.
- Minimum macOS version (prefer recent).
- Network discovery method for SDS200s on the LAN, if the protocol allows one.
- How hit boundaries are detected from `PSI` updates and aligned with the audio stream (see the protocol notes §6 and §8).
- Test strategy, including a simulated scanner for development without hardware.

## 14. Risks

1. **Protocol gaps** (§5.2). The core is confirmed on hardware; the open items are listed in the protocol notes §8. Mitigation: hardware capture at the start of development.
2. **Display colors won't match a customized scanner in the MVP** (§7.3), because `profile.cfg` import is deferred. `STS` still gives the correct items and text.
3. **SDS150 Bluetooth protocol undocumented** (§5.1). Mitigation: later stage; research first.
4. **Audio/metadata alignment** — recorded audio must line up with hit boundaries for per-transmission files.
