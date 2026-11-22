# Plan 21: Taking Noctule Scan public — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make `noctule-dev/noctule-scan` ready to go public under Apache 2.0: brand art out of the repo (pulled in only by the official release), contributor docs, a pull-request build behind the README's badges, source-file notices, and a fresh public history.

**Architecture:** One sourced shell helper (`scripts/branding.sh`) decides which art a build uses: the folder `NOCTULE_BRANDING_DIR` names (from the environment or the git-ignored `config/branding.env`), else committed placeholder art. `compile-app-icon.sh` and `make-dmg.sh` consume it; `release.sh` refuses an official release without it; `release.yml` checks the art out of the private design-language repo at a pinned commit. Everything else is files: legal and community docs, a new `ci.yml`, and Swift tests that keep the repo clean (notices, no brand files, no roadmap words, no unsafe workflow triggers).

**Tech Stack:** Bash scripts, Swift Testing (`Tests/NoctuleCLIIntegrationTests`), GitHub Actions on `xcode-27`, `gh`, Icon Composer `.icon` + `actool`, CoreGraphics for the placeholder background, dmgbuild (unchanged).

**Spec:** `docs/specs/2026-11-20-open-source-prep-design.md` (owner-approved 2026-11-20). Read it with this plan; section numbers below are its.

## Global Constraints

