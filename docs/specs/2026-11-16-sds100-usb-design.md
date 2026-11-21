# The SDS100 over USB — design

Date: 2026-11-16. Status: approved by the owner in chat, 2026-11-16, after a builder check. **Built** on `feature/sds100-usb`
(Plan 17, `2026-11-16-plan-17-sds100-usb.md`) against the mock, not yet merged; §10 says what was built and how it differs
from §5. The hardware session (§7) has not run. The checks in §3 ran on throwaway edits that were reverted and never committed.

Labels: **(the owner's call)** is a decision the owner made in the brainstorm on 2026-11-16;
**(designer's call)** is a default the designer chose that the owner hasn't ruled on and can
overturn. **[hw]** is a fact seen on the owner's SDS100 (firmware 1.26.01) on 2026-11-16;
**[spec]** is Uniden's *SDS Series Remote Command Specification* V2.00; **[assumed]** is something
neither has shown. Everything not labeled is fact about the code or a pointer.

## 1. Why

The owner has an SDS100, the first-generation SDS handheld, on its latest firmware, attached to the
Mac by USB beside the SDS150. Noctule Scan supports the SDS200 over the network and the SDS150 over
USB serial. The owner wants the SDS100 supported too, and proposed finding out first whether the
SDS150's protocol stack and UI handling carry over. **(the owner's call)**

They do, with one difference (§3): the SDS100 stops sending status pushes after about three
minutes, as the SDS150 does, but the SDS150's remedy (`KAL`) is a command the SDS100 doesn't know.
Sending the subscription again keeps it pushing. This design makes the SDS100 a third supported
model on the shared stack.

## 2. Goals, non-goals, anti-goals

**Goals.**

1. An SDS100 on USB works as a station the way the SDS150 does: the command line (`info`, `status`,
   `display`, `menu`, `watch`, `log`, `hits`) and the Mac app (both views, keys, volume and
   squelch, menus, hit detection and the hit log), with no audio. **(the owner's call)**
2. One connection stack for both handhelds. What differs between them is per-model data.
   **(the owner's call: "ideally the same connection stack for the SDS150 can be reused")**
3. Each handheld keeps the keep-alive proven on it: the SDS150 stays on `KAL`, the SDS100 sends its
   `PSI` again. **(the owner's call: approach 1 of §4)**
4. Stations find their port as they do today: a saved port, or the only Uniden port found. With
   both handhelds plugged in the owner picks a port per station in the editor. **(the owner's
   call; the owner added the SDS100 station that way on 2026-11-16 and found the Port picker made
   it easy)**
5. The SDS100 subscribes at 100 ms and its screen is read at most once per 100 ms while it
   changes, like the SDS150 and the SDS200. **(the owner asked for 100 ms to be tried; it ran in
   the app for about five minutes, §3; adopting it is the designer's call)**
6. Built against the mock first: the mock gains an SDS100 personality from the facts in §3.
7. The agent rules cover two real handhelds on USB (§5.7).

**Non-goals.**

- Audio from the SDS100 (no audio over USB, as for the SDS150).
- A battery reading. `GCS`, the SDS150's source for it, gives none on the SDS100 (§3.5), so the
  SDS100's profile stays without it. [spec] and the `sds200` library say the SDS100 reports a
  `Battery` attribute in `GSI` (0.0–3.3); whether the owner's unit does is a hardware check
  (§7 H1), and showing it is backlog. **(designer's call)**
- A station that knows which radio it is: a model remembered per station so that Automatic looks
  only at ports of that model, or a serial number. Backlog (§8). **(the owner's call: keep port
  selection as it is for this plan)**
- An SDS100 drawing of the front panel. The Scanner view keeps the SDS200's panel for every model.
- The BCD436HP, the SDS200 over USB, Bluetooth, iPhone and iPad.
- Any change to how the SDS150 or the SDS200 behaves. The SDS150's keep-alive stays `KAL` every
  60 s, byte for byte.

**Anti-goals** (failure even if the code is right).

- `KAL` sent to an SDS100. It answers `ERR` **[hw]**; nothing may send it there.
- `MSM,1`, `POF` or any guessed command (an `ESN` query, for one) sent to the SDS100.
- `GCS` sent to an SDS100 by the product. The owner allows agents to test `GCS` on the SDS100
  without asking **(the owner's call, 2026-11-16)**, but it gives no reading there (§3.5), so no
  command, session or loop sends it to that model.
- A test, tool or agent that opens the wrong handheld. With two on USB, "the only Uniden port" no
  longer exists; every hardware run names its port or its model, and `MDL` must name the model
  expected before anything else is sent.
- Real system, site or channel names, frequencies or IDs from the SDS100 in tracked files. The
  probe output of 2026-11-16 was real traffic and stays out of the repo.
- Loosening tests to make them pass. A test that pinned "the SDS100 has no keep-alive, 500 ms,
  1 s" pins the new values; a test that needs "a model without a keep-alive" or "a model at the
  old rate" moves to the BCD436HP, not to a wider assertion.

## 3. What the check found (2026-11-16)

All on the owner's SDS100, firmware 1.26.01, at the owner's go-ahead for each step. Every run
named the SDS100's port explicitly, confirmed against the USB registry by product name just
before, with `NOCTULE_NO_USB_DETECTION=1` set; the SDS150 beside it was never opened.

### 3.1 The USB device **[hw]** (registry reads only)

- Product name `SDS100 Serial Port`, vendor `UNIDEN AMERICA CORP.`, vendor ID 0x1965, **product ID
  0x001A: the same as the SDS150's**. Device release 0x0100 (the SDS150's is 0x0200).
- It reports **no USB serial number**, so macOS names its port from the USB location
  (`/dev/cu.usbmodem<location>1`): the path changes when the cable moves to another socket or hub.
  The SDS150's path comes from its placeholder serial number and stays put.

### 3.2 Read-only commands **[hw]**

`noctule info`, `status`, `display` and `menu` with `--serial <path>`, existing code unchanged:

| Command | Result |
|---|---|
| `MDL` | `SDS100` |
| `VER` | `1.26.01` |
| `VOL`, `SQL` | plain numbers, parsed |
| `GSI` | parsed; during a trunked ID search: system, site, frequency and modulation, no department or channel, `Sig` 0 |
| `STS` | decoded: 13 screen lines and three soft keys on the owner's screen (the count depends on the user's screen; nothing may assume 13). Icon glyphs are low control bytes: 0x06, 0x07, 0x1A and 0x1B were seen (the SDS150 mock uses 0x80, 0x81, 0x8D) |
| `MSI` outside a menu | the `TypeError` screen, as on the other models |

Not seen: the raw bytes of any reply (so the XML line form is known only as "the serial reader
parsed it"), whether each `STS` line's text and mask have the same width, and whether `GSI`
carries a `Battery` attribute.

### 3.3 Pushes and the keep-alive **[hw]**

| Run | Sent | Pushes | Median gap | Last push after `PSI` | Result |
|---|---|---|---|---|---|
| `watch`, 500 ms | `PSI,500` | 339 | 537 ms | 182.1 s | pushes stopped; port still open |
| `watch`, 100 ms | `PSI,100` | 1,354 | 137 ms | 186.1 s | pushes stopped |
| `watch`, 100 ms, `KAL` every 60 s | `PSI,100`, 3 `KAL` | 1,355 | 136 ms | 185.0 s | pushes stopped |
| keep-alive check, `KAL` every 60 s | `PSI,1000`, 3 `KAL` | 176 | about 1 s | 181.6 s | pushes stopped; **each `KAL` answered `ERR`** |
| keep-alive check, `PSI` again every 60 s | `PSI,1000` four times | 232 | about 1 s | 239.8 s of a 240 s hold | **passed**; longest gap 1.1 s; each `PSI` answered `PSI,OK`; nothing else came back; no push after `PSI,0` |

- **The SDS100 stops pushing about 182–186 s after the `PSI`**, port still open (`watch` reported
  a stall, not a closed port, and every later run opened the port and got `MDL` at once). The same
  lifetime as the SDS150's 183 s.
- **`KAL` does nothing on the SDS100**: firmware 1.26.01 answers it `ERR`, the answer to an
  unknown command. [spec] lists `KAL` for the series; it was added to the spec in 2025.
- **The same `PSI` sent again every 60 s, on the open port, with no `PSI,0` between, kept the
  pushes going** through a 240 s hold, with no visible hiccup at a re-send.
- **At `PSI,100` the SDS100 pushes about every 137 ms** (the SDS150: 116 ms), longest gap 161 ms.
- The last two rows used the SDS150's keep-alive check (`SDS150HardwareChecks.keepAlive`) with its
  model guard relaxed, because `watch` shows neither what was written nor any line that isn't a
  push: the owner asked for the method to be confirmed before `KAL` was ruled out.

### 3.4 The app **[hw]** (the owner's run)

A throwaway build with the SDS100 at `PSI,100`, `PSI,100` again every 60 s, and `STS` at 100 ms.
The owner added a USB station with the editor's Port picker and ran it for about five minutes:
the screen was good, the controls worked, hit tracking worked. The app's warning log held nothing
from the SDS100 station (no stall, no `subscribing again`).

Not checked in the app: menus, an unplug and replug, a run longer than five minutes, both
handhelds connected at once.

### 3.5 `GCS` **[hw]**

The owner asked what `GCS` does (Get Charge Status: read-only, the SDS150's battery reading) and
allowed agents to test it on the SDS100 without asking. One `GCS` was sent, through `noctule info`
on a throwaway edit that gave the SDS100's profile `supportsChargeStatus`: `info` printed
`warning: no battery status (no answer to GCS)` and the four other reads answered as before. So
**`GCS` gives no battery reading on the SDS100** (fw 1.26.01). `info` can't tell an `ERR` from
silence: it waits for a line that starts `GCS`. An `ERR`, as `KAL` got, is likely but was not
seen.

## 4. Approaches

1. **One stack; each handheld keeps its own keep-alive. Chosen (the owner's call).** The SDS100 is
   a third `ModelProfile`. `PushKeepAlive` grows from "a command with no reply" to also allow
   "send the subscription again". The SDS150 stays on `KAL` (proven for an hour), the SDS100
   renews its `PSI` (proven for four minutes and a five-minute app run). Cost: the keep-alive
   code handles two kinds.
2. **One stack; one keep-alive for both handhelds.** Both renew `PSI`, and `KAL` is retired.
   Simpler code, but it throws away the SDS150's proof and needs a new SDS150 hardware session;
   whether a repeated `PSI` restarts the SDS150's timer has never been tried.
3. **A separate stack for the SDS100.** The check found one difference, so a second stack would
   hold nothing. The owner raised it in case the models differed enough; they don't.

Also considered and dropped: no keep-alive for the SDS100, leaving the existing replace-a-dead-
subscription rule (Plan 8 D6) to recover. That works but leaves up to a minute of silence every
three minutes.

## 5. Design

### 5.1 The SDS100's profile

`ModelProfile.profile(for: .sds100)` becomes:

| Field | Value | Source |
|---|---|---|
| `volumeRange`, `squelchRange` | 0–15 | [spec]; unchanged |
| `transports` | USB serial | unchanged |
| `hasNetworkAudio`, `supportsRemoteRestart`, `supportsChargeStatus` | false | unchanged; `GCS` gave no reading **[hw]** (§3.5) |
| `usbProductIDs` | 0x001A | **[hw]** (shared with the SDS150; §5.3) |
| `pushKeepAlive` | renew the subscription every 60 s (§5.2) | **[hw]**, the only interval tried |
| `pushInterval` | 100 ms | **[hw]**; goal 5 |
| `displayRefreshInterval` | 100 ms | **[hw]** in the owner's app run; goal 5 |
| `protocolVerifiedOnHardware` | **false** until the owner rules after §7 | **(designer's call)**: it is `true` today on the Python library's word, never ours; nothing in `Sources` reads the flag |

After this the BCD436HP (and a name that is no known model) is the only thing left at 500 ms
pushes, 1 s screen reads and no keep-alive.

### 5.2 The keep-alive: renewing the subscription

"Renew" here means writing the subscription's own `PSI,<ms>` again on the open port. It is not
the Plan 8 D6 rule, which this document calls "replacing" a subscription (`PSI,0`, the port
closed and reopened, a fresh `PSI`), and which stays as it is.

- `PushKeepAlive` says what is written each interval: a named command with no arguments and no
  reply awaited (`KAL`, as today), or the renewal. The names are the builder's.
- For a renewal `ScannerClient` writes exactly the `PSI,<ms>` that subscription was started with,
  so `watch --interval 500` on an SDS100 renews with `PSI,500` and the app with `PSI,100`. No
  profile holds a second copy of the interval.
- Every existing keep-alive rule holds for a renewal unchanged (`ScannerClient`'s type comment):
  the first no sooner than one interval after the `PSI`; two never closer than an interval; each
  write takes the request slot and is never written while a reply is pending; every end of the
  push cancels it; none is written after that push's `PSI,0` or after `disconnect()`; a write that
  throws ends that push's keep-alive and is reported once (`onKeepAliveFailure`,
  `StationRunner.keepAliveFailedMessage`), never retried.
- The client writes the first `PSI` without waiting for its reply, and a renewal the same way.
  `PSI,OK` to a renewal is absorbed as the first one's is.
- **A rejected renewal is not a rejected first `PSI`. (designer's call, after the builder check)**
  A first `PSI` that is rejected ends the push with no `PSI,0`, rightly: no subscription exists.
  When a renewal is rejected, the earlier subscription is still running, so ending the push that
  way would leave it live on the radio. Instead a rejection that arrives once a renewal's write has
  begun (not only once it has been written: part of it may already be with the scanner) is treated as a failed keep-alive write is today: the push stays, that push's renewals
  stop, and the failure is reported once (`onKeepAliveFailure`, so `log` and the app show the
  existing keep-alive warning, with an error that reads as "the scanner refused `PSI`"; `watch`
  shows only the eventual stall, as it does for a failed `KAL` write). Every stop still writes
  `PSI,0`, since the push is still the active one. If the pushes then stop at the end of their
  lifetime, the existing D6 rule replaces the subscription, once per connection, with its own
  `PSI,0`. A scanner that kept rejecting renewals would therefore run with a warning and a gap of
  about a minute roughly every four, the same as an SDS150 whose `KAL` writes fail today; that is
  accepted. No hardware has ever rejected a `PSI`.
- `PushKeepAlive.forSubscription(reportedModel:overSerial:interval:)` keeps its rules: only over a
  serial link, only for a model that has a keep-alive, an override only changes the interval. So
  `NOCTULE_TEST_KEEPALIVE_SECONDS` now also shortens the SDS100's 60 s (still test-only, still
  needing the kill-switch).
- Because the SDS100 now has a keep-alive, Plan 8 D6 applies to it with no code change: a
  connection that has delivered a push and then goes max(keep-alive interval, 3 s) without one,
  port still there, is replaced once (`warning: the scanner stopped sending status updates;
  subscribing again`). That is the recovery if a renewal ever fails to restart the timer, or after
  a pause longer than the push lifetime.
- Who sends it: `watch --serial`, `noctule log` on a USB station, and the app's USB sessions, all
  through the paths that send `KAL` to an SDS150 today (`KeepAliveOverride.forWatch`,
  `StationRunner`). Nothing sends a renewal over the network, or to a model whose profile doesn't
  ask for it.

### 5.3 Telling the handhelds apart

- `SerialPortInfo.knownModel` reads the USB product name first: its first word through
  `ScannerModel(reported:)` (`SDS100 Serial Port` → SDS100, `SDS150 Serial Port` → SDS150). Only
  when the name gives no model does it fall back to the product ID, and then only if exactly one
  model's `usbProductIDs` holds it; otherwise nil (`unknown model`). **(designer's call)** So
  `noctule ports` labels each handheld correctly.
- The decoy ports of `NOCTULE_TEST_SERIAL_PORTS` keep reading as SDS150s (give them the SDS150's
  product name).
- **Nothing else about ports changes** (goal 4): a station's saved port is still its identity, a
  station with none still takes the only Uniden port found, and several found is still the
  several-ports hint. The station editor is unchanged; its Port picker already shows each port's
  product name.
- What this means in use, to be written into `AGENTS.md` (the repository has no user-facing
  README, and this design adds none): with both handhelds plugged in, every USB station needs a saved port; an Automatic
  USB station conflicts with every other USB station in the app (SDS150 design §13 AA), so the
  owner's `sds150` station needs its port saved before both can run at once; and the SDS100's
  saved port must be picked again if its cable moves to another socket.

### 5.4 The mock

A third personality, `MockPersonality.sds100`, and `noctule-mock-scanner --model sds100 --serial`
(like the SDS150 it has no network port, so it needs `--serial`; `MockSerialScanner(personality:
.sds100)` in tests).

| Behaviour | Value | Source |
|---|---|---|
| `MDL` | `MDL,SDS100` | **[hw]** |
| `VER` | `VER,Version 1.26.01` | **[hw]** (`info` printed `1.26.01`; the `Version ` prefix is the SDS150's form and [spec]'s) |
| `VOL`, `SQL` | 0–15; out of range `NG`, nothing changed | range [spec]; the `NG` **[assumed]**, the other mocks' rule |
| XML documents | the SDS150's serial form: `\r`-separated lines, no `<Footer>` | **[assumed]**: the serial reader parsed the real replies, the raw bytes weren't looked at |
| `KAL` | `ERR`, and it restarts nothing | **[hw]** |
| Push lifetime | pushes stop 183 s after the latest `PSI` from that client; a `PSI` while subscribed restarts the count and adds no second subscription | stop at 182–186 s and renewal at 60 s **[hw]**; that every `PSI` restarts the full count, and that a `PSI` after the pushes stopped starts them again, **[assumed]** |
| `--push-lifetime S` | accepted with `--model sds100` too | |
| `--kal-after-expiry` | stays `--model sds150` only | |
| `GCS` | `ERR` | no usable answer **[hw]** (§3.5); that the line sent back is `ERR`, as for `KAL`, is **[assumed]** |
| `MSM,1` | `MSM,NG`, nothing else happens | **[assumed]**, never sent; the SDS150 mock's rule |
| Idle between transmissions | the trunk idle form (`IdleForm.trunkSite`) | **[hw]**: one `GSI` during a trunked ID search had that shape |
| `STS` icon glyphs | 0x06, 0x07, 0x1A, 0x1B in place of the SDS150's three bytes, one byte per column | bytes **[hw]**; one column each **[assumed]** (§7 H1 measures) |
| Menus, scenarios, faults, unplug and replug, conventional and trunk transmissions | the SDS150 mock's | **[assumed]** |

The type comments of `MockPersonality` and `MockSerialScanner` list these assumptions the way they
list the SDS150's. Following LESSONS.md 2026-11-12, each assumption a product path leans on gets
its pessimistic twin tested: the one that matters is "a `PSI` after the pushes stopped starts them
again", which the replace rule (D6) doesn't depend on, since it sends a fresh `PSI` on a reopened
port; a test shows the SDS100 recovering that way when renewals are dropped
(`--fault drop-request=PSI`-style, or a lifetime shorter than the renewal interval).

### 5.5 What the user sees

- **Command line.** `noctule ports` shows `SDS100` in the model column. `info --serial` on an
  SDS100 prints model, firmware, volume and squelch and no battery line (no `GCS` is sent).
  `watch --serial` and `log` on a USB station keep an SDS100's pushes going past three minutes.
  `log` prints what it prints for an SDS150 (`log: no audio over USB`, the disconnect, wait and
  reconnect lines).
- **The app.** An SDS100 station behaves as an SDS150 station does, minus the battery: no audio
  controls, `No audio over USB`, knobs and sliders 0–15, the waiting banner while unplugged, the
  resume, the menus. No new UI.
- **Messages.** No new text. The keep-alive failure warning and the D6 warning are reused as they
  are.

### 5.6 Hardware checks in the test suite

- The checks in `SDS150HardwareChecks` (read-only, quiet port, push, keep-alive) take the model
  they expect and the keep-alive to use; `MDL` must name that model, else nothing more is sent.
  Whether the file and types are renamed is the builder's call.
- New opt-in suites for the SDS100, shaped like the SDS150's and skipped while
  `NOCTULE_NO_USB_DETECTION` is set: `NOCTULE_SDS100_HARDWARE_TESTS=1` (read-only and quiet port),
  plus `NOCTULE_SDS100_PUSH_TEST=1`, plus `NOCTULE_SDS100_KEEPALIVE_TEST=1`. The SDS100 keep-alive
  check is today's with the renewal in place of `KAL`: `MDL`, `PSI,1000`, the same `PSI` again
  every 60 s, held 240 s, `PSI,0`, the 1.5 s quiet hold; it reports how many `PSI`s were written
  and every line that comes back that is neither a push nor `PSI,OK`. A second keep-alive check,
  `NOCTULE_SDS100_KEEPALIVE_100MS_TEST=1` (with the read-only variable; added after the final
  review), runs the same at the product's rate, `PSI,100` renewed as `PSI,100`, and fails on
  anything in that list (§7 H4).
- The SDS100 read-only suite also prints whether `GSI`'s `Property` has a `Battery` attribute
  (present or absent, and its value, which is not radio traffic), and the `STS` line count and
  widths as the SDS150's does, never the text.
- **Which port a hardware suite opens (designer's call):** `SCANNER_SERIAL_SDS100` (for the SDS150
  suites, `SCANNER_SERIAL`, as today) from `config/dev-scanner.env`, used exactly as written;
  else the one Uniden port whose USB product name names that model; none or several fails with
  what to do. Today the SDS150 suites take "the one Uniden port found", which with two handhelds
  plugged in finds two and fails; this lets both suites run with both attached. It changes test
  resolution only, never how `noctule` or the app find a port. `config/dev-scanner.env.example`
  gains the new key.
- Every check also runs against `MockSerialScanner` in each `swift test`, as the SDS150's do,
  pinning exactly what each sends.

### 5.7 Documents and agent rules

- **`AGENTS.md`**: a section "The owner's SDS100" beside the SDS150's, and the lines that say the
  only Uniden port on this Mac is the SDS150 corrected to two handhelds. The SDS100's
  hardware rules are standing rules, approved with this design on 2026-11-16:
  - It is real hardware; each run against it, and each app launch against it, is the owner's call.
  - Agents keep `NOCTULE_NO_USB_DETECTION=1` and `--settings-dir`, pass `--serial` only the mock's
    path, and in a hardware run the owner asked for pass the SDS100's explicit path, checked
    against the registry by product name just before each run.
  - Read-only by default: `MDL`, `VER`, `VOL`/`SQL` with no argument, `GSI`, `STS`, `MSI`. `PSI`,
    its renewal and `PSI,0` belong to a run the owner asked for; always end with `PSI,0`.
  - Never `KAL` (it answers `ERR`), never `MSM,1`, never `POF`, never a guessed command.
    `noctule restart` already refuses `--serial`.
  - `GCS` is read-only and the owner allows agents to test it on the SDS100 without asking
    (2026-11-16). It gave no reading on fw 1.26.01, so the product never sends it there; a test of
    it is one `GCS`, never a loop.
  - `KEY`, `MSV` and a `VOL` or `SQL` value need the owner's go-ahead each time; one action sends
    at most one state-changing command and never resends it.
  - The mock's SDS100 mode and its assumptions, in the mock section.
- **Protocol notes** (`2026-11-08-sds-remote-protocol.md`): the SDS100's rows marked [hw] with
  §3's facts (USB identity, `KAL` → `ERR`, the push lifetime, the renewal).
- **SDS150 backlog** (`2026-11-13-sds150-future-features-and-enhancements.md` §2.5): the SDS100
  taken off the "not supported" list; the backlog items of §8 added.
- **`LESSONS.md`**: the 2026-11-16 entries are written with this design.
- No new README. `packaging/README.md` and `docs/uniden/README.md` change only if they name the
  supported models.

## 6. Tests

Written first, against the mock, per task (the project's developer and QA workflow). What must
be covered, at least:

- `ModelProfile`: the SDS100's new values; the BCD436HP still at 500 ms, 1 s and no keep-alive.
  The existing tests that use the SDS100 as "the model without a keep-alive" or "the model at the
  old rate" (`ModelProfileTests`, `DisplayRefreshPolicyTests`, `KeepAliveCLITests`,
  `StationRunnerUSBTests`, `SerialIntegrationTests`) move to the BCD436HP or an unknown name.
- `ScannerClient`: a renewal writes the subscription's own `PSI,<ms>`; every timing and ordering
  rule the `KAL` tests pin, pinned for the renewal too (none after `PSI,0`, never while a reply is
  pending, a failed write reported once and not retried); `PSI,OK` to a renewal reaches no caller;
  a rejected renewal (`MockFaults.rejectNext`) keeps the push, stops the renewals, is reported
  once, and the stop that follows still writes `PSI,0`; a rejected first `PSI` behaves as today.
- `SerialPortInfo.knownModel`: by name, by a unique product ID, nil for a shared ID with no name.
- The mock: `MockPersonalityTests` pins the SDS100's bytes; `KAL` answers `ERR` and restarts
  nothing; a `PSI` while subscribed restarts the lifetime and leaves one subscription; the
  argument parser's `--model sds100` rules.
- `StationRunner` and `StationSession` on an SDS100 mock: pushes past the lifetime with renewals
  and no `KAL`, `GCS`, `MSM` or `POF`; the D6 replacement when renewals don't help; a rejected
  renewal (the warning once, then the D6 replacement, never a reopen loop faster than that, and
  no subscription left at the end); `watch` after a rejected renewal exits with `PSI,0` written;
  unplug and replug; `PSI,0` last; no subscription left.
- `SerialIntegrationTests` and `AppLifecycleIntegrationTests`: `ports`, `info`, `watch` and `log`
  past the push lifetime against `noctule-mock-scanner --model sds100 --serial`, and one app
  launch on it, with the same end-of-run checks the SDS150 tests make.
- The SDS150's and SDS200's tests pass unchanged. The mock's log for an SDS150 run still shows
  `KAL` and no repeated `PSI`.
- `RealNamesTests` passes; the iOS build of `NoctuleAppCore` still builds.

## 7. Hardware session (the owner's, after the build)

Each item at the owner's go-ahead. Results go into this document, the protocol notes and
`LESSONS.md`.

- **H1** The SDS100 read-only suite: `STS` line widths (text against mask), and whether `GSI` has
  `Battery`.
- **H2** The quiet-port check before and after the others.
- **H3** The push suite (`PSI,500`, 20 `GSI`s while pushes arrive).
- **H4** The SDS100 keep-alive suite (renewal, 240 s), twice: at `PSI,1000`
  (`NOCTULE_SDS100_KEEPALIVE_TEST=1`, `…/KeepAlive`) and at the product's `PSI,100`
  (`NOCTULE_SDS100_KEEPALIVE_100MS_TEST=1`, `…/KeepAliveAtTheProductRate`). `log` and the app
  subscribe and renew at 100 ms, with pushes about 137 ms apart, so a renewal's `PSI,OK` can land
  beside a push document, and a reply cut into a push would be lost in `SerialResponseAssembler`;
  only the check's `unexpected` list would show it, which the 100 ms run fails on (a push that
  didn't parse, a stray line). Pass: pushes to the end of the hold, `unexpected` empty.
- **H5** An hour of `noctule log` on an SDS100 station: no stall, no `subscribing again`.
- **H6** The app for half an hour or more: both views, a key, a `VOL` and an `SQL` step, a menu
  in both views (`KEY,M,P`, `MSI` inside a menu; an `MSV` only if the owner wants one), an unplug
  and replug with the window open, quit. Each view stays in a menu for at least 3 minutes (three
  or more renewals, past the 183 s lifetime): the radio stays on the same menu screen, `MSI` keeps
  answering (the Mac-style menu never says the scanner isn't answering), and no
  `refused PSI` or `subscribing again` warning appears (the stderr warning log).
- **H7** Both handhelds at once: two stations, each with a saved port, both windows open.
- **H8** A conventional hit and a trunked hit in the hit log, with the fields a hit should have.

Not planned, as for the SDS150: a sleep longer than the push lifetime, and a terminal program
sharing the port. After the session the owner rules whether the SDS100 is verified, and
`protocolVerifiedOnHardware` follows.

## 8. Known limits and backlog

- **Two radios of the same model can't be told apart.** The SDS100 reports no USB serial number,
  the SDS150's is a placeholder, and [spec] has no command that returns a serial number or ESN.
  A station's saved port therefore means "the radio in that socket": two same-model radios that
  swap sockets swap stations silently, hit logs included. The owner asked whether a serial number
  should be tied to the station; there is none to tie. Backlog: "a station knows which radio it
  is" (a model remembered per station so Automatic narrows to that model's ports; a serial number
  if a documented source ever appears; an undocumented `ESN` query would need the owner's
  approval and is not proposed).
- **The SDS100's saved port follows the socket** (§3.1).
- **No battery reading** for the SDS100: `GCS` gives none (§3.5); H1 says whether `GSI` offers
  one.
- **The renewal has run for four minutes and for five**, at 60 s only. H5 is the long run.
- **Menus on the SDS100 are unchecked** until H6; the destructive-item list is the shared one.
- The Scanner view draws the SDS200's panel around the SDS100's screen.

## 9. Left to the builder

Type and case names for the keep-alive kinds; whether `SDS150HardwareTests.swift` is split or
renamed; where exactly the mock places the SDS100's glyph bytes; the wording of comments and of
the `AGENTS.md` section within the rules above; task order, provided the mock personality and the
keep-alive land before anything that depends on them.

## 10. What was built (Plan 17, 2026-11-16)

On `feature/sds100-usb`, test first against the mock, each task with a developer and a QA pass
(mutation runs). Nothing here has run on the SDS100 yet; §7 is the owner's session.

- **The keep-alive kinds** (`ScannerModel.swift`): `PushKeepAlive.Action` is `.command(String)`
  (the SDS150's `KAL`) or `.renewSubscription`; `PushRenewalRefused` (described as "the scanner
  refused PSI") is what `onKeepAliveFailure` gets for a refused renewal. `ScannerClient` writes a
  renewal as the push's own `PSI,<ms>`, through the keep-alive loop and the request slot, under
  every rule of §5.2. A push's keep-alive failures, a failed write and a refused renewal alike,
  are reported once in all (`KeepAliveFailureReport`).
- **When a rejection is the renewal's** (§5.2, wording aligned to the code): from the moment a
  renewal's write has *begun* (`writeKeepAlive` marks it before the transport's `send`), not
  once it has been written, since part of it may already be with the scanner. A `PSI,NG` before
  that ends the push with no `PSI,0`, as before; after it, the push stays, its renewals end, and
  the refusal is reported once. A `KAL` push still ends on any `PSI,NG`.
- **A newer push waits for an older renewal on its way** (a fix found in the Task 1 review):
  `startPush` ends the older push and then waits for any of its renewals already being written
  (past the slot's checks) before writing the newer `PSI`, so the scanner never ends on the
  older rate. A renewal still waiting for the slot writes nothing once it gets it, and a `KAL`
  holds nothing up, so the SDS150's ordering is unchanged. A `disconnect()` while such a push
  waits (a fix found in the final review) still writes `PSI,0` after that renewal and before the
  close, since the older subscription still runs on the scanner; the waiting push then throws
  `notConnected` and writes nothing (`ScannerClient.startsAwaitingRenewals`).
- **Accepted, designer's call: a late `PSI,NG` can end a newer push.** The protocol has no
  request IDs, so a rejection is matched to a push only by timing. If a `PSI,NG` meant for an
  old push's renewal arrived after a newer push had started (and before any renewal of the newer
  one had begun), it would be taken as the newer push's first `PSI` being refused and would end
  that push with no `PSI,0`. No product path starts a second push on a client while renewals
  run (`watch`, `log` and the app each run one push per connection; the D6 replacement closes the
  port first), and no hardware has ever rejected a `PSI`, so this is accepted rather than guarded.
- **The profile** (§5.1): the SDS100 renews every 60 s, `pushInterval` and
  `displayRefreshInterval` 100 ms, levels 0–15, `usbProductIDs` [0x001A],
  `protocolVerifiedOnHardware` false. Tests that used the SDS100 as "no keep-alive" or "the old
  rate" moved to the BCD436HP.
- **Ports** (§5.3): `SerialPortInfo.knownModel` reads the product name first, then a product ID
  only one model holds; an unnamed 0x001A port is now `unknown model`. The decoys of
  `NOCTULE_TEST_SERIAL_PORTS` are named `SDS150 Serial Port`.
- **The mock** (§5.4): `MockPersonality.sds100` and `noctule-mock-scanner --model sds100
  --serial`, with `--push-lifetime`; `--kal-after-expiry` is refused for it. As designed.
- **Hardware checks** (§5.6, builder's call on the names): the checks moved from
  `SDS150HardwareChecks` to `HandheldHardwareChecks` (`Tests/NoctuleKitTests/
  HandheldHardwareChecks.swift`), each taking the model it expects; `SDS100HardwareTests` with
  `SDS100HardwareGate` (`NOCTULE_SDS100_HARDWARE_TESTS`, `_PUSH_TEST`, `_KEEPALIVE_TEST`, and
  since the final review `_KEEPALIVE_100MS_TEST` for H4 at the product's rate, all skipped under
  the kill-switch). The suites open `SCANNER_SERIAL_SDS100` (the SDS150's:
  `SCANNER_SERIAL`) as written, else the one port whose product name names the model
  (`DevScannerConfig.serialPath(from:key:)`, `config/dev-scanner.env.example`). Beyond §5.6:
  the push check now sends `MDL` first and stops unless it names the expected model, for the
  SDS150 too; and with both gates set the two models' suites can run in one `swift test` at
  the same time, on their two ports.
- **Documents** (§5.7): `AGENTS.md` (the owner's SDS100, two handhelds on USB, the mock, the
  suites), the protocol notes (§1, §3, §4, §5, §8 item 11), the SDS150 backlog (§2.5, 2.5a,
  2.5b) and `LESSONS.md`.

### 10.1 By hand on the mock (2026-11-16)

The built app (`scripts/build-app.sh`, debug) on `noctule-mock-scanner --model sds100 --serial
--serial-link <tmp>/port --push-lifetime 20 --verbose`, one USB station saved on that link, with
`NOCTULE_SETTINGS_DIR` on a fresh temporary directory, `NOCTULE_NO_USB_DETECTION=1` and
`NOCTULE_TEST_KEEPALIVE_SECONDS=5`, launched twice (the station's `preferredView` set to `scanner`,
then `macStyle`, since the agent had no Accessibility grant to click the toolbar): about 75 s in
the Scanner view and about 3 min 15 s in the Mac-style view, each quit through AppleScript.

- **The mock's log:** per launch `MDL`, `VER`, `PSI,100`, then a `PSI,100` renewal every 5.00–5.19 s
  (mean 5.06 s; 15 renewals in the first run, 38 in the second), `STS` reads (81 in all), and
  `PSI,0` last at each quit. No `KAL`, `GCS`, `MSM`, `POF`, `KEY`, `MSV`, `VOL` or `SQL` was
  received. The mock printed `active-subscriptions=0`.
- **The renewal kept the pushes going past the mock's 20 s lifetime** in both runs: the hit log
  (`noctule hits`) holds 39 transmissions from the scenario, spread over both runs to their ends,
  and no recordings were made (no audio over USB).
- **No warning:** the app's stderr (where every warning the Mac controls bar shows is also
  written, `SessionWarningLog`) held only its three `test override` lines in each run: no stall,
  no `subscribing again`, no keep-alive failure.
- **Not seen:** the window itself. Screen capture of the app's window (`screencapture -l <id>`)
  failed with `could not create image from window` (the agent's terminal has no Screen Recording
  grant), so "the screen keeps updating" and "no battery shown" rest on the mock's log (`STS` read
  through each run; no `GCS` sent) rather than a picture. The owner's look at both views is part
  of H6.
