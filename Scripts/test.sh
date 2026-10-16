#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/toolchain-env.sh"
cd "$recorder_root"
exec swift test --disable-sandbox -j "${SWIFT_JOBS:-2}" "$@"
