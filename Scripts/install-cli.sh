#!/bin/bash
# Installs the CLI and optional viewer; the existing service and history stay in place.
set -euo pipefail
recorder_root=$(cd "$(dirname "$0")/.." && pwd)
recorder_binary="$recorder_root/.build/release/mpml"
recorder_dashboard="$recorder_root/.build/release/Mac Performance Monitor Lite.app"
recorder_support="$HOME/Library/Application Support/MacPerformanceRecorder"
recorder_command_dir="${1:-$HOME/.local/bin}"
recorder_command="$recorder_command_dir/mpml"
recorder_target="$recorder_support/bin/mpml"
if [ ! -x "$recorder_binary" ] || [ ! -x "$recorder_dashboard/Contents/MacOS/mpml-dashboard" ]; then
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
recorder_viewer_temp=$(mktemp -d "$recorder_support/bin/.dashboard.XXXXXX")
recorder_viewer_target="$recorder_support/bin/Mac Performance Monitor Lite.app"
cleanup_install() {
    rm -f "$recorder_temp"
    if [ -d "$recorder_viewer_temp/previous.app" ] && [ ! -e "$recorder_viewer_target" ]; then
        mv "$recorder_viewer_temp/previous.app" "$recorder_viewer_target"
    fi
    rm -rf "$recorder_viewer_temp"
}
trap cleanup_install EXIT
ditto "$recorder_dashboard" "$recorder_viewer_temp/new.app"
if [ -e "$recorder_viewer_target" ]; then
    mv "$recorder_viewer_target" "$recorder_viewer_temp/previous.app"
fi
mv "$recorder_viewer_temp/new.app" "$recorder_viewer_target"
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
