# Plan 15: cutting a release with one command

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. This repo's rules (AGENTS.md) apply on top. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** the owner runs `packaging/cut-release.sh beta` (or `final`, `patch`, `minor`, `major`, with `--beta`) on `main`, and it computes the next version from the latest `v` tag, tests, asks once, tags, pushes and follows the release workflow to the draft; the tag is the only source of a release's version; and the release run fails fast instead of hanging.

**Architecture:** a new bash script, `packaging/cut-release.sh`, beside Plan 12–14's scripts, calling `git`, `swift` and `gh` by name (tests stub `swift` and `gh`, and use a fake repository with a bare `origin`). `release.sh` gains a tag requirement (`--untagged` to opt out) and a version self-check inside the finished DMG. Tests get one trait, `.skippedOnCIRunner(_:)`, in `NoctuleKitTestSupport`; `release.yml` sets `NOCTULE_CI_RUNNER` and time limits. A probe on a throwaway branch finds the hang seen on the first tag.

**Tech Stack:** bash, git, `gh`, GitHub Actions, Swift Testing (`ConditionTrait`, `TimeLimitTrait`).

**Spec:** `docs/specs/2026-11-14-release-manager-design.md` (owner-approved 2026-11-14). Plan 14 (`docs/specs/2026-11-14-plan-14-release-from-tag.md`) built what this extends.

## Global Constraints

- Usage: `packaging/cut-release.sh beta | final | patch [--beta] | minor [--beta] | major [--beta]`; anything else usage, exit 2.
- Versions: only `vX.Y.Z` and `vX.Y.Z-beta.N` are read or made; the latest is the highest by semantic-version precedence among the tags on `origin` (`git ls-remote --tags origin`, so a tag made only locally never counts); none means `v0.0.0`; unreadable `v` tags: `cut-release: ignoring tags it can't read: <tags>` and ignored.
- The version table, refusals and messages are the spec's §1, verbatim.
- Checks in the spec's order: branch `main`, clean tree, `git fetch origin main --tags`, local `main` = `origin/main`, tag absent on `origin` and locally (a local-only one: `cut-release: v<next> exists locally but not on GitHub; delete it with git tag -d v<next>`, exit 1), no release (`gh release view`, "release not found" handling as `release-from-tag.sh`), then `NOCTULE_NO_USB_DETECTION=1 swift test` to `build/cut-release-test.log`. Nothing to skip it.
- Prompt (standard input): `Tag <short sha> (<subject>) as v<next> (latest v<latest>) and push it? This starts the release workflow, which uploads the app to Apple for notarization. [y/N]`; anything but `y`/`yes` → `cut-release: nothing tagged`, exit 1.
- Tag: `git tag -a v<next> -m "Noctule Scan <next>"`; `git push origin v<next>`; a failed push deletes the local tag, exit 1.
- `release.sh`: `HEAD` must carry `v<version>`, else `release: HEAD isn't tagged v<version>; cut releases with packaging/cut-release.sh (or pass --untagged to try a release locally)`, exit 1, before anything is built; `--untagged` names the DMG `build/noctule-scan-<version>-untagged.dmg`. Self-check message: `release: the app in the DMG says <v> (build <n>), expected <v'> (build <n'>)`.
- `NOCTULE_CI_RUNNER`: set (non-empty) only by workflows; the trait disables a test only then.
- Plan 12–14 script rules: `#!/bin/bash`, `set -euo pipefail`, mode 100755, paths quoted, usage 2 / failures 1, tools by name; no `set -x`; no secret printed.
- **Agents never run `cut-release.sh`, push a `v` tag, or create or publish a release.** Tests run it only in fake repositories with stub `swift` and `gh`. The probe branch (Task 3) is pushed under the owner's go-ahead for this plan (2026-11-14).
- `export NOCTULE_NO_USB_DETECTION=1` in every shell that runs tests. File names lower case, no spaces.

## Review Focus

1. **Ctrl-C during the local test run** (6 minutes is long): nothing tagged, exit 130, no stray tag. Pinned in Task 5 (`interruptDuringTestsTagsNothing`).
2. **A push the remote refuses** (the ruleset, a network error): the local tag must not stay behind to confuse the next run. Pinned in Task 5 (`refusedPushRemovesTheLocalTag`).
3. **The prompt answered by EOF or an empty line** (run from a pipe, or Return pressed): nothing tagged. Pinned in Task 5 (`emptyAnswerTagsNothing`).
4. **Version precedence beyond one digit** (`v0.10.0` vs `v0.9.0`, `beta.10` vs `beta.9`, a final above its betas): the next version must come from the true latest. Pinned in Task 5 (`latestIsByPrecedence`).
5. **The workflow run isn't found** (Actions slow, or two runs): the tag stays pushed, the owner gets the Actions URL, exit 1. Pinned in Task 5 (`runNotFoundLeavesTheTagAndPointsAtActions`).

