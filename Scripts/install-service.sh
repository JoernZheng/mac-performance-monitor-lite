#!/bin/bash
# Compatibility wrapper for the self-contained CLI command.
set -euo pipefail
recorder_root=$(cd "$(dirname "$0")/.." && pwd)
recorder_binary="${1:-$recorder_root/.build/release/mpml}"
if [ ! -x "$recorder_binary" ]; then
    echo 'Build first with Scripts/build.sh, or run mpml install.' >&2
    exit 1
fi
exec "$recorder_binary" install
