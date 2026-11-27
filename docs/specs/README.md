# Noctule Scan specs

The design notes, protocol notes and plans behind Noctule Scan, in the order they were written. They are kept as the project's record, so some describe a step that has since moved on. Where a doc and the code disagree, the code and `AGENTS.md` at the repository root win.

## Notes on reading them

- **"The owner"** is the maintainer and their hardware. Dated hardware results ("on 2026-11-13 the SDS150 …") were seen on the maintainer's own units, with the firmware named in the doc; other units may differ.
- **Labels.** **(owner)** marks a decision the owner made; **(designer's call)** marks a default chosen while designing that the owner hadn't ruled on. In the protocol notes, **[hw]** is something seen on real hardware, **[spec]** is something Uniden's remote command specification states, **[lib]** is something read in the open-source `sds200` Python library (MIT, © Steven Boyd), and **[assumed]** is none of those: a reasonable guess until checked.
- **Commit and PR numbers** (`PR #7`, short hashes) refer to the earlier, archived repository, not to this one.
- Real names, frequencies and IDs have been replaced with fictional ones of the same shape.
- The Uniden manuals and command specification are copyrighted and not in this repository; `docs/uniden/README.md` says where to get them.

## Protocol notes

- [`2026-11-08-sds-remote-protocol.md`](2026-11-08-sds-remote-protocol.md): working notes on the SDS-series remote protocol: commands, key codes, XML replies, audio, and what is still unverified.

## Designs

**Core**
- [`2026-11-08-noctule-scan-design.md`](2026-11-08-noctule-scan-design.md): the overall design: goals, architecture, stations, audio, the app, logging.

**Stations, the reconnect cooldown and the hit log**
- No design doc of its own: the per-station reconnect cooldown is in Plan 5 (below), the hit log in the overall design and Plan 3.

**The app and its menus**
- [`2026-11-10-remote-menus-design.md`](2026-11-10-remote-menus-design.md): driving the scanner's menus remotely (`KEY`, `MSI`, `MSV`) and showing them in the app.
- [`2026-11-26-services-range-design.md`](2026-11-26-services-range-design.md): the Scanner view's Services and Range buttons walk the menu to Select Service Types and Set Range, one button set on every model (issue #14).

**USB and the SDS100, SDS150, SDS200 and BCD436HP**
- [`2026-11-11-sds150-usb-design.md`](2026-11-11-sds150-usb-design.md): the SDS150 over USB serial: the command line, then the app; hardware checks and results.
- [`2026-11-13-sds150-future-features-and-enhancements.md`](2026-11-13-sds150-future-features-and-enhancements.md): ideas for the SDS150 that were not built.
- [`2026-11-13-sds200-100ms-design.md`](2026-11-13-sds200-100ms-design.md): giving the SDS200 the SDS150's rates: `PSI,100` and `STS` every 100 ms.
- [`2026-11-16-sds100-usb-design.md`](2026-11-16-sds100-usb-design.md): the SDS100 over USB, on the SDS150's stack.
- [`2026-11-25-bcd436hp-usb-design.md`](2026-11-25-bcd436hp-usb-design.md): the BCD436HP over USB, on the same stack: its keep-alive, its menu commands (`MNU`, `MSB`) its 24-column screen and Hold by `HLD`.

**Line-in audio**
- [`2026-11-17-usb-line-in-audio-design.md`](2026-11-17-usb-line-in-audio-design.md): audio for USB scanners from the headphone jack through a Mac audio input.
- [`2026-11-17-plan-19-line-in-cli-design.md`](2026-11-17-plan-19-line-in-cli-design.md): line-in on the command line: a short design.

**Quick keys**
- [`2026-11-18-quick-keys-design.md`](2026-11-18-quick-keys-design.md): the Favorites quick keys: what the scanners answer, and the pop-over that switches them.

**Updates**
- [`2026-11-22-update-check-design.md`](2026-11-22-update-check-design.md): the app checks GitHub for a newer stable release and says so; nothing is downloaded or installed.

**Packaging and releases**
- [`2026-11-13-app-icon-design.md`](2026-11-13-app-icon-design.md): the app icon: format, build step, checks.
- [`2026-11-13-release-packaging-design.md`](2026-11-13-release-packaging-design.md): a signed, notarized DMG and tag-driven releases.
- [`2026-11-14-release-manager-design.md`](2026-11-14-release-manager-design.md): cutting a release with one command, versions from tags.

**Taking the project public**
- [`2026-11-20-open-source-prep-design.md`](2026-11-20-open-source-prep-design.md): licence, history, branding art, hygiene checks and community files for the public repository.
- [`2026-11-21-ci-docs-fast-path.md`](2026-11-21-ci-docs-fast-path.md): a documentation-only pull request runs only the repository suites **(owner)**.

## Plans (history)

Each plan was the step-by-step implementation plan for one piece of work. They show how it was built and what each step found; they are not instructions for today.

- [`2026-11-08-plan-1-scanner-core.md`](2026-11-08-plan-1-scanner-core.md): Plan 1, the scanner core (`NoctuleKit`).
- [`2026-11-08-plan-2-audio.md`](2026-11-08-plan-2-audio.md): Plan 2, audio over RTSP.
- [`2026-11-08-plan-3-stations-hitlog.md`](2026-11-08-plan-3-stations-hitlog.md): Plan 3, stations, hit logging and storage.
- [`2026-11-09-plan-4-mac-app.md`](2026-11-09-plan-4-mac-app.md): Plan 4, the Mac app.
- [`2026-11-09-plan-5-stations-cooldown.md`](2026-11-09-plan-5-stations-cooldown.md): Plan 5, station flow and a per-station reconnect cooldown.
- [`2026-11-10-plan-6-remote-menus.md`](2026-11-10-plan-6-remote-menus.md): Plan 6, remote menus.
- [`2026-11-11-plan-7-sds150-usb.md`](2026-11-11-plan-7-sds150-usb.md): Plan 7, the SDS150 over USB: protocol, mock and command line.
- [`2026-11-12-plan-8-sds150-app.md`](2026-11-12-plan-8-sds150-app.md): Plan 8, the app for the SDS150.
- [`2026-11-13-plan-9-sds200-100ms.md`](2026-11-13-plan-9-sds200-100ms.md): Plan 9, the SDS200 at 100 ms.
- [`2026-11-13-plan-10-app-icon.md`](2026-11-13-plan-10-app-icon.md): Plan 10, the app icon.
- [`2026-11-13-plan-11-move-to-noctule-dev.md`](2026-11-13-plan-11-move-to-noctule-dev.md): Plan 11, moving to `noctule-dev/noctule-scan` with one commit.
- [`2026-11-13-plan-12-hello-dmg.md`](2026-11-13-plan-12-hello-dmg.md): Plan 12, the first signed, notarized DMG.
- [`2026-11-14-plan-13-installer-window.md`](2026-11-14-plan-13-installer-window.md): Plan 13, the DMG's installer window.
- [`2026-11-14-plan-14-release-from-tag.md`](2026-11-14-plan-14-release-from-tag.md): Plan 14, releases from a tag.
- [`2026-11-14-plan-15-cut-release.md`](2026-11-14-plan-15-cut-release.md): Plan 15, cutting a release with one command.
- [`2026-11-16-plan-17-sds100-usb.md`](2026-11-16-plan-17-sds100-usb.md): Plan 17, the SDS100 over USB.
- [`2026-11-17-plan-18-line-in-audio.md`](2026-11-17-plan-18-line-in-audio.md): Plan 18, line-in audio for USB scanners (core and app).
- [`2026-11-17-plan-19-line-in-cli.md`](2026-11-17-plan-19-line-in-cli.md): Plan 19, line-in audio on the command line.
- [`2026-11-18-plan-20-quick-keys.md`](2026-11-18-plan-20-quick-keys.md): Plan 20, Favorites quick keys.
- [`2026-11-20-plan-21-open-source-prep.md`](2026-11-20-plan-21-open-source-prep.md): Plan 21, taking Noctule Scan public (done 2026-11-22; Results at the end).
- [`2026-11-22-plan-22-update-check.md`](2026-11-22-plan-22-update-check.md): Plan 22, checking GitHub for a newer release (design: [`2026-11-22-update-check-design.md`](2026-11-22-update-check-design.md)).
- [`2026-11-25-plan-23-bcd436hp-usb.md`](2026-11-25-plan-23-bcd436hp-usb.md): Plan 23, the BCD436HP over USB (design: [`2026-11-25-bcd436hp-usb-design.md`](2026-11-25-bcd436hp-usb-design.md); built against the mock, hardware session pending).
