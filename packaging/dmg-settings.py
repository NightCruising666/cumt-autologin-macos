# SPDX-License-Identifier: AGPL-3.0-only
# Used by dmgbuild; all artifact paths are supplied by package_dmg.sh.
format = "UDZO"
filesystem = "HFS+"
files = [(defines["app"], "校园网助手.app")]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
icon_locations = {"校园网助手.app": (160, 200), "Applications": (480, 200)}
window_rect = ((200, 200), (640, 400))
default_view = "icon-view"
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
arrange_by = None
icon_size = 96
text_size = 14
label_pos = "bottom"
include_icon_view_settings = True
include_list_view_settings = False
