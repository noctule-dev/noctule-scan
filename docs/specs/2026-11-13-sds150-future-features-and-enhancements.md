# SDS150: future features and enhancements

Date: 2026-11-13
Status: a backlog, not a plan. Nothing here is approved or scheduled; each item is the owner's to rule on, and any that is picked up gets its own design and plan in `docs/specs/`, built against the mock first (AGENTS.md).

## 1. Where the SDS150 stands

The SDS150 over USB serial is supported end to end: the command line (Plan 7) and the Mac app (Plan 8), verified on the owner's SDS150 (fw 1.01.02) on 2026-11-12 and 2026-11-13. Control, the mirrored display, keys, volume and squelch, status pushes (100 ms, kept alive with `KAL`), menus, hit detection and the hit log all work as they do for the SDS200, except audio. The designs are `2026-11-11-sds150-usb-design.md` (§8 has the hardware results, §13 the build decisions) and `2026-11-12-plan-8-sds150-app.md`.

## 2. New features

### 2.1 Audio from the SDS150

The largest gap: an SDS150 station logs hits but can't play or record them. The USB connection is a serial port only **[hw]**, and Uniden's command specification has no audio command. Routes to explore:

- **Line-in from the headphone jack** into the Mac's audio input (or a USB audio interface). Works with any firmware, needs a cable, and the app would align the input with hits from the `PSI` pushes (the SDS200's recorder already aligns RTP audio with pushes, so `TransmissionRecorder` may carry over). Open: input level and squelch-tail handling, latency between the audio and the pushes, and choosing the input device per station.
- **Bluetooth audio** (the SDS150's Bluetooth is undocumented; see 2.2). Open: whether the scanner offers a standard audio profile the Mac can pair with.

Either route needs a design: where the audio enters (`AudioSession` today is RTSP-only), recordings and the save-audio rules for a USB station (today they have no effect), and the Listen control (hidden for USB stations).

### 2.2 Bluetooth

The station editor shows `Bluetooth — not supported yet`, disabled. Uniden documents neither the Bluetooth control link nor audio over it, and Uniden's spec names the model `SDS150GBT` (the mock can report it with `--mdl-name`). A first step is read-only discovery with the owner: what the scanner advertises, and whether the command set answers over it. Bluetooth would also be the likeliest route to 2.3.

### 2.3 iPhone and iPad

They can't open USB serial; the shared code (`NoctuleKit`, `NoctuleStore`, `NoctuleAppCore`) builds for iOS so the app can follow once there is a link: Bluetooth (2.2), or a relay on the Mac that serves the scanner on the local network. A relay must never be exposed to the internet (the protocol has no authentication; AGENTS.md).

### 2.4 An SDS150 drawing of the front panel

The Scanner view draws the SDS200's panel for every model (design §7.3); the screen inside it is the SDS150's own, from `STS`. An SDS150 drawing (its keys, knob and layout) would make the keypad match the radio in hand. Per-model layout belongs in per-model data (AGENTS.md).

### 2.5 Other models over USB

The serial transport is model-neutral (design goal 5). **The SDS100 is supported since Plan 17** (`2026-11-16-sds100-usb-design.md`): on this stack, with a mock personality from the owner's check of 2026-11-16, `PSI,100`, `STS` at 100 ms and its own keep-alive (its `PSI` renewed every 60 s, since it answers `KAL` `ERR`); its hardware session is pending (that design's §7). Still not tested or supported: the SDS200 over USB (control without audio) and the BCD436HP. Each needs a mock personality from hardware facts, a hardware session, and its own `ModelProfile` values (push and display intervals, keep-alive, battery).

### 2.5a A station knows which radio it is

From the SDS100 design §8. A station's saved port is its identity, so it means "the radio in that socket": the SDS100 reports no USB serial number (its path follows the socket), the SDS150's is a placeholder, and Uniden's spec has no command that returns a serial number or ESN. Two radios of one model that swap sockets swap stations silently, hit logs included, and an SDS100 whose cable moves needs its port picked again. Possible steps: a model remembered per station, so that Automatic looks only at ports whose product name names that model (`SerialPortInfo.knownModel` already tells the SDS100 and the SDS150 apart) and an SDS100 station with both handhelds plugged in needs no saved port; a serial number if a documented source ever appears. An undocumented `ESN` query would need the owner's approval and is not proposed.

### 2.5b A battery reading for the SDS100

