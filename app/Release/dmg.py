# dmgbuild settings for Den's disk image; release.sh passes app=, icon= and background= with -D.
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]  # background@2x.png next to it is picked up for Retina
format = "ULFO"
filesystem = "HFS+"
window_rect = ((200, 160), (660, 400))
default_view = "icon-view"
show_toolbar = show_status_bar = show_pathbar = show_sidebar = show_tab_view = False
icon_size = 128
text_size = 13
icon_locations = {"Den.app": (170, 190), "Applications": (490, 190)}
hide_extension = ["Den.app"]
