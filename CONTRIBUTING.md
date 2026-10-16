# Developing Mac Performance Monitor Lite

This project is a headless performance recorder. The accepted scope is all available
performance metric families, native macOS memory pressure, activity classification,
local persistence and read-only command-line analysis. See README.md and
`docs/personal-recorder-design.md` before changing collection or statistical semantics.

The authoritative development branch is `main`; maintain Lite independently of
the original project. Use an isolated checkout for changes and preserve the MIT license.
Do not restore the upstream updater, app identity, data directory, or GUI dependencies.
Missing values must remain distinguishable from zero, and gaps must not become idle
or normal-pressure coverage. Activity classes are estimates, not verified work records.

Validation:

```sh
Scripts/build.sh
Scripts/test.sh
swift format lint --strict --recursive Sources Tests Package.swift
git diff --check
```

Use a temporary database for bounded live captures. Do not install login startup,
replace an installed service, or collect indefinitely as a side effect of a build
or test. Installation is a separate explicit action. Never commit live history,
exports or logs. Source review and tests do not establish a long-duration performance
or security guarantee. Commit and push permissions remain separate.
