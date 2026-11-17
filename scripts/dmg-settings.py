# dmgbuild settings for the Bowerbird disk image. Invoked by make-dmg.sh as
#   dmgbuild -s scripts/dmg-settings.py -D app=build/Bowerbird.app "Bowerbird" out.dmg
#
# The window is a plain colour with two icons, the app and an Applications shortcut, and nothing
# else. A drawn background with an arrow and a first-launch note was tried: Finder on macOS 26
# draws background pictures at pixel size, so the Retina version spilled off the window and the
# 1x version looked soft. Plain colour has nothing to get wrong. The first-launch note lives on
# the release page and in the README instead.

app = defines["app"]  # noqa: F821  (dmgbuild injects `defines`)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Support/Bowerbird.icns"

background = "#f9f8fb"  # dmgbuild wants lowercase hex
# Finder keeps the window frame, title bar included; 28 pt of this height is the title bar.
window_rect = ((200, 120), (660, 340))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 12
icon_locations = {
    "Bowerbird.app": (165, 150),
    "Applications": (495, 150),
}
