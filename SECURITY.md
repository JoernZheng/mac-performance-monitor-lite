# Security and privacy

Mac Performance Monitor Lite collects local system and process performance data.
It stores history in SQLite and provides read-only queries and explicit exports.
The recorder has no telemetry, cloud model, updater or network scanning features.
Per-process network accounting invokes the local nettop tool.

History and exports can contain process names, executable paths and usage patterns.
Exports retain these details; do not treat them as anonymous. Detailed battery
snapshot payloads omit serial fields. The default data directory is private to the
current user, and the recorder applies owner-only database permissions.

Activity classification uses input-idle duration and session state. It records no
keystroke contents, event stream, screenshots, browser contents or Apple knowledge
history. Activity labels are estimates rather than verified work records.

The service runs as the current user and has no root helper. Some system-process
readings and ANE power are therefore unavailable. Readers inherited from upstream
may use private interfaces that can change between macOS versions.

Queries open history read-only, accept a single read-only SQL statement, and have
row/time limits. Export streams a selected range. An external agent that reads
these results may send them to its own provider; that is outside this executable.

Keep keys, credentials, certificates, live databases, diagnostic captures, logs,
exports and machine-specific installation notes out of Git. Include only a minimal,
sanitized reproduction in a report. Local validation is not a security audit.

Report vulnerabilities privately to the fork maintainer using private reporting
if the repository enables it. Avoid posting sensitive details in public issues.
Fixes target the current Lite development branch. This fork does not publish a
signed/notarized application package or provide the upstream updater's guarantees.
