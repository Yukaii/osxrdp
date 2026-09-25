#!/bin/bash
#
# Build the "OSXRDP Microphone" Core Audio HAL plug-in (AudioDriver/) as a
# universal bundle. It is installed to /Library/Audio/Plug-Ins/HAL.
#
# Usage:
#   scripts/build_audio_driver.sh [output dir]      # default: build/audiodriver
#
#   SIGN_IDENTITY="Developer ID Application: ..." scripts/build_audio_driver.sh
#       signs for distribution (default: ad-hoc signature)
#

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$REPO_DIR/build/audiodriver}"
BUNDLE="$OUT_DIR/OSXRDPAudio.driver"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MACOS_MIN="12.0"

# CommandLineTools SDK 가 링커와 맞지 않는 환경이 있으므로 가능하면 Xcode toolchain 을 사용
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
CC="$(xcrun -f clang)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$REPO_DIR/AudioDriver/Info.plist" "$BUNDLE/Contents/Info.plist"

"$CC" -isysroot "$SDKROOT" -bundle \
    -arch arm64 -arch x86_64 \
    -mmacosx-version-min="$MACOS_MIN" \
    -O2 -Wall -Wextra -Werror \
    -framework CoreAudio -framework CoreFoundation \
    -o "$BUNDLE/Contents/MacOS/OSXRDPAudio" \
    "$REPO_DIR/AudioDriver/OSXRDPAudioDriver.c"

if [ "$SIGN_IDENTITY" = "-" ]; then
    codesign --force --sign - "$BUNDLE"
else
    codesign --force --sign "$SIGN_IDENTITY" --timestamp --options runtime "$BUNDLE"
fi

lipo -archs "$BUNDLE/Contents/MacOS/OSXRDPAudio"
echo "Built $BUNDLE"
