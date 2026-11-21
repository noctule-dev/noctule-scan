# Line-in on the command line (Plan 19): short design

**Status:** approved by the owner on 2026-11-17. It builds phase 3 of
`docs/specs/2026-11-17-usb-line-in-audio-design.md` (§7 there is the authority; this note records
the decisions taken when Plan 19 was planned). Plan: `docs/specs/2026-11-17-plan-19-line-in-cli.md`.

**Built, 2026-11-17, on `feature/line-in-cli`, against the mocks** (`noctule-mock-scanner --serial
--line-out` through `NOCTULE_TEST_LINE_IN`, `FakeLineInSource`, `FixedAudioInputListing`); the
owner's hand check on the rig (`noctule listen --station <station> --meter`, then `noctule log`) is
pending, and agents never run either against the real input. The build's rulings, all **the
controller's calls, not the owner's** (the owner's are this design, §7 of the parent design, and
`station edit` deferred), are in the parent design's §12.4. In short: the meter's `|` sits after the
18th of 20 cells (-6 dBFS); `audio-inputs --host` exits 64 like every usage error; the `station add`
suffix goes inside the parentheses, names match ignoring case, and with no listing a value is saved
as an ID with a note; a denied permission or the kill-switch ends `listen` with `audio: failed: …`
(exit 1); `--port` and `--reconnect-cooldown` still override a network station's values under
`listen --station`; a line-in `listen` prints no packet counts.

## Intent

The command line gets what the app got in Plan 18 for a USB station whose scanner's headphone jack
is cabled into a Mac audio input: list inputs, give a new station an input, record and warn in
`log`, and play, record and meter a line-in station in `listen`. **(the owner's call, design §2
item 5.)** The owner tried Plan 18 on the rig before this plan: their ad-hoc hardware test looked
good (2026-11-17).

## Approaches

1. **The command-line shell over the Plan 18 core (chosen).** `log` already runs `StationRunner`,
   which captures, records and warns; the CLI passes it a line-in source factory, prints the new
   events and wording, and `listen --station` drives a `LineInSource` with the existing player and
   WAV writer. Everything hard (capture, conversion, clip and silence rules, the kill-switch) is
   reused, already reviewed.
2. A separate capture path for the CLI: rejected, it would duplicate the hardest part.

There was one sensible way; the owner approved it with this design.

## Decisions

- **`noctule audio-inputs`:** one line per input (`<UID>  <name>  <n> ch`), opening none (Core
  Audio properties only). Under `NOCTULE_NO_USB_DETECTION` it lists none, as `ports` does, and
  prints the same kind of empty message.
- **`station add --usb … --audio-input <name or UID> [--audio-channel left|right|both]`:** a UID
  is taken as given; a name must match exactly one present input (none or several: refused with a
  hint, exit 64). Saved as `audioInputDevice` (UID), `audioInputName`, `audioInputChannel` in the
  device settings, before the station. `--audio-*` on a network station is refused (exit 64).
  Under the kill-switch no input is present, so only a UID can be given (with its name taken as the
  UID). `station list` shows `line-in <name> (<channel>)`.
- **`noctule log` on a line-in station:** `StationRunner` gets the line-in factory chosen by
  `LineInDetection.selection(…, app: false)` (system, disabled under the kill-switch, or the
  `NOCTULE_TEST_LINE_IN` pipe). It prints `audio: line-in <name> (<channel>)` in place of
  `log: no audio over USB`, records WAVs under `--recordings`, end lines get `→ <file>`, clipped
  hits print `warning: the audio input clipped during "<channel>"; turn the scanner's volume down`,
  and the missing-input, silence, permission and kill-switch warnings print as `warning: …`. No
  cooldown wait or record, as for any USB station.
- **`noctule listen --station <name>`:** for a line-in station it opens only the audio input: no
  serial port, no station lock, no scanner traffic, no RTSP, no cooldown. It plays through the
  current output (the line-in prefill), records with `--record PATH`, honours `--seconds`,
  `--no-play` and today's exit codes (0, 1, 130, 143, 129). `--meter` draws a one-line text meter
  on stderr (`line-in ▇▇▇▇▇▇▇····|···· peak −9 dBFS`, a shape only: the built line is in the parent design's §12.4; `CLIP` latching 3 s): redrawn in place about
  10 times a second when stderr is a terminal, one line a second otherwise. For a network station
  `--station` supplies its address and reconnect wait and runs RTSP as today; a USB station without
  an input is refused (`listen: <name> has no audio input`). **(designer's call:** not opening the
  serial port or taking the lock means `log` can run beside `listen`, and `listen` sends nothing to
  the scanner.)
- **Test override:** `NOCTULE_TEST_LINE_IN` is honoured by `noctule` with the kill-switch set
  (design §8), with the stderr note `LineInDetection.overrideNotes` gives. Tests and agents run
  against `noctule-mock-scanner --serial --line-out`, never a real input.
- **Permission:** on the command line macOS asks for the terminal app that runs `noctule`; a
  denial prints the permission warning and `log` goes on without audio, `listen` exits 1.

## Non-goals

- **`station edit`** (changing an existing station's input, or anything else, from the CLI): a
  future enhancement, the owner's call. The app's editor does it today.
- Anything for network stations beyond `listen --station` picking an address.

## Left to the builder

The exact meter glyphs and widths, the help text, and how `listen`'s loop is shared between the
RTSP and line-in paths, within the repo's patterns (`NoctuleCLICore` pure and tested, `Sources/noctule`
only the I/O shell).
