#!/bin/zsh
# Creates a signed, update-ready release locally.
#
#   ./scripts/release.sh 1.1.0            # build + zip + appcast
#   ./scripts/release.sh 1.1.0 --publish  # ... and create the GitHub release
#
# Requirements: Sparkle EdDSA key in the login keychain (generate_keys),
# gh CLI authenticated for --publish.
set -e
# Unmatched globs must expand to nothing instead of aborting the script.
setopt NULL_GLOB
cd "$(dirname "$0")/.."

REPO="finn2212/PDFsPDFsPDFs"
VERSION=$1
if [ -z "$VERSION" ]; then
  echo "usage: ./scripts/release.sh <version> [--publish]" >&2
  exit 1
fi

# CFBundleVersion == marketing version, identical to the CI workflow —
# mixing schemes would silently break Sparkle's version comparison.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" Info.plist

./build_app.sh

ZIP="dist/PDFsPDFsPDFs-$VERSION.zip"
rm -f dist/PDFsPDFsPDFs-*.zip dist/appcast.xml
rm -rf dist/download
ditto -c -k --sequesterRsrc --keepParent dist/PDFsPDFsPDFs.app "$ZIP"

# generate_appcast signs the zip with the EdDSA key from the keychain
# and writes dist/appcast.xml. The version-pinned download URL keeps old
# appcast entries valid even after newer releases become "latest".
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
  dist/

# A key mismatch makes generate_appcast emit an UNSIGNED appcast with exit 0;
# ad-hoc-signed apps hard-require the EdDSA signature, so fail loudly here.
grep -q "sparkle:edSignature" dist/appcast.xml || {
  echo "ERROR: appcast has no EdDSA signature (key mismatch?)" >&2
  exit 1
}
echo "Created $ZIP + dist/appcast.xml"

# A second copy under a version-less name, so the website can link to
# releases/latest/download/PDFsPDFsPDFs.zip and never needs updating.
# It lives in a subdirectory because generate_appcast scans dist/ for zips
# and would otherwise read this copy as a second release entry.
STABLE="dist/download/PDFsPDFsPDFs.zip"
mkdir -p dist/download
cp "$ZIP" "$STABLE"

if [ "$2" = "--publish" ]; then
  gh release create "v$VERSION" "$ZIP" "$STABLE" dist/appcast.xml \
    -R "$REPO" \
    --title "PDFsPDFsPDFs $VERSION" \
    --generate-notes
  echo "Published release v$VERSION"
else
  echo "Publish with: gh release create v$VERSION $ZIP $STABLE dist/appcast.xml -R $REPO --title \"PDFsPDFsPDFs $VERSION\" --generate-notes"
fi
