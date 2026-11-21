# Cutting a release: one command, versions from tags, a reliable release run

Plan 15's design. Builds on Plan 14 (`docs/specs/2026-11-14-plan-14-release-from-tag.md`): a pushed `v*.*.*` tag makes a draft GitHub Release through `.github/workflows/release.yml`.

## Why

The owner, acting as release manager, wants **one command run against `main`** that picks the next version, tags `main`, starts the release workflow and shows it through to the draft. Today it is two `git` commands and a version number typed by hand. The owner's concern is **keeping versions in sync**: the app has a version, the tag has a version, and nothing stops them disagreeing (0.1.0 was made by running `release.sh` by hand, with no tag).

The first real tag (`v0.1.1-beta.1`, 2026-11-14) also showed the release run isn't reliable on GitHub's 3-core `xcode-27` runner: a new timing flake (`MockPersonalityTests/pushesGoToTheSubscribingPeer`) and then a hang of 66 minutes in the parallel test step, with output stopped while `ListenIntegrationTests` (the `noctule listen` signal tests, `listenWaitsOutCooldown`) and `ReleaseTests/failedGatekeeperCheckFailsTheRun` were unfinished. The run was cancelled before any key existed; nothing reached Apple. The tag stays, with no release.

## Goals

1. `packaging/cut-release.sh <kind>`: the owner's one command. It computes the next version from the latest `v` tag, checks `main`, runs the full test suite locally, asks once, tags, pushes, and follows the workflow to the draft.
2. **The tag is the only source of a release's version.** Nobody types a version. The app's version is stamped from the tag (as now) and checked against it inside the finished DMG. `release.sh` refuses to release a version `HEAD` isn't tagged with.
3. **The release run fails fast and names the culprit** instead of hanging: time limits on the test steps and on each test.
4. **Known runner flakes are marked on the tests themselves**, with their reasons, and skipped only on CI runners.
5. **The hang is found** (a probe on a throwaway branch) and fixed or marked.

## Non-goals

