#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors
# Usage: ci-changes.sh <base> <head>
# Says whether a pull request changes only documentation, so CI can skip the full test suite
# (docs/specs/2026-11-21-ci-docs-fast-path.md). Prints `docs` when every path changed between the
# merge base of <base> and <head> and <head> is documentation, else `code`. Documentation is a path under
# docs/ or images/, LICENSE, NOTICE, or a .md file outside Sources/, Tests/ and Resources/ (matched ignoring case). An empty
# diff is `code`; when in doubt, `code`. Renames count on both sides (--no-renames).
# Exit 0 after printing, 2 on a usage error or when git can't compare the two.
set -u

if [ "$#" -ne 2 ]; then
    echo "usage: ci-changes.sh <base> <head>" >&2
    exit 2
fi
base="$1" head="$2"

paths=$(git diff --no-renames --name-only "$base...$head" 2>/dev/null) || { echo "ci-changes: can't compare $base and $head" >&2; exit 2; }

# The runner's file system ignores case, so `sources/x.md` lands in Sources/: match those trees in lower case.
scope=docs count=0
while IFS= read -r path; do
    [ -n "$path" ] || continue
    count=$((count + 1))
    lower=$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')
    case "$lower" in
        sources/*|tests/*|resources/*) scope=code; continue ;;
    esac
    case "$path" in
        docs/*|images/*|LICENSE|NOTICE) ;;
        *.md) ;;
        *) scope=code ;;
    esac
done <<< "$paths"

if [ "$count" -eq 0 ]; then scope=code; fi
echo "$scope"
