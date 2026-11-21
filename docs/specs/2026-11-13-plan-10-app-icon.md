# Plan 10: App icon — Implementation Plan

> **Note (2026-11-20, Plan 21):** the icon and the installer background no longer live in this repository. Since Plan 21 the icon is in the design-language repository's `builds/noctule-scan/AppIcon.icon`, and this repository builds the placeholder `Resources/Placeholder/AppIcon.icon` unless `NOCTULE_BRANDING_DIR` names that folder. Paths below name where the art was when this was written.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `build/Noctule Scan.app` shows the Noctule Scan icon (Liquid Glass, all appearances) instead of the generic app icon.

**Architecture:** The four NoctuleScan layers from the owner's design language, C2PA stripped, live in an Icon Composer file, `Resources/AppIcon.icon`. A new `scripts/compile-app-icon.sh` compiles it with `xcrun actool` into `Assets.car` and `AppIcon.icns`; `scripts/build-app.sh` calls it into the bundle's `Contents/Resources` before signing, and `Resources/Info.plist` names the icon.

**Tech Stack:** Icon Composer `.icon` format, `actool` (Xcode 27.2), bash, Swift Testing.

**Spec:** `docs/specs/2026-11-13-app-icon-design.md` (read its "What a trial compile settled" section: the `actool` command and `icon.json` below come from that trial).

## Global Constraints

- The layers' source: `../noctule-design-language/icons/noctulescan/layers/` (outside this repo, untracked). Never edit those originals.
- Committed SVGs carry no C2PA: the `<metadata><c2pa:manifest>…</c2pa:manifest></metadata>` block and the `xmlns:c2pa="http://c2pa.org/manifest"` declaration are removed; nothing else in them changes (no reformatting, colors or geometry).
- The icon's name is `AppIcon` everywhere: the `.icon` file's basename, `actool --app-icon`, `CFBundleIconName`, `CFBundleIconFile`.
- `--minimum-deployment-target 26.0`, matching `LSMinimumSystemVersion`.
- The app's name stays "Noctule Scan" (owner).
- No Xcode project; the build stays SwiftPM plus `scripts/build-app.sh`.
- Agents never launch the app except as AGENTS.md says (a temporary `NOCTULE_SETTINGS_DIR` with only mock stations, `NOCTULE_NO_USB_DETECTION=1`). Nothing in this plan needs the app launched: the icon is checked from the bundle.

## Review Focus

1. **An icon name that doesn't match.** If `Info.plist`, the `.icon` basename and `--app-icon` disagree, macOS silently shows the generic icon. `compile-app-icon.sh` checks `actool`'s partial plist against `Resources/Info.plist` and fails on a mismatch; `infoPlistNamesTheCompiledIcon` pins it (Task 2).
2. **C2PA coming back** when someone recopies the layers from the design language. `layersCarryNoProvenanceMetadata` fails on any `c2pa` or `<metadata` (Task 1).
3. **A broken compile that still produces an app.** A missing `.icon` or an `actool` error must fail `build-app.sh`, never ship an iconless bundle. `failsWithoutTheIcon` (Task 2); `build-app.sh` already runs `set -euo pipefail`.
4. **Real names in the new files.** `RealNamesTests` doesn't read `.svg` files today; Task 1 adds the extension and pins that the icon files are scanned.
5. **A machine without Xcode's `actool`** (a Command Line Tools-only setup). The compile tests are skipped there, with the reason given; `build-app.sh` fails with `actool`'s own error, which is correct for a build that needs it.

---

### Task 0: Branch and the design docs

- [ ] **Step 1:** `git checkout -b feature/app-icon` (from `main`).
- [ ] **Step 2: Commit the two design docs written during brainstorming**

```bash
git add docs/specs/2026-11-13-app-icon-design.md docs/specs/2026-11-13-design-language-gap-review.md docs/specs/2026-11-13-plan-10-app-icon.md
git commit -m "docs: app icon design, plan 10, and the design language gap review"
```

### Task 1: The icon source

