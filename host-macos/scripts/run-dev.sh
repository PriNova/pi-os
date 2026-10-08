#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
"$ROOT/host-macos/scripts/build-app.sh"
# Direct launch allows explicit test switches. For TCC identity QA use `open` instead;
# a shell-launched app may inherit its terminal's permissions.
exec "$ROOT/host-macos/build/pi-os.app/Contents/MacOS/pi-os"
