#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="${PI_OS_INSTALL_PATH:-$HOME/Applications/pi-os.app}"
# A bundle ID alone is not a stable TCC identity. Ad-hoc signatures are tied to
# cdhash; replacing the binary leaves Screen Recording's stored requirement stale.
if [[ -z "${PI_OS_SIGN_IDENTITY:-}" || "${PI_OS_SIGN_IDENTITY:-}" == "-" ]]; then
  if [[ "${PI_OS_ALLOW_ADHOC_INSTALL:-}" != "1" ]]; then
    echo "Install blocked: select a stable code-signing certificate with PI_OS_SIGN_IDENTITY." >&2
    echo "Ad-hoc updates invalidate Screen Recording grants and can cause repeated permission prompts." >&2
    echo "The installed app was not changed. UI-only probes can still use build-app.sh." >&2
    echo "For an explicitly consented disposable install only: PI_OS_ALLOW_ADHOC_INSTALL=1." >&2
    exit 78
  fi
  echo "WARNING: explicitly requested ad-hoc install; expect a one-time permission repair after replacing a granted build." >&2
  echo "Quit pi-os, run: tccutil reset ScreenCapture dev.pi-os.mac, then open the installed app and grant it again." >&2
fi
if [[ "$DEST" != /*/pi-os.app ]]; then echo "Install path must be an absolute pi-os.app path" >&2; exit 1; fi
if [[ -f "$DEST/Contents/MacOS/pi-os" ]] && /usr/sbin/lsof -t "$DEST/Contents/MacOS/pi-os" >/dev/null 2>&1; then
  echo "Quit the installed pi-os from its menu before refreshing. No process was killed." >&2; exit 1
fi
"$ROOT/host-macos/scripts/build-app.sh"
SOURCE="$ROOT/host-macos/build/pi-os.app"
if [[ -d "$DEST" ]]; then
  REQUIREMENT="$(codesign -d -r- "$DEST" 2>&1 | grep 'designated =>' | head -1 || true)"
  REQUIREMENT="${REQUIREMENT#*designated => }"
  if [[ -z "$REQUIREMENT" ]] || ! codesign --verify --strict -R "=$REQUIREMENT" "$SOURCE" >/dev/null 2>&1; then
    if [[ "${PI_OS_ALLOW_SIGNING_CHANGE:-}" != "1" ]]; then
      echo "Install blocked: this build does not satisfy the installed app's permission identity." >&2
      echo "For an explicit one-time signing migration, use PI_OS_ALLOW_SIGNING_CHANGE=1 and repair only pi-os's Screen Recording grant afterward." >&2
      exit 78
    fi
    echo "Signing identity migration selected. After installing, reset only: tccutil reset ScreenCapture dev.pi-os.mac; then approve the new app." >&2
  fi
fi
mkdir -p "$(dirname "$DEST")"
STAGE="$(mktemp -d "$(dirname "$DEST")/.pi-os-install.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
/usr/bin/ditto "$SOURCE" "$STAGE/pi-os.app"
codesign --verify --strict "$STAGE/pi-os.app"
if [[ -d "$DEST" ]]; then mv "$DEST" "$STAGE/previous.app"; fi
if ! mv "$STAGE/pi-os.app" "$DEST"; then
  if [[ -d "$STAGE/previous.app" ]]; then mv "$STAGE/previous.app" "$DEST"; fi
  exit 1
fi
echo "Installed: $DEST"
if [[ "${PI_OS_BUNDLE_RUNTIME:-}" != "1" ]]; then
  echo "Development build: references the checkout's node-harness and explicitly configured Node."
fi
echo "Launch with: open \"$DEST\""
