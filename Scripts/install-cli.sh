#!/bin/bash
# Installs only the CLI; the existing service and history stay in place.
set -euo pipefail
recorder_root=$(cd "$(dirname "$0")/.." && pwd)
recorder_binary="$recorder_root/.build/release/mpml"
recorder_support="$HOME/Library/Application Support/MacPerformanceRecorder"
recorder_command_dir="${1:-$HOME/.local/bin}"
recorder_command="$recorder_command_dir/mpml"
recorder_target="$recorder_support/bin/mpml"
if [ ! -x "$recorder_binary" ]; then
    echo 'Build first with Scripts/build.sh.' >&2
    exit 1
fi
if [ -e "$recorder_command" ] || [ -L "$recorder_command" ]; then
    if [ ! -L "$recorder_command" ] || [ "$(readlink "$recorder_command")" != "$recorder_target" ]; then
        echo 'The command directory already contains another mpml; choose a different directory.' >&2
        exit 1
    fi
fi
mkdir -p "$recorder_support/bin" "$recorder_command_dir"
chmod 700 "$recorder_support" "$recorder_support/bin"
recorder_temp=$(mktemp "$recorder_support/bin/.mpml.XXXXXX")
trap 'rm -f "$recorder_temp"' EXIT
install -m 700 "$recorder_binary" "$recorder_temp"
mv -f "$recorder_temp" "$recorder_target"
if [ ! -L "$recorder_command" ]; then
    ln -s "$recorder_target" "$recorder_command"
fi
echo "Installed $recorder_command. Background recording was not restarted."
case ":$PATH:" in
    *":$recorder_command_dir:"*) echo 'Query with: mpml status' ;;
    *) echo "Add $recorder_command_dir to your PATH to use mpml directly." ;;
esac