- License: Apache License 2.0, unmodified text. Copyright holder: Sean Foley. `NOTICE` says "Copyright 2026 Sean Foley".
- Source notice, exactly (comment syntax per language): `SPDX-License-Identifier: Apache-2.0` then `Copyright 2026 Sean Foley and the Noctule Scan contributors`. Year stays 2026.
- Brand: "Noctule", "Noctule Scan", any other product name beginning "Noctule", the Noctule mark and the app icons are the owner's, not Apache-licensed. `images/screenshots/` stays, all rights reserved, under its own `LICENSE.md`.
- **No product-roadmap references anywhere in the repo** (owner, 2026-11-20): no other editions of the app, no other Noctule products, no plans to sell; also no owner home paths and no links to private claude.ai pages. The words are listed only in the git-ignored `config/private-words.txt` (already on the owner's Mac; like `config/real-names.txt`, publishing the list would publish the words). Read it before writing anything; `PrivateWordsTests` (Task 8) checks every tracked text file against it. **A worktree doesn't get git-ignored files: copy `config/*.txt` and `config/*.env` into it.**
- **Plan decision (departs from design §6.4's "a test"):** the check is a deny-list test like `RealNamesTests`, skipped where the list is absent (CI, contributors), because a list inside a tracked test would itself publish the words.
- Placeholder icon is candidate A, "Signal on graphite": grey squircle, gradient top `#8b939b` to bottom `#5b636b`, white antenna, dot and three white arcs fading upward. No night blue, bat, amber or wordmark.
- Placeholder installer background: 640 × 400 pt (images 640×400 and 1280×800), light grey vertical gradient, dotted grey arrow from (170, 214) toward (470, 214), "Drag the app to Applications to install it." near the bottom. Window layout (`packaging/dmg/settings.py`) unchanged.
- Contributor builds keep the name Noctule Scan, bundle ID `app.noctule.scan` and the shared data folders. Only the icon and installer art differ.
- Contributions: DCO sign-off (`Signed-off-by:`), checked in CI on pull requests. No CLA.
- `NOCTULE_BRANDING_DIR` semantics: set and non-empty = that folder; **set and empty = placeholder, and `config/branding.env` is not read** (tests rely on this); unset = read `config/branding.env`, else placeholder.
- Branding folder shape (design §4.2): `AppIcon.icon/`, `dmg/background.tiff`, `dmg/render-background.swift`, `dmg/noctule-mark-on-dark.svg`, `dmg/fonts/`, `README.md`. Lives at `builds/noctule-scan/` in `noctule-dev/noctule-design-language`.
- Workflows: actions pinned by commit SHA (reuse `release.yml`'s `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`); no `pull_request_target`; PR jobs get `permissions: contents: read` and no secrets or `environment`.
- AGENTS.md rules still bind every task: `export NOCTULE_NO_USB_DETECTION=1` in every shell that runs `noctule` or tests; agents never create, read or print secrets, push `v` tags, run `cut-release.sh`, `release.sh` or `notarize.sh` for real, or change the owner's account settings; tests never open a real port, scanner or audio input.
- Owner checkpoints are marked **[owner]**. Do not perform them; stop and ask.

## Review Focus

1. **The owner's own `config/branding.env` leaking into tests.** On the owner's Mac that file exists, so any test that runs `compile-app-icon.sh`, `make-dmg.sh`, `build-app.sh` or `release.sh` without setting `NOCTULE_BRANDING_DIR` would use the real art and pass or fail for the wrong reason. Expected: every such test sets it (empty, or a stub folder). Pinned by `runScriptDefaultsToThePlaceholder` (Task 1) and the shared helper default.
2. **A malformed branding folder.** A path that exists but lacks `AppIcon.icon` or `dmg/background.tiff` (a wrong checkout, the repo root instead of `builds/noctule-scan`). Expected: the script fails with the folder named, never silently falls back to the placeholder. Pinned by `brandingFolderMissingPartsFails` (Task 1).
3. **Relative paths in `config/branding.env`.** The owner writes `../noctule-design-language/builds/noctule-scan`; scripts run from any working directory. Expected: resolved against the repo root, not the caller's directory. Pinned by `relativeBrandingPathResolvesFromTheRoot` (Task 1).
4. **A release with stale art.** The owner's local checkout of the design-language repo is on a different commit than `packaging/branding-ref`. Expected: `release.sh` warns, naming both commits, and goes on. Pinned by `releaseWarnsWhenTheArtIsntThePinnedCommit` (Task 3).
5. **A DCO trailer that doesn't match its commit.** A sign-off for another name or email, or a merge commit in the PR. Expected: mismatch fails naming the commit; merge commits are skipped. Pinned by `dcoRejectsAMismatchedSignOff` and `dcoSkipsMergeCommits` (Task 6).

---

## Phase A: on a branch of the current repo (nothing public changes)

Work on `docs/open-source-prep` (it holds the design and two doc commits). Commit after each task with the session's attribution trailers and `-s`.

### Task 1: The branding switch and the placeholder icon

**Files:**
- Create: `scripts/branding.sh`
- Create: `Resources/Placeholder/AppIcon.icon/` (`icon.json`, `Assets/00-background.svg`, `Assets/01-signal.svg`)
- Create: `config/branding.env.example`
- Modify: `scripts/compile-app-icon.sh` (default icon from the switch)
- Modify: `scripts/build-app.sh` (header comment only)
- Modify: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`runScript` default env)
- Modify: `Tests/NoctuleCLIIntegrationTests/AppIconTests.swift` (compile tests pass `NOCTULE_BRANDING_DIR`)
- Create: `Tests/NoctuleCLIIntegrationTests/BrandingTests.swift`

**Interfaces:**
- Produces: `scripts/branding.sh`, sourced (never executed), defines `noctule_branding <repo-root>`: sets the shell variable `branding_dir` to an absolute path or the empty string (placeholder), prints exactly one line to stderr: `branding: <absolute path>` or `branding: placeholder (set NOCTULE_BRANDING_DIR for the official art)`; on a bad folder prints `branding: <path> isn't a branding folder (it needs AppIcon.icon and dmg/background.tiff)` and returns 1. `config/branding.env` is parsed as `KEY=VALUE` lines (`#` comments, optional surrounding quotes), never `source`d.
- Produces: helper `stubBrandingFolder(in: URL) throws -> URL` in `BrandingTests.swift` (internal, reused by Tasks 2–3): a folder with `AppIcon.icon` (a copy of the placeholder's) and `dmg/background.tiff` (two images, 640×400 and 1280×800, solid `#FF00FF`).
- Produces: `runScript` (PackagingTests.swift) defaults `NOCTULE_BRANDING_DIR` to `""`; a caller's own value wins.
- The placeholder is named `AppIcon.icon` because `actool` names the compiled icon after the file and `Info.plist` says `AppIcon`.

- [x] **Step 1: Write the failing tests** in `BrandingTests.swift` (run `scripts/compile-app-icon.sh` in a temporary tree copied from the repo, as `failsWhenInfoPlistNamesAnotherIcon` does, so a `config/branding.env` can be planted):
  - `emptyVariableMeansPlaceholder`: tree has a `config/branding.env` pointing at a stub folder; run with `NOCTULE_BRANDING_DIR=""`; stderr contains `branding: placeholder (set NOCTULE_BRANDING_DIR for the official art)`; status 0; output `AppIcon.icns` exists.
  - `variableNamesTheFolder`: `NOCTULE_BRANDING_DIR=<stub>`; stderr contains `branding: <stub absolute path>`.
  - `configFileIsReadWhenTheVariableIsUnset`: no variable (remove it from the environment), `config/branding.env` = `NOCTULE_BRANDING_DIR="<stub>"`; stderr names the stub.
  - `relativeBrandingPathResolvesFromTheRoot`: `config/branding.env` holds a path relative to the tree root; run with the current directory set elsewhere; stderr names the resolved absolute path.
  - `brandingFolderMissingPartsFails`: a folder with only `AppIcon.icon`; status 1; stderr contains `isn't a branding folder (it needs AppIcon.icon and dmg/background.tiff)`; no `AppIcon.icns` written.
  - `configFileIsNotExecuted`: `config/branding.env` contains `NOCTULE_BRANDING_DIR=$(touch <marker>)`; the marker file is never created.
  - `runScriptDefaultsToThePlaceholder`: `runScript("scripts/compile-app-icon.sh", [out])` with no extra env prints the placeholder line.
  - `placeholderIconIsCandidateA`: `Resources/Placeholder/AppIcon.icon/Assets/00-background.svg` contains `#8b939b` and `#5b636b` (case-insensitive) and none of `bat`, `#f5a83a`, `#1d2648`; neither SVG mentions `c2pa`.
- [x] **Step 2: Run them; expect failures** (`swift test --filter BrandingTests`; the script and placeholder don't exist).
- [x] **Step 3: Write `scripts/branding.sh`** with `noctule_branding` as specified above. The root argument is the repository root; relative values are resolved against it.
- [x] **Step 4: Make the placeholder icon** at `Resources/Placeholder/AppIcon.icon`, with `icon.json` in the same shape as today's `Resources/AppIcon.icon/icon.json` (two groups: `signal` with `01-signal.svg`, glass true; `background` with `00-background.svg`, glass false), full-bleed 1024×1024 SVG layers, drawn per the global constraint and the mockup's geometry (arcs centred above a dot at about (512, 528) on 1024, stroke ≈ 48, opacities 0.95/0.75/0.5, antenna down to ≈ 800).
- [x] **Step 5: Change `compile-app-icon.sh`'s default** from `Resources/AppIcon.icon` to: source `scripts/branding.sh`, call `noctule_branding "$root"` (exit on failure), use `$branding_dir/AppIcon.icon` if `branding_dir` is set, else `$root/Resources/Placeholder/AppIcon.icon`. An explicit `[ICON]` argument still wins and skips the switch. Update its usage comment and `build-app.sh`'s header ("the official icon when NOCTULE_BRANDING_DIR names the art, else the placeholder").
- [x] **Step 6: Default `NOCTULE_BRANDING_DIR` to `""` in `runScript`**, and pass `["NOCTULE_BRANDING_DIR": ""]` in `AppIconTests`' `compileIcon` helper and its `Subprocess` call, so the owner's `config/branding.env` can never reach a test.
- [x] **Step 7: Write `config/branding.env.example`**: one comment line saying what it's for (the official art for local builds; the folder is `builds/noctule-scan` in the private design-language repo) and `NOCTULE_BRANDING_DIR=`. `config/*.env` is already git-ignored.
- [x] **Step 8: Run `swift test --filter "BrandingTests|AppIconCompileTests|AppIconBuildScriptTests"`; expect PASS.** `AppIconSourceTests` still checks the real icon and still passes (it moves in Task 4).
- [x] **Step 9: Commit** (`feat: choose the official or placeholder app icon by NOCTULE_BRANDING_DIR`).

### Task 2: The placeholder installer background

**Files:**
- Create: `packaging/dmg/placeholder/render-placeholder-background.swift`
- Create: `packaging/dmg/placeholder/background.tiff` (rendered by the script, committed)
- Modify: `packaging/dmg/make-dmg.sh` (background from the switch)
- Modify: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`MakeDMGTests`, new `PlaceholderBackgroundTests`)

**Interfaces:**
- Consumes: `noctule_branding`, `stubBrandingFolder(in:)` (Task 1).
- Produces: `make-dmg.sh` uses `$branding_dir/dmg/background.tiff` or `packaging/dmg/placeholder/background.tiff`; its usage line and arguments are unchanged; `--prepare` does not call the switch.

- [x] **Step 1: Write the failing tests.**
  - `PlaceholderBackgroundTests.tiffHasBothResolutions`: images `[[640, 400], [1280, 800]]`.
  - `PlaceholderBackgroundTests.isPlainLightGrey`: 1x pixels at (320, 4) and (320, 396) all channels ≥ 0xD8, and every channel within 6 of each other (grey); (20, 214) likewise; no pixel in the image has red > blue + 40 (no amber).
  - `PlaceholderBackgroundTests.rendererReproducesTheCommittedImage`: running `swift packaging/dmg/placeholder/render-placeholder-background.swift <tmp>.tiff` produces images whose pixels equal the committed TIFF's within 2 per channel.
  - `MakeDMGTests.usesThePlaceholderByDefault`: the image's `.background.tiff` bytes equal `packaging/dmg/placeholder/background.tiff`'s; stderr contains `branding: placeholder`.
  - `MakeDMGTests.usesTheBrandingFolderWhenSet`: with `NOCTULE_BRANDING_DIR=<stub>`, the image's `.background.tiff` bytes equal the stub's.
- [x] **Step 2: Run; expect failures.**
- [x] **Step 3: Write the renderer** (CoreGraphics + CoreText, same style as `packaging/dmg/background/render-background.swift`, which you may read for structure): gradient top `#F6F7F8` to bottom `#E9EBED`; dotted line from (250, 214) to (378, 214), stroke `#9AA1A8` width 3, round caps, dash 1 9; chevron (376, 204)–(392, 214)–(376, 224); centred system-font 13 pt text `#7A828A` "Drag the app to Applications to install it." at baseline y = 352 (top-left origin). No fonts committed: use the system font. Render and commit `background.tiff`.
- [x] **Step 4: Change `make-dmg.sh`**: after argument parsing and only when not `--prepare`, source `scripts/branding.sh`, call `noctule_branding "$root"`, pick the background, pass it to `dmgbuild` as `-D background=…`.
- [x] **Step 5: Run `swift test --filter "PlaceholderBackgroundTests|MakeDMGTests"`; expect PASS.**
- [x] **Step 6: Commit** (`feat: placeholder installer background; make-dmg picks the art by NOCTULE_BRANDING_DIR`).

### Task 3: `release.sh` requires the official art

**Files:**
- Create: `packaging/branding-ref` (one line: a 40-hex commit; a placeholder `0000000000000000000000000000000000000000` until Task 4 fills it)
- Modify: `packaging/release.sh`
- Modify: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`ReleaseTests`, `fakeRepository`)

**Interfaces:**
- Consumes: `noctule_branding`, `stubBrandingFolder(in:)`.
- Produces: `release.sh` behaviour: resolves branding right after the tag check and before `notarize.sh --check`. No art and no `--untagged` → `release: no official art: set NOCTULE_BRANDING_DIR (or config/branding.env) to the design-language repo's builds/noctule-scan folder`, exit 1, nothing built or sent. No art with `--untagged` → goes on with the placeholder and names the DMG `noctule-scan-<version>-untagged-unbranded.dmg`. With art, `branding_dir` is exported as `NOCTULE_BRANDING_DIR` to `build-app.sh` and `make-dmg.sh`. When `branding_dir` is inside a git work tree whose `HEAD` differs from `packaging/branding-ref`, it prints `release: warning: the art at <dir> is <head>, not packaging/branding-ref's <ref>` and goes on.
- `fakeRepository` also copies `scripts/branding.sh`; its stub `build-app.sh` logs `env NOCTULE_BRANDING_DIR=${NOCTULE_BRANDING_DIR-unset}`.

- [x] **Step 1: Write the failing tests** in `ReleaseTests` (every existing test gets `NOCTULE_BRANDING_DIR=<stub>` so they keep passing):
  - `releaseWithoutArtIsRefused`: tagged HEAD, `NOCTULE_BRANDING_DIR=""`; status 1; stderr contains the "no official art" line; `stubs.calls()` is empty (no `security`, no build).
  - `untaggedWithoutArtIsMarkedUnbranded`: `--untagged`, empty variable; status 0; `build/noctule-scan-0.2.0-untagged-unbranded.dmg` exists.
  - `artIsPassedToTheBuild`: with a stub folder, the stub log has `env NOCTULE_BRANDING_DIR=<stub>`.
  - `releaseWarnsWhenTheArtIsntThePinnedCommit`: the stub folder is a git repo with one commit; `packaging/branding-ref` in the fake repo holds another SHA; stderr contains `release: warning: the art at`; status 0.
  - `noWarningWhenTheArtIsThePinnedCommit`: same with the ref equal to the stub's `HEAD`; no warning.
- [x] **Step 2: Run; expect failures.**
- [x] **Step 3: Implement in `release.sh`** as specified; update its header comment and usage text (`--untagged` mentions the unbranded name).
- [x] **Step 4: Run `swift test --filter "ReleaseTests|ReleaseFromTagTests"`; expect PASS.**
- [x] **Step 5: Commit** (`feat: release.sh refuses an official release without the official art`).

### Task 4: Move the art to the design-language repo

**Files (this repo):**
- Delete: `Resources/AppIcon.icon/`, `packaging/dmg/background/` (all of it: `background.tiff`, `noctule-mark-on-dark.svg`, `render-background.swift`, `fonts/`)
- Modify: `packaging/branding-ref` (the merged design-language commit)
- Modify: `Tests/NoctuleCLIIntegrationTests/AppIconTests.swift` (drop `AppIconSourceTests`; the compile tests already use the placeholder)
- Modify: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (drop `BackgroundArtTests`; keep its C2PA walk as `nothingInPackagingCarriesC2PA` under `PlaceholderBackgroundTests`)
- Modify: `ACKNOWLEDGMENTS.md` (the Inter Tight section leaves with the font)

**Files (`~/projects/noctule/noctule-design-language`, its own branch and PR):**
- Create: `builds/noctule-scan/AppIcon.icon/`, `builds/noctule-scan/dmg/{background.tiff,render-background.swift,noctule-mark-on-dark.svg,fonts/}`, `builds/noctule-scan/README.md`

- [x] **Step 1: In the design-language repo**, branch `noctule-scan-build-art`, copy the files above byte for byte from this repo's `main`, write `README.md` (what the folder is; that `noctule-scan`'s `scripts/compile-app-icon.sh` and `packaging/dmg/make-dmg.sh` read it through `NOCTULE_BRANDING_DIR`; that `render-background.swift` is run from this folder and writes `dmg/background.tiff`; the Inter Tight OFL notice and credit moved here from `noctule-scan`'s `ACKNOWLEDGMENTS.md`; that the art's design record is `docs/` here). Move this repo's `AppIconSourceTests` checks into a short `builds/noctule-scan/check.sh` (four layers present, no `c2pa` anywhere, `icon.json` lists every layer) and run it. Commit, push, open a PR.
- [x] **Step 2: [owner] Merge the design-language PR.** Then record its merge commit's full SHA.
- [x] **Step 3: Write the SHA into `packaging/branding-ref`.** Verify a local branded build: `NOCTULE_BRANDING_DIR=~/projects/noctule/noctule-design-language/builds/noctule-scan scripts/build-app.sh` prints `branding: …/builds/noctule-scan`; compare `build/Noctule Scan.app/Contents/Resources/AppIcon.icns` with one built from `main` (`cmp`; identical expected, since the source is byte-identical).
- [x] **Step 4: Delete the art from this repo** (the paths above), drop `AppIconSourceTests` and `BackgroundArtTests`, update `ACKNOWLEDGMENTS.md`.
- [x] **Step 5: Run `swift test --filter "AppIcon|PackagingTests|Branding|Placeholder|MakeDMG|Release"`; expect PASS** with no reference to the deleted paths (`git grep -n "Resources/AppIcon.icon\|dmg/background/"` lists only docs, fixed in Task 9).
- [x] **Step 6: Commit** (`chore: move the brand art to the design-language repo`).

### Task 5: The release job checks out the art

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`ReleaseWorkflowTests`)
- Modify: `packaging/README.md` (branding section)

