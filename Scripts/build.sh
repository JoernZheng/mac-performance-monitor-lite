#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain-env.sh"
cd "$recorder_root"
exec swift build --disable-sandbox -c "${CONFIGURATION:-release}" -j "${SWIFT_JOBS:-2}" "$@"