---

### Task 1: `.skippedOnCIRunner(_:)` and the three known flakes

**Files:**
- Create: `Sources/NoctuleKitTestSupport/CIRunner.swift`
- Modify: `Package.swift` (`NoctuleStoreTests` and `NoctuleMockScannerTests` gain `NoctuleKitTestSupport`), `Tests/NoctuleKitTests/ScannerClientTests.swift`, `Tests/NoctuleStoreTests/StationRunnerTests.swift`, `Tests/NoctuleMockScannerTests/MockPersonalityTests.swift`, `.github/workflows/release.yml`
- Test: `Tests/NoctuleKitTests/CIRunnerTraitTests.swift`; `ReleaseWorkflowTests` in `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift`

**Interfaces:**
- Produces: `public func isCIRunner(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool` (true when `NOCTULE_CI_RUNNER` is set and non-empty) and `extension Trait where Self == ConditionTrait { public static func skippedOnCIRunner(_ reason: Comment) -> Self }` (`.disabled(if: isCIRunner(), reason)`). If `NoctuleKitTestSupport` can't import `Testing`, put the same two in a file per test target that needs them, and say so in the report.

- [ ] **Step 1: Failing tests.** `CIRunnerTraitTests`: `unsetIsNotARunner` (`isCIRunner([:]) == false`), `emptyIsNotARunner` (`["NOCTULE_CI_RUNNER": ""]` → false), `setIsARunner` (`"1"` → true). `ReleaseWorkflowTests`: `jobMarksTheCIRunner` (job `env:` has `NOCTULE_CI_RUNNER: "1"`); `noSingleTestIsSkipped` (no `--skip` in any `run:` except the four suite names of the first test step); update `testsCoverEverySuite` (the second step has no `--skip`).
- [ ] **Step 2:** `swift test --filter "CIRunnerTraitTests|ReleaseWorkflowTests"` fails.
- [ ] **Step 3:** Write `CIRunner.swift`; add the dependencies; mark `pushUpdatesAreStampedOnArrival` (`"70–130 ms window; too tight on the 3-core CI runner"`), `neverLeavesAHitInProgressUnrecorded` (`"reads the mock before it has taken in the final PSI,0; flaked on the CI runner"`), `pushesGoToTheSubscribingPeer` (`"failed under the CI runner's parallel load"`); in `release.yml` add `NOCTULE_CI_RUNNER: "1"` to the job `env:` and drop `--skip pushUpdatesAreStampedOnArrival`.
- [ ] **Step 4:** The filter passes; `NOCTULE_CI_RUNNER=1 swift test --filter "pushUpdatesAreStampedOnArrival|neverLeavesAHitInProgressUnrecorded|pushesGoToTheSubscribingPeer"` reports all three skipped with their reasons; without the variable they run and pass.
- [ ] **Step 5: Commit** `test: skippedOnCIRunner, and the three runner flakes marked`.

### Task 2: Time limits

**Files:**
- Modify: `.github/workflows/release.yml`; the `@Suite` declarations of every suite in `Tests/NoctuleCLIIntegrationTests/` and `Tests/NoctuleMockScannerTests/`
- Test: `ReleaseWorkflowTests`