**Interfaces:**
- Consumes: `packaging/branding-ref` (Task 4), the release behaviour (Task 3).
- Produces: two steps placed after "Create the signing keychain" and before "Build, sign, notarize and draft the release": `Read the branding ref` (`echo "ref=$(cat packaging/branding-ref)" >> "$GITHUB_OUTPUT"`, `id: branding`) and `Check out the branding` (`actions/checkout` at the existing pin, `repository: noctule-dev/noctule-design-language`, `ref: ${{ steps.branding.outputs.ref }}`, `ssh-key: ${{ secrets.NOCTULE_BRANDING_DEPLOY_KEY }}`, `path: branding`, `sparse-checkout: builds/noctule-scan`, `persist-credentials: false`). The build step's own `env:` gains `NOCTULE_BRANDING_DIR: ${{ github.workspace }}/branding/builds/noctule-scan`; the test steps don't get it, so tests stay on the placeholder.

- [x] **Step 1: Write the failing tests** in `ReleaseWorkflowTests`: `brandingIsCheckedOutAtThePinnedRef` (the step's lines as above, the same checkout SHA as the first step); `brandingComesAfterTheTestsAndBeforeTheBuild` (step order); `onlyTheBuildStepSeesTheBranding` (`NOCTULE_BRANDING_DIR` appears in exactly one step and not in the job env); extend the secrets list test with `NOCTULE_BRANDING_DEPLOY_KEY`; `brandingRefIsAFullSHA` (`packaging/branding-ref` matches `^[0-9a-f]{40}\n?$`).
- [x] **Step 2: Run; expect failures.**
- [x] **Step 3: Add the steps**, keeping the file's formatting rule (job keys at 4 spaces, steps as `      - `).
- [x] **Step 4: Document** in `packaging/README.md`: `NOCTULE_BRANDING_DIR`, `config/branding.env`, `packaging/branding-ref` (how to move it after an art change: merge in the design-language repo, write the new SHA here, open a PR), the deploy key and its secret, the unbranded `--untagged` DMG.
- [x] **Step 5: Run `swift test --filter ReleaseWorkflowTests`; expect PASS.**
- [x] **Step 6: Commit** (`ci: the release job checks out the official art at packaging/branding-ref`).
- [x] **Step 7: [owner] Create the deploy key**: an SSH key pair; the public half as a read-only deploy key on `noctule-design-language`; the private half as `NOCTULE_BRANDING_DEPLOY_KEY` in this repo's `release` environment. (Repeated for the new repo in Task 12.)

### Task 6: The pull-request build, the DCO check and repo safety

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `scripts/check-dco.sh`
- Create: `.github/CODEOWNERS`
- Create: `Tests/NoctuleCLIIntegrationTests/CIWorkflowTests.swift`

**Interfaces:**
- Produces: `scripts/check-dco.sh <base> <head>`: for every non-merge commit in `<base>..<head>`, requires a trailer line `Signed-off-by: <author name> <author email>` matching that commit's author exactly; prints `dco: <short sha> <subject>: no Signed-off-by for <name> <email>` per failure and exits 1; prints `dco: <n> commits signed off` and exits 0 otherwise; usage error exit 2.
- Produces: `ci.yml`: `on: push: branches: [main]` and `pull_request:`; top-level `permissions: contents: read`; `concurrency: group: ci-${{ github.ref }}`, `cancel-in-progress: true`; one job `build` on `runs-on: xcode-27`, `timeout-minutes: 120`, env `NOCTULE_NO_USB_DETECTION: "1"`, `NOCTULE_CI_RUNNER: "1"`, `NOCTULE_PYTHON: /opt/homebrew/bin/python3`; steps: checkout (`fetch-depth: 0`, `persist-credentials: false`, the pinned SHA), DCO (`if: github.event_name == 'pull_request'`, `scripts/check-dco.sh "${{ github.event.pull_request.base.sha }}" "${{ github.event.pull_request.head.sha }}"`), select Xcode 27.2, `swift build --build-tests`, the two test steps exactly as `release.yml` has them, `scripts/build-app.sh`, and `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build`. No `environment`, no `secrets.`.
- Produces: `.github/CODEOWNERS`: `/.github/ @sean-foley`, `/packaging/ @sean-foley`, `/scripts/ @sean-foley` (the owner's GitHub login, checked 2026-11-20).

- [x] **Step 1: Write the failing tests** in `CIWorkflowTests.swift`:
  - `dcoAcceptsSignedCommits`, `dcoRejectsAMissingSignOff`, `dcoRejectsAMismatchedSignOff` (trailer for another email), `dcoSkipsMergeCommits`, `dcoUsageErrors` (wrong argument count → 2): each on a temporary git repo built in the test.
  - `ciRunsOnPushesToMainAndPullRequests`, `ciIsReadOnlyAndSecretless` (`permissions:\n  contents: read` at the top; no `secrets.`, no `environment:`, no `pull_request_target`), `ciTestsAsTheReleaseJobDoes` (the two test commands equal `release.yml`'s), `ciChecksTheDCOOnlyOnPullRequests`, `ciActionsArePinned` (every `uses:` is `@<40 hex>`).
  - `noWorkflowGivesForkCodeSecrets`: for every file in `.github/workflows/`, no `pull_request_target` and no `workflow_run`; every `uses:` pinned by SHA.
  - `codeOwnersCoverTheBuildPath`: `.github/CODEOWNERS` has lines for `/.github/`, `/packaging/`, `/scripts/`.
- [x] **Step 2: Run; expect failures.**
- [x] **Step 3: Write `check-dco.sh`, `ci.yml` and `CODEOWNERS`** as specified.
- [x] **Step 4: Run `swift test --filter CIWorkflowTests`; expect PASS.**
- [x] **Step 5: Commit** (`ci: build and test every pull request; check DCO sign-offs`).

### Task 7: License, notices and community files

**Files:**
- Create: `LICENSE` (the Apache 2.0 text from https://www.apache.org/licenses/LICENSE-2.0.txt, byte for byte)
- Create: `NOTICE`, `TRADEMARKS.md`, `CODE_OF_CONDUCT.md`, `SECURITY.md`, `images/screenshots/LICENSE.md`
- Create: `.github/ISSUE_TEMPLATE/bug_report.yml`, `.github/ISSUE_TEMPLATE/feature_request.yml`, `.github/ISSUE_TEMPLATE/config.yml`, `.github/pull_request_template.md`
- Create: `Tests/NoctuleCLIIntegrationTests/RepositoryFilesTests.swift`

- [x] **Step 1: Write the failing tests**: `licenseIsApache20` (SHA-256 of `LICENSE` equals the official text's, which the implementer computes from the downloaded file and pins); `noticeNamesTheHolderAndTheExceptions` (`NOTICE` contains `Copyright 2026 Sean Foley`, `TRADEMARKS.md`, `images/screenshots`, `ACKNOWLEDGMENTS.md`); `screenshotsAreExcluded` (`images/screenshots/LICENSE.md` contains `not licensed under the Apache License`, `Sean Foley`, `TRADEMARKS.md`); `communityFilesExist` (each file above exists and is non-empty; `CODE_OF_CONDUCT.md` contains `Contributor Covenant` and `version 2.1` and `info@noctule.app`; `SECURITY.md` contains `private vulnerability reporting` and `no authentication`).
- [x] **Step 2: Run; expect failures.**
- [x] **Step 3: Write the files.** Content is design §3 and §3.1; `TRADEMARKS.md` follows §3.1's bullets (fork welcome, rename what you ship, "based on Noctule Scan" allowed, code identifiers may stay, Uniden's marks are Uniden's, not legal advice). `images/screenshots/LICENSE.md` per design §4.3. Issue templates per §3 (bug: model, firmware, network or USB, macOS version, reproduces on the mock?, a reminder to strip real system names and frequencies; `config.yml` sets `blank_issues_enabled: false` and links `SECURITY.md` for vulnerabilities). PR template as shown to the owner (What this changes; How it was tested with the four boxes; Checklist: sign-off, no real radio traffic, SPDX notice, spec or LESSONS entry).
- [x] **Step 4: Run `swift test --filter RepositoryFilesTests`; expect PASS.**
- [x] **Step 5: Commit** (`docs: Apache 2.0 license, notice, trademark policy and community files`).

### Task 8: Source notices and the repository hygiene tests

**Files:**
- Modify: every tracked `*.swift`, `*.sh`, `*.py`, `*.yml` file (299 today, plus this plan's new ones)
- Create: `Tests/NoctuleCLIIntegrationTests/RepositoryHygieneTests.swift`
- Create: `Tests/NoctuleMockScannerTests/PrivateWordsTests.swift`, `config/private-words.txt.example`
- Modify: `Tests/NoctuleMockScannerTests/RealNamesTests.swift` (`trackedTextFiles` from `git ls-files`)

**Interfaces:**
- Produces: `RepositoryHygieneTests` (reads `git ls-files` from the repo root; skips non-UTF-8 files):
  - `everySourceFileCarriesTheNotice`: for each tracked `.swift/.sh/.py/.yml` outside `images/screenshots/`, the first two lines after an optional `#!…` or `// swift-tools-version…` line are the notice in that language's comment form (`// ` for Swift, `# ` otherwise). Failure lists every offending path.
  - `noBrandArtIsTracked`: none of `Resources/AppIcon.icon`, `packaging/dmg/background/` is tracked; no tracked file contains the string `noctule-mark` outside `docs/`.
- Produces: `PrivateWordsTests.noPrivateWordsInTrackedFiles` beside `RealNamesTests` (in `Tests/NoctuleMockScannerTests/`), reading `config/private-words.txt` with the same parsing, matching rule (`RealNames.hits(in:list:)`) and skip-when-absent trait. `RealNames.trackedTextFiles(root:)` changes to every file `git ls-files` lists that decodes as UTF-8, so both deny-lists also cover `.github/`, `packaging/`, `images/screenshots/*.md` and the new root files (`NOTICE`, `TRADEMARKS.md`, …); fall back to today's directory walk only if `git` fails. Add `config/private-words.txt.example` (a comment explaining the file, and two harmless example lines such as `example-internal-codename`).

- [x] **Step 1: Write the tests.** Run them: `everySourceFileCarriesTheNotice` fails (no notices yet); `noPrivateWordsInTrackedFiles` fails on the docs Task 9 cleans (note which files); `noBrandArtIsTracked` passes.
- [x] **Step 2: Add the notice to every source file** with a one-off script kept in the scratchpad (not committed): insert after a `#!` or `// swift-tools-version` first line, else at line 1; add one blank line after the notice when the next line isn't blank. Re-run the line-based workflow tests afterwards: `ReleaseWorkflowTests` reads `release.yml`'s header lines and must still pass.
- [x] **Step 3: Run `swift build` and `swift test --filter "RepositoryHygieneTests|RealNamesTests|ReleaseWorkflowTests|CIWorkflowTests|AppBundleTests"`; expect PASS** (`PrivateWordsTests` still fails until Task 9).
- [x] **Step 4: Commit** (`chore: SPDX notice in every source file`).

### Task 9: Clean the docs at the tip

**Files:**
- Delete: `docs/specs/2026-11-13-design-language-gap-review.md` (copy it into the design-language repo's `docs/` in the Task 4 PR or a second one)
- Modify: `docs/specs/2026-11-13-release-packaging-design.md`, `docs/specs/2026-11-13-plan-11-move-to-noctule-dev.md` (owner home paths and the old personal repo name → generic wording: "the agent's memory folder for this project", "the archived earlier repository")
- Modify: `docs/specs/2026-11-14-plan-13-installer-window.md` (remove the mockup link; move the background's recipe — the colours, mark placement and wordmark settings of its design section — to `builds/noctule-scan/README.md` in the design-language repo and leave a one-line pointer)
- Modify: `docs/specs/2026-11-20-open-source-prep-design.md` (already done: its mockup link and home-folder quote were removed when this plan was written)
- Modify: `docs/specs/2026-11-13-release-packaging-design.md` line 133 (a note that the open-source prep design replaces "remove `docs/specs/`")
- Modify: specs and `AGENTS.md` lines that point at `Resources/AppIcon.icon` or `packaging/dmg/background/` (point at the design-language repo's `builds/noctule-scan/` and the placeholder paths)
- Create: `docs/specs/README.md` (design §6.3)

- [x] **Step 1: Make the edits above.** `docs/specs/README.md`: protocol notes first, then design docs grouped by area (core, audio, stations and hit log, the app, menus, USB, line-in, quick keys, packaging and releases), then plans as history; the note on "the owner" and on the labels **(owner)**, **[hw]**, **[spec]**, **[lib]**; that commit and PR numbers in the specs refer to the earlier, archived repository.
- [x] **Step 2: Run `swift test --filter "RepositoryHygieneTests|RealNamesTests|PrivateWordsTests"`; expect PASS** (both deny-lists present on the owner's Mac).
- [x] **Step 3: Commit** (`docs: clean the specs for publication; add a specs index`).

### Task 10: AGENTS.md for contributors, and the owner's local file

**Files:**
- Modify: `AGENTS.md` (rewrite, design §6.1)
- Create (git-ignored, not committed): `AGENTS.local.md`, `CLAUDE.local.md` (one line: `@AGENTS.local.md`)
- Modify: `.gitignore` (add `AGENTS.local.md`, `CLAUDE.local.md`)
- Create: `CONTRIBUTING.md` (design §6.2)

- [x] **Step 1: Inventory the rules.** Make a checklist (in the scratchpad) of every rule in today's `AGENTS.md`, one line each, tagged *general* (applies to anyone's scanner or the project), *owner* (the owner's units, settings, rig, pending sessions, release secrets handling specific to the owner) or *fact* (hardware behaviour). This list is the review aid for Step 4.
- [x] **Step 2: Write `AGENTS.local.md`** from every *owner* line, verbatim where possible, with the branding path note. Write `CLAUDE.local.md`. Add both to `.gitignore`. Check `git status` shows neither.
- [x] **Step 3: Rewrite `AGENTS.md`**: *general* rules addressed to "your scanner" and "the person you work for"; *facts* kept; *owner* lines gone; release rules phrased for maintainers (no agent pushes `v` tags, runs `cut-release.sh`/`release.sh`/`notarize.sh` for real, or touches secrets); the mock and build-and-test sections kept, trimmed where they repeat a spec (cite the spec instead). Add the branding switch and the hygiene tests to Build and test. `CLAUDE.md` stays `@AGENTS.md`.
- [x] **Step 4: Check nothing protective was dropped**: walk the Step 1 checklist; every *general* and *fact* line is in the new `AGENTS.md` (or a spec it cites), every *owner* line in `AGENTS.local.md`. Hand the checklist to the reviewer with the diff.
- [x] **Step 5: Write `CONTRIBUTING.md`** (design §6.2): build and test, mock first, your-scanner hardware rules (short, pointing to `AGENTS.md`), the real-traffic rule and the optional deny-list, the iOS check, specs and `LESSONS.md`, the DCO with `git commit -s` and how to fix a missing sign-off (`git rebase --signoff`), an issue first for anything large, the SPDX notice for new files.
- [x] **Step 6: Run `swift test --filter "RepositoryHygieneTests|PrivateWordsTests|RealNamesTests"`; expect PASS.**
- [x] **Step 7: Commit** (`docs: AGENTS.md for contributors; CONTRIBUTING.md`).

### Task 11: The README

**Files:**
- Create: `README.md`
- Modify: `Tests/NoctuleCLIIntegrationTests/RepositoryFilesTests.swift`

- [x] **Step 1: Write the failing test** `readmeHasTheBadgesAndPointers`: the first non-heading lines contain, in order, badge images for the `ci.yml` status on `main` (`https://github.com/noctule-dev/noctule-scan/actions/workflows/ci.yml/badge.svg?branch=main`), the license (`img.shields.io/github/license/noctule-dev/noctule-scan`), the latest release (`img.shields.io/github/v/release/noctule-dev/noctule-scan?include_prereleases`), Swift (`img.shields.io/badge/Swift-6.4-`), Xcode (`img.shields.io/badge/Xcode-27.2-`) and platform (`img.shields.io/badge/platform-macOS-`); the README links `CONTRIBUTING.md`, `TRADEMARKS.md`, `LICENSE`, `docs/specs/README.md`; every `images/screenshots/…` it references exists; it contains "not affiliated with Uniden".
- [x] **Step 2: Run; expect failure.**
- [x] **Step 3: Write `README.md`** per design §3.2: name, one line, badges, what it does, two or three screenshots by relative path (`scanner-view-sds200.png`, `mac-style-view-sds200.png`, `hit-log.png`), requirements (macOS 26 or later as `Package.swift` says, Xcode 27.2, the three scanners), quick start against the mock, the unbranded-build note, where to read, contributing, license and trademarks, acknowledgments, the Uniden line.
- [x] **Step 4: Run `swift test --filter RepositoryFilesTests`; expect PASS.**
- [x] **Step 5: Commit** (`docs: README`).

### Task 12a: Whole-branch check and merge

- [x] **Step 1: Run the full suite** with `NOCTULE_NO_USB_DETECTION=1 swift test`; expect all pass (count it). Run `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build`; expect success. Run `scripts/build-app.sh` with `NOCTULE_BRANDING_DIR=""` and look at the icon in Finder (placeholder).
- [x] **Step 2: Whole-branch review** (fresh reviewer; include Task 10's checklist).
- [x] **Step 3: Push the branch and open a PR.** `ci.yml` runs on it for the first time: confirm it passes, note its duration and whether billing shows any charge (design §5.2). The DCO step will flag this branch's early commits that were made before sign-off was the rule; that is expected on the old repo and moot after Task 12's fresh commit, so note it in the PR rather than rewriting.
- [x] **Step 4: [owner] Merge** (`gh pr merge --merge --delete-branch`).

## Phase B: the public repository (hard to reverse; each step waits for the owner)

### Task 12: The fresh repository

**Interfaces:**
- Produces: `noctule-dev/noctule-scan` (new, private until Task 14) with one commit, `Initial public commit`, authored by the owner's configured identity and signed off; `noctule-dev/noctule-scan-private-archive` (the old repo, archived, private).
- `cut-release.sh` gains `--first <version>` (below).

- [x] **Step 1: `cut-release.sh --first`** (on a small branch of the old repo, merged before Step 3): when `origin` has no readable `v` tags, `cut-release.sh` refuses with `cut-release: no release tags on origin; pass --first X.Y.Z or X.Y.Z-beta.N for the first release` (exit 1); `--first V` is accepted only then (else `cut-release: --first is only for a repository with no release tags`, exit 2) and proposes `vV`. Tests in `CutReleaseTests`: `noTagsNeedsFirst`, `firstProposesThatVersion`, `firstIsRefusedWhenTagsExist`, `firstMustBeAVersion`. Update the script's header and `packaging/README.md`.
- [x] **Step 2: [owner] Approve the move**, after reading this task's remaining steps.
- [x] **Step 3: Check the local repo is safe to move**: `git status --porcelain` empty; `git branch -vv` shows no branch with unpushed commits (list any and ask); `git stash list` empty.
- [x] **Step 4: Rename the old repo**: `gh repo rename noctule-scan-private-archive --repo noctule-dev/noctule-scan`. Create the new one: `gh repo create noctule-dev/noctule-scan --private --description "Control, listen to and log Uniden SDS scanners on the Mac"`.
- [x] **Step 5: Make the fresh commit**, keeping the old history aside rather than deleting it: `mv .git ../noctule-scan-old.git`; `git init -b main`; `git add -A`; check `git status` lists no ignored file (`config/*.env`, `config/real-names.txt`, `docs/uniden/*.pdf`, `AGENTS.local.md`, `CLAUDE.local.md`, `.superpowers/`, `build/` all absent) and that the file count equals the old `git ls-files | wc -l`; `git commit -s -m "Initial public commit"` with the attribution trailers; `git remote add origin https://github.com/noctule-dev/noctule-scan.git`; `git push -u origin main`.
- [x] **Step 6: Check the new history** (design §7): `git log --all --oneline` is one commit; `git log --all -- Resources/AppIcon.icon packaging/dmg/background docs/specs/2026-11-13-design-language-gap-review.md <the private planning document removed at the start of this branch>` is empty; the full suite passes in the new clone with `config/*.txt` copied in (`RepositoryHygieneTests`, `RealNamesTests`, `PrivateWordsTests` included, none skipped).
- [x] **Step 7: Move what moves**: `gh issue transfer 13 noctule-dev/noctule-scan --repo noctule-dev/noctule-scan-private-archive`; recreate the `Release tags` ruleset (same rules as id 27276075 on the archive: tags `refs/tags/v*`, creation, update, deletion, non-fast-forward) and a `main` ruleset requiring the `ci.yml` `build` check (no required approvals); create the `release` environment with the deployment rule tags `v*`; turn on private vulnerability reporting (`gh api -X PUT repos/noctule-dev/noctule-scan/private-vulnerability-reporting`).
- [x] **Step 8: [owner] Add the secrets** to the new repo's `release` environment: the five signing secrets and `NOCTULE_BRANDING_DEPLOY_KEY` (the design-language deploy key from Task 5 Step 7 can be reused; its public half is on the design-language repo, not on this one).
- [x] **Step 9: Archive the old repo** (after the issue transfer): `gh repo archive noctule-dev/noctule-scan-private-archive --yes`. Leave `../noctule-scan-old.git` until the owner says to delete it.
- [x] **Step 10: Update the agent memory** for this project (repo, the archive's name, where old PR rulings live).

### Task 13: The first release from the new repository

- [x] **Step 1: [owner] Run `packaging/cut-release.sh beta --first 0.1.1-beta.4`** (the owner's command, never an agent's).
- [x] **Step 2: Check the draft release** when the workflow finishes, as Plan 14 Task 6 Step 2 did: the DMG's checksum, `spctl`, `stapler`, version 0.1.1 build `<run number>`, and that the app inside shows the official icon and the installer window the official background (mount it; compare `.background.tiff` with the design-language repo's at `packaging/branding-ref`).
- [x] **Step 3: [owner] Publish or delete the draft.**

### Task 14: Going public (the owner's checklist)

**[owner]** in the repo's settings, after Tasks 12–13:
- [x] Read `TRADEMARKS.md` (and have a lawyer read it, if wanted).
- [x] Description and topics.
- [ ] Social preview image (brand art, uploaded in settings, never committed). Optional; the setting appears only once the repository is public.
- [x] Discussions on or off.
- [x] Change visibility to public.
- [x] Afterwards: the README's badges render; a fork's pull request runs `ci.yml` without secrets.

## Results

**Phase A (2026-11-20 and 2026-11-21), Tasks 1–11 and 12a**, on `docs/open-source-prep` in the old repository, merged there as its PR #15 (52 commits). Each task had its own review and an independent QA pass with mutation checks, then a whole-branch review and one fix wave. The full suite passed at the branch's head: 2,075 tests, plus the 22 known issues.
- **Task 12a Step 3, a change from the plan:** the early commits made before sign-off became the rule were signed off with `git rebase --signoff` before the first push (owner-approved). The plan said to leave them and note them in the PR.
- **The first `ci.yml` runs**, the first time the line-in suites met the CI runner, failed on tests that waited fixed times. The runner wakes timers late, and `taskpolicy -c background` reproduces that locally (LESSONS.md 2026-11-20). Fixing them turned up two bugs in the mock (the headphone jack refused a fast reconnect, and its timers coalesced under load). About fifteen tests changed to wait for conditions. The last two runs passed in about 17 minutes each. macOS minutes that month: 250, $0 net.

**Task 12 (2026-11-21), the fresh repository.**
- **Step 1:** `cut-release.sh --first` was merged as the old repository's PR #16. The kind must agree with the version's form (`beta` needs `X.Y.Z-beta.N`).
- **Steps 3–6:**
  - The old repository became `noctule-scan-private-archive`, and the new `noctule-dev/noctule-scan` got one commit, `Initial public commit` (392 files; its tree is identical to the old `main`'s).
  - The removed art, the gap review and the private planning document are absent from the new history.
  - The full suite passed in a fresh clone with the deny-lists in place: 2,079 tests, none of the hygiene suites skipped.
- **Step 7:**
  - Issue #13 became #1. AGENTS.md's pointer followed it in PR #2.
  - `Release tags` was recreated. The `main` ruleset requires a pull request (no approvals) and the `build` check, blocks deletion and force-pushes, and lets admins bypass.
  - The `release` environment admits `v*` tags.
  - Private vulnerability reporting needs a public repository, so it was turned on after Task 14.
- **The new repository's CI didn't start at first:** the organization's Actions budget was $0 with usage stopped, and the month's included macOS minutes were spent. The owner raised the budget.
- **Step 8:** the owner added the six secrets. The first `.p12` value was stored empty; see Task 13.

**Task 13 (2026-11-21), `v0.1.1-beta.4`.** An agent ran `cut-release.sh beta --first 0.1.1-beta.4`, at the owner's explicit go-ahead for this release, from the merge of PR #2.
- **The first attempt** stopped at "Create the signing keychain": `NOCTULE_DEVELOPER_ID_P12` was empty. Nothing reached Apple. The owner set the secret again, and a re-run of the failed job passed every step.
- **Step 2:** the draft's checksum is `OK`. `spctl` accepts the DMG and the app (Notarized Developer ID), `stapler validate` passes on both, and `codesign --verify --strict --deep` passes. The version is 0.1.1, build **1**; run numbers start again in the new repository. The installer background is byte-identical to the design-language art at `packaging/branding-ref`, and the app shows the official icon.
- **Step 3:** the owner published it as a pre-release.

**Task 14 (2026-11-21 and 2026-11-22), going public.**
- **Before the switch:** the owner read `TRADEMARKS.md` and set the description and topics. Discussions were turned on, and PR #3 points questions and ideas there.
- **The switch:** the repository went public on 2026-11-21. Private vulnerability reporting was turned on.
- **The badges:** they render. The license and release badges showed a cached "repo not found" from before the switch for a few hours.
- **Issue #1's history:** its transfer line names no source repository to a visitor who isn't signed in.
- **The fork check:** PR #4, from a fork, ran `ci.yml` with `Contents: read` and no secrets (2026-11-22).
- **Still open:** the social preview image.

**After going public: CI on the runner (2026-11-21 and 2026-11-22).** From about 18:45 UTC on 2026-11-21, every CI run on the free `xcode-27` runner failed, though the code hadn't changed.
- **The cause:** the integration tests blocked Swift's cooperative threads (three on that runner) while they waited for their tools, which starved the fakes inside the same process. A `TCPStream.connect` that held its thread for the whole handshake made it worse.
- **PR #6** fixed both, the second in product code. It was merged with the admin bypass while `main` was already red.
- **"Flake hunts"** then ran ci.yml's test commands on five runner VMs at once, two passes each. On the free runner, 4 of 10 VMs failed and one hung for 90 minutes. On a larger runner (an M2 Pro VM, 5 cores, 14 GB), none of the VMs failed.
- **PR #9, the sweep:** it took every remaining blocking wait off the pool, and rewrote the tests that skipped themselves on CI to wait for conditions. No test is skipped on CI now.
- **PR #7, a product fix found by the sweep's review:** a quick-key set, or a menu `KEY` or `MSV`, that had passed its last check could still be sent after the pop-over closed, the scanner entered a menu or the session stopped, while it waited for the request slot. Now the decision is made after the slot is taken.
- **PR #8:** the owner moved `ci.yml` and `release.yml` to the billed `xcode-27-xlarge` runner. Outside contributors' pull requests wait for the maintainer's approval before CI runs.
- **PR #5:** a pull request that changes only documentation runs just the repository's checks (`scripts/ci-changes.sh`; spec `2026-11-21-ci-docs-fast-path.md`).
- **The cost of a run:** a full CI run takes about 16 minutes on the larger runner; PR #4's documentation-only run took 2 min 44 s.
- **More:** LESSONS.md 2026-11-20 to 2026-11-22.

**Follow-ups:**
- the 90-minute hang seen once in a hunt, unexplained (the time limits now name the test);
- `release.sh` attaching the DMG without a retry;
- `EngineLineInSource` listing devices on the cooperative pool;
- `HitLogSchema.enableWAL` sleeping between retries;
- the Scanner view's key presses and the volume and squelch steps not going through the request-slot guard;
- tuning the number of tests run at once to the runner's cores;
- a self-hosted runner.
