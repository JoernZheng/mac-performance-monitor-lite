# Mac Performance Monitor Lite validation

Baseline upstream commit: bfbd512dd5e2e00b763f8b58e2986e3549885fd7.
The implementation branch is codex/lite in the
[personal fork](https://github.com/JoernZheng/mac-performance-monitor-lite/tree/codex/lite).

## Required checks

- Release build using Scripts/build.sh and pinned GRDB 7.11.0.
- Scripts/test.sh: 92 tests passed after the Lite naming change.
- Strict Swift formatting, shell syntax and whitespace checks.

Coverage includes native-state independence from the custom pressure index,
unknown values, interval weighting and clipping, sleep/clock gaps, activity
classification, read-only SQL and truncation, single-writer locking, retention,
streaming export, stopped-run state, identifier redaction, partial-minute process
weighting, empty history and duplicate SQL column handling.

## Bounded live verification

The recorder has completed bounded captures and a ten-minute resource observation
on Apple silicon. System snapshots, process rollups, native pressure and complete
JSONL export were checked. SIGTERM saved the final interval and ended the run;
concurrent writers were rejected while read-only queries remained usable.
Ordinary-user permission gaps were explicitly annotated.

During the project rename, the existing LaunchAgent, executable and data directory
remain in place. The renamed command reads that database without migrating it.
The new command and compatibility product both display the Lite name, and the
new command reads the live database with the same open run and original history
start. Detailed local measurements and captures are deliberately excluded from Git.

This does not establish long-term battery cost, multi-day growth, exhaustive reader
correctness, or a repository-wide security audit. CI and actual logout/login tests
are separate from local checks.

## Publication checks

Gitleaks v8.30.1 scanned the staged changes and an export of the final tracked
source tree with no credential findings. Additional checks excluded runtime
history, diagnostics, local installation notes, private key files, credential URLs
and user-home paths. These checks concern publication hygiene, not a full security
audit of the inherited performance readers.
