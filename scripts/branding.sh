# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors
# Sourced (never run) by the scripts that use the app's art. Defines noctule_branding <repo-root>,
# which sets branding_dir to the absolute path of the official art folder, or to "" for the
# committed placeholder art, and says which on stderr. The folder comes from NOCTULE_BRANDING_DIR
# (set but empty means the placeholder), else from NOCTULE_BRANDING_DIR in config/branding.env;
# a relative path is taken from the repository root. The file is read as KEY=VALUE lines, never
# sourced. An official folder holds AppIcon.icon and dmg/background.tiff; anything else returns 1.

noctule_branding() {
    local root="$1" value="" line key
    branding_dir=""
    if [ -n "${NOCTULE_BRANDING_DIR+set}" ]; then
        value="$NOCTULE_BRANDING_DIR"
    elif [ -f "$root/config/branding.env" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|'#'*) continue ;; esac
            key="${line%%=*}"
            [ "$key" = "NOCTULE_BRANDING_DIR" ] || continue
            value="${line#*=}"
            case "$value" in
                \"*\") value="${value#\"}"; value="${value%\"}" ;;
                \'*\') value="${value#\'}"; value="${value%\'}" ;;
            esac
        done < "$root/config/branding.env"
    fi

    if [ -z "$value" ]; then
        echo "branding: placeholder (set NOCTULE_BRANDING_DIR for the official art)" >&2
        return 0
    fi
    case "$value" in /*) ;; *) value="$root/$value" ;; esac
    local resolved
    resolved="$(cd "$value" 2>/dev/null && pwd)" || resolved=""
    if [ -z "$resolved" ] || [ ! -d "$resolved/AppIcon.icon" ] || [ ! -f "$resolved/dmg/background.tiff" ]; then
        echo "branding: ${resolved:-$value} isn't a branding folder (it needs AppIcon.icon and dmg/background.tiff)" >&2
        return 1
    fi
    branding_dir="$resolved"
    echo "branding: $branding_dir" >&2
}
