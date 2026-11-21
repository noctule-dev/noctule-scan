# Plan 13: the installer window

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. This repo's rules (AGENTS.md) apply on top. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** opening the release DMG shows the owner-approved Noctule Scan installer window: the night background with the echo mark and the "Noctule Scan" wordmark, the line "Drag Noctule Scan onto Applications to install it.", the app icon, an amber scan-bar arrow, and the Applications folder, each name on a slate plate.

**Architecture:** the background is a committed two-resolution TIFF (`packaging/dmg/background/background.tiff`, 640×400 pt at 1x and 2x) drawn by a Swift script from committed sources (the design language's mark, the Inter Tight font), so a release never renders art. `packaging/dmg/make-dmg.sh` keeps its interface (`<app> <dmg>`) and now builds the image with `dmgbuild` (the release design's option B) from `packaging/dmg/settings.py`, in a private virtual environment installed from hash-pinned wheels; `release.sh`, `notarize.sh` and their tests don't change.

**Tech Stack:** Swift script with AppKit and Core Text (`swift <file>`), `tiffutil`, Python 3.10+ with `dmgbuild` 1.6.7, `ds_store` 1.3.3, `mac_alias` 2.2.3; Swift Testing in `NoctuleCLIIntegrationTests` (`PackagingTests.swift`).

**Spec:** the maintainer-approved mockup (2026-11-14; the mockup itself is not kept in this repository), with the geometry in the design-language repository's recipe (see "The background" below); `docs/specs/2026-11-13-release-packaging-design.md` §4 (DMG option B, "when the custom window … arrive[s]"); the design language (`../noctule-design-language/README.md`, product names two words since 2026-11-14, no tagline).

## Global Constraints

- **Names:** the product is "Noctule Scan" (two words) everywhere a person reads it: volume name `Noctule Scan`, wordmark, the line of text. Files the scripts write stay lower case with hyphens (`noctule-scan-<version>.dmg`, Plan 14); the app bundle stays `Noctule Scan.app`.
- **The window:** content 640×400 pt (Finder's window bounds 640×432: they include the 32 pt title bar, measured on macOS 27), no toolbar, status bar, sidebar or path bar; icon view, icons 128 pt, label text 12 pt; the app's label reads `Noctule Scan` because Finder hides `.app` by default (unless "Show all filename extensions" is on); `hide_extensions` is not used, since it breaks `codesign --verify --strict` *(decided during execution, R6)*; icon centres app (170, 214), Applications (470, 214) (top-left origin, points); the volume icon is the app's `AppIcon.icns`.
- **The background:** its recipe (gradient, header row with the mark and the wordmark, the line of text, name plates, arrow) is in the design-language repository's `builds/noctule-scan/README.md`, "Background recipe"; the plates sit at x 104 and 404, top 282, under icon centres (170, 214) and (470, 214), which Task 3 may move to sit under Finder's labels. *(Since Plan 21 (2026-11-20) the art, its renderer and this recipe live in the design-language repository's `builds/noctule-scan/`; the paths below name where Plan 13 first put them.)*
- **Fonts:** Inter Tight only (`InterTight[wght].ttf` from `google/fonts` `ofl/intertight`, SHA-256 `b81b73dcb64df3c230cabade7df6c5773bf863233f24c9ee51087519f1f88b6f`, 581,588 bytes, with its `OFL.txt`, SHA-256 `50240ab035cf1b6b3307940235481d515c4b6de3ab1fa843dbe59e7892cb9d58`), committed under `packaging/dmg/background/fonts/` and credited in `ACKNOWLEDGMENTS.md`. The line of text uses the system font, matching Finder's labels *(designer's call: one font file fewer)*.
- **The mark** is the design language's `logo/noctule-mark-on-dark.svg` with its C2PA `<metadata>` and `xmlns:c2pa` stripped (the owner's 2026-11-13 ruling for committed copies); no file under `packaging/` contains `c2pa`.
- **Python:** 3.10 or newer, found as `NOCTULE_PYTHON` if set, else `python3` if new enough, else the error below; the environment lives in `build/dmg-venv/` (git-ignored), made on first use and reused while `requirements.txt` is unchanged. Installed with `pip install --require-hashes --only-binary :all: -r packaging/dmg/requirements.txt`, the three wheels pinned by SHA-256: `dmgbuild-1.6.7-py3-none-any.whl` `37ee5771c377beb3203d9164aae8046ffed8531c06edf9227f5788b3c599b1bf`, `ds_store-1.3.3-py3-none-any.whl` `b92a371efbf1b4ccce2a04d1ed13fceacc4736c81ba09cf5aefb74c088160a35`, `mac_alias-2.2.3-py3-none-any.whl` `7362b521d2132ef92f606a37abfed5fcd849ceb2f28b6f9743e014b02af92f0d`. The first run needs the network (PyPI); later runs don't.
- Plan 12's script rules hold (`#!/bin/bash`, `set -euo pipefail`, `100755`, quoted paths, exit 2 for usage and 1 for failures), and `make-dmg.sh`'s interface and output line (`dmg: <path>`) don't change.
- AGENTS.md: `export NOCTULE_NO_USB_DETECTION=1` in every shell that runs tests. Nothing in this plan signs, notarizes or sends anything to Apple.

