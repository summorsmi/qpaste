#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/qpaste-clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/qpaste-swift-cache"
TOOLCHAIN_BIN="$(dirname "$(xcrun --find swiftc)")"
swift test --disable-sandbox --cache-path .build/cache --config-path .build/config --security-path .build/security \
  -Xswiftc -plugin-path -Xswiftc "$TOOLCHAIN_BIN/../lib/swift/host/plugins/testing" "$@"
