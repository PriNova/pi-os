#!/bin/bash
# Build a local development bundle. Never launches, installs or signs the app.
set -euo pipefail
[[ $# == 0 ]] || { printf 'Usage: %s\n' "$0" >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
"$root/scripts/swift.sh" build --configuration release --product pi-os-native-shell -Xswiftc -warnings-as-errors
bin=$("$root/scripts/swift.sh" build --configuration release --show-bin-path)
app="$root/dist/pi-os-dev.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/pi-os-native-shell" "$app/Contents/MacOS/pi-os-native-shell"
chmod 755 "$app/Contents/MacOS/pi-os-native-shell"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"
printf '\nBuilt (not launched): %s\n' "$app"
printf 'Experimental shell only; no agent. No distribution signing or notarization performed.\n'
