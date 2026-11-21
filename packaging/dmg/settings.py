# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Sean Foley and the Noctule Scan contributors

# dmgbuild settings for the release image (make-dmg.sh passes -D app=<app> -D background=<tiff>).
# The window's numbers are the design's (docs/specs/2026-11-14-plan-13-installer-window.md): content
# 640x400 pt (window 640x432 with its title bar), icons 128 pt, labels 12 pt,
# icon centres (170, 214) and (470, 214), top-left origin.
import os

app = defines["app"]  # noqa: F821 (dmgbuild provides `defines`)
background = defines["background"]  # noqa: F821
app_name = os.path.basename(app)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
# hide_extensions is left out on purpose: dmgbuild sets it as a FinderInfo flag on the app, which makes
# `codesign --verify --strict` refuse the copy ("detritus not allowed"). Finder hides .app anyway
# (unless "Show all filename extensions" is on).
icon = os.path.join(app, "Contents", "Resources", "AppIcon.icns")
background = background

# Finder's window bounds include the 32 pt title bar (macOS 27, measured), so a 640x400 content area
# (the background's size) is a 640x432 window.
window_rect = ((200, 120), (640, 432))
default_view = "icon-view"
show_toolbar = show_status_bar = show_tab_view = show_pathbar = show_sidebar = False
icon_size = 128
text_size = 12
icon_locations = {app_name: (170, 214), "Applications": (470, 214)}
