#!/bin/bash
# Removes only login startup; recorded history and the CLI are preserved.
set -euo pipefail
recorder_root=$(cd "$(dirname "$0")/.." && pwd)
recorder_binary="$recorder_root/.build/release/mpml"
if [ ! -x "$recorder_binary" ]; then
    recorder_binary="$HOME/Library/Application Support/MacPerformanceRecorder/bin/mpml"
fi
if [ ! -x "$recorder_binary" ]; then
    echo 'Build first with Scripts/build.sh, or run mpml uninstall.' >&2
    exit 1
fi
exec "$recorder_binary" uninstall
