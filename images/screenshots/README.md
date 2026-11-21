# Screenshots

Pictures of the Noctule Scan Mac app for the noctule.app website and other docs. Every one was
taken on `noctule-mock-scanner`, so the systems, talkgroups, frequencies and IDs on screen are the
mock's fictional ones (Riverbend County P25, Lakeview Fire, …); none is real radio traffic. The
station picker and Settings come from a showcase settings folder with made-up addresses
(192.0.2.10 is a documentation address; the `/dev/cu.usbmodem…` ports don't exist).

Each is one window, captured with `screencapture -l <window id>` (dark appearance, window shadow
kept, 1× display). Taken 2026-11-16 from the build of `main` after Plan 17.

| File | What it shows |
|---|---|
| `scanner-view-sds200.png` | Scanner view: the SDS200 front panel mirrored live (display, keypad, knobs) during a trunked transmission, with Listen and Logging on and Recent Hits beside it |
| `mac-style-view-sds200.png` | Mac-style view of the same SDS200: system › department breadcrumb, channel name, detail chips, the scanner's volume and squelch, "Active now" in Recent Hits |
| `scanner-view-sds100-usb.png` | Scanner view on an SDS100 over USB: no audio over USB, so no Listen button; "No audio over USB" in the status bar |
| `mac-style-view-sds100-usb.png` | Mac-style view on the SDS100 over USB during a transmission |
| `mac-style-menu-sds100-usb.png` | The scanner's own menu shown as a native list in the Mac-style view (Menu › Set Scan Selection) |
| `mac-style-menu-confirm-sds100-usb.png` | The same menu asking before it sends an item that can't be undone ("Set All Lists On") |
| `hit-log.png` | The Hit Log window: every transmission, with the inspector showing one transmission and its recording |
| `station-picker.png` | The station picker with a network SDS200 and two USB handhelds |
| `settings-stations.png` | Settings › Stations: per-station recording rules, display colors and the key map |

To retake them, follow AGENTS.md "To run it on the mock by hand" and the USB variant, and
LESSONS.md 2026-11-16 (website screenshots).
