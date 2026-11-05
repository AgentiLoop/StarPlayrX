#!/bin/zsh
# StarPlayrX for Mac — run the test suite.
# Usage: scripts/test-mac.sh

set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/StarPlayrXMac"

xcodebuild test -project StarPlayrXMac.xcodeproj -scheme StarPlayrXMac \
  -configuration Debug -derivedDataPath build-tests \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO
