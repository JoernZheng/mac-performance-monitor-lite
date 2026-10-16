#!/bin/bash
# Stops recording and removes login startup. Recorded history is preserved.
set -euo pipefail
recorder_label=org.joernzheng.mac-performance-recorder
launchctl bootout "gui/$(id -u)/$recorder_label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$recorder_label.plist"
echo 'Service stopped. History remains in ~/Library/Application Support/MacPerformanceRecorder.'
