#!/bin/bash
# Pure helper tests only. No app launch, hotkey registration or TCC requests.
set -euo pipefail
[[ $# == 0 ]] || { printf 'Usage: %s\n' "$0" >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
exec "$root/scripts/swift.sh" test -Xswiftc -warnings-as-errors
