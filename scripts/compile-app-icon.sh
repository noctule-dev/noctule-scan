#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors

# Compiles the app icon (an Icon Composer file) into AppIcon.icns and Assets.car in OUT_DIR,
# for "Noctule Scan.app"'s Contents/Resources. Fails if actool does, or if the icon it names
# isn't the one Resources/Info.plist names (a mismatch shows the generic icon, silently).
# Usage: scripts/compile-app-icon.sh OUT_DIR [ICON]
# The default ICON is the official art's AppIcon.icon when NOCTULE_BRANDING_DIR names it (or
# config/branding.env does), else the committed placeholder (scripts/branding.sh); it says which on stderr.
# An explicit ICON skips that choice.
set -euo pipefail

if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "usage: $0 OUT_DIR [ICON]" >&2
    exit 2
fi

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$1"
if [ $# -eq 2 ]; then
    icon="$2"
else
    # shellcheck source=branding.sh
    . "$root/scripts/branding.sh"
    noctule_branding "$root" || exit 1
    if [ -n "$branding_dir" ]; then
        icon="$branding_dir/AppIcon.icon"
    else
        icon="$root/Resources/Placeholder/AppIcon.icon"
    fi
fi
info="$root/Resources/Info.plist"

if [ ! -d "$icon" ]; then
    echo "compile-app-icon: no icon at $icon" >&2
    exit 1
fi

partial="$(mktemp -t compile-app-icon)"
trap 'rm -f "$partial"' EXIT

xcrun actool --compile "$out" --platform macosx --minimum-deployment-target 26.0 \
    --app-icon AppIcon --output-partial-info-plist "$partial" \
    --output-format human-readable-text --notices --warnings --errors "$icon"

# actool can report an error and still exit 0, so check what it wrote.
for file in AppIcon.icns Assets.car; do
    if [ ! -s "$out/$file" ]; then
        echo "compile-app-icon: actool didn't produce $out/$file" >&2
        exit 1
    fi
done

for key in CFBundleIconName CFBundleIconFile; do
    expected="$(/usr/libexec/PlistBuddy -c "Print :$key" "$info" 2>/dev/null || true)"
    produced="$(/usr/libexec/PlistBuddy -c "Print :$key" "$partial" 2>/dev/null || true)"
    if [ "$expected" != "$produced" ]; then
        echo "compile-app-icon: Info.plist names icon \"$expected\" but actool produced \"$produced\" ($key)" >&2
        exit 1
    fi
done

echo "compiled $icon into $out"
