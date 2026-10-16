# Security and privacy

The recorder stores performance history locally. It has no telemetry, automatic
updater, cloud model or network scanner. Per-process network accounting invokes
local nettop. The service runs as the current user, without a root helper.
Some readers use private macOS interfaces and may change with OS updates.

History and exports can contain process names, executable paths and usage patterns.
They are not anonymous. Detailed battery snapshots omit serial fields. Data files
are private to the current user by default. Activity classification stores idle
and session signals, not keystrokes, screenshots or Apple activity history.

Queries open SQLite read-only, limit rows and duration, and accept a single
read-only statement. Exports stream a selected range. An external agent may send
what it reads to its own provider; that is outside this executable.

Keep credentials, live databases, logs and diagnostic exports out of Git and public
reports. Report vulnerabilities privately to the maintainer using private reporting
if available. Include a minimal sanitized reproduction. Local checks are not a
security audit; builds use local ad-hoc signing, not Developer ID signing or notarization.