## Review Focus

1. **The app's signature and stapled ticket survive the copy into the image** (dmgbuild copies the bundle itself, where Plan 12 used `ditto`): a release whose mounted app fails `codesign --verify` would pass notarization of the DMG and still be refused by Gatekeeper on the user's Mac. Pinned in Task 2 (`signedAppSurvivesTheCopy`).
2. **No usable Python** (the stock `/usr/bin/python3` is 3.9.6 on macOS 27): the script must say what to install, not fail inside `pip`. Pinned in Task 2 (`oldPythonIsExplained`, `missingPythonIsExplained`).
3. **Finder's labels landing beside, not on, the plates** (Finder places labels itself; the plates are paint): checked by eye in Task 3, in Dark Mode by the agent and Light Mode by the owner.
4. **The supply chain on the release path:** a package swapped on PyPI must not reach a build that later holds the signing key (Plan 14). Pinned in Task 2 (`requirementsArePinnedByHash`).
5. **A stale or half-made environment** (an interrupted first install, a changed `requirements.txt`): the next run must rebuild it, not use it. Pinned in Task 2 (`changedRequirementsRebuildTheEnvironment`).

---

### Task 1: The background art

**Files:**
- Create: `packaging/dmg/background/render-background.swift`, `packaging/dmg/background/noctule-mark-on-dark.svg`, `packaging/dmg/background/fonts/InterTight[wght].ttf`, `packaging/dmg/background/fonts/OFL.txt`, `packaging/dmg/background/background.tiff` (rendered)
- Modify: `ACKNOWLEDGMENTS.md` (Inter Tight, SIL OFL 1.1, © 2022 The Inter Project Authors, with the source URL)
- Test: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`@Suite struct BackgroundArtTests`)

**Interfaces:**
- Produces: `swift packaging/dmg/background/render-background.swift <out.tiff>`: registers the committed font for the process (`CTFontManagerRegisterFontsForURL`, scope `.process`), draws the Global Constraints' background into a 640×400 and a 1280×800 bitmap (sRGB, scale 1 and 2, top-left geometry flipped for Core Graphics), writes both as PNGs to a temporary directory and joins them with `tiffutil -cathidpicheck <1x.png> <2x.png> -out <out.tiff>`; prints `background: <out.tiff>`. Any failure (font not registered, SVG not loaded) exits 1 naming it. The committed `background.tiff` is its output.

