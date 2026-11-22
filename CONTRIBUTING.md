# Contributing to Noctule Scan

Thanks for helping. Noctule Scan controls, listens to and logs Uniden SDS-series scanners, which are real radios their owners rely on, so the workflow puts a simulated scanner first and keeps real hardware safe. If you work with a coding agent, point it at [`AGENTS.md`](AGENTS.md): it holds every rule below in full, and more.

## Before you start

- **Open an issue first for anything large** (a new feature, a new scanner model, a change to how the app talks to the scanner, a new dependency), so we can agree on the approach before you spend time on it. Small fixes can go straight to a pull request.
- Bugs and feature requests go through the issue templates. Questions, ideas that aren't yet a concrete request, and what you've built go to [Discussions](https://github.com/noctule-dev/noctule-scan/discussions). Security problems go through private vulnerability reporting ([`SECURITY.md`](SECURITY.md)), never a public issue.
- Everyone who takes part follows the [Code of Conduct](CODE_OF_CONDUCT.md).

## Build and test

You need macOS 26 and Xcode 27.2 (Swift 6.4); older toolchains can't build the code.

```sh
swift build                 # everything, including the `noctule` command and the mock scanner
swift test                  # every test, against simulated scanners; hardware tests are skipped
scripts/build-app.sh        # the Mac app, as build/Noctule Scan.app
xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build   # the shared code builds for iOS
```

Set `export NOCTULE_NO_USB_DETECTION=1` in the shell you test from: it stops `noctule` and the app from finding a USB scanner or an audio input on their own, so a test can never reach a radio plugged into your Mac.

Keep the scanner protocol, transports, stations, logging and storage in shared code with no Mac-only UI dependencies (the iOS build above checks it), and put model-specific knowledge in per-model data (`ModelProfile`).

Local builds use placeholder art: the official icon and installer art aren't in this repository, and the Noctule name and brand aren't licensed with the code ([`TRADEMARKS.md`](TRADEMARKS.md)). A fork you distribute needs its own name and art.

## The mock scanner first

**Test every change against the mock scanner first, and a real scanner second.** `noctule-mock-scanner` imitates the SDS200 over the network and the SDS150 and SDS100 over a pseudo-terminal, including the hardware's hazards (a quick audio reconnect that wedges it, lost replies, status pushes that stop):

```sh
swift run noctule-mock-scanner                      # prints udp-port=P and rtsp-port=P
swift run noctule info --host 127.0.0.1 --port <udp>
swift run noctule-mock-scanner --model sds150 --serial --serial-link /tmp/mock-port
swift run noctule info --serial /tmp/mock-port
```

In Swift tests use `MockSDS200` and `MockSerialScanner`. `AGENTS.md` ("The mock scanner") lists every flag and fault, and how to run the app against the mock with a private settings folder.

## Your own scanner

Tests against real hardware are opt-in (environment variables, see `AGENTS.md`, "Hardware tests") and read-only unless marked otherwise. When you try a change on your own scanner:

- probe read-only first; send a state-changing command (a key press, a menu value, a volume or squelch value, a quick-key set) once per action and never resend it, even after a timeout: re-read to see whether it took effect;
- always end an RTSP audio session with `TEARDOWN` and a status subscription with `PSI,0`, on every exit path;
- respect the reconnect cooldown (120 s after an unclean close): a quick reconnect can leave an SDS200's audio dead until you power-cycle it;
- never send guessed or undocumented commands, never `POF`, and `MSM,1` (restart) only to an SDS200 over the network when you mean to restart it;
- never expose a scanner or a relay to the internet: the protocol has no authentication.

`AGENTS.md` ("Your scanner") has the full rules and what is known about each model. Your saved stations live in `~/Library/Application Support/NoctuleScan/`, shared by the command line and the app; use `--settings-dir` (and the app's `NOCTULE_SETTINGS_DIR`) with a temporary folder when you don't mean to touch them.

## No real radio traffic

Nothing tracked may contain real radio traffic: no real system, site or channel names, frequencies, unit IDs, or NAC, Sys ID or WACN values, even in fixtures, test data, specs or screenshots. Sanitize captures to fictional values of the same shape. Recordings and hit logs made on a real scanner are real traffic too: never commit them.

To have the tests check this for you, list the real names you want kept out in a git-ignored `config/real-names.txt` (copy `config/real-names.txt.example`); `RealNamesTests` then checks every tracked text file against it. Without the file the check is skipped. Keep your scanner's address and serial port in git-ignored `config/*.env` files (templates are `*.env.example`), never in tracked files.

## Specs and lessons

- Designs and plans go in [`docs/specs/`](docs/specs/README.md), named `YYYY-MM-DD-<topic>.md`. Read the protocol notes and the design for the area you're changing first; a sizeable change gets a spec of its own.
- When something surprises you, costs time or changes how we work, add a dated entry to [`LESSONS.md`](LESSONS.md) with what happened and what to do, as you go.
- Uniden's manuals are copyrighted: keep them out of the repository (`docs/uniden/README.md` says where to get them).

## New source files

Every new `.swift`, `.sh`, `.py` and `.yml` file starts with this notice (after a `#!` or `// swift-tools-version` line, if any), with `#` instead of `//` for shell, Python and YAML:

```swift
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors
```

`RepositoryHygieneTests` fails without it. Contributions are under the [Apache License 2.0](LICENSE); you keep the copyright in what you write.

## Sign off every commit (DCO)

We use the [Developer Certificate of Origin](https://developercertificate.org/) (DCO 1.1) instead of a contributor license agreement. Signing off says you wrote the change, or otherwise have the right to submit it under the project's license. Sign off every commit with `-s`:

```sh
git commit -s -m "Fix the thing"
```

That adds a `Signed-off-by: Your Name <you@example.com>` line, which must match the commit's author name and email. CI checks every commit of a pull request (`scripts/check-dco.sh`) and fails one that lacks it. To fix commits you've already made:

```sh
git commit --amend --no-edit -s             # the last commit
git rebase --signoff origin/main            # every commit on your branch since main
git push --force-with-lease
```

## Pull requests

Fill in the pull request template: the tests you ran, the mock first, the iOS build for shared code, signed-off commits, no real traffic, and a spec or lessons entry where the change needs one. CI builds and tests every pull request on a larger paid runner (`xcode-27-xlarge`), so a pull request from an outside contributor waits for the maintainer's approval before CI runs; changes under `.github/`, `packaging/` and `scripts/` also wait for the maintainer's review.
