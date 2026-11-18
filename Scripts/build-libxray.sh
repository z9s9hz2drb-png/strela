#!/usr/bin/env bash
# Builds Frameworks/LibXray.xcframework (Xray-core + libXray, gomobile) for iOS.
# Requirements: macOS with Xcode (+ iOS Simulator runtime), Go 1.27+, Python 3, git.
set -euo pipefail

LIBXRAY_TAG="${LIBXRAY_TAG:-v26.11.9}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/.build/libXray"

echo "==> libXray $LIBXRAY_TAG"
rm -rf "$WORK"
mkdir -p "$ROOT/.build"
git clone --depth 1 --branch "$LIBXRAY_TAG" https://github.com/XTLS/libXray.git "$WORK"

GOPATH_BIN="$(go env GOPATH)/bin"
export PATH="$PATH:$GOPATH_BIN"
cd "$WORK"
# Official build script: pins Xray-core, installs gomobile/gobind, runs `gomobile bind`.
python3 build/main.py apple gomobile

if [ ! -d "$WORK/LibXray.xcframework" ]; then
  echo "LibXray.xcframework was not produced" >&2
  exit 1
fi

mkdir -p "$ROOT/Frameworks"
rm -rf "$ROOT/Frameworks/LibXray.xcframework"
cp -R "$WORK/LibXray.xcframework" "$ROOT/Frameworks/"
echo "==> Done: Frameworks/LibXray.xcframework"
