# Taking Noctule Scan public — design

Date: 2026-11-20
Status: Draft for the owner's approval.

Labels: **(owner)** marks what the owner decided; **(builder's call)** marks a choice made while writing this that the owner hasn't ruled on and may overturn.

## 1. Intent

Noctule Scan's code goes public under the Apache License 2.0, to build a community around it and draw contributions **(owner)**. Anyone may fork it and make their own thing **(owner)**. The owner keeps tight control of the "Noctule" brand: the name, the icons, the logos and the rest of the brand art **(owner)**.

The official, signed build is the product; the brand is what marks it. This repo holds no product plans beyond its own specs: the owner's other product plans live elsewhere and are never referenced here (owner, 2026-11-20; §6.4).

### Success

- A stranger who lands on the GitHub page sees what the project is, that it is healthy (badges), how to build it, and how to contribute.
- A contributor can clone, build and run every test without any of the owner's private material, hardware or secrets, and gets an app that is visibly not the official one.
- The official release (a `v*` tag) still produces the branded, signed, notarized DMG, exactly as today.
- Nothing the owner wants private is reachable in the public repo, including its history.

### Non-goals

- Registering the trademark. The repo can only state a policy; registration is the owner's business with a lawyer.
- Rewriting the specs' voice ("the owner" stays; an index explains it, §6.3).
- Flipping the repo public. The owner does that, after this work is merged (§9).

### Anti-goals (a failure even if it all works)

- A fork can ship an app that looks like Noctule Scan by doing nothing (building the repo as cloned).
- Brand art or the owner's private planning documents reachable in the public repo's history or pull-request refs.
- A contributor's pull request can reach a secret (the signing keys, the branding deploy key).
- The official release looks or behaves differently from today's.
- A contributor's agent, following `AGENTS.md`, touches the owner's real scanners or settings, or anyone's real hardware without being asked.

## 2. Constraints

- Apache 2.0 §6 grants no trademark rights; but its copyright grant covers every file in the repo, so brand art can't stay in it under that license (the owner chose to move it out rather than carve it out, §4; the screenshots alone stay, under a carve-out of their own, §4.3).
- The existing rules stay: no real radio traffic in tracked files (`RealNamesTests`, which skips when `config/real-names.txt` is absent, so contributors are unaffected), Uniden manuals stay git-ignored, no Uniden logos, the `sds200` library credited in `ACKNOWLEDGMENTS.md`.
- Agents never create, read, print or move the owner's secrets, push `v` tags, create releases, or run the release workflow (AGENTS.md). The new deploy key and secret are the owner's to create and add (§5.4).
- The repo is private today: `noctule-dev/noctule-scan`, 298 commits from a clean initial commit (2026-11-13), 14 PRs (13 `refs/pull/*` heads on GitHub), one open issue (#13), tags `v0.1.1-beta.1`–`.3` with no releases, the `Release tags` ruleset (id 27276075; blocks creating, updating and deleting `v*` tags), no branch protection on `main`, the `release` environment holding five signing secrets.
- History holds what must not go public: a private planning document (removed at the start of the `docs/open-source-prep` branch) and the brand art (§4.1). (34 commits are authored under the owner's personal address, the rest under the project's commit address; the owner is fine with either being public, 2026-11-20, but no commit or personal address is named in these docs, which use `info@noctule.app`.) A history scan for private IP addresses and `config/*.env|*.txt` found nothing.
- GitHub keeps every PR's head commits reachable through `refs/pull/N/head`, which a force-push can't remove; only GitHub Support can purge them. So rewriting history in place would leave the old commits reachable once the repo is public (§7).

## 3. What a visitor and a contributor get

New files at the root **(owner: README with badges; the rest builder's call)**:

- `LICENSE`: the Apache License 2.0 text, unmodified.
- `NOTICE`: the project name, "Copyright 2026 Sean Foley" (owner), the pointer that the Noctule name and brand are not licensed (see `TRADEMARKS.md`), and the existing third-party credits by reference to `ACKNOWLEDGMENTS.md` (the Inter Tight font leaves with the DMG art, §4.1, so its OFL entry moves too).
- `TRADEMARKS.md`: the brand policy (§3.1).
- `README.md` (§3.2).
- `CONTRIBUTING.md` (§6.2): how to build and test, the mock-first rule, hardware rules for your own scanner, the real-traffic rule, the DCO sign-off (`git commit -s`, which adds `Signed-off-by:`; **owner, 2026-11-20**: a DCO, not a CLA; `ci.yml` fails a PR with a commit lacking a `Signed-off-by:` line that matches its author, a check of our own rather than a third-party app **(builder's call)**), how specs and `LESSONS.md` work. The DCO 1.1 text is linked (developercertificate.org), not copied.
- `CODE_OF_CONDUCT.md`: Contributor Covenant 2.1, contact `info@noctule.app` **(builder's call)**.
- `SECURITY.md`: report privately through GitHub's private vulnerability reporting; states that the scanner protocol has no authentication and the scanner must never be exposed to the internet.
- `.github/ISSUE_TEMPLATE/` (bug report asking for model, firmware, connection type, macOS version and whether it reproduces on the mock, with a reminder to strip real system names and frequencies; feature request) and `.github/pull_request_template.md` (tests run, mock first, DCO, no real traffic).

Every source file carries a two-line SPDX notice **(owner, 2026-11-20)**:

```swift
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors
```

- Which files: every tracked Swift, shell, Python and workflow (`.yml`) file (299 today), in each language's comment form (`#` for shell, Python and YAML). Not JSON fixtures, `Info.plist`, the entitlements, the `.icon` file, Markdown, images or the font: `NOTICE` covers them.
- Where: the first lines, except that `Package.swift` keeps `// swift-tools-version:` first and scripts keep their `#!` line first; the notice goes right after those.
- The year stays 2026 (first publication); it isn't bumped yearly. "And the Noctule Scan contributors" because, under the DCO, contributors keep the copyright in what they write; `NOTICE` keeps "Copyright 2026 Sean Foley" as the project's notice.
- A test fails when a file of those kinds lacks the two lines, so new files get them. `images/screenshots/` and anything else under its own terms are excluded.

### 3.1 The trademark policy (`TRADEMARKS.md`)

- "Noctule", "Noctule Scan", any other product name beginning "Noctule", the Noctule mark and the app icons are the owner's trademarks, not licensed under Apache 2.0.
- Forks are welcome. A fork you distribute (a built app, a DMG, an App Store listing, a Homebrew cask) must not be called Noctule or Noctule Scan and must not use the brand art. Saying "based on Noctule Scan" or "a fork of Noctule Scan" is fine.
- Code identifiers containing "noctule" (module names `NoctuleKit` and the rest, the `noctule` command, `NOCTULE_*` environment variables, `app.noctule.*` in the source) may stay in a fork's source; a fork that ships should change its bundle identifier and display name. The repo doesn't make that configurable (§10, question 2).
- Uniden, SDS100, SDS150 and SDS200 are Uniden's trademarks, used only to name the hardware supported (a line in the README too).
- Not legal advice; the owner may want a lawyer to read it before the repo goes public.

### 3.2 The README

Top: the name, a one-line description, then badges **(owner: badges for repo health)**:

- build status of the new CI workflow (§5.3) on `main`,
- license (Apache 2.0),
- latest release (it shows "none" until the owner publishes one, which is fine),
- Swift and Xcode version and platform (macOS; iOS planned): static badges saying Swift 6.4 / Xcode 27.2, what the code actually needs (`Package.swift`'s tools version, 6.2, understates it; Xcode 26.6 can't build the code, Plan 14 Results), updated by hand when the requirement changes,
- **builder's call**: no coverage badge (no coverage tooling exists; adding it is out of scope).

Badges are shields.io images over the GitHub API, with no third-party service to sign up for.

Then: what it does (control, listen to and log Uniden SDS100, SDS150 and SDS200 scanners; network and USB; the mock), two or three screenshots (from `images/screenshots/`, §4.3), requirements (macOS version, Xcode version, the scanners), quick start against the mock (`swift run noctule-mock-scanner`, `swift run noctule info --host 127.0.0.1 --port <udp>`, building the app with `scripts/build-app.sh`), a word that local builds are unbranded and why (§4), where to start reading (`docs/specs/README.md`, the protocol notes), contributing, license and trademarks, acknowledgments, and the "not affiliated with Uniden" line.

## 4. The brand art leaves the repo

### 4.1 What counts as brand art

Moves out (and is purged from history, §7) **(owner: move the art out and let the build pull it in)**:

- `Resources/AppIcon.icon` (the Icon Composer file: NoctuleScan layers from the design language),
- `packaging/dmg/background/` in full: `background.tiff` (the rendered installer background with the mark and the wordmark), `noctule-mark-on-dark.svg`, `render-background.swift` (it draws the wordmark and the mark; it is the art's source), `fonts/` (Inter Tight, used only for the wordmark),

Stays: everything else, including the app's name strings, the bundle identifier and the Info.plist (question 2, §10), and the DMG layout (`packaging/dmg/settings.py`: window size, icon positions), which is not art.

### 4.2 Where it goes and how the build finds it

The art goes to the private `noctule-dev/noctule-design-language` repo, which already holds `icons/noctulescan` and `logo/`. **Builder's call** on the layout there: a `builds/noctule-scan/` folder holding exactly what this repo's build consumes, so the release checkout is one sparse path:

```
builds/noctule-scan/
  AppIcon.icon/              the Icon Composer file as it is in Resources/ today
  dmg/background.tiff        the rendered installer background
  dmg/render-background.swift, dmg/noctule-mark-on-dark.svg, dmg/fonts/   its source
  README.md                  what this folder is for, and which noctule-scan scripts read it
```

This repo gets placeholder art, under Apache 2.0, made for this purpose and plainly not the brand **(builder's call)**:

- `Resources/Placeholder.icon` (or a plain `.icns` if an Icon Composer file is overkill): **"Signal on graphite" (owner, 2026-11-20; the 2026-11-20 mockup's candidate A)**: a grey squircle (top #8b939b to bottom #5b636b) with a white antenna, a dot, and three white radio-wave arcs fading upward; no night blue, bat, amber or wordmark. It must read at 32 pt.
- `packaging/dmg/placeholder-background.tiff`: the same window size (640 × 400 pt, two resolutions), a plain light grey vertical gradient, a dotted grey arrow from the app's slot (170, 214) to Applications' (470, 214), and the line "Drag the app to Applications to install it." near the bottom; no mark or wordmark (same mockup; owner, 2026-11-20). Rendered by a small script of its own, committed beside it, so it can be redrawn.

The scripts choose by one variable, **`NOCTULE_BRANDING_DIR`** **(builder's call on the name)**: a path to a folder shaped like `builds/noctule-scan/`.

- `scripts/compile-app-icon.sh` and `scripts/build-app.sh`: with it set, compile `$NOCTULE_BRANDING_DIR/AppIcon.icon`; without it, the placeholder. The compiled icon keeps the name `AppIcon` either way (Info.plist's `CFBundleIconName` is unchanged).
- `packaging/dmg/make-dmg.sh`: background from `$NOCTULE_BRANDING_DIR/dmg/background.tiff`, else the placeholder.
- `packaging/release.sh` (the official release): **refuses to run without `NOCTULE_BRANDING_DIR`**, and checks the folder holds what it needs, so an official DMG can never ship the placeholder. `--untagged` local tries may use the placeholder, with the DMG name marked (`…-untagged-unbranded.dmg`) **(builder's call)**.
- Each script says which art it used on stderr (`branding: <path>` or `branding: placeholder (set NOCTULE_BRANDING_DIR for the official art)`).
- On the owner's Mac, the setting lives in a git-ignored `config/branding.env` (`NOCTULE_BRANDING_DIR=../noctule-design-language/builds/noctule-scan`, a path relative to the repo root or absolute), which the scripts read when the variable isn't already set, as they read `config/*.env` today; `config/branding.env.example` documents the key for anyone **(owner agreed, 2026-11-20)**. With it set, `build-app.sh` gives the owner the real icon and `release.sh --untagged` a branded local DMG. Contributors can't use it to get the real art, which sits in the private repo.

### 4.3 Screenshots

`images/screenshots/` stays in this repo, excluded from the Apache license by a file of its own **(owner, 2026-11-20)**: `images/screenshots/LICENSE.md` says the pictures show the Noctule Scan brand, are © Sean Foley, all rights reserved, are not licensed under Apache 2.0, and may be shown only to talk about this project (as in a review or an article linking here); it points to `TRADEMARKS.md`. The root `NOTICE` and `TRADEMARKS.md` name the folder as the one exception to the license. Screenshots don't go into any build, so unlike the icon (§4.1) they can't make a fork look official by default.

The README uses two or three of them by relative path. New screenshots go in the same folder, under the same terms, taken by the existing convention (mocks only, one window, no real values; the folder's `README.md`). The website repo may copy them.

**Other repos (builder's call):** this work's changes to `noctule-design-language` (§4.2) go in by a PR there, made by the builder like a PR here.

### 4.4 Tests

- `AppIconSourceTests` (`Tests/NoctuleCLIIntegrationTests/AppIconTests.swift`) checks the real icon's four layers and the absence of C2PA metadata. It moves with the art: the C2PA check becomes a check in the design-language repo or runs here only when `NOCTULE_BRANDING_DIR` is set; the default suite checks the placeholder compiles and that `Info.plist`'s icon name matches **(builder's call)**.
- `PackagingTests` and `MakeDMGTests` run against the placeholder by default, plus one test that `release.sh` refuses without `NOCTULE_BRANDING_DIR` and one that a stub branding folder (a fixture with a tiny fake icon and TIFF, Apache-licensed) is the one used when it is set.
- A new test that no brand file is tracked: none of the moved paths exist, and no tracked file's contents match the real art (for instance the SVG path data of the mark, read from the design-language checkout when available, else skipped) **(builder's call; the exact check is the builder's)**.

## 5. Builds and CI

### 5.1 Pull requests and pushes (new `ci.yml`)

**(owner: badges for repo health, which need this.)** A workflow on every push to `main` and every pull request: `swift build`, `swift test` (with `NOCTULE_NO_USB_DETECTION=1` and `NOCTULE_CI_RUNNER=1`, as the release job sets, so `.skippedOnCIRunner` tests are skipped there), and the app build with the placeholder (`scripts/build-app.sh`). No secrets, no `environment`, `permissions: contents: read`, no branding checkout. Its status is the README's build badge. Concurrency cancels superseded runs on the same PR.

**Public-repo safety (owner agreed, 2026-11-20):** no workflow uses `pull_request_target` or any other trigger that gives fork code secrets or write permission (a test over `.github/workflows/` checks it); every action stays pinned by commit SHA; a `.github/CODEOWNERS` names the owner for `.github/` and `packaging/` (and `scripts/`), so changes to the build and release path always await the owner's review. The release scripts and workflow stay public: they name secrets, the environment and the design-language repo, never a value, and that openness lets anyone see how the official DMG is made.

Out of scope: linting

### 5.2 The runner

The release job uses `runs-on: xcode-27`, GitHub's Xcode 27 public-preview image (`packaging/README.md`, "The runner"), chosen because `macos-26`'s newest Xcode (26.6) can't build the code. It is a GitHub-hosted image, not an org larger runner (the org lists none), so it should be free for public repos; the builder confirms that, and the run cost shows on the first runs **(builder checks)**. A preview image has no uptime guarantee: if it goes away, `ci.yml` moves with `release.yml` to the next label (`packaging/README.md` says what to change). Fork PRs run on it with no secrets.

### 5.3 Branch protection

Once `ci.yml` exists, `main` requires its check to pass before merge, through a ruleset beside `Release tags` (no required approvals: the owner can't approve their own PRs and merges with `gh pr merge --merge`) **(builder's call)**. Agents may create the ruleset (they created `Release tags`). If the preview runner is withdrawn, the required check blocks every merge until `runs-on` moves; the owner can bypass the ruleset as admin meanwhile (`packaging/README.md` notes it).

## 6. Docs for contributors

**(owner: option 2: keep the specs and lessons; rewrite AGENTS.md for contributors; the owner-only rules move to a git-ignored local file.)**

### 6.1 `AGENTS.md` and the owner's local file

`AGENTS.md` (132 KB today) is rewritten for anyone's agent:

- Rules about real hardware become rules about **your** scanner: probe read-only, ask before state changes, one state-changing command per action and never resent, always TEARDOWN, `PSI,0`, the reconnect cooldown (never shortened against a real scanner), never `MSM,1` unless the person explicitly confirms it, never `POF` or guessed commands, the kill-switch and `--settings-dir` for every agent run, the app launched only with a private `NOCTULE_SETTINGS_DIR`.
- Facts about the hardware (the SDS150's 183 s push lifetime, the SDS100's `KAL` `ERR`, paged `GLT`) stay; facts about the owner's units ("the owner's SDS100 is plugged in beside the SDS150", "as of 2026-11-16 the owner's settings hold…", which hardware sessions are pending) move out.
- The release rules stay (any agent must still never push a `v` tag, run `cut-release.sh`, or touch secrets), phrased for maintainers.
- The mock, build-and-test and app sections stay, trimmed where they repeat the specs **(builder's call how far)**.

The owner-only material goes to **`AGENTS.local.md`**, git-ignored, which `CLAUDE.md` imports after `AGENTS.md` when present **(builder's call; the builder checks how Claude Code treats an `@`-import of a missing file and adjusts, for instance by a separate git-ignored `CLAUDE.local.md`, which Claude Code reads natively)**. It holds the owner's units and their state, the owner's settings warnings, hardware session status, the owner's rig, and the branding path.

The rewrite keeps every rule that protects hardware; it is reviewed rule by rule against today's `AGENTS.md` so nothing is dropped by accident (the plan should make that a checklist step).

### 6.2 `CONTRIBUTING.md`

Covers what §3 lists, with the workflow the repo actually uses: specs in `docs/specs/` named by date, `LESSONS.md` entries when something surprises you, tests against the mock first, opt-in hardware tests, the real-traffic rule and the optional deny-list, the iOS build check, and how to propose a change (an issue first for anything large).

### 6.3 `docs/specs/README.md`

An index: the protocol notes first (`2026-11-08-sds-remote-protocol.md`), then the design docs by area (core, audio, stations, the app, menus, USB, line-in, quick keys, packaging and releases), then the plans as history. It says that "the owner" in these documents means the maintainer and their hardware, that the dated hardware results were on the maintainer's units, and that the labels **(owner)**, **[hw]**, **[spec]**, **[lib]** mean what they mean.

### 6.4 Other docs

- `docs/specs/2026-11-13-design-language-gap-review.md` moves to the design-language repo and is purged from history **(builder's call, suggested to the owner; not yet ruled)**.
- `packaging/README.md` documents `NOCTULE_BRANDING_DIR`, `packaging/branding-ref` and the deploy key.
- `LESSONS.md` stays as is.
- **No product-roadmap references (owner, 2026-11-20).** Nothing in this repo mentions other editions of the app, other Noctule products, or plans to sell. Done on `docs/open-source-prep` before this design was committed: the lines about what might become of the project in `AGENTS.md`, `LESSONS.md` and the main design; the planned AI module in the remote-menus design; the other-icons wording in the app-icon design and Plan 10. Feature backlogs and "later" items about this app itself (iPad and iPhone, SDS150 audio, Bluetooth) are not product roadmap and stay; the owner kept `2026-11-13-sds150-future-features-and-enhancements.md` (2026-11-20). The builder re-checks before the fresh commit (§7) with a search for such words and adds a test that fails if they come back **(builder's call)**.
- This design replaces the earlier plan in `2026-11-13-release-packaging-design.md` (line 133: "At the flip to public: remove `docs/specs/` and rewrite the history"): the specs stay (owner: option 2). That line gets a note pointing here.
- AGENTS.md, `ACKNOWLEDGMENTS.md` and the specs' pointers to moved files are updated (the app-icon and installer-window docs point at the design-language repo for the art).

## 7. History and the public repo

What must not be reachable: the private planning document, the brand art (§4.1 paths), and the design-language gap review.

Because PR refs keep old commits reachable (§2), the rewritten history can't simply be force-pushed over the existing repo.

**The owner chose B (2026-11-20)**: the history starts over from one fresh commit of the cleaned tree, the way the owner has done it before (delete `.git`, `git init`, push). With B nothing old reaches the public repo, so what §4.1, §6.4 and open question 4 remove is removed at the tip only, and no history rewriting tool is needed. The fresh commit is authored by the owner's configured git identity. Whether the old GitHub repo is deleted or renamed and archived is open question 1. The options considered were:

- **A. Rewrite, new repo.** `git filter-repo` (installed with Homebrew) on a fresh clone removes the paths and rewrites the email across all 298 commits; the result is pushed to a new repo that becomes `noctule-dev/noctule-scan`, after the current one is renamed (for instance `noctule-scan-private-archive`) and archived, private. History and `git blame` survive, with new SHAs. Commit messages that name a PR number or SHA point into the old repo; a note in `docs/specs/README.md` says so.
- **B. One fresh commit, new repo.** As Plan 11 did on 2026-11-13: the cleaned tree as a single `Initial public commit` in a new repo; the full history stays in the archived private repo. Simplest and leaves nothing to miss, but contributors get no history or blame (the specs carry the reasons).
- **C. Rewrite in place**, force-push, and ask GitHub Support to purge the PR refs and cached views. Keeps the repo, its issue and PR pages and stars; depends on Support, and until they act the old commits are reachable.

For A and B, what moves to the new repo: issue #13 (transferred), the `Release tags` ruleset (recreated by an agent), the `release` environment and its five signing secrets plus the new deploy key (**the owner** recreates them), the CI ruleset. The tags `v0.1.1-beta.1`–`.3` don't move (no releases were published); the next release in the new repo continues the version line (`cut-release.sh` reads the latest tag on `origin`, so the owner either pushes the next beta as `v0.1.1-beta.4` by hand or the builder makes `cut-release.sh` accept a starting version; **builder's call**, flagged in the plan).

After the move, a check on the new repo before it goes public: no tracked or historical file under the moved paths (`git log --all -- <paths>` empty), the deny-list check (`RealNamesTests`) and a scan of all history for private IP addresses, as in §2.

## 8. Order of work

1. The art and its build switch (§4, §5.4 except the secret), with the placeholder; tests pass with no branding and with a stub branding folder; the owner checks a local official build with `NOCTULE_BRANDING_DIR` set looks as today.
2. The art lands in the design-language repo (`builds/noctule-scan/`), its commit recorded in `packaging/branding-ref`.
3. The owner creates the deploy key and secret.
4. Docs (§3, §6) and `ci.yml` (§5.1).
5. Merge into `main` of the current repo.
6. History (§7), the new repo, rulesets and environment.
7. A release from a tag in the new repo (the owner's `cut-release.sh beta`) proves the branded release path end to end.
8. The owner flips the repo public (§9).

Steps 1–5 change nothing that is public. Step 6 is the hard-to-reverse one: the owner approves its exact form before it runs.

## 9. Going public (the owner's checklist)

The owner, not an agent, makes the repo public, after: the history check in §7 passes, the release in step 7 succeeded, `TRADEMARKS.md` read (by a lawyer if the owner wants), private vulnerability reporting turned on, Discussions turned on or not (the owner's choice), the repo's description and topics set, and the social preview image (brand art, uploaded through GitHub's settings, so not in the repo) set.

## 10. The owner's decisions and the calls left to check

1. **History (§7): B, chosen by the owner.** The old GitHub repo is renamed `noctule-scan-private-archive` and archived, private, not deleted (owner, 2026-11-20), keeping the 14 PRs' bodies (the rulings, deferred minors and test plans of Plans 12–20); issue #13 is transferred to the new `noctule-dev/noctule-scan`.
2. **The unbranded build's name: unchanged (owner, 2026-11-20).** A contributor's build keeps the name Noctule Scan, the bundle ID `app.noctule.scan` and the shared data folders (so the RTSP cooldown record stays shared with the CLI); only the icon and installer art are the placeholder. A contributor's build is for their own machine, and the project's CI always builds Noctule Scan. Forks that distribute a build rename it, per `TRADEMARKS.md`.
3. **The copyright holder: Sean Foley (owner, 2026-11-20).** `NOTICE` reads "Copyright 2026 Sean Foley".
4. **What else is cleaned at the tip (builder's call, for the owner to check).** The planned AI module is already gone (§6.4). Local paths with the owner's user name (the agent's memory folder and the earlier personal repository's name) in the release-packaging and Plan 11 docs become generic wording; links to private claude.ai artifacts (five docs) are removed; the installer background's exact recipe (colours, mark placement, wordmark type) in `2026-11-14-plan-13-installer-window.md` moves to the design-language repo with the art, leaving a pointer, and `MakeDMGTests`' pixel checks test the placeholder instead.
5. **Contributions: DCO (owner, 2026-11-20).** A sign-off on each commit, checked in CI (§3).
6. **Screenshots: stay in the repo under their own all-rights-reserved file (owner, 2026-11-20; §4.3).**

## 11. Left to the builder

The placeholder art's exact look, test names and structure, `AGENTS.md`'s final shape within §6.1, the issue templates' wording, and the plan's task breakdown.