- PR checks, branch protection, linting, security scanning: Plan 16.
- Conventional Commits, changelogs, a release bot.
- Fixing the flaky tests' root causes (follow-ups), except the hang, which must at least be identified.
- Whether the release run should repeat the full suite at all (deferred to Plan 16's discussion).
- A version in dev builds: `scripts/build-app.sh` keeps `0.0.0` / `0` (owner's question left open; the default keeps "not a release" obvious).
- Publishing the release: stays the owner's click.

## Anti-goals (a failure even if it works)

- Any path that makes a signed, notarized release whose version isn't a pushed tag on `main`.
- A script that pushes to `main`, or edits code to bump a version.
- A test skipped on the owner's Mac. The CI skip applies only where `NOCTULE_CI_RUNNER` is set.
- An agent cutting a release: `cut-release.sh` is the owner's tool; agents never run it, as they never push a `v` tag.

## Approaches considered (versioning)

- **A. The owner names the kind of release; the script computes the number from the latest tag.** *(Chosen: the controller's recommendation; the owner asked for help with semantic versioning and didn't object.)* No change to how anyone commits; the owner still judges patch/minor/major; the script does the arithmetic.
- B. The kind comes from Conventional Commits (`fix:`, `feat:`, `feat!:`). Fully automatic, but this repository's commit prefixes name the area (`docs:`, `packaging:`, `test:`), so it would need a new commit style first.
- C. A release bot (e.g. release-please) opens version-bump PRs whose merge creates the tag. Needs B's commit style and adds a GitHub App with write access, against Plan 14's secrets lockdown.

Also rejected: a `VERSION` file bumped per release. Each bump would be a commit to `main`, either a PR per release or a push that bypasses review.

## The design

### 1. `packaging/cut-release.sh`

Usage: `packaging/cut-release.sh beta | final | patch [--beta] | minor [--beta] | major [--beta]`. Anything else: usage, exit 2. Script rules as for every packaging script (`#!/bin/bash`, `set -euo pipefail`, mode 100755, paths quoted, usage 2, other failures 1, `git` and `gh` called by name so tests stub `gh` and use a fake repository).

**The latest version** is the highest `v*` tag by semantic-version precedence (not by date), among tags that parse as `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-beta.N`; any other `v` tag is listed in a warning (`cut-release: ignoring tags it can't read: …`) and otherwise ignored. The "next tag exists" check compares the exact name, so an ignored tag can't hide a clash. Tags are read from `origin` (`git ls-remote --tags origin`), so a tag made only locally never counts; one that exists locally but not on `origin` is refused. With no such tag, the latest is `v0.0.0` (final).

**The next version**, from latest `L`:

| Kind | If `L` is a beta `X.Y.Z-beta.N` | If `L` is final `X.Y.Z` |
|---|---|---|
| `beta` | `X.Y.Z-beta.(N+1)` | refused: `latest is v X.Y.Z (final); use patch --beta, minor --beta or major --beta` |
| `final` | `X.Y.Z` | refused: `latest is vX.Y.Z, already final` |
| `patch` | refused: `vX.Y.Z-beta.N isn't final yet; release it with final, or another beta with beta` | `X.Y.(Z+1)` |
| `minor` | refused (same) | `X.(Y+1).0` |
| `major` | refused (same) | `(X+1).0.0` |
| `… --beta` | refused (same) | the same bump with `-beta.1` |

Only `-beta.N` pre-releases are made or counted. A tag counts even when its release was never made (`v0.1.1-beta.1` today), so the next beta is `v0.1.1-beta.2`.

**Checks, in order, all before anything is changed:**
1. The current branch is `main`; the working tree is clean (`git status --porcelain` empty).
2. `git fetch origin main --tags`; local `main` equals `origin/main`.
3. The next tag exists neither locally nor on `origin`; `gh release view <tag>` finds no release (the same "release not found" handling as `release-from-tag.sh`; any other `gh` failure stops with its first line).
4. `NOCTULE_NO_USB_DETECTION=1 swift test`, the full suite in one plain run as on any developer Mac, output to `build/cut-release-test.log`; a failure stops with the log's path and its last summary lines (no retry; the owner runs the script again). No way to skip it (controller's call: a release always comes from a tree tested on the owner's Mac; it costs about 6 minutes). The CI split and skips don't apply here: the flakes seen so far are runner-only, and the full suite passed in one run on this Mac every time on 2026-11-14.

**Then it asks once** (reading the answer from standard input): `Tag <short sha> (<subject>) as v<next> (latest v<latest>) and push it? This starts the release workflow, which uploads the app to Apple for notarization. [y/N]`. Anything but `y`/`yes` exits 1 with `cut-release: nothing tagged`.

**Then:** `git tag -a v<next> -m "Noctule Scan <next>"`; `git push origin v<next>` (a failed push deletes the local tag and exits 1). It finds the workflow run (`gh run list --workflow release.yml --event push` for that tag, polled every 5 s for up to 2 minutes; none, or more than one, prints the Actions page's URL and exits 1, the tag left pushed), prints its URL, and follows it with `gh run watch <id> --exit-status`. Ctrl-C there stops only the watching: it prints `cut-release: the release run goes on: <url>` and exits 130. On success it prints the draft's URL and its asset names (`gh release view v<next> --json url,assets`), and `Check it, write the notes, then publish it.` On failure it prints the failing step's name and points at `packaging/README.md`'s failure list; it retries nothing.

### 2. The tag is the only source: `release.sh`

- `release.sh <version>` now requires `HEAD` to carry the tag `v<version>` (`git tag --points-at HEAD`), else `release: HEAD isn't tagged v<version>; cut releases with packaging/cut-release.sh (or pass --untagged to try a release locally)`, exit 1, before anything is built. `--untagged` allows it and names the DMG `build/noctule-scan-<version>-untagged.dmg`, so it can't pass for a release. In CI the checkout is the tagged commit, so `release-from-tag.sh`'s call passes unchanged.
- **Already guaranteed, unchanged:** a tag whose commit isn't on `origin/main` never releases. The workflow's first step (`release-from-tag.sh --preflight`) and the full run both refuse it before any key exists (Plan 14). So the manual `git tag` fallback can't release a branch.
- **Version and build number today, unchanged:** `release.sh` stamps `CFBundleShortVersionString` with the numeric part only (`0.1.1` for `0.1.1-beta.2`; Apple allows only `X.Y.Z` there) and `CFBundleVersion` with `--build N`, which `release-from-tag.sh` sets to the workflow's run number. The `-beta.N` lives in the tag, the DMG's name and the release title.
- **The self-check:** in the existing in-DMG step (the image already attached read-only for Gatekeeper), `release.sh` reads the app's `CFBundleShortVersionString` and `CFBundleVersion` from the copy inside the image; they must equal the short version and the build number it was given, else `release: the app in the DMG says <v> (build <n>), expected <v'> (build <n'>)`, exit 1. This runs after notarization but before `release-from-tag.sh` uploads anything to GitHub.

### 3. Fail fast: time limits

- `release.yml`: `timeout-minutes` on each test step (`Build the tests` 15, each `Test` step 20). A hang then fails the job in minutes, before the keychain step, and the step's log ends where it stopped.
- Swift Testing time limits on the suites that drive processes and real disk images (the `NoctuleCLIIntegrationTests` suites, `NoctuleMockScannerTests`), at suite level (`.timeLimit(.minutes(N))`, inherited by their tests), so a stuck test fails by name. N is the builder's, from local timings with a wide margin (Swift Testing counts whole minutes). If Swift Testing offers a single default for the whole run, that is preferred.

### 4. Marking runner flakes: `.skippedOnCIRunner(_:)`

- One trait, `.skippedOnCIRunner(_ reason: Comment)`: `.disabled(if: <NOCTULE_CI_RUNNER set and non-empty>, reason)`. Defined once if a module every test target can import may import `Testing`; otherwise one identical small copy per test target that needs it, each pinned by a test that it disables only when the variable is set.
- `release.yml` sets `NOCTULE_CI_RUNNER: "1"` in the job's `env:`, and drops `--skip pushUpdatesAreStampedOnArrival` (the trait replaces it). The second test step (the four timing-sensitive suites, one at a time) stays: those suites pass alone, so they are kept, not skipped.
- Marked now, each with its reason: `ScannerClientTests/pushUpdatesAreStampedOnArrival` (a 70–130 ms window), `StationRunnerTests/neverLeavesAHitInProgressUnrecorded` (reads the mock before it has taken in the final `PSI,0`), `MockPersonalityTests/pushesGoToTheSubscribingPeer` (failed under the runner's parallel load). Each gets a follow-up line in LESSONS.md or the plan's Results, not a fix here.
- `ReleaseWorkflowTests` follow: the job sets `NOCTULE_CI_RUNNER`; no `--skip` of a single test remains; every test step has `timeout-minutes`.

### 5. Finding the hang

A throwaway branch with its own `probe.yml` (as Plan 14's Task 1: triggered by a push to that branch, never merged; `release.yml`'s trigger is not touched; no secrets reach it) runs copies of the release workflow's test steps with §3's time limits, up to three times. Whichever test the time limit names is then:
- **a test-harness problem** (a helper waiting forever on a subprocess or a mount): fixed in the test, or marked with `.skippedOnCIRunner` and a follow-up, the builder's call recorded as a ruling;
- **a product problem** (e.g. `noctule listen` not exiting on a signal under load): **stop and report to the owner** before changing product code. `listen` must always TEARDOWN; a hang there matters on hardware. The rest of this plan doesn't depend on the probe and may be built and merged meanwhile; the product fix becomes its own change. The next beta tag waits until the hang is explained (fixed, or marked with a reason the owner accepts), since a time-limited failure still fails the release.

If three runs show no hang, record that, keep the time limits, and go on.

### 6. Docs

- `packaging/README.md`: "Cutting a release" leads with `cut-release.sh` (kinds, the version table, what it checks, the prompt, following the run, Ctrl-C); the manual `git tag` route stays as a fallback; `release.sh --untagged`; the CI skip trait and time limits under the runner notes.
- `AGENTS.md`: agents never run `cut-release.sh` (nor push a `v` tag); new tests that can't run reliably on CI runners take `.skippedOnCIRunner("<reason>")`, never a workflow `--skip`.
- `LESSONS.md`: the first tag's hang and flakes (what happened, what to do).

## Constraints

- Plan 14's rules stand: no secret printed or tracked; tags `v*` only from admins; the `release` environment; agents never push a `v` tag, create or publish a release, or run the workflow's signing steps. The probe branch is pushed with the owner's go-ahead (given for this plan, 2026-11-14).
- `export NOCTULE_NO_USB_DETECTION=1` wherever tests run.
- File names lower case, no spaces.

## Decisions

**The owner's:** one command run against `main` that tags and starts the release (2026-11-14); help automating semantic versions; keep the versions in sync; fold the time limits, the CI skip trait and the hang probe into this plan; PR automation later (Plan 16).

**The controller's (the owner can overrule):** approach A; the tag as the only version source and `release.sh --untagged`; no way to skip the local test run; `beta` refused after a final; only `-beta.N` pre-releases; `NOCTULE_CI_RUNNER` as the variable's name; the version self-check inside the DMG; `v0.1.1-beta.1` left as a tag without a release (the next beta is `-beta.2`).

Also the controller's, from the builder check: a plain local `swift test` (no CI split, no retry); unreadable `v` tags warned about and ignored; a run not found within 2 minutes leaves the tag pushed and exits 1; the plan may merge with the hang unexplained, but no beta is tagged until it is explained.

**Left to the builder:** where the skip trait lives; the time limits' values; how tests drive the prompt and the fake remote; exact wording of messages not quoted above.
