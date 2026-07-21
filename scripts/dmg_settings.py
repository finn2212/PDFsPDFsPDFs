# dmgbuild settings for the PDFsPDFsPDFs installer DMG.
# Driven entirely by environment variables set in make_dmg.sh, and rendered
# headlessly (dmgbuild writes the .DS_Store directly) so it works in CI without
# Finder automation or a logged-in GUI session.
import os.path

application = os.environ["DMG_APP"]
appname = os.path.basename(application)

# Contents: the app plus an Applications symlink to drag onto.
files = [application]
symlinks = {"Applications": "/Applications"}

# Volume icon.
icon = os.environ["DMG_ICON"]

# Window: 600x400 icon view, no chrome, designed background.
# lookForHiDPI picks up background@2x.png next to the @1x file automatically.
background = os.environ["DMG_BG"]
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((300, 150), (600, 400))
icon_size = 128
text_size = 12

# Same 600x400 space as the background art: app on the left, Applications right.
icon_locations = {
    appname: (155, 195),
    "Applications": (445, 195),
}

# Compressed, read-only distributable image.
format = "UDZO"
filesystem = "HFS+"