- [ ] **Step 1: Failing test** `testStepsHaveTimeLimits`: `Build the tests` has `timeout-minutes: 15`; both `Test` steps `timeout-minutes: 20`.
- [ ] **Step 2:** It fails.
- [ ] **Step 3:** Add the step limits. Add `.timeLimit(.minutes(N))` to each suite in those two targets (on the outermost `@Suite` where suites nest, e.g. `DiskImageTests`): N = the longest test's local time in that suite, ×3, rounded up to whole minutes, at least 1; list each suite's N and its measured basis in the report. If Swift Testing offers one default limit for a whole run (an environment variable or `swift test` option), use that in the workflow's test steps instead and say so.
- [ ] **Step 4:** `swift test --filter ReleaseWorkflowTests` passes; the full `swift test` passes locally (the limits must not trip on the owner's Mac).
- [ ] **Step 5: Commit** `ci: time limits on the release run's tests`.

### Task 3: Find the hang (controller, with the owner's go-ahead given 2026-11-14)

**Files:** a throwaway branch `probe/release-hang` with `.github/workflows/probe.yml` (never merged); this plan's Results.

- [ ] **Step 1:** From this branch's HEAD (Tasks 1–2 in), `probe.yml`: `on: push: branches: [probe/release-hang]`, `runs-on: xcode-27`, `permissions: contents: read`, job `env:` `NOCTULE_NO_USB_DETECTION: "1"`, `NOCTULE_CI_RUNNER: "1"`, `NOCTULE_PYTHON: /opt/homebrew/bin/python3`; steps copied from `release.yml` up to and including the two test steps (with their `timeout-minutes`), nothing after. No `environment:`, no secrets.
- [ ] **Step 2:** Push; watch; save each log to the ledger directory. Up to three runs (push an empty commit to re-run).
- [ ] **Step 3:** For a test the time limit names: a test-harness cause → fix it in a task-sized change (failing test first where possible) or mark it with `.skippedOnCIRunner("<reason>")`, a `Ruling:` either way. A product cause (e.g. `noctule listen` not exiting on a signal) → **stop and report to the owner**; Tasks 4–6 continue. A new flake → mark it, with its reason. No hang in three runs → record it.
- [ ] **Step 4:** Delete the branch (remote and local). Results: each run's outcome, timings, what was found and done. Commit `docs: Plan 15 hang probe`.

### Task 4: `release.sh` takes its version from a tag, and checks the DMG's app

**Files:**
- Modify: `packaging/release.sh`
- Test: `ReleaseTests` and `ReleaseFromTagTests` in `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (the fake repository is tagged where a release is expected to go through, with the existing `tagHead`)

**Interfaces:**
- Produces: `release.sh <version> [--build N] [--allow-dirty] [--untagged]`; the tag check runs after argument parsing and the dirty-tree check, before `notarize.sh --check`.

- [ ] **Step 1: Failing tests:** `untaggedHeadIsRefused` (no tag → exit 1, the message, no `build` call); `wrongTagIsRefused` (`HEAD` tagged `v0.1.9`, version `0.2.0` → refused); `untaggedFlagMarksTheDMG` (`--untagged`, no tag → exit 0, `build/noctule-scan-0.2.0-untagged.dmg`, no `noctule-scan-0.2.0.dmg`); `versionInsideTheDMGIsChecked` (a full tagged run; the DMG's app says `0.2.0` and build `12` and the run passes); `wrongVersionInsideTheDMGFails` (a `plutil` stub on PATH: with `STUB_PLUTIL_NOOP` set it ignores `-replace` and passes everything else to `/usr/bin/plutil`, so the app keeps `0.0.0` / `0` → exit 1 with the self-check message, no `release:` DMG line). Existing `ReleaseTests` that expect success tag `HEAD` first; `ReleaseFromTagTests` already tag it.
- [ ] **Step 2:** `swift test --filter "ReleaseTests|ReleaseFromTagTests"` fails as expected.
- [ ] **Step 3:** Implement in `release.sh`: the `--untagged` flag; the tag check (`git -C "$root" tag --points-at HEAD` contains `v$version` exactly); the DMG name; in the in-DMG step, `plutil -extract CFBundleShortVersionString raw` and `CFBundleVersion` from `"$mnt/Noctule Scan.app/Contents/Info.plist"`, compared with `$short_version` and `$build_number`. Update the header comment.
- [ ] **Step 4:** The filter passes, and `MakeDMGTests` and `NotarizeTests` still do.
- [ ] **Step 5: Commit** `packaging: release.sh takes its version from a tag and checks the DMG's app`.

### Task 5: `packaging/cut-release.sh`

**Files:**
- Create: `packaging/cut-release.sh`, `Tests/NoctuleCLIIntegrationTests/CutReleaseTests.swift`
- Modify: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (make `runScript`, `StubTools`, `fakeRepository`, `tagHead`, `repositoryFile` internal instead of `private`, so the new file can use them; `runScript` gains `input: String? = nil` for standard input if it lacks one; `StubTools` gains a `swift` stub and grows the `gh` stub)

**Interfaces:**
- Consumes: Plan 14's `gh` stub (`release view` exit `STUB_GH_VIEW_STATUS`, stderr `STUB_GH_VIEW_STDERR`, default `release not found`).
- Produces (test support): `swift` stub: records `swift <args>`, sleeps `STUB_SWIFT_SLEEP` seconds if set, exits `STUB_SWIFT_STATUS` (default 0), writing `Test run with 1 tests passed` (or `failed`). `gh` stub additions: `run list …` prints `STUB_GH_RUNS` (JSON; default one run, `databaseId` 4242, `headBranch` the tag, `url` `https://example.invalid/runs/4242`); `run watch <id> --exit-status` exits `STUB_GH_WATCH_STATUS` (default 0); `release view <tag> --json url,assets` prints `{"url":"https://example.invalid/releases/<tag>","assets":[{"name":"noctule-scan-<v>.dmg"},{"name":"noctule-scan-<v>.dmg.sha256"}]}` when `STUB_GH_DRAFT` is set (the view-before-tagging call still returns "not found"). A helper `releaseRepository(tags: [String])` makes the fake repository a clone of a bare `origin` (in the test directory) on `main`, with the given tags pushed to `origin`.

- [ ] **Step 1: Failing tests** (each answers the prompt through standard input; `STUB_LOG` checked for what ran):
  - `nextVersionTable` (parameterized, answering `n`; the prompt line names `v<next> (latest v<latest>)`): `[v0.1.1-beta.1] beta → v0.1.1-beta.2`; `[v0.1.1-beta.1] final → v0.1.1`; `[v0.1.1] patch → v0.1.2`; `[v0.1.1] patch --beta → v0.1.2-beta.1`; `[v0.1.1] minor → v0.2.0`; `[v0.1.1] major --beta → v1.0.0-beta.1`; `[] minor → v0.1.0`; `[] patch --beta → v0.0.1-beta.1`.
  - `refusedKinds` (exit 1, the spec's messages, no `swift` call): `beta` after `v0.1.1`; `final` after `v0.1.1`; `patch`, `minor`, `major` after `v0.1.1-beta.1`.
  - `latestIsByPrecedence`: tags `v0.9.0, v0.10.0` → `patch` gives `v0.10.1`; `v0.2.0-beta.9, v0.2.0-beta.10` → `beta` gives `v0.2.0-beta.11`; `v0.2.0-beta.3, v0.2.0` → `patch` gives `v0.2.1`.
  - `unreadableTagsAreWarnedAbout`: `v0.1.1-rc.1, vfoo, v0.1.0` → the warning names `v0.1.1-rc.1 vfoo`; latest `v0.1.0`.
  - `refusesOffMain`, `refusesADirtyTree`, `refusesBehindOrAhead` (a commit on `origin/main` not local; a local commit not pushed), `refusesALocalOnlyTag` (`origin` has `v0.1.1-beta.1`; `v0.1.1-beta.2` exists only locally → `beta` refused with the local-only message), `localTagsDontCount` (a local-only `v9.0.0` → `patch` after `origin`'s `v0.1.1` still proposes `v0.1.2`), `refusesAnExistingRelease` (`STUB_GH_VIEW_STATUS=0`), `stopsOnAnyOtherGhError`: each exit 1 before `swift`, nothing tagged.
  - `failingTestsTagNothing` (`STUB_SWIFT_STATUS=1`): exit 1, the log path `build/cut-release-test.log` named, no tag locally or on `origin`. `swift` was called as `swift test` with `NOCTULE_NO_USB_DETECTION=1` in its environment (the stub records it).
  - `emptyAnswerTagsNothing` (input `""`) and EOF (no input): `cut-release: nothing tagged`, exit 1, no tag.
  - `interruptDuringTestsTagsNothing`: `STUB_SWIFT_SLEEP=5`, send SIGINT to the script's process after 1 s → exit 130, no tag.
  - `yesTagsPushesAndFollowsTheRun` (input `y`, `STUB_GH_DRAFT=1`): exit 0; `origin` has annotated tag `v0.1.1-beta.2` (`git cat-file -t` → `tag`, message `Noctule Scan 0.1.1-beta.2`) on `main`'s commit; stdout has the run URL, the draft URL and both asset names, and `Check it, write the notes, then publish it.`
  - `refusedPushRemovesTheLocalTag`: `origin`'s `hooks/pre-receive` exits 1 → exit 1, no local tag.
  - `runNotFoundLeavesTheTagAndPointsAtActions` (`STUB_GH_RUNS=[]`, poll shortened by `CUT_RELEASE_POLL_SECONDS=0.1` and `CUT_RELEASE_POLL_LIMIT=3`; both honoured only for tests, defaulting to 5 and 24): exit 1, tag on `origin`, stdout names `https://github.com/noctule-dev/noctule-scan/actions` (or the URL `gh` derives: the builder's call, documented); also with two runs listed.
  - `failedRunIsReported` (`STUB_GH_WATCH_STATUS=1`): exit 1, a line pointing at `packaging/README.md`; nothing retried (one `gh run watch`).
  - `refusesBadArguments`: none, `beta extra`, `patch --rc`, `--beta`, `final --beta` → exit 2.
- [ ] **Step 2:** `swift test --filter CutReleaseTests` fails (the script is missing).
- [ ] **Step 3:** Write `cut-release.sh` (`chmod 755`) to the spec's §1 and this plan's Global Constraints. The version comparison is the one algorithm the tests don't fully determine: compare major, minor, patch numerically; a final outranks its own betas; betas compare by N numerically. Ctrl-C during `gh run watch` prints `cut-release: the release run goes on: <url>` and exits 130 (the builder adds a test if one is practical).
- [ ] **Step 4:** The filter passes; `ReleaseTests`, `ReleaseFromTagTests` still pass.
- [ ] **Step 5: Commit** `packaging: cut-release.sh, a release with one command`.

### Task 6: Documentation

**Files:** `packaging/README.md`, `AGENTS.md`, `LESSONS.md`

- [ ] **Step 1:** README: "Cutting a release" leads with `cut-release.sh` (the kinds, the version table, the checks, the prompt, following the run, Ctrl-C, what to do when the run isn't found or fails); the manual `git tag` route as a fallback; `release.sh` needs a tag, `--untagged` for local tries; the runner notes gain `NOCTULE_CI_RUNNER`, `.skippedOnCIRunner`, the time limits. AGENTS.md: agents never run `cut-release.sh`; tests that can't run reliably on CI runners take `.skippedOnCIRunner("<reason>")`, never a workflow `--skip`; the Build and test bullet mentions `NOCTULE_CI_RUNNER`. LESSONS.md: 2026-11-14, the first tag's hang and flakes, and what Task 3 found.
- [ ] **Step 2:** `swift test --filter RealNamesTests` passes. **Step 3: Commit** `docs: cutting a release`.
- [ ] **Step 4:** Final whole-branch review (most capable model), one fix wave, the full `swift test`, then push and PR with the owner's go-ahead; the owner merges. The next beta (`cut-release.sh beta` → `v0.1.1-beta.2`) is the owner's, once the hang is explained (spec §5).

## Results

### Task 3: the hang probe (2026-11-15 UTC)

Branch `probe/release-hang` (from 52e6b46, Tasks 1–2 in; `probe.yml` on `xcode-27`, the release workflow's test steps with their time limits, the second step marked `if: always()` so both report; no environment, no secrets), pushed under the owner's go-ahead and deleted afterwards. Three runs:

| Run | Test (parallel) | Timing-sensitive step | Found |
|---|---|---|---|
| 43662027291 | passed, 6 m 44 s | failed, 53 s | `KeepAliveOnTheMock/passesWhenKALRestartsTheLifetime` (10 pushes, 5 `KAL`s) |
| 43662867890 | failed, 7 m 00 s | failed, 53 s | `RTSPClientTests/closeWaitsForTheTeardownWorker` (line 907); the `KAL` test again |
| 43663640001 | failed, 6 m 56 s | failed, 54 s | `SerialTransportTests/noDrainAfterTheDeviceWentAway` (`close()` over 100 ms); the `KAL` test again |

- **No hang in three runs.** Every step finished well within its limit, and no suite time limit tripped; the slowest test on the runner took 30 s (`changedRequirementsRebuildTheEnvironment`). The first tag's 66-minute stall (run 43652944695, at 83d1f15) wasn't reproduced, so its cause is still unknown. The time limits stay: if it happens again, the run fails within 20 minutes and names the test.
- **Three new runner flakes, all test timing, none product code**, marked with `.skippedOnCIRunner` (d565cad): the `KAL` test (real-clock 50 ms pushes and 150 ms `KAL`s; the runner delivered about half, in three of three runs, even one test at a time), `closeWaitsForTheTeardownWorker` (250 ms `TEARDOWN` replies against a 300 ms timeout), and `noDrainAfterTheDeviceWentAway` (a 100 ms bound on `close()`). All three still run and pass on a developer Mac.
- Ruling: three timing flakes marked rather than fixed — the spec defers root-cause fixes of flakes to follow-ups — if wrong, the release run loses three timing checks it never passed reliably anyway.
- Follow-ups: `passesWhenKALRestartsTheLifetime` disagrees with itself (`keepAlives` 5–8 at line 1078 but at least 7 `KAL`s at line 1088); each of the six marked tests wants a timing-independent rewrite.