**Files:**
- Create: `Resources/AppIcon.icon/icon.json`, `Resources/AppIcon.icon/Assets/{00-background,01-bat,02-echo,03-signal}.svg`
- Create: `Tests/NoctuleCLIIntegrationTests/AppIconTests.swift`
- Modify: `Tests/NoctuleMockScannerTests/RealNamesTests.swift` (`trackedTextFiles` extensions; `scanCoversScriptsAndResources`)
- Modify: `LESSONS.md` (one dated entry, below)

**Interfaces:**
- Produces: `Resources/AppIcon.icon` (Task 2 compiles it); in `AppIconTests.swift`, a file-private `iconRoot: URL?` (the repository root found by walking up from `#filePath` to the directory holding `Package.swift`, as `RealNames.repositoryRoot` does) that Task 2's tests reuse.

- [ ] **Step 1: Write the failing tests** in `AppIconTests.swift`, `@Suite struct AppIconSourceTests`:

```swift
@Test func layersAreTheFourNoctuleScanLayers() throws
// contents of Resources/AppIcon.icon/Assets, sorted ==
// ["00-background.svg", "01-bat.svg", "02-echo.svg", "03-signal.svg"]

@Test func layersCarryNoProvenanceMetadata() throws
// for each layer: text.lowercased() contains neither "c2pa" nor "<metadata"

@Test func layersAreFullBleed1024() throws
// for each layer: text contains #"viewBox="0 0 1024 1024""#

@Test func iconJSONUsesEveryLayerInOrder() throws
// decode icon.json with JSONSerialization; groups = json["groups"] as [[String: Any]]
// groups.count == 3
// image-names per group, in order == [["03-signal.svg", "02-echo.svg"], ["01-bat.svg"], ["00-background.svg"]]
// glass per layer: signal true, echo false, bat true, background false
```

And in `RealNamesTests.scanCoversScriptsAndResources`, add `"Resources/AppIcon.icon/icon.json"` and `"Resources/AppIcon.icon/Assets/01-bat.svg"` to the paths it expects.

- [ ] **Step 2: Run them to see them fail**

Run: `NOCTULE_NO_USB_DETECTION=1 swift test --filter 'AppIconSourceTests|RealNamesTests'`
Expected: FAIL (no `Resources/AppIcon.icon`; the two new paths not scanned).

- [ ] **Step 3: Copy the layers, stripped**

```bash
mkdir -p Resources/AppIcon.icon/Assets
for f in 00-background 01-bat 02-echo 03-signal; do
  perl -0pe 's#<metadata><c2pa:manifest>.*?</c2pa:manifest></metadata>##s; s# xmlns:c2pa="http://c2pa.org/manifest"##' \
    ../noctule-design-language/icons/noctulescan/layers/$f.svg > Resources/AppIcon.icon/Assets/$f.svg
done
```

Check that only those two pieces changed: for each layer, `diff` the result against the original with the same two substitutions applied by `sed` instead of `perl` and expect no output; and `grep -c c2pa Resources/AppIcon.icon/Assets/*` prints 0 for each.

