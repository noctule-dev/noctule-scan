#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors

# Builds the NoctuleScan executable and wraps it in "build/Noctule Scan.app", ad-hoc signed, with the
# app icon compiled by scripts/compile-app-icon.sh: the official icon when NOCTULE_BRANDING_DIR names the art, else the placeholder.
# Usage: scripts/build-app.sh [debug|release]   (default: debug)
# The app is unsandboxed: it shares the RTSP cooldown record with the CLI. It is signed with the hardened
# runtime and Resources/NoctuleScan.entitlements (audio input, for a USB scanner's line-in), as a release is.
set -euo pipefail

configuration="${1:-debug}"
case "$configuration" in
    debug|release) ;;
    *) echo "usage: $0 [debug|release]" >&2; exit 2 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

swift build -c "$configuration" --product NoctuleScan
bin_dir="$(swift build -c "$configuration" --show-bin-path)"

app="$root/build/Noctule Scan.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
cp "$bin_dir/NoctuleScan" "$app/Contents/MacOS/NoctuleScan"
"$root/scripts/compile-app-icon.sh" "$app/Contents/Resources"
plutil -lint "$app/Contents/Info.plist" >/dev/null

codesign --force --options runtime --entitlements "$root/Resources/NoctuleScan.entitlements" --sign - "$app"
echo "built $app ($configuration)"
