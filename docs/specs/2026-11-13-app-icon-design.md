# App icon — design

> **Note (2026-11-20, Plan 21):** the icon and the installer background no longer live in this repository. Since Plan 21 the icon is in the design-language repository's `builds/noctule-scan/AppIcon.icon`, and this repository builds the placeholder `Resources/Placeholder/AppIcon.icon` unless `NOCTULE_BRANDING_DIR` names that folder. Paths below name where the art was when this was written.

Short design for a small change. Labels as in the main design: **(owner)** = decided by the owner; **(designer's call)** = a default the owner hasn't ruled on.

## Intent

The Mac app has no icon: `scripts/build-app.sh` copies only `Info.plist` and the binary into `build/Noctule Scan.app`, so the Dock shows the generic app icon. Give it the NoctuleScan icon from the owner's Noctule design language (`../noctule-design-language`, outside this repo; its README §4 and `icons/noctulescan/`). **(owner)**

This is the first step toward the design language, not the whole of it. **(owner)**

## Goals

- The Dock, Finder, the app switcher and About show the Noctule Scan icon: night background, moonlight bat, amber echoes, channel ticks with one locked. **(owner)**
- The icon gets the system's Liquid Glass treatment and its Default, Dark, Clear and Tinted appearances, as the design language specifies (README §4).
- One icon source that the iPad and iPhone apps can reuse later.

## Non-goals

- Renaming the app. It stays "Noctule Scan" (bundle name, `.app` folder, `~/Music/Noctule Scan/`), although the design language writes it as one word. **(owner)**
- Theming the app's views with the design language's colors and type. A separate piece of work (see the gap review the owner asked for alongside this).
- Other icons, a wordmark, or an About-panel redesign.

## Anti-goals

- Shipping the flattened `noctulescan-preview.svg` as the icon (the design language says it's for review only).
- An icon that macOS 26 shrinks onto a grey rounded square because it doesn't follow the new icon rules.
- Committing Anthropic's C2PA provenance metadata (see Constraints).

## Constraints

- The layers are copied into this repo: the design language folder isn't tracked anywhere this repo can reference.
- **Strip the C2PA block** (`<metadata><c2pa:manifest>…</c2pa:manifest></metadata>`) from every SVG committed here, and the `xmlns:c2pa="http://c2pa.org/manifest"` declaration it leaves unused. **(owner)** The originals in `../noctule-design-language` stay untouched as the owner's record. Nothing else in the SVGs changes: no reformatting, no color or geometry edits.
- The build stays SwiftPM plus `scripts/build-app.sh`; no Xcode project.
- `LSMinimumSystemVersion` is 26.0, so the icon only has to work on macOS 26 and later. Xcode 27.2 (with Icon Composer and `actool`) is installed.
- No Uniden logos or trademarks (AGENTS.md); `RealNamesTests` already scans `Resources/`.

## Approaches

1. **Icon Composer `.icon`, compiled by the build script. (owner: chosen)** Commit `Resources/AppIcon.icon` (the folder format Icon Composer saves: `icon.json` plus the layer SVGs); `build-app.sh` compiles it with `xcrun actool` into `Assets.car` and `AppIcon.icns` in the bundle's `Contents/Resources`, and `Info.plist` names it. Real glass and all appearances; the owner can open and adjust it in Icon Composer; reusable on iOS. Risk: `icon.json` isn't publicly documented, so writing it by hand may take some trial.
2. **Flattened `.icns`** from PNGs via `iconutil`. Simple, but no glass or appearances, and macOS 26 puts a full-bleed square icon on a grey plate. Rejected.
3. **Asset catalog with flattened PNGs.** Same look and drawbacks as 2, more files. Rejected.

## Design

- **Source:** `Resources/AppIcon.icon/`, holding the four NoctuleScan layers in order (`00-background`, `01-bat`, `02-echo`, `03-signal`), C2PA stripped, and an `icon.json` following the design language's Icon Composer setup:
  - groups: background alone; bat alone; echo and signal together;
  - glass on the bat and signal groups, subtle specular, no heavy refraction on the thin echo bands;
  - Default and Dark use the layer colors (Dark may darken the background toward `#000`); Clear and Tinted use the mono treatment (bat and signals white, opacities kept); bat and scan bar identical across all six appearances.
- **Build:** `build-app.sh` runs `xcrun actool` on `Resources/AppIcon.icon` for `macosx`, minimum deployment target 26.0, app icon `AppIcon`, output into the bundle's `Contents/Resources`, before signing. If `actool` fails the script fails (it already runs `set -euo pipefail`).
- **Info.plist:** `CFBundleIconName` = `AppIcon` (and `CFBundleIconFile` = `AppIcon` for the `.icns` fallback), added to `Resources/Info.plist` directly rather than merged from `actool`'s partial plist, so the tracked plist stays the single source.
- **Docs:** AGENTS.md's Mac-app paragraph says where the icon lives and that its source of truth is the design language; a note that the committed SVGs are stripped copies.

## What a trial compile settled (2026-11-13, in a scratch folder)

- A hand-written `icon.json` (three groups, front to back: echo and signal, bat, background; `glass` on the bat and signal layers, off on the echo layer so the thin bands aren't refracted **(designer's call)**) compiles with `xcrun actool --compile <dir> --platform macosx --minimum-deployment-target 26.0 --app-icon AppIcon --output-partial-info-plist <plist> <path>/AppIcon.icon` into `AppIcon.icns` and `Assets.car`, with Aqua, DarkAqua and tintable renditions; the partial plist names `CFBundleIconFile` and `CFBundleIconName` `AppIcon`. The rendered icon shows the macOS mask and glass.
- `actool` accepted a `fill-specializations` entry for the tinted appearance without complaint, but the compiled catalog gave no sign it took effect, and Icon Composer's file format isn't documented. So the Clear and Tinted treatment (the mono annotation) is set and checked **in Icon Composer**, which saves it into `icon.json`; the committed `icon.json` starts without specializations, and the system's own derivation is the fallback.
- The compile lives in its own script, `scripts/compile-app-icon.sh`, which `build-app.sh` calls, so a test can compile the icon into a temporary folder without building or signing the app. **(designer's call)**

## Left to the builder

- Setting the Clear and Tinted appearances in Icon Composer (the owner's hand check if the agent can't drive Icon Composer).
- Verification: `codesign -dv` still passes; `Contents/Resources` holds `Assets.car` and `AppIcon.icns`; the built app shows the icon in Finder and the Dock (macOS caches icons, so a rebuilt app may need `touch` on the bundle or a relaunch of the Dock to show a change). Launch it only under the usual rules (mock-only `NOCTULE_SETTINGS_DIR`, `NOCTULE_NO_USB_DETECTION=1`).
- Whether a test should assert the bundle contains the compiled icon (e.g. alongside `AppLifecycleIntegrationTests`, which already builds the app).
