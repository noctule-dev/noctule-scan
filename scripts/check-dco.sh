#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors
# Usage: check-dco.sh <base> <head>
# Checks the Developer Certificate of Origin sign-off on every non-merge commit in <base>..<head>:
# each needs a `Signed-off-by: <author name> <author email>` trailer that matches its author
# exactly. Only real trailers count (git's own parser reads them), not the same words in the body.
# Exit 0 when all are signed off, 1 when any isn't, 2 on a usage error.
set -u

if [ "$#" -ne 2 ]; then
    echo "usage: check-dco.sh <base> <head>" >&2
    exit 2
fi
base="$1" head="$2"

shas=$(git rev-list --no-merges "$base..$head") || { echo "dco: can't list $base..$head" >&2; exit 2; }

count=0 failed=0
for sha in $shas; do
    count=$((count + 1))
    author=$(git log -1 --format='%an <%ae>' "$sha")
    signed=0
    while IFS= read -r trailer; do
        if [ "$trailer" = "$author" ]; then signed=1; break; fi
    done < <(git log -1 --format='%(trailers:key=Signed-off-by,valueonly,unfold)' "$sha")
    if [ "$signed" -eq 0 ]; then
        echo "dco: $(git log -1 --format='%h %s' "$sha"): no Signed-off-by for $author"
        failed=$((failed + 1))
    fi
done

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "dco: $count commits signed off"
