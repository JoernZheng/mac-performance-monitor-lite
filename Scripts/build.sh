#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain-env.sh"
cd "$recorder_root"
swift build --disable-sandbox -c "${CONFIGURATION:-release}" -j "${SWIFT_JOBS:-2}" "$@"

# Wrap the optional viewer as a normal macOS app for Dock/window lifecycle support.
recorder_configuration="${CONFIGURATION:-release}"
recorder_products="$recorder_root/.build/$recorder_configuration"
recorder_app="$recorder_products/Mac Performance Monitor Lite.app"
mkdir -p "$recorder_app/Contents/MacOS"
install -m 755 "$recorder_products/mpml-dashboard" "$recorder_app/Contents/MacOS/mpml-dashboard"
install -m 644 "$recorder_root/Resources/Dashboard-Info.plist" "$recorder_app/Contents/Info.plist"
codesign --force --sign - "$recorder_app"
