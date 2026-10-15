# dmgbuild settings for Nocci's disk image. Scripts/build-dmg.sh passes the
# app, background, volume icon and layout with -D, so the window and the
# background are drawn from the same numbers.
app = defines["app"]
width, height = int(defines["width"]), int(defines["height"])
icon_y = int(defines["icon_y"])

format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["volume_icon"]
background = defines["background"]

window_rect = ((200, 160), (width, height))
default_view = "icon-view"
icon_size = int(defines["icon_size"])
text_size = 13
icon_locations = {
    "Nocci.app": (int(defines["app_x"]), icon_y),
    "Applications": (int(defines["applications_x"]), icon_y),
}
