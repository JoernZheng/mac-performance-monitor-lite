#!/bin/bash
set -euo pipefail
recorder_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Prefer the selected Xcode Git. A stale Intel-only /usr/local/bin/git can
# otherwise break SwiftPM dependency resolution on Apple silicon.
recorder_git_dir=$(dirname "$(xcrun --find git)")
export PATH="$recorder_git_dir:$PATH"
