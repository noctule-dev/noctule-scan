# Line-in audio for USB scanners — design

Date: 2026-11-17. Status: approved by the owner in chat, 2026-11-17, after a builder check.
**Phases 1 and 2 (§9: the core and the app) are built, as Plan 18, against the mocks, on
2026-11-17; §12 lists where the build departs from §5–§8. Plan 18 merged as PR #11; the owner's
ad-hoc hardware test of it on the rig looked good (2026-11-17); the full session (§10) hasn't run.
The command line (§7) is Plan 19 (`docs/specs/2026-11-17-plan-19-line-in-cli-design.md`), built
against the mocks on 2026-11-17 on branch `feature/line-in-cli`; §12.4 lists where it departs from §7.
The owner's hand check of it on the rig (`noctule listen --station <name> --meter`, then `noctule
log`) is pending.** The mockups shown in the brainstorm are in the git-ignored `.superpowers/brainstorm/`
(`usb-audio-ui.html`); §6 describes what they showed, with the changes agreed afterwards.

Labels: **(the owner's call)** is a decision the owner made in the brainstorm on 2026-11-17;
**(designer's call)** is a default the designer chose that the owner hasn't ruled on and can
overturn. **[assumed]** is something no hardware has shown yet; §10 lists the checks that will.
Everything not labeled is fact about the code or a pointer.

## 1. Why

The SDS150 and the SDS100 have no audio over USB (SDS150 design §2, SDS100 design §2), so a USB
station logs hits but can't play or record them. The owner wants USB stations treated "just like
the SDS200": each hit stored as a WAV file, the hit log, playback in the hit-log window, and live
listening all working. **(the owner's call)**

The audio comes from a cable: the scanner's headphone jack, by a 3.5 mm stereo cable, into an
audio input on the Mac (the owner's SDS150 is cabled to a USB audio interface, "USB Audio Device",
as of 2026-11-17). That input is the scanner's headphone output, not a line-level output, so its
level follows the scanner's volume setting, and too much volume clips the input. The owner wants
a level meter to set it by. **(the owner's call)** And with a plug in the headphone jack the
scanner's own speaker is silent, so the app must play the audio through the Mac's current output.
**(the owner's call)**

## 2. Goals, non-goals, anti-goals

**Goals.**

1. A USB station (SDS150, SDS100, or any later USB model) can name an **audio input** on the Mac
   and a **channel** of it (Left, Right, or Both mixed). Such a station is a **line-in station**.
   **(the owner's call** for the input; the channel choice is the **designer's call**, so two
   handhelds can share one stereo interface, one per side.)
2. A line-in station records hits as an SDS200 station does: one WAV per transmission under the
   station's save-audio rule, with the same pre-roll and post-roll, the same 16-bit 8 kHz mono
   format, the path in the hit log, playback in the hit-log window, `hits` unchanged.
   **(the owner's call)**
3. The app plays the line-in live through the Mac's current output (Listen and the app volume,
   as for the SDS200), following the system output when it changes. **(the owner's call)**
4. A **line-in level meter** with a latching **CLIP** light, shown only on line-in stations,
   under the scanner's Volume slider in the Mac-style view and, in the Scanner view, beside the
   VOL knob on the front panel (§6.2); a warning naming the hit when the input clips, with a
   **Volume −1** button.
   **(the owner's call:** placement A of the mockups, shown only on line-in stations, after the
   owner noted that the SDS200's RTSP level doesn't follow the scanner's volume; the Scanner
   view's place, option C of a second set of mockups, on 2026-11-17, §12.1.)
5. The command line gets the same support (§7): listing inputs, setting a station's input,
   `log` recording, `listen` playing a line-in station, and a text meter. **(the owner's call)**
6. Sequencing: **1 the shared core, 2 the app, 3 the command line.** **(the owner's call)** The
   owner wants to try the experience in the app before the command line exists.
7. Capture with **AVAudioEngine, one engine per line-in station** (§4). **(the owner's call)**

**Non-goals.**

- Line-in for a network station. The SDS200 has RTSP audio; a network station never captures.
- Changing the Mac's own input gain (System Settings › Sound). The editor's note mentions it; the
  app never writes it. Whether the owner's interface needs it is a hardware check (§10).
- Detecting which scanner is on which cable. The station's settings say so; nothing checks.
- Bluetooth audio, iPad and iPhone (the capture module should not rule an iPad out, §4).
- Higher-fidelity recordings. Everything is 8 kHz mono, as the SDS200's (§5.2).
- Trimming the dead air at either end of a recording (§3a). A recording spans the hit, as the
  SDS200's do. **(the owner's call, 2026-11-17)**
- Changing the SDS200's audio, except the shared player's output-device fix (§5.6).

**Anti-goals** (would make this a failure even if it works).

- **Anything sent to a scanner that the user didn't do.** Capture is passive. The only scanner
  command this feature adds is the Volume −1 button's one `VOL` step, sent once per click and
  never resent, under the existing rule (one action, at most one state-changing command).
- **Touching the RTSP cooldown** for a line-in station: no wait, no record read or written.
- **An agent, a test or a mutation opening a real audio input.** It would trigger the macOS
  microphone prompt and record the owner's room or radio. §8 says how this is prevented.
- **A meter that misleads**: shown where the scanner's volume doesn't drive it (the SDS200), or
  measured after a conversion that hides clipping.
- **Silent loss**: a clipped or empty recording with nothing on screen saying so.

## 3. Constraints

- `NoctuleAppCore` must keep building for iOS with no AVFAudio, AppKit or UIKit; capture code
  lives in its own module and reaches the session through an injected protocol, as playback does
  (`AudioOutput`, `NoctuleAudioPlayback`).
- `StationRunner` (in `NoctuleStore`) is shared by `noctule log` and the app; the audio source
  plugs in there so both get it.
- The release app is signed with the **hardened runtime** (`packaging/notarize.sh`,
  `codesign --options runtime`) and today has no entitlements file. Under the hardened runtime,
  audio input needs the `com.apple.security.device.audio-input` entitlement, or capture silently
  delivers nothing. `scripts/build-app.sh` signs ad hoc without the hardened runtime, so a
  dev build works where a release build would not: the release must be checked (§10).
- `Info.plist` needs `NSMicrophoneUsageDescription`. The command line's permission is asked for
  the terminal app that runs it.
- The hit log's schema is version 1; a new column means version 2 and a migration
  (`HitLogSchema`).
- Rules from AGENTS.md hold: no real names in tracked files, mocks first, the owner's call for
  each hardware run.

## 3a. What the owner's rig showed (2026-11-17)

Probes on the owner's SDS150 (fw 1.01.02, scanning busy conventional channels, volume 5) with
its headphone jack cabled to the mic input of a C-Media "USB Audio Device", before the build
(statistics only, no audio kept; LESSONS.md 2026-11-17). Labeled **[rig]** below.

- The interface is a **mono** input: one channel at 48 kHz. Left/Right sharing (goal 1) needs a
  stereo line-in interface; on this one the channel choice has no effect. Its input gain is
  adjustable in Core Audio (it read 0.33).
- Its UID embeds the USB location (`AppleUSBAudioEngine:<maker>:<name>:<location>:2,1`), so it
  likely changes when the interface moves to another socket. Hence the name fallback in §5.1.
- AVAudioEngine on that device works (approach A): `auAudioUnit.setDeviceID` selected it. A tap
  delivered 100 ms buffers whatever size was asked; an `AVAudioSinkNode` delivered the device's
  512-frame blocks every 10.67 ms. §5.2 uses the sink node.
- The idle floor (squelch closed) is broadband hiss, no mains hum: block RMS about −52 dBFS,
  peaks about −38 dBFS. A fixed "peak below −50 dBFS" never means silence (§5.3 changed).
- Over 150 s and 6 hits, each hit's audio lay inside the hit as the pushes timed it: it began
  0.1–3.6 s after the first active push (median 2.1 s) and ended 3.5–5.2 s before the hit's end.
  Two real hits (1.5 s, 2.0 s) carried no audio at all. `audioOffset` stays 0 (§5.2).
- Volume 5 at that input gain peaked at −3.4 dBFS on the loudest hit: the band is reached
  around volume 4.

## 4. Approaches

All three share the rest of the design: an audio-source seam in the runner, so it takes chunks
from either the SDS200's RTSP session or a line-in; a new capture module beside
`NoctuleAudioPlayback`; and a small Core Audio layer to list inputs and notice one going away
and coming back.

- **A. AVAudioEngine, one engine per line-in station.** Each station's engine is pointed at its
  device (on macOS, through the input node's audio unit), with a tap that keeps the chosen
  channel and converts to 8 kHz mono. The same framework as the player, so the project's notes
  on its threading apply (LESSONS.md 2026-11-08, `AudioPlayer.Box`); low latency (about
  10–20 ms of device buffering); carries over to an iPad. Pointing an engine at a non-default
  device is fiddly on macOS, and the engine stops on configuration changes, which must be
  handled.
- **B. Core Audio AUHAL for everything.** Most direct device control, lowest latency, clearest
  unplug handling; more low-level code, Mac-only.
- **C. AVCaptureSession.** Easy device choice and connect/disconnect notices, works on iPad;
  built for media capture, with larger and less predictable buffering (more lag behind the
  display) and clumsier channel selection.

**Chosen: A (the owner's call).** It reuses what the project knows from playback, keeps up with
the 100 ms pushes, and leaves an iPad open. B is the fallback if A's device handling proves
unreliable on the owner's interface.

## 5. Design: the core

### 5.1 Station settings

- The input is Mac-specific, so it lives in the **device settings** (`device.json`, beside
  `usbPort`), not in `stations.json`: `audioInputDevice` (the Core Audio device UID),
  `audioInputName` (the name when it was chosen, for display when the device is missing, and to
  find it again: when no present input has the saved UID but exactly one has the saved name, that
  one is used and the saved UID is left as it was; **[rig]** UIDs carry the USB location) and
  `audioInputChannel` (`left`, `right`, `both`; absent means `both`). **(designer's call)**
  Absent `audioInputDevice` means no line-in: the station behaves exactly as today. The existing
  unused `audioOutputDevice` key stays unused.
- A network station ignores these keys; the editor offers them only for USB.
- A line-in input is used whenever it is set, **whatever the save-audio rule**: save-audio
  governs recordings only, so `never` still allows Listen and the meter. **(designer's call;
  differs from the SDS200,** where `never` means no audio session at all, to keep RTSP traffic
  away from the scanner; a line-in has no such hazard.)
- Two stations naming the same device and an overlapping channel are allowed, with a note in the
  editor (§6.1); they would record the same audio twice. **(designer's call)**

### 5.2 Capture and format

- A new module (working name `NoctuleAudioCapture`, AVFAudio and Core Audio, macOS now) provides
  a **line-in source**: given a device UID and a channel, it starts an AVAudioEngine on that
  device, takes its input through an **`AVAudioSinkNode`** (not a tap, which delivered 100 ms
  buffers **[rig]**) at the device's rate and format, takes the channel (Both: the mean of
  left and right; a mono device: its one channel whatever is chosen), measures levels (§5.3) on
  those samples, then converts to **16-bit 8 kHz mono** and yields `AudioChunk`s of **320
  samples (40 ms)**, the size of an SDS200 RTP packet, so the recorder's gap rule
  (`lostBefore × 320` zero samples) holds unchanged. **(designer's call)**
- Chunk fields for a line-in: `receivedAt` is the capture time of the chunk's first sample (from
  the sink node's host time, not the time the callback ran); `sequence` counts chunks; `ssrc` is fixed per
  engine start; `lostBefore` counts whole chunks dropped by an engine overload, normally 0;
  `discontinuity` is true on the first chunk after a restart of the engine (device back,
  configuration change, wake).
- **The source protocol** lives in `NoctuleKit` (no AVFAudio): start, a chunk stream, a level
  stream, a state stream, stop. `StationRunner` takes a factory for it, as it takes one for its
  transport; the app and `noctule` inject the AVAudioEngine one, tests a fake.
- **Recording alignment.** `TransmissionRecorder` already places chunks by
  `receivedAt + audioOffset` against the pushes. On the SDS150 the audio lies inside the hit as
  the pushes time it **[rig]**, so `audioOffset` is 0; it stays a per-model `ModelProfile` value
  (`lineInAudioOffset`) for the SDS100, unmeasured. Recordings carry a few seconds of dead air
  at each end, as the hit's span does. **(designer's call)**

### 5.3 Levels, clipping and silence

- **Measured before conversion**, on the chosen channel at the device's rate, so resampling
  can't hide a clip. Per ~33 ms (30 Hz): peak in dBFS. A **clip** is a run of samples at or
  within 0.1 dB of full scale (two or more consecutive, so one stray full-scale sample from a
  well-behaved converter isn't one). The exact rule is the builder's, pinned by tests.
- **The meter scale** is −60 to 0 dBFS, green to −12, yellow to −3, red above, with a marked
  **target band of −18 to −6 dBFS** for peaks during a transmission and a peak-hold tick held
  about 1.5 s. **(designer's call)**
- **CLIP latches** until the user clicks it (app) or until the meter line is redrawn after 3 s
  (command line).
- **A hit that clipped** is recorded as clipped: the runner marks the hit (§5.5), the app shows a
  warning naming it (§6.3), and `log` prints a warning line (§7). One warning per hit. A clip
  counts for a hit when its time (as the recorder times chunks, `receivedAt + audioOffset`) falls
  between the hit's start and end; a clip outside any hit (a key beep, noise with the squelch
  open) only lights CLIP. **(designer's call)**
- **A silent line-in**: the runner keeps the **idle floor**, the median block RMS of the line-in
  outside hits (over the last minute). A hit of at least 2 s is **silent** when its block RMS
  never rises 15 dB above that floor. Real hits can be silent **[rig]** (a carrier blip, a wrong
  tone, data), so the runner warns only after **three silent hits in a row**:
  `no audio on the line-in during the last 3 transmissions; check the cable and the scanner's
  volume`, then not again until a hit carries audio. **(designer's call;** catches a loose
  cable or volume 0; changed after the rig showed a fixed −50 dBFS peak can't mean silence.)

### 5.4 The runner

- `hasAudio` becomes: a network station as today, **or** a USB station with an
  `audioInputDevice` (once `MDL` has answered, as today). For a line-in station the runner never
  builds an `AudioSession`, never calls the cooldown store or gate, and starts the line-in
  source instead, after the scanner has connected.
- What follows the chunks is unchanged: the recorder, the `liveAudio()` tap, `audioStreaming`,
  hits waiting for audio, the end-of-run close.
- **States** reuse `AudioSessionState` where they fit: `.starting`, `.streaming`, `.stopped`,
  and `.failed(reason)` for a start that can't happen. New for a line-in: the input being
  **missing** (device not present) is a waiting state, not a failure: the runner logs hits
  without audio, warns once (`the audio input "<name>" isn't connected; logging without audio`),
  watches for the device (Core Audio's device-list notice, no polling of the device itself), and
  starts the source when it returns, with no limit on attempts (nothing is sent to a scanner).
  The builder decides whether that is a new case or a separate line-in state.
- **Permission denied** is `.failed("Noctule Scan isn't allowed to use audio input. …")` with
  hits logged without audio; not retried until the next start.
- A scanner disconnect (USB unplug) doesn't stop the line-in: the scanner's resume path is
  untouched, and no hit runs while the scanner is away, so no recording happens. **(designer's
  call)**
- Stop, sleep and quit stop the engine; wake starts it again. There is nothing to tear down on
  the scanner.

### 5.5 Hit log

- Schema version 2 adds `audio_clipped INTEGER` (0/1, NULL for hits logged before, and for
  network stations). It is set for any line-in hit that clipped, recorded or not.
  `HitLog` migrates version 1 in place. **(designer's call)**
- The hit-log window's inspector shows "Clipped" for such a recording; the table is unchanged.
  `hits --csv` gains an `audio_clipped` column at the end. **(designer's call)**

### 5.6 Playback

- The same `liveAudio()` tap and `AudioPlayer` as the SDS200. Listen starts **on**, as today.
- **A smaller jitter buffer for a line-in** (the SDS200's prefill is 200 ms of network jitter;
  a cable has none): about 60 ms, the builder's to tune by ear on hardware, configurable in
  `AudioPlayer`'s init. **(designer's call)**
- **The player follows the system output**: when the default output device changes (AirPods
  connected, speakers chosen), the engine is rebuilt on the new device. Today's player doesn't
  handle `AVAudioEngineConfigurationChange`; the fix serves the SDS200 too.
- Turning the app volume down or Listen off never affects recordings or the meter.

## 6. Design: the app

The mockups (`usb-audio-ui.html`) used the app's own layout from `images/screenshots/`.

### 6.1 The station editor

For a USB station, a new **Audio** section after Connection:

- **Audio input**: a popup of the Mac's inputs by name, plus **None (no audio)**, the default.
  A saved input that isn't present shows as `<name> (not connected)`.
- **Channel**: Left, Right, Both (segmented). Shown when an input is chosen.
- **Line-in level**: a live meter (§5.3), shown when an input is chosen, for proving the device
  and channel are right ("key the radio up and watch it move"). The editor opens its own
  short-lived capture for it, closed when the sheet closes; if the station's window is running
  the same input, the meter reads from the session instead. **(designer's call)**
- A note: "Connect the scanner's headphone jack to this input. Set the level in the station
  window with the scanner's volume: during a transmission the peaks should sit in the marked band
  and CLIP should never light." When another station uses the same input and an overlapping
  channel: "<station> also uses this input (<channel>)."
- Saving an input change for a station whose session is open restarts its audio source only
  (the scanner session keeps running), like a saved-port change does today but without closing
  the port. **(designer's call)**

### 6.2 The station window

- **Mac-style view**: Listen and the app volume are shown again for a line-in station. In the
  Scanner group, directly under **Volume**, a **Line-in level** row with the meter and CLIP.
  Shown only on line-in stations; a network station and a USB station without an input are
  unchanged.
- **Scanner view**: a slim vertical meter on the front panel, just right of the VOL knob (its
  volume), between the knob column and the display: a small round CLIP lamp on top, the bar
  filling bottom-up below it (about 6 pt wide, as tall as the knob and its labels; the same
  scale, zones, band ticks and peak hold as every meter here), and `IN` under it. SQL stays
  under VOL; the display, keypad and Scroll knob move right by the meter's width. The controls
  bar has no meter. A network station and a USB station without an input show the panel as
  before. **(the owner's call, 2026-11-17:** option C of five placements; it replaced the
  controls bar's "In" meter, §12.1.)
- **Status bar**: `No audio over USB` becomes `Listening · <device>`, `Not listening`, or
  `Line-in not connected` (the input missing), and `Line-in blocked` with the reason in its help
  when permission is denied. Battery stays.
- The meter moves whether or not Listen is on.

### 6.3 Clipping and warnings

- When a hit clips: CLIP latches red, and a warning shows in the Mac controls bar like the
  session's other warnings: `The audio input clipped during "<channel>". Turn the scanner's
  volume down a step.` with **Volume −1** (sends one `VOL` step down through
  `setScannerVolume`, as one slider notch does; disabled at 0; never repeats) and a dismiss. It is
  also written to stderr as every session warning is (`SessionWarningLog`).
- Missing input, silent line-in and permission denied are warnings in the same place.
- Permission denied adds an **Open Privacy Settings** button (System Settings › Privacy &
  Security › Microphone).

### 6.4 Unchanged

The hit-log window plays a line-in station's recordings as an SDS200's. Settings › Stations ›
Recording now applies to a line-in station (its Format line already reads "WAV, 16-bit, 8 kHz
mono"). A USB station's `.noAnswer` and waiting banners are unchanged.

## 7. Design: the command line (phase 3)

- `noctule audio-inputs`: one line per input (`<UID>  <name>  <n> ch`), opening none; with the
  kill-switch (§8) it lists none, as `ports` does.
- `station add --usb … --audio-input <name or UID> [--audio-channel left|right|both]`: a name
  must match exactly one present input; saved as its UID and name. `--audio-*` refuse a network
  station (exit 64). `station list` shows `line-in <name> (<channel>)`.
- `noctule log` on a line-in station: prints `audio: line-in <name> (<channel>)` instead of
  `log: no audio over USB`, records WAVs, and its end lines get `→ <file>`. Clips print
  `warning: the audio input clipped during <channel>; turn the scanner's volume down`; missing
  input, silence and permission print their warnings (§5.3, §5.4). No cooldown wait.
- `noctule listen --station <name>`: for a line-in station, plays (and with `--record`, records)
  the line-in; `--seconds`, `--no-play` and the exit codes as today; no RTSP, no cooldown.
  `--meter` draws a one-line text meter on stderr (`line-in ▇▇▇▇▇▇▇····|···· peak −9 dBFS`, `CLIP`
  latching 3 s), redrawn about 10 times a second when stderr is a terminal, one line a second
  otherwise. For a network station, `--station` picks its address and reconnect wait and runs
  RTSP as today. **(designer's call)**
- The kill-switch and test override apply to `noctule` as to the app (§8).

## 8. Testing and agent safety

- **No real input in tests or agent runs.** `NOCTULE_NO_USB_DETECTION` (which agents always set)
  also turns off audio-input detection: no input is listed, and **no Core Audio input is opened,
  even one saved in a station** (unlike a saved serial port), so no test or agent can trigger the
  microphone prompt. A line-in station then logs without audio with the warning
  `audio input disabled by NOCTULE_NO_USB_DETECTION`. **(designer's call)**
- **The mock's headphone jack.** `noctule-mock-scanner --serial --line-out PATH` writes the
  scenario's audio in real time to a local pipe or socket at `PATH`, as the jack would:
  48 kHz stereo (so the conversion and channel paths run), the tone during each transmission and
  silence between (the radio's squelch), its amplitude following the mock's `VOL` (0–15) so high
  volumes clip, on the channel given by `--line-out-channel left|right|both`. A fault
  `--fault line-out-silent` writes silence throughout. All of it **[assumed]** (the level curve,
  the stereo layout) and marked so in `MockPersonality`.
- **Test-only override** `NOCTULE_TEST_LINE_IN=<path>` (the app: honoured only with a private
  `NOCTULE_SETTINGS_DIR` and the kill-switch; `noctule`: only with the kill-switch) replaces every
  line-in station's device with the mock's `--line-out` stream, feeding the same channel,
  metering and conversion code; only the Core Audio device piece is bypassed. Printed to stderr
  when in effect, as the other overrides are.
- Unit tests use a fake source (chunks and levels on demand): runner wiring, the recorder with
  line-in timing, clip and silence detection, missing input and its return, permission denied,
  no cooldown call, settings round-trip, schema migration, the player's device change through an
  injected engine seam where practical.
- The app is checked on the mocks with the computer-use tools (AGENTS.md "Driving the app"):
  the editor's Audio section, the meter moving with the mock's `VOL`, CLIP and Volume −1 (one
  `VOL` in the mock's log per click), Listen, a hit recorded and played in the hit-log window.
- AGENTS.md gains the rules: agents never open a real audio input; a hardware run with the line-in
  is the owner's call each time; recordings from the real line-in are real radio audio and never
  committed.

## 9. Delivery

Two plans, in the owner's order **(designer's call** for the split**)**: Plan 18 is phases 1 and 2,
so the owner has something to try at its end; Plan 19 is phase 3. The phases: **1 core** (settings, capture
module, source protocol, runner, levels, hit-log v2, player fix, the mock's `--line-out` and the
override); **2 app** (entitlement and usage string, editor, meter, warnings, status bar);
**3 command line** (`audio-inputs`, `station add` flags, `log`, `listen --station`, `--meter`).
The owner tries the app on the mock and on the SDS150 after phase 2.

## 10. Hardware session (the owner's, after phase 2)

On the owner's SDS150 and USB Audio Device, each step the owner's call. Items 2, 4 and 5 were
answered by the 2026-11-17 probes (§3a); re-check them with the built app. After Plan 18 merged the
owner ran an ad-hoc test of the app on the rig and reported that it looked good (2026-11-17); the
items below haven't been run one by one.

1. The input listed by name; its UID stable across an unplug and replug, and across USB sockets
   (if not, a moved interface needs picking again, as the SDS100's port does).
2. The SDS150's jack: mono on both channels, or stereo? Which channel choice is right.
3. Levels: meter peaks at each scanner volume step during transmissions; the step that lands in
   the band; whether the lowest useful step still clips (then the Mac's input gain matters).
4. Hum or noise with the scanner on USB power (a ground loop); whether an isolator is needed.
5. Latency: `audioOffset` from recordings against hits (the start of speech against pre-roll).
6. Clip: CLIP lights at high volume, the warning names the hit, Volume −1 sends one `VOL`.
7. The release build's permission prompt and capture, with the entitlement (a signed build).
8. Output switching (speakers to headphones) mid-listen.
9. The interface unplugged and replugged during `log` and in the app.

## 11. Left to the builder

- Whether a missing line-in is a new `AudioSessionState` case or a separate state type.
- The clip rule's exact threshold and run length, and the meter's refresh and ballistics, within
  §5.3.
- How the editor's meter shares a running session's capture.
- The mock's `--line-out` transport (named pipe or socket) and how it drops audio when no one
  reads.
- The AVAudioEngine device-selection mechanics, and how configuration-change restarts are
  debounced.

## 12. What was built (Plan 18)

Plan 18 (`docs/specs/2026-11-17-plan-18-line-in-audio.md`) built phases 1 and 2 on branch
`feature/line-in-audio`, test-first against `MockLineOut` and `FakeLineInSource`. Nothing in it has
run on the owner's rig: every claim below is about the code and the mocks. Where §5–§8 say
otherwise, this section is what the code does. Labels as above, and **(designer's call)** here marks
a ruling made during the build that the owner hasn't seen. This section also supersedes §3's
stale remarks that the app has no entitlements file and that `scripts/build-app.sh` signs without the
hardened runtime: both are done (§12.2).

### 12.1 Departures from §5–§8

- **The mock's level curve (§8).** `MockLineOut.peak(forVolume:)` is `volume / 8`, with no ceiling
  before the sum with the noise is hard-clipped to +-1, so volume 8 and up clips: at 8 the tone
  reaches full scale, and a crest at the scenarios' tones (440 Hz to 1 kHz) holds two or more
  samples above the clip threshold (about five at 440 Hz), which the detector counts as a clip; 9
  and up cut the tone flat. The plan had `min(1, volume / 8)`, which could clip only through the
  noise's help; §8 says high volumes clip, and a mock that clips the tone itself is what the clip
  tests need. **(designer's call)** **[assumed]** like the rest of the curve.
- **The mock's jack isn't silent between transmissions (§8).** §8 says the mock plays silence
  between transmissions and that `--fault line-out-silent` writes silence throughout. The code plays
  white Gaussian noise at -52 dBFS RMS there, under the tone as well, and the fault keeps that noise
  (it silences the tone only). The owner's rig showed an idle floor of broadband hiss at that level,
  not silence (§3a), and the idle floor (§5.3) is measured against it. **(designer's call)** **[assumed]**
- **The command line didn't read `NOCTULE_TEST_LINE_IN` in Plan 18 (§8).** §8 says `noctule`
  honours it with the kill-switch. `LineInDetection` defined the rule and the app used it; `noctule`
  took it up with the rest of the command line in Plan 19 (§12.4).
- **Chunk times follow the capture clock (§5.2).** `receivedAt` is the capture time of a chunk's
  first sample. `LineInPipeline` counts samples from the first buffer's host time, and starts the
  count again at a buffer's host time when the two differ by more than 20 ms (no discontinuity, no
  sequence skip), so a device clock that runs a little fast or slow doesn't drift away from the
  pushes. 20 ms clears the pipe source's read jitter and is far inside the recorder's 0.5 s
  pre-roll. **(designer's call)** The constant is a hardware check (§12.3).
- **Under Both the meter reads the louder raw channel (§5.2, §5.3).** **(designer's call)** §5.2
  measures levels on the chosen channel, which under Both is the mean of left and right; a clip on
  one channel alone (a mono plug in a stereo interface, or a one-sided jack, §10) then averages to
  half scale, about -6 dBFS, inside the target band, and CLIP stays dark. So under Both on a device
  with two channels `LineInPipeline` meters left and right apart: each window takes the louder
  channel's peak and RMS, and is clipped when either channel clipped. The recording still takes the
  mean. A one-channel device, Left and Right are unchanged.
- **The engine seam takes a device UID.** `LineInEngine.start(deviceUID:onBuffer:)`, not a Core
  Audio device ID, so the translation (UID to `AudioDeviceID`) stays inside `AVLineInEngine` and no
  test touches Core Audio. Nothing else consumes the protocol.
- **A pipeline per engine start.** `EngineLineInSource` builds a new `LineInPipeline` from the
  format each engine `start` returns, so a device that comes back at another rate (48 kHz, then
  44.1 kHz) streams chunks instead of silently dropping buffers at a foreign rate; the first chunk
  after a restart is flagged `discontinuity`, and the sequence carries on. The pipeline also drops
  any buffer whose rate isn't its `inputFormat`'s.
- **A stopped source never starts its engine.** Once `stop()` has run, a start, a configuration
  change or a device notice that was already queued is dropped instead of acted on; otherwise it
  could open the input after the user stopped. `stop()` returns while a permission prompt is still
  up, and a stopped source can't be started again.
- **A first chunk after an initially missing socket is flagged `discontinuity`** (`PipeLineInSource`,
  the mock's reader). `EngineLineInSource` doesn't flag a first start. The recorder ignores the flag,
  so nothing treats either as an error.
- **The Scanner view's meter stands beside the VOL knob (§6.2).** **(the owner's call)** The plan
  put a compact "In" meter and CLIP at the end of the controls bar under the panel. On
  2026-11-17 the owner reviewed five placements in mockups and chose option C: a vertical meter on
  the front panel just right of the VOL knob, with a round CLIP lamp on top (a button; a click
  clears the latch) and `IN` under the bar. The bar is 6 pt wide and at least 58 pt tall,
  stretched to the knob's height with its labels; one meter view draws both orientations
  (`LineInMeterView`'s `axis`, `MeterLayout`), and `LineInMeterPlacement` says which view puts
  its meter where. The Mac-style view's Line-in level row, the clip warning under the controls,
  and the editor's meter are unchanged.
- **`.failed` is a line-in state the window shows (§6.2).** Under the kill-switch the source is a
  `DisabledLineInSource` that reports `.failed(reason)` (`audio input disabled by
  NOCTULE_NO_USB_DETECTION`), and the runner still counts the station as having audio. The status
  bar maps `.failed` as it maps `.denied`: `Line-in blocked`, the reason as its help. Listen and
  the app volume are disabled while the line-in is `.failed` or `.denied`
  (`StationSession.canListen`), since there is no audio to hear. **(designer's call)**
- **The editor's name fallback (§5.1, §6.1).** **(designer's call)** The editor applies §5.1's rule too: with no present
  input at the saved UID but exactly one with the saved name, it selects that input and shows no
  `<name> (not connected)` entry; a save that changes nothing leaves the saved UID as it was.
  Otherwise the editor would say "not connected" while the runner records from the input.
- **Only a normally ended hit is judged silent (§5.3).** **(designer's call)** A hit ended by a stop, a scanner
  disconnect or a missing input neither counts toward the three silent hits in a row nor resets
  them: a stop must not raise `no audio on the line-in …`. The warning text has no channel in it,
  so it is a constant (`StationRunner.silentLineInMessage`). Digital silence (-inf dB) counts as
  silent, and levels of hits that arrive while logging is paused stay out of the idle floor.
- **A clip counts through the detector's hangover (§5.3).** §5.3 counts clips between a hit's
  start and end. The runner counts them until the hit's end including the detector's hangover of
  about 1 s: on the rig the line-in audio ends 3.5–5.2 s before the hit ends (§3a), so the hangover
  holds only the scanner's own tail, which is still its audio. **(designer's call)**
- **A preview's lifetime (§6.1).** The editor's meter opens a source of its own
  (`SessionRegistry.previewLevels`); the registry stops it when the meter's stream ends (`cancel`,
  or its reader's task cancelled) and at `suspendAll()` (a fresh one starts on the same stream at
  `resumeAll()`, none while suspended) and `stopAll()`, so a preview never keeps the input open
  after its view is gone or the Mac sleeps. A running session's input change or stop doesn't end a
  preview; the sheet closing does.
- **New cases in every exhaustive switch.** `RunnerEvent` gained `.lineIn(LineInState)` and
  `.clipped(LoggedHit)`; the command line's `log` handles them, and `.recording`, by printing
  nothing (Plan 19 owns that copy). Levels reach the app through the runner's consumer, not as
  events.
- **`NoctuleAudioCapture` is macOS only.** `NoctuleKit`, `NoctuleStore` and `NoctuleAppCore` keep
  building for iOS with no AVFAudio (the line-in protocol and types, the meter and the session are in
  them). The capture module's Core Audio parts are under `#if os(macOS)`, and its iOS build isn't
  checked.

### 12.2 Additions

- **The capture ring's slots are 1024 frames.** The render callback copies each device block into a
  preallocated slot of a 64-slot `CaptureRing` and wakes a serial queue; `LineInBlock.maxFrames` is
  1024, twice the rig's 512-frame blocks, and `AVLineInEngine` splits any larger block. The pages
  are touched before the engine starts, so the render thread never faults one in.
- **More status-bar copy (§6.2).** `Line-in starting…` while the source starts (the permission
  prompt included) and `Line-in off` once it has stopped, besides `Listening · <device>`, `Not
  listening`, `Line-in not connected` and `Line-in blocked`; each has a tooltip.
- **Volume −1 leaves the clip warning up** after its one `VOL` step; the user dismisses it. CLIP
  latches until clicked.
- **Signing (§3).** `Resources/NoctuleScan.entitlements` holds the audio-input entitlement and
  `Info.plist` the microphone usage string; `scripts/build-app.sh` signs ad hoc with the hardened
  runtime and the file, as the release does, so a development build behaves as a release will.

### 12.3 For the hardware session (§10)

What the build couldn't settle without the owner's rig. Each is a thing to look at, never to
repeat in a loop, and each run is the owner's call.

- **The engine's setup.** The format the input node reports after `setDeviceID` is the device's
  (48 kHz mono on the rig); an engine with no output node starts; a switch of the system output
  doesn't restart or stop the capture.
- **Unplug.** After the interface is pulled, no chunk may arrive from another input (the built-in
  microphone); the source reports `.missing`. On replug in another USB socket the input is found
  by name (§5.1) and capture resumes.
- **Timing.** Host times from the sink node are valid; blocks are 512 frames; capture resumes after
  a wake; `lostBefore` stays 0 over an hour; how long `engine.start` takes; the 20 ms re-anchor
  threshold (§12.1) and the 60 ms player prefill, to tune by ear.
- **Output changes.** The player follows a real output switch (AirPods connected during Listen):
  macOS posts the configuration-change notice that the fake engine only imitates.
- **The signed build.** The first launch of a hardened, entitled build prompts for the microphone
  and then captures (§3: without the entitlement it captures nothing and says nothing). Whether an
  ad hoc development build asks again after each rebuild is unchecked.
- **The editor's listing.** `CoreAudioInputs` is read about once a second while the sheet is open
  (`refreshPorts`); it must stay cheap and open no stream (the microphone indicator stays off
  while the editor shows no meter).

### 12.4 The command line (Plan 19)

Plan 19 (`docs/specs/2026-11-17-plan-19-line-in-cli.md`; short design
`docs/specs/2026-11-17-plan-19-line-in-cli-design.md`) built §7 on branch `feature/line-in-cli`,
test-first against `noctule-mock-scanner --serial --line-out` (through `NOCTULE_TEST_LINE_IN`),
`FakeLineInSource` and `FixedAudioInputListing`. Nothing in it has run on the owner's rig. §7 is
built as written, and the owner's own calls are only §7 itself, `station edit` deferred and approval
of the design note. Everything below is **(the controller's call)**, a ruling made during the
build that the owner hasn't seen; each is cheap to change.

- **Where §7 is exact, the code is.** `audio-inputs` lines, the `station add` refusals, the `log`
  and `listen --station` copy, and the meter are as the design note gives them; AGENTS.md's Build and
  test bullets hold the wording.
- **The meter's bar sits after the 18th cell.** §7's sample (`▇▇▇▇▇▇▇····|····`) is only a shape.
  The meter has 20 cells over -60…0 dBFS (cell k, counted from 0, lights at -60 + 3(k+1)) and the
  `|` between cells 17 and 18, at -6 dBFS, the target band's top: a peak of -9 dBFS reads
  `line-in ▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇▇·|·· peak -9 dBFS` (17 filled; the real line has U+2212 for the minus).
  The peak is the held peak (`PeakHold`, moved from `NoctuleAppCore` to `NoctuleKit`, API unchanged),
  rounded to a whole dB. Cost if wrong: one string constant and a test.
- **`audio-inputs --host x` exits 64, not 2.** Every `CLIUsageError` in `main.swift` exits 64 today
  (`ports --host` too); "as today" won over the brief's 2.
- **`station add` details §7 leaves open.** The `, line-in <name> (<channel>)` suffix sits inside the
  line's parentheses after `save audio: …`. An input name is matched ignoring case and surrounding
  spaces (station names already match that way); several matches are still ambiguous. A UID that is
  listed is taken as given. Where no inputs are listed (the kill-switch, or `NOCTULE_TEST_LINE_IN`,
  which has no list) a value that matches nothing is saved as a UID with that text as its name and
  the note `station: saved "<x>" as an audio input ID (no inputs are listed)`: it is the only way to
  give a station an input there. No `--audio-channel` saves no channel key (it reads as both).
- **`log`'s warnings.** The terminal-permission sentence and the clip warning print as
  `warning: …` lines. The clip warning names the hit's channel (§7's sample had no quotes; the design note
  adds them), or its source label when the hit has no channel name, never empty quotes.
- **`listen --station` on a line-in station** opens only the input (no serial port, no station lock,
  no scanner traffic, no RTSP, no cooldown; as the owner-approved design note says). A permission denial prints
  `audio: failed: <the terminal sentence>` and exits 1, since `listen` reports its failures as
  `audio: failed: …`; the kill-switch prints `audio: failed: audio input disabled by
  NOCTULE_NO_USB_DETECTION`, exit 1. It prints no `packets … lost … recoveries` line, which counts RTP
  packets. `--seconds` counts from the start, waiting for a missing input included. It doesn't
  record the station as the last one used. The meter shows nothing while the input is missing.
  The fix wave after the final review added three rulings. **A failure after the input has
  streamed is a wait, not an exit**: `EngineLineInSource` reports `.failed` when an engine start
  fails (plausible just after a replug) and then keeps watching the input and starts it again, so
  `listen` prints `audio: <reason>; waiting` once per change and goes on, as `log` does; `.failed`
  before the first `.streaming` (the kill-switch, an input that can't be opened) and `.denied` at
  any time still exit 1. No mock produces a `.failed` after streaming, so a unit test
  (`aFailureAfterStreamingIsAWait`) is its only check. **A run that fails before the input ever
  streamed leaves no `--record` file**: the empty WAV is removed (the file is still created at the
  start, so an unwritable path is refused at once). A run stopped by a signal, or by `--seconds`,
  keeps its file even if empty. Cost if wrong: a few lines in `LineInListenStatus` and
  `LineInListen`.
- **`log` under the kill-switch prints no `audio: line-in` line**: the
  `warning: audio input disabled by NOCTULE_NO_USB_DETECTION` alone says the station has no audio
  this run (`StationCLI.usbAudioLine`). A permission denial is learned only when the source opens
  the input, after the connect, so there the `audio: line-in` line still comes first and the denied
  warning after it.
- **On a network station `--port` and `--reconnect-cooldown` still override `--station`'s values**;
  only `--host` and `--rtsp-port` are refused (an explicit flag is the user's choice; the full 120 s
  after an unclean close is untouched). `--meter` there is refused (exit 2).
- **Refusals of `listen`'s flags print without the `noctule: ` prefix** (`listen: --meter needs a
  line-in station`), so the parse-time and the runtime refusal read the same.
- **`NOCTULE_TEST_LINE_IN` in `noctule`** needs only the kill-switch (no settings directory), and
  `LineInDetection.overrideNotes` prints as `noctule: test override: …` once, for `audio-inputs`,
  `station`, `log` and `listen`. The mock's `--line-out` serves one client, so the test of `listen`
  beside `log` (`listenTakesNoStationLock`) gives the stream to `listen` and runs `log` without it:
  it tests the lock and the port, not shared audio.

For the hardware session (§10): the command line adds nothing to measure beyond §10's checks, with
three extra looks on the rig: that `noctule listen --station <station> --meter` plays and meters
the real input (and macOS asks for the terminal app's microphone permission the first time), that
unplugging and replugging the USB audio interface during it ends in `audio: line-in … (…)` again
with `listen` still running (whatever it says in between, the waiting line or
`audio: <reason>; waiting`), and that `noctule log` on the same station records a hit's WAV with the
permission already given.
