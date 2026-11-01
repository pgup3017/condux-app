#!/bin/sh
# Builds Condux from source and opens it. No Apple Developer account is needed: the app is signed for this Mac only.
# Extra xcodebuild arguments can be passed through, for example: scripts/build-local.sh -configuration Debug
set -eu
cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Xcode is required. Install it from the App Store, open it once, and run this script again." >&2
  exit 1
fi

OUT=".build-xcode"
xcodebuild -project Condux.xcodeproj -scheme Condux -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$OUT" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO "$@" build

APP=$(ls -d "$OUT"/Build/Products/*/Condux.app | head -1)
echo "Built: $APP"
if [ -z "${CONDUX_NO_OPEN:-}" ]; then open "$APP"; fi
