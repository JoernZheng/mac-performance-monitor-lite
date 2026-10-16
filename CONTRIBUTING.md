# Development

Maintain Lite independently on `main` and preserve the upstream MIT license.
Use an isolated checkout, inspect the diff and preserve unrelated changes.

## Modules

- `CMacPerfMonitor`: C access to macOS process and kernel APIs.
- `MacPerfMonitorCore`: metric readers, sampling, SQLite writes and retention.
- `RecorderKit`: background lifecycle, activity/coverage, service management and queries.
- `mpml`: command parsing and output.
- `mpml-dashboard`: optional SwiftUI/Charts viewer, using read-only RecorderKit queries.

There is no hosted CI or required Git hook. Run these checks locally:

```sh
Scripts/build.sh
Scripts/test.sh
swift format lint --strict --recursive Sources Tests Package.swift
bash -n Scripts/*.sh
git diff --check
```

Use temporary databases for bounded captures. Service tests use an isolated home
and a fake launchd backend. Building or testing must not enable login startup,
replace a running recorder, or touch live history. Installation is an explicit action.

Keep missing readings distinct from zero, and never turn collection gaps into idle
or normal-pressure time. Preserve database and service IDs across upgrades. Retain
all supported metric families. The optional Dashboard must not sample hardware,
write or migrate history, or manage the recording service. No scanning or cleanup tools.

Keep credentials, databases, logs, exports and machine-specific notes out of Git.
Commit and push permissions remain separate.
