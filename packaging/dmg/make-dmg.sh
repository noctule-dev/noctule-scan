#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors

# Makes the release DMG: a compressed image (UDZO) named "Noctule Scan" that opens as the designed
# Finder window (background art, icon positions, no toolbar), holding the app and an Applications
# link to drag it onto. dmgbuild (pinned by hash in packaging/dmg/requirements.txt, installed into
# build/dmg-venv on first use) copies the app itself, so its signature and a stapled ticket survive.
# Needs Python 3.10 or newer: NOCTULE_PYTHON if set, else python3 on PATH. NOCTULE_DMG_VENV moves
# the environment (tests). It then attaches the finished image read-only to check the app's copy.
# The background is the placeholder's unless NOCTULE_BRANDING_DIR names the official art folder.
# Signing and notarizing the image is packaging/notarize.sh's job.
# Usage: packaging/dmg/make-dmg.sh <app> <dmg>   (an image already at <dmg> is replaced)
#        packaging/dmg/make-dmg.sh --prepare     (only find Python and build or reuse the
#                                                 environment, then stop; CI runs it before the
#                                                 signing keychain exists, so PyPI is never reached with a key)
set -euo pipefail

usage() { echo "usage: $0 <app> <dmg> | --prepare" >&2; exit 2; }
prepare=0
if [[ $# -eq 1 && "$1" == --prepare ]]; then
    prepare=1
else
    [[ $# -eq 2 && "$1" != --prepare && "$2" != --prepare ]] || usage
    app="$1"
    dmg="$2"
    [[ "$app" == *.app && -d "$app" ]] || { echo "make-dmg: $app isn't an app bundle" >&2; exit 2; }
fi

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

# Python 3.10 or newer: the one NOCTULE_PYTHON names, else python3 on PATH.
# Prints the version, or nothing; a failed probe's stderr goes to the file named by $2.
python_version() {
    "$1" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>"$2" || true
}
python_is_new_enough() {
    local major minor
    IFS=. read -r major minor _ <<<"$1"
    [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] && { ((major > 3)) || ((major == 3 && minor >= 10)); }
}
py="${NOCTULE_PYTHON:-}"
if [[ -z "$py" ]]; then
    py="$(command -v python3 || true)"
fi
found=""
probe_err="$(mktemp)"
[[ -n "$py" ]] && found="$(python_version "$py" "$probe_err")"
if [[ -z "$found" ]] || ! python_is_new_enough "$found"; then
    why="none"
    if [[ -z "$found" ]]; then
        first="$(head -n 1 "$probe_err" | tr -d '\r')"
        [[ -n "$first" ]] && why="none: $first"
    else
        why="$found"
    fi
    rm -f "$probe_err"
    echo "make-dmg: needs Python 3.10 or newer (found $why); install one (brew install python; with pyenv, select a 3.10+ version) or set NOCTULE_PYTHON" >&2
    exit 1
fi
rm -f "$probe_err"

venv="${NOCTULE_DMG_VENV:-$root/build/dmg-venv}"
[[ -n "$venv" ]] || { echo "make-dmg: NOCTULE_DMG_VENV is empty" >&2; exit 2; }
requirements="$here/requirements.txt"
want="$(shasum -a 256 "$requirements" | cut -d ' ' -f 1)"

log="$(mktemp)"
mnt=""
cleanup() {
    rm -f "$log"
    if [[ -n "$mnt" ]]; then
        hdiutil detach -force "$mnt" >/dev/null 2>&1 || true
        rmdir "$mnt" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# Reused while requirements.txt is unchanged and dmgbuild imports; the hash file is written last, so an
# interrupted install is rebuilt. The environment's Python runs isolated (-I): PYTHONPATH and the user
# site can't stand in for the hash-pinned packages.
if [[ "$(cat "$venv/requirements.sha256" 2>/dev/null || true)" != "$want" ]] \
    || ! "$venv/bin/python" -I -c "import dmgbuild" >/dev/null 2>&1; then
    # Only an absent directory or a virtual environment is ever removed.
    if [[ -e "$venv" && ! -f "$venv/pyvenv.cfg" ]]; then
        echo "make-dmg: $venv isn't a virtual environment; not removing it" >&2
        exit 1
    fi
    echo "make-dmg: installing dmgbuild into $venv" >&2
    rm -rf "$venv"
    if ! { "$py" -m venv "$venv" \
            && "$venv/bin/python" -I -m pip install --require-hashes --only-binary :all: --disable-pip-version-check \
                -r "$requirements"; } >"$log" 2>&1; then
        cat "$log" >&2
        echo "make-dmg: couldn't install dmgbuild (see above)" >&2
        exit 1
    fi
    echo "$want" >"$venv/requirements.sha256"
fi

if [[ $prepare -eq 1 ]]; then
    echo "make-dmg: dmgbuild ready in $venv"
    exit 0
fi

# The installer art: the official folder's (NOCTULE_BRANDING_DIR; scripts/branding.sh) or the placeholder.
# shellcheck source=../../scripts/branding.sh
source "$root/scripts/branding.sh"
noctule_branding "$root" || exit 1
if [[ -n "$branding_dir" ]]; then
    background="$branding_dir/dmg/background.tiff"
else
    background="$here/placeholder/background.tiff"
fi

# dmgbuild's output is kept for a failure.
if ! "$venv/bin/python" -I -m dmgbuild -s "$here/settings.py" -D "app=$app" \
        -D "background=$background" "Noctule Scan" "$dmg" >"$log" 2>&1; then
    cat "$log" >&2
    echo "make-dmg: dmgbuild failed" >&2
    exit 1
fi

# dmgbuild copies the app with ditto and ignores its exit status, so check the copy here: attach the
# image read-only at a private mount point, compare it with the source, and when the source's signature
# verifies, require the copy's to as well. A bad image is removed.
bad_copy() {
    rm -f "$dmg"
    echo "make-dmg: the app in the image isn't a faithful copy: $1" >&2
    exit 1
}
mnt="$(mktemp -d)"
if ! hdiutil attach -readonly -nobrowse -noverify -noautoopen -mountpoint "$mnt" "$dmg" >"$log" 2>&1; then
    cat "$log" >&2
    mnt=""
    rm -f "$dmg"
    echo "make-dmg: couldn't attach the image to check it" >&2
    exit 1
fi
copy="$mnt/$(basename "$app")"
[[ -d "$copy" ]] || bad_copy "$(basename "$app") is missing"
diff -rq "$app" "$copy" >"$log" 2>&1 || { cat "$log" >&2; bad_copy "it differs from the source"; }
if codesign --verify --strict "$app" >/dev/null 2>&1; then
    codesign --verify --strict "$copy" >"$log" 2>&1 || { cat "$log" >&2; bad_copy "its signature doesn't verify"; }
fi
hdiutil detach "$mnt" >/dev/null 2>&1 || hdiutil detach -force "$mnt" >/dev/null 2>&1 || true
rmdir "$mnt" 2>/dev/null || true
mnt=""
echo "dmg: $dmg"
