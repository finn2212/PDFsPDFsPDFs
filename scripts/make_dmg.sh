#!/bin/zsh
# Builds dist/PDFsPDFsPDFs.dmg: a drag-to-Applications installer window with a
# designed background. Rendered headlessly via dmgbuild (writes the .DS_Store
# directly), so it needs no Finder automation and works in CI.
# Expects dist/PDFsPDFsPDFs.app to exist (run build_app.sh first).
#
#   ./scripts/make_dmg.sh              # -> dist/PDFsPDFsPDFs.dmg
#   ./scripts/make_dmg.sh 1.1.0        # -> dist/PDFsPDFsPDFs-1.1.0.dmg (+ stable copy)
set -e
cd "$(dirname "$0")/.."

APP="dist/PDFsPDFsPDFs.app"
VOLNAME="PDFsPDFsPDFs"
VERSION="$1"
FINAL_DMG="dist/PDFsPDFsPDFs.dmg"

[ -d "$APP" ] || { echo "ERROR: $APP not found — run ./build_app.sh first" >&2; exit 1; }

# Regenerate the background art if missing, so the repo builds from source alone.
if [ ! -f "assets/dmg/background.png" ] || [ ! -f "assets/dmg/background@2x.png" ]; then
  swift scripts/make_dmg_background.swift
fi

# dmgbuild is a pip package; prefer it on PATH, fall back to the user install dir.
if ! command -v dmgbuild >/dev/null 2>&1; then
  export PATH="$PATH:$(python3 -c 'import site; print(site.getuserbase())')/bin"
fi
command -v dmgbuild >/dev/null 2>&1 || {
  echo "ERROR: dmgbuild not found. Install with: python3 -m pip install --user dmgbuild" >&2
  exit 1
}

rm -f "$FINAL_DMG"
export DMG_APP="$APP"
export DMG_ICON="assets/AppIcon.icns"
export DMG_BG="assets/dmg/background.png"

dmgbuild -s scripts/dmg_settings.py "$VOLNAME" "$FINAL_DMG"
echo "Built $FINAL_DMG"

# Version-pinned + stable copies for the release, mirroring the zip naming.
if [ -n "$VERSION" ]; then
  cp "$FINAL_DMG" "dist/PDFsPDFsPDFs-$VERSION.dmg"
  mkdir -p dist/download
  cp "$FINAL_DMG" dist/download/PDFsPDFsPDFs.dmg
  echo "Also wrote dist/PDFsPDFsPDFs-$VERSION.dmg + dist/download/PDFsPDFsPDFs.dmg"
fi
