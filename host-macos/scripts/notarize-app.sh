#!/bin/bash
# Explicit release operation. Never invoked by normal builds/tests or installed updates.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="${PI_OS_RELEASE_APP:-$ROOT/host-macos/build/pi-os.app}"
PROFILE="${PI_OS_NOTARY_PROFILE:-}"
if [[ -z "$PROFILE" ]]; then
  echo "Set PI_OS_NOTARY_PROFILE to an explicitly configured notarytool Keychain profile." >&2; exit 78
fi
if [[ "$APP" != /*/pi-os.app || ! -f "$APP/Contents/Resources/runtime/bin/node" || ! -f "$APP/Contents/Resources/node-harness/dist/index.js" ]]; then
  echo "Release requires a self-contained pi-os.app, not a checkout-linked development build." >&2; exit 78
fi
IDENTITY="$(codesign -dv --verbose=4 "$APP" 2>&1)"
if ! grep -q '^Authority=Developer ID Application:' <<< "$IDENTITY"; then
  echo "Notarization requires a Developer ID Application signature; Apple Development/ad-hoc builds are not distribution releases." >&2; exit 78
fi
codesign --verify --deep --strict "$APP"
OUT="$ROOT/host-macos/build/release"
mkdir -p "$OUT"
ARCHIVE="$OUT/.pi-os-submission.zip"
trap 'rm -f "$ARCHIVE"' EXIT
# Submit a clean archive; never mix a new build with an earlier release ZIP.
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
xcrun notarytool submit "$ARCHIVE" --keychain-profile "$PROFILE" --wait --output-format json > "$OUT/notarization.json"
STATUS="$(plutil -extract status raw -o - "$OUT/notarization.json")"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "Notarization was not accepted. Inspect $OUT/notarization.json; no success artifact was produced." >&2
  rm -f "$ARCHIVE"; exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
# The downloadable artifact must contain the ticket, not the pre-stapling submission.
rm -f "$ARCHIVE"
ditto -c -k --keepParent "$APP" "$ARCHIVE"
mv "$ARCHIVE" "$OUT/pi-os.zip"
shasum -a 256 "$OUT/pi-os.zip" > "$OUT/pi-os.zip.sha256"
echo "Notarized/stapled archive: $OUT/pi-os.zip"