- [ ] **Step 1: Write the failing tests.**
  - `tiffHasBothResolutions`: `CGImageSourceCreateWithURL` on `background.tiff` has 2 images, 640×400 and 1280×800 pixels.
  - `committedSourcesArePinned`: the font's SHA-256 is the one above; `OFL.txt` exists; `noctule-mark-on-dark.svg` contains no `c2pa` and parses as SVG (`<svg` at the start, `</svg>` at the end).
  - `colorsAreWhereTheDesignPutsThem`: decode the 1x image; the pixel at (320, 4) is within 6 per channel of the gradient's start colour, at (320, 396) of its end colour; at (170, 294) (a plate's centre) within 3 of the plate colour; at (358, 214) (the last tick) within 12 of the arrow's amber; at (20, 214) no channel above `#2A` (empty background); the colours are in the recipe.
  - `nothingInPackagingCarriesC2PA`: no file under `packaging/` contains the bytes `c2pa`.
- [ ] **Step 2:** `NOCTULE_NO_USB_DETECTION=1 swift test --filter BackgroundArtTests` fails.
- [ ] **Step 3:** Copy and strip the mark; add the font and its licence (check both hashes); write the renderer; run it to make `background.tiff`. Put both resolutions side by side with the canvas artboard (screenshots under `.superpowers/screenshots/plan-13/`) and fix anything that differs from the mockup beyond font rasterising.
- [ ] **Step 4:** The filter passes.
- [ ] **Step 5: Commit** `packaging: the installer window's background art`.

### Task 2: `make-dmg.sh` with `dmgbuild`

