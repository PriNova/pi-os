#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT="$ROOT/host-macos/build/pi-os.app"
IDENTITY="${PI_OS_SIGN_IDENTITY:--}"
NODE="${PI_OS_NODE_PATH:-$(command -v node || true)}"
if [[ ! -x "$NODE" || "$NODE" != /* ]]; then
  echo "Set PI_OS_NODE_PATH to an absolute Node 22+ executable path." >&2; exit 1
fi
if [[ -d "$OUTPUT" ]] && /usr/sbin/lsof -t "$OUTPUT/Contents/MacOS/pi-os" >/dev/null 2>&1; then
  echo "Quit the existing build of pi-os before replacing it." >&2; exit 1
fi
npm --prefix "$ROOT/node-harness" run build
swift build --jobs 2 --package-path "$ROOT/host-macos" -c release --product pi-os
mkdir -p "$ROOT/host-macos/build"
STAGE="$(mktemp -d "$ROOT/host-macos/build/.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/pi-os.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/host-macos/.build/release/pi-os" "$APP/Contents/MacOS/pi-os"
cp "$ROOT/host-macos/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/host-macos/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
if [[ "${PI_OS_BUNDLE_RUNTIME:-}" == "1" ]]; then
  "$ROOT/host-macos/scripts/bundle-runtime.sh" "$APP"
else
  # Explicit development configuration, never PATH search or shell-profile execution at runtime.
  /usr/libexec/PlistBuddy -c "Add :PiOSNodePath string $NODE" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :PiOSNodeEntry string $ROOT/node-harness/dist/index.js" "$APP/Contents/Info.plist"
fi
if [[ "$IDENTITY" == "-" ]]; then
  echo "WARNING: ad-hoc UI-only build. Its code identity changes on rebuild and invalidates existing TCC grants." >&2
  echo "Do not use it to refresh an authorized installation. Select PI_OS_SIGN_IDENTITY for stable installs." >&2
  codesign --force --sign - "$APP"
else
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"
# Build from an empty stage: no stale bundled runtime or dependency survives a mode switch.
if [[ -d "$OUTPUT" ]]; then mv "$OUTPUT" "$STAGE/previous.app"; fi
if ! mv "$APP" "$OUTPUT"; then
  if [[ -d "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$OUTPUT"; fi
  exit 1
fi
echo "$OUTPUT"