- [ ] **Step 4: Write `Resources/AppIcon.icon/icon.json`** exactly as the trial compile used it (groups front to back; the design language's grouping, glass off on the thin echo bands):

```json
{
  "groups" : [
    {
      "layers" : [
        { "glass" : true, "image-name" : "03-signal.svg", "name" : "signal" },
        { "glass" : false, "image-name" : "02-echo.svg", "name" : "echo" }
      ],
      "name" : "signal"
    },
    {
      "layers" : [ { "glass" : true, "image-name" : "01-bat.svg", "name" : "bat" } ],
      "name" : "bat"
    },
    {
      "layers" : [ { "glass" : false, "image-name" : "00-background.svg", "name" : "background" } ],
      "name" : "background"
    }
  ],
  "supported-platforms" : { "circles" : [ "watchOS" ], "squares" : "shared" }
}
```

- [ ] **Step 5: Add `"svg"`** to the `extensions` set in `RealNames.trackedTextFiles`.

- [ ] **Step 6: Run the tests to see them pass**

Run: `NOCTULE_NO_USB_DETECTION=1 swift test --filter 'AppIconSourceTests|RealNamesTests'`
Expected: PASS.

- [ ] **Step 7: Add the LESSONS.md entry** (newest first, dated 2026-11-13): `actool` and `ictool` have no `--help` (each answers a plist error; `ictool` points to a man page that isn't installed), and Icon Composer's `icon.json` isn't documented. A trial `.icon` written by hand compiled with `xcrun actool --compile … --app-icon AppIcon … AppIcon.icon` into `AppIcon.icns` and `Assets.car`, but a `fill-specializations` entry for the tinted appearance left no visible trace in `assetutil --info`. What to do: check an `.icon`'s appearances in Icon Composer, not from the compiled catalog; and when recopying layers from the design language, strip C2PA (the metadata block and its `xmlns:c2pa`), which `AppIconSourceTests` checks.

- [ ] **Step 8: Commit**

```bash
git add Resources/AppIcon.icon Tests/NoctuleCLIIntegrationTests/AppIconTests.swift Tests/NoctuleMockScannerTests/RealNamesTests.swift LESSONS.md
git commit -m "feat: the NoctuleScan app icon source, C2PA stripped"
```

### Task 2: Compile the icon into the app

**Files:**
- Create: `scripts/compile-app-icon.sh` (executable)
- Modify: `scripts/build-app.sh` (call it after copying the binary, before `plutil` and `codesign`)
- Modify: `Resources/Info.plist` (two keys)
- Modify: `Tests/NoctuleCLIIntegrationTests/AppIconTests.swift`, `Tests/NoctuleMockScannerTests/RealNamesTests.swift` (the script's path in `scanCoversScriptsAndResources`)
- Modify: `Package.swift:37-38` (the comment naming what `build-app.sh` uses)

**Interfaces:**
- Consumes: `Resources/AppIcon.icon`; `iconRoot` from Task 1.
- Produces: `scripts/compile-app-icon.sh OUT_DIR [ICON]`. `ICON` defaults to `<repo>/Resources/AppIcon.icon`. On success it writes `OUT_DIR/AppIcon.icns` and `OUT_DIR/Assets.car`, prints one line `compiled <ICON> into <OUT_DIR>`, exits 0. It exits non-zero, with `actool`'s messages on stderr, when `ICON` is missing, `actool` reports an error, either output is missing, or `actool`'s partial plist's `CFBundleIconName` or `CFBundleIconFile` differs from `Resources/Info.plist`'s (message: `compile-app-icon: Info.plist names icon "<x>" but actool produced "<y>"`).

- [ ] **Step 1: Write the failing tests**, `@Suite struct AppIconCompileTests` in `AppIconTests.swift`, enabled only when `/usr/bin/xcrun --find actool` exits 0 (reason: `"needs Xcode's actool"`). Each runs the script with `Subprocess` (from `IntegrationSupport.swift`) and a fresh temporary `OUT_DIR`, waits with `waitFor(120) { !p.process.isRunning }` before `finish()` (a cold `actool` can take longer than `finish()`'s 10 s), and removes the directory afterwards:

```swift
@Test func compilesIntoIcnsAndAssetCatalog() throws
// status == 0; AppIcon.icns and Assets.car exist in OUT_DIR, each larger than 1 KB

@Test func infoPlistNamesTheCompiledIcon() throws
// Resources/Info.plist (PropertyListSerialization): CFBundleIconName == "AppIcon", CFBundleIconFile == "AppIcon";
// after a compile, OUT_DIR contains "\(CFBundleIconFile).icns"

@Test func failsWithoutTheIcon() throws
// ICON = OUT_DIR/../Missing.icon: status != 0; OUT_DIR holds no Assets.car and no AppIcon.icns
```

And in `RealNamesTests.scanCoversScriptsAndResources`, add `"scripts/compile-app-icon.sh"` to the paths it expects.

- [ ] **Step 2: Run them to see them fail**

Run: `NOCTULE_NO_USB_DETECTION=1 swift test --filter AppIconCompileTests`
Expected: FAIL (no script; `Info.plist` lacks the keys). `NOCTULE_NO_USB_DETECTION=1 swift test --filter RealNamesTests/scanCoversScriptsAndResources` fails too (script not there).

- [ ] **Step 3: Write `scripts/compile-app-icon.sh`** in the style of `build-app.sh` (header comment with usage, `set -euo pipefail`, `root` from `dirname "$0"`). The `actool` call, verified in the trial:

```bash
xcrun actool --compile "$out" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon AppIcon --output-partial-info-plist "$partial" \
  --output-format human-readable-text --notices --warnings --errors "$icon"
```

`$partial` is a `mktemp` file removed on exit (`trap`). Compare names with `/usr/libexec/PlistBuddy -c 'Print :CFBundleIconName'` on both plists (and the same for `CFBundleIconFile`). `actool` exits 0 on some errors, so check that both outputs exist rather than trusting its status alone.

- [ ] **Step 4: Add the keys to `Resources/Info.plist`** in its alphabetical order: `CFBundleIconFile` = `AppIcon`, `CFBundleIconName` = `AppIcon`.

- [ ] **Step 5: Call it from `build-app.sh`**: `"$root/scripts/compile-app-icon.sh" "$app/Contents/Resources"` after `cp "$bin_dir/NoctuleScan" …`; update the header comment to say the bundle gets the compiled icon from `Resources/AppIcon.icon`. Update `Package.swift`'s comment the same way.

- [ ] **Step 6: Run the tests to see them pass**

Run: `NOCTULE_NO_USB_DETECTION=1 swift test --filter 'AppIcon|RealNamesTests'`
Expected: PASS.

- [ ] **Step 7: Build the app and check the bundle**

Run: `scripts/build-app.sh && codesign -dv "build/Noctule Scan.app" && ls "build/Noctule Scan.app/Contents/Resources"`
Expected: `built …`; codesign prints the identifier `org.noctulescan.NoctuleScan` with no error; `Resources` lists `AppIcon.icns` and `Assets.car`.

Then look at it without launching the app: `qlmanage -t -s 512 -o <scratch dir> "build/Noctule Scan.app"` and view the PNG; expect the bat, two amber echo arcs and the tick row with one tall amber tick, on the night background inside the macOS rounded-square mask (not on a grey plate).

- [ ] **Step 8: Commit**

```bash
git add scripts/compile-app-icon.sh scripts/build-app.sh Resources/Info.plist Package.swift Tests/NoctuleCLIIntegrationTests/AppIconTests.swift Tests/NoctuleMockScannerTests/RealNamesTests.swift
git commit -m "feat: build-app.sh compiles the app icon into the bundle"
```

### Task 3: Docs, the full suite, and the appearance check

**Files:**
- Modify: `AGENTS.md` (the Mac app paragraph, where it describes `scripts/build-app.sh`)

- [ ] **Step 1: Update AGENTS.md.** After "assembles `build/Noctule Scan.app` (git-ignored) from `Resources/Info.plist`", add that the bundle's icon comes from `Resources/AppIcon.icon` (an Icon Composer file: the NoctuleScan layers from the owner's design language, `../noctule-design-language`, with C2PA stripped), compiled by `scripts/compile-app-icon.sh` with `actool` into `Assets.car` and `AppIcon.icns`; to change the icon, edit it in Icon Composer (`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`) or recopy the layers stripped (LESSONS.md 2026-11-13); and macOS caches icons, so after a change `touch` the bundle (or `killall Dock`) before judging it.

- [ ] **Step 2: Full suite**

Run: `NOCTULE_NO_USB_DETECTION=1 swift test`
Expected: all pass (hardware suites skipped). If a known flake from LESSONS.md fails, rerun that suite alone before suspecting the change.

- [ ] **Step 3: iOS build still clean** (nothing here touches shared code; this is the routine check)

Run: `xcodebuild -scheme NoctuleAppCore -destination 'generic/platform=iOS' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add AGENTS.md
git commit -m "docs: where the app icon lives and how it is built"
```

- [ ] **Step 5: The owner's appearance check (hand check; report it as pending if not done).** Open `Resources/AppIcon.icon` in Icon Composer. Preview Default, Dark, Clear light/dark and Tinted light/dark. Per the design language: the bat and scan bar look the same in all six; Dark may darken the background toward black; in Clear and Tinted the bat and signals are white with their opacities kept. If Clear or Tinted don't show that, set the mono treatment in Icon Composer and save; then rerun `swift test --filter AppIcon` (the tests check layer names and glass, not appearance keys, so they still pass) and commit the changed `icon.json` with `fix: the icon's Clear and Tinted appearances`. An agent may do this only if the owner grants it access to Icon Composer; otherwise it is the owner's.
