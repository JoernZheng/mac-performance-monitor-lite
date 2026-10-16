#!/bin/bash
# Explicitly install the already-built executable as a per-user LaunchAgent.
set -euo pipefail
recorder_root=$(cd "$(dirname "$0")/.." && pwd)
recorder_binary="${1:-$recorder_root/.build/release/mpm-lite}"
if [ ! -x "$recorder_binary" ]; then
    echo 'Build first with Scripts/build.sh, or pass the built executable path.' >&2
    exit 1
fi
recorder_support="$HOME/Library/Application Support/MacPerformanceRecorder"
recorder_agents="$HOME/Library/LaunchAgents"
# Compatibility identifiers: existing history and login startup stay in place.
recorder_label=org.joernzheng.mac-performance-recorder
mkdir -p "$recorder_support/bin" "$recorder_agents"
chmod 700 "$recorder_support" "$recorder_support/bin"
launchctl bootout "gui/$(id -u)/$recorder_label" 2>/dev/null || true
# The service runs a stable copy, never a build artifact being overwritten.
install -m 700 "$recorder_binary" "$recorder_support/bin/mac-recorder"
# Keep the service path stable while exposing the new command name.
ln -sfn mac-recorder "$recorder_support/bin/mpm-lite"
python3 - "$recorder_support" "$recorder_agents/$recorder_label.plist" "$recorder_label" <<'PY'
import os,plistlib,sys
support,path,label=sys.argv[1:]
value={
 'Label':label,
 'ProgramArguments':[support+'/bin/mac-recorder','record','--db',support+'/history.sqlite'],
 'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':30,
 'ProcessType':'Background',
 'StandardOutPath':'/dev/null',
 'StandardErrorPath':support+'/service.log',
}
with open(path,'wb') as f:plistlib.dump(value,f)
os.chmod(path,0o600)
PY
launchctl bootstrap "gui/$(id -u)" "$recorder_agents/$recorder_label.plist"
echo "Installed $recorder_label. Query with:"
printf '"%s/bin/mpm-lite" status\n' "$recorder_support"
