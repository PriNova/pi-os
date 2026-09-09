#!/bin/bash
# Shared headless SwiftPM invocation; keep generated state within host-macos.
set -euo pipefail
case "${1:-}" in
    build|test) command=$1; shift ;;
    *) printf 'Internal helper accepts build or test only.\n' >&2; exit 2 ;;
esac
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
[[ "$(uname -s)" == Darwin ]] || { printf 'macOS with an existing Xcode toolchain is required.\n' >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET=14.0
export CLANG_MODULE_CACHE_PATH="$root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/swift-module-cache"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$SWIFTPM_MODULECACHE_OVERRIDE"
exec xcrun swift "$command" \
    --package-path "$root" --scratch-path "$root/.build" \
    --cache-path "$root/.build/cache" --config-path "$root/.build/config" \
    --security-path "$root/.build/security" --manifest-cache local \
    --disable-netrc --disable-keychain --jobs 4 "$@"