From the SDS100 design §8. `GCS` gave no reading on the owner's SDS100 (fw 1.26.01), so its profile has no `supportsChargeStatus` and the app shows no battery for it. Uniden's spec and the `sds200` library say the SDS100 reports a `Battery` attribute (0.0–3.3, a voltage) on `GSI`'s `Property`; the SDS100 hardware suite prints whether the owner's unit does (that design's §7 H1). If it does, the app could show it from the pushes it already gets, with no extra command; what a voltage means as a percent is still to be worked out.

### 2.6 Battery

The app shows the last `GCS` reading (`Battery <n>%`, warning tone at 15 % or less while not charging). Possible additions: a notification when the battery runs low while logging, and the SDS150's undocumented `CST=8` (seen at 100 % on USB power) given a name once its meaning is known.

### 2.7 A raw capture option for fixtures

Test fixtures come from sanitized hardware captures. Plan 8 skipped a trunked `GSI` fixture because no command prints the raw document. A `--raw` option for `status`, `display` and `menu` (read-only, output to a git-ignored file, sanitized by hand before anything is committed) would make captures routine. The owner was to be asked before it is added.

## 3. Enhancements to what exists

- **Fast scans.** The SDS150 subscribes at 100 ms and its screen is read at each step (design §13 AC). On a mostly digital scan the reported channel lasted about 300 ms, so 100 ms missed nothing; a fast analog scan was not measured. `PSI` can't go faster than about 41 ms. If a fast analog scan shows channels between pushes, the rate could follow the scan (faster while scanning, slower when stopped) rather than being fixed.
- **Volume and squelch in a menu.** In the Mac-style view the sliders show `–` while the scanner is in a menu (owner's screenshot, 2026-11-13), probably because the menu's pushes carry no `Property` levels. Keeping the last known levels, marked as such, would read better. Check the menu push's shape first (`noctule status --serial` in a menu).
- **Items `MSI` leaves out** (Manage Full Database's Review Avoids on the SDS150; Analyze and others on the SDS200). The owner ruled on 2026-11-13 that these stay as they are: the Mac-style list shows what `MSI` offers, with the hint, and the Scanner view reaches the rest. The options considered, in case it is revisited: naming the missing items in the hint by comparing `STS` rows with the `MSI` indexes; showing them greyed with a switch to the Scanner view; testing whether `MSV` accepts an omitted index (one state-changing command, the owner's go-ahead).
- **Hits gated by `Mute` as well as `Sig`.** Hit detection reads `Sig` only; `Mute` is shown beside it (Plan 7's deferred question).
- **"Not logging" while waiting for the scanner.** The status bar says `Not logging` during `.waitingForScanner`; accurate, but it can read as "switched off". A wording like `Waiting to log` is an option.
- **One scanner, two spellings of its port.** A USB station's identity is its saved port string, so a link and its target (or `tty` and `cu`) are not seen as one scanner; the port's exclusive open still refuses the second session (design §13 AA). Resolving the path would make the app's own message clearer.

## 4. Open questions on hardware

- **A sleep longer than 183 s with a subscription open** (check 16, design §13 P): does a late `KAL` start the pushes again, or only a new `PSI`? Skipped by the owner; the resubscribe rule recovers either way.
- **A terminal program holding the port** (check 12): does it end up sharing the port with Noctule? Skipped by the owner.
- **What resets the 183 s push lifetime** besides `KAL` at 60 s: other commands, other intervals.
- **A long run at 100 ms:** the app ran about 18 minutes and ten more in a menu at 100 ms with `STS` at each step; an hour or more of `log` at that rate hasn't been run.
- **Trunked hit logging over a long run, and an unprogrammed channel or talkgroup** on the SDS150.
- **`GCS` state codes** outside Uniden's 0–6.

## 5. Cleanups carried from Plan 8's reviews

From the Plan 8 ledger (`.superpowers/sdd/2026-11-12-plan-8-sds150-app/progress.md`, git-ignored), not re-checked since; none blocks anything.

- `StationSession.swift` is over 1,100 lines; splitting control, restart and sleep into extensions would help.
- Test timing: a few tests sleep in real time with small margins (`StationRunnerUSBTests`' idle-channel test, `twoMissedReadsClearTheReading` at about 7 s (three 2 s `GCS` timeouts), `displayLoopEndsAtAnUnplug`'s fixed 3.2 s).
- `USBDetection`'s tests live in `NoctuleCLICoreTests` (`SerialCLITests`, `KeepAliveCLITests`) though `USBDetection` moved to `NoctuleStore`.
- `deviceSettingsChanged`'s same-port case is untested (covered by the shared replace path).
- The station editor reads device settings for network stations too, and a failed read disables Save for them (rare).
- A stop while a keep-alive waits writes `PSI,0` only after every queued request is answered or times out; the app's 15 s quit budget allows for it, but a silent scanner makes the quit slower.
- `"Couldn't start the station: <error>"` shows the error's `String(describing:)`, which can read like an identifier.
