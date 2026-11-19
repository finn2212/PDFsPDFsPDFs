#!/bin/zsh
# Notarizes and staples a signed .app or .dmg.
#
#   ./scripts/notarize.sh dist/PDFsPDFsPDFs.app
#   ./scripts/notarize.sh dist/PDFsPDFsPDFs-2.1.1.dmg
#
# Needs an App Store Connect API key (Users and Access › Integrations › Team Keys, role Developer):
#   NOTARY_KEY_PATH   path to the AuthKey_<id>.p8 file
#   NOTARY_KEY_ID     the key's ID
#   NOTARY_ISSUER_ID  the issuer ID shown above the key list
set -e
TARGET=$1
if [ -z "$TARGET" ] || [ -z "$NOTARY_KEY_PATH" ] || [ -z "$NOTARY_KEY_ID" ] || [ -z "$NOTARY_ISSUER_ID" ]; then
  echo "usage: NOTARY_KEY_PATH=… NOTARY_KEY_ID=… NOTARY_ISSUER_ID=… ./scripts/notarize.sh <app|dmg>" >&2
  exit 1
fi

SUBMIT=$TARGET
if [[ "$TARGET" == *.app ]]; then
  # notarytool takes a zip, dmg or pkg; the ticket is then stapled to the app itself.
  SUBMIT="$(mktemp -d)/$(basename "$TARGET" .app).zip"
  ditto -c -k --keepParent "$TARGET" "$SUBMIT"
fi

xcrun notarytool submit "$SUBMIT" \
  --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" \
  --wait --timeout 30m --output-format json | tee /tmp/notary-result.json
grep -q '"status" *: *"Accepted"' /tmp/notary-result.json || {
  echo "ERROR: notarization was not accepted, see the log: xcrun notarytool log <id> …" >&2
  exit 1
}

xcrun stapler staple "$TARGET"
xcrun stapler validate "$TARGET"
if [[ "$TARGET" == *.app ]]; then
  spctl --assess --type execute -vv "$TARGET"
fi
echo "Notarized $TARGET"