**Files:**
- Create: `packaging/dmg/settings.py`, `packaging/dmg/requirements.txt`
- Modify: `packaging/dmg/make-dmg.sh` (header comment, body), `packaging/README.md` (the table's `make-dmg.sh` line; "Python 3.10 or newer" under requirements, with `brew install python` and `NOCTULE_PYTHON`)
- Test: `Tests/NoctuleCLIIntegrationTests/PackagingTests.swift` (`MakeDMGTests`, inside `DiskImageTests`, still serialized)

**Interfaces:**
- Consumes: Task 1's `background.tiff`; the app's `Contents/Resources/AppIcon.icns`.
- Produces: `packaging/dmg/make-dmg.sh <app> <dmg>`, same arguments, exits and output line as Plan 12. Steps: argument checks (unchanged); find Python (Global Constraints) or fail with `make-dmg: needs Python 3.10 or newer (found <version or "none">); install one (brew install python) or set NOCTULE_PYTHON`, exit 1; make or reuse `<root>/build/dmg-venv` (`NOCTULE_DMG_VENV` overrides, for tests): rebuilt when missing, when `<venv>/requirements.sha256` doesn't match `shasum -a 256` of `requirements.txt`, or when `<venv>/bin/python -c "import dmgbuild"` fails; the hash file is written last, so an interrupted install is rebuilt; pip's output goes to stderr only on failure (`make-dmg: couldn't install dmgbuild (see above)`). Then `"<venv>/bin/python" -m dmgbuild -s packaging/dmg/settings.py -D app=<app> -D background=<tiff> "Noctule Scan" <dmg>`, its output kept for a failure as `hdiutil`'s was (`make-dmg: dmgbuild failed`). An image already at `<dmg>` is replaced.
- `settings.py` reads `defines['app']` and `defines['background']` and sets: `format = 'UDZO'`; `files = [app]`; `symlinks = {'Applications': '/Applications'}`; `icon = <app>/Contents/Resources/AppIcon.icns`; `background = <tiff>`; `window_rect = ((200, 120), (640, 432))` *(decided during execution: Finder's outer frame, 32 pt title bar included; content 640×400)*; `default_view = 'icon-view'`; `show_toolbar = show_status_bar = show_tab_view = show_pathbar = show_sidebar = False`; `icon_size = 128`; `text_size = 12`; `icon_locations = {<app's file name>: (170, 214), 'Applications': (470, 214)}`.

- [ ] **Step 1: Write the failing tests** (`NOCTULE_DMG_VENV` set to one shared directory under the test run's temporary folder, so the suite installs once; `fakeApp` gains `Contents/Resources/AppIcon.icns`, a copy of `/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns`):
  - `makesAnImageWithTheAppAndApplications` (Plan 12's, kept): plus the volume name is `Noctule Scan`; the mounted image holds `.background.tiff` (dmgbuild writes it at the volume's root, not in a `.background/` folder) and `.VolumeIcon.icns`.
  - `windowLayoutIsTheDesigns`: read the mounted image's `.DS_Store` with the venv's `ds_store` (`<venv>/bin/python -c …`, printing JSON): icon positions `Noctule Scan.app` (170, 214) and `Applications` (470, 214); icon size 128; text size 12; the background set to a picture; toolbar and status bar hidden; window bounds `{{200, 120}, {640, 432}}`.
  - `signedAppSurvivesTheCopy`: `codesign --force --sign - <fake app>` (ad hoc, real `codesign`) before making the image; the mounted copy passes `codesign --verify --strict`, and `Contents/marker` (a file the test adds before signing) is byte-identical in the copy.
  - `aSecondRunReplacesTheImage` and `refusesWhatIsNotAnApp` (Plan 12's, kept); `hdiutilFailureIsReported` becomes `buildFailureIsReported` (an output directory that doesn't exist: exit 1, `make-dmg: dmgbuild failed`).
  - `oldPythonIsExplained`: `NOCTULE_PYTHON` a stub that reports 3.9.6 (the machine running the tests may have no such Python) → exit 1, the message naming `3.9`, no `<dmg>`, no venv made. `missingPythonIsExplained`: `NOCTULE_PYTHON=<tmp>/none` → the message with `none`. `failedPythonProbeNamesItsReason`: a shim whose probe fails (a pyenv-style "version is not installed") → the message carries the shim's first line. Added after the final review (I1, M1, M2): `aFailedCopyOfTheAppFailsTheBuild` (a signed app with an unreadable file → exit 1, `make-dmg: the app in the image isn't a faithful copy`, no image left; make-dmg attaches the image read-only and compares the copy with the source, and checks its signature when the source's verifies), `refusesToRemoveADirectoryThatIsNotAVenv` (`NOCTULE_DMG_VENV` at a directory without `pyvenv.cfg` → exit 1, nothing removed) and `pythonPathCannotBypassTheInstalledPackages` (the venv's Python runs with `-I`).
  - `changedRequirementsRebuildTheEnvironment`: after a run, overwrite `<venv>/requirements.sha256` with `0`; the next run rebuilds (stderr or a marker shows `pip` ran; the hash file matches again) and succeeds. And deleting `<venv>/bin/python` likewise.
  - `requirementsArePinnedByHash`: every non-comment line of `requirements.txt` is `<name>==<version> --hash=sha256:<64 hex>`, and the three names and hashes are those above.
- [ ] **Step 2:** `swift test --filter MakeDMGTests` fails.
- [ ] **Step 3:** Write `requirements.txt`, `settings.py` and the script.
- [ ] **Step 4:** `swift test --filter "MakeDMGTests|ReleaseTests|NotarizeTests"` passes; then `NOCTULE_NO_USB_DETECTION=1 swift test` in full (with `noRealNamesInTrackedFiles` run).
- [ ] **Step 5: Commit** `packaging: the designed installer window with dmgbuild`.

### Task 3: Look at it in Finder

**Files:** this plan (Results); Task 1's renderer and `background.tiff`, and `settings.py`, only if something moves.

- [ ] **Step 1:** `scripts/build-app.sh` (a development build, ad-hoc signed: nothing to Apple), then `packaging/dmg/make-dmg.sh "build/Noctule Scan.app" "<tmp>/noctule-scan-test.dmg"`; `open` the image; Finder shows the window. Capture it by window id only (`screencapture -x -o -l <id>`, the id of Finder's window titled `Noctule Scan` from `CGWindowListCopyWindowInfo`; LESSONS.md 2026-11-13), into `.superpowers/screenshots/plan-13/`. Eject the volume afterwards.
- [ ] **Step 2:** Compare with the canvas artboard: each label sits on its plate (centred, inside it), the icons sit where the mockup has them, nothing is cropped or scrolled, no scroll bars. If labels miss the plates, move the plates' `top` (and if needed both icon centres' `y`, in `settings.py` and the arrow's centre line together), re-render, rebuild, recapture; record the final numbers in Global Constraints and Results.
- [ ] **Step 3 (owner):** open the same image with the Mac in **Light** appearance (an agent doesn't change the owner's appearance setting) and say whether the black labels read well on the plates.
- [ ] **Step 4: Commit** any adjustment: `packaging: line the plates up with Finder's labels`.

### Task 4: Documentation and review

**Files:**
- Modify: `packaging/README.md` (how to change the art: edit the renderer's constants, `swift packaging/dmg/background/render-background.swift packaging/dmg/background/background.tiff`, commit the TIFF; what the window shows), `AGENTS.md` (the Releases bullet: `make-dmg.sh` uses `dmgbuild` in `build/dmg-venv`, needs Python 3.10+; `MakeDMGTests` install it once per run from PyPI), `docs/specs/2026-11-13-release-packaging-design.md` (§4: option B arrived with Plan 13), `LESSONS.md` (anything that surprised us).

- [ ] **Step 1:** Write them; `swift test --filter RealNamesTests` passes. **Commit** `docs: the installer window`.
- [ ] **Step 2:** Final whole-branch review by a fresh reviewer (most capable model); fixes with failing tests first.
- [ ] **Step 3:** With the owner's go-ahead, push and open the PR; the owner merges. The first signed and notarized DMG with this window comes from Plan 14's first tag (or `release.sh` by hand, the owner's call), whose Gatekeeper checks cover it.

## Results

**Task 3 (Finder, Dark Mode, macOS 27; agent steps 1, 2, 4).** Dev build (ad-hoc) and `make-dmg.sh` with `NOCTULE_PYTHON=/opt/homebrew/bin/python3`, opened in Finder, captured by window id.
- **Labels and plates:** with the plates at x 104 and 404, top 282, and icon centres (170, 214) and (470, 214), each label (`Noctule Scan.app`, `Applications`) sits centred inside its plate, icons where the mockup has them, nothing in the art cropped. **Nothing in the plates, icons or arrow moved.**
- **One real finding: the window height.** dmgbuild's `window_rect` is Finder's *outer* bounds, including a 32 pt title bar (measured: the art starts 32 px below the top), so 640x400 gave a 368 pt content area. `settings.py` now says 640x432 (`WindowBounds {{200, 120}, {640, 432}}`, pinned in `windowLayoutIsTheDesigns`). Screenshots: `.superpowers/screenshots/plan-13/finder-1.png` (before, 640x400) and `finder-2.png` (after, 640x432).
- **What the screenshots show beyond the design is the owner's global Finder settings, not the image:** the path bar, status bar (`4 items`), hidden files (`.background.tiff`, `.VolumeIcon.icns`; hence a scroll bar) and file extensions (label `Noctule Scan.app` rather than `Noctule Scan`) are on in this Mac's Finder (`defaults read com.apple.finder`: ShowStatusBar 1, ShowPathbar 1, AppleShowAllFiles YES; AppleShowAllExtensions 1). Finder takes these globally, so they can't be checked here; on a default Mac they are off. Not changed (they are the owner's settings). `hide_extensions` stays out (see Task 2).
- **Waiting on the owner:** Step 3 (Light appearance: do the black labels read on the plates), and a look on a default-settings Mac or user account that the status/path bars and scroll bar are gone and the label reads `Noctule Scan`.
- Tests: `swift test --filter "BackgroundArtTests|MakeDMGTests"` passes (14 tests).
