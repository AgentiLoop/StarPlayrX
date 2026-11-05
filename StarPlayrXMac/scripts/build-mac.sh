#!/bin/zsh
# StarPlayrX for Mac — quick debug build (no signing/notarization).
# Mirrors the "From the command line" section of README.md.
#
# Usage: scripts/build-mac.sh        (from anywhere; paths are resolved from the repo)

set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT/StarPlayrXMac"

xcodebuild -project StarPlayrXMac.xcodeproj -scheme StarPlayrXMac \
  -configuration Release -derivedDataPath build \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build

echo "== built: $ROOT/StarPlayrXMac/build/Build/Products/Release/StarPlayrX.app"
open build/Build/Products/Release/StarPlayrX.app
