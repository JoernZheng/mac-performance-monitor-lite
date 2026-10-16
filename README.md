# Mac Performance Monitor Lite

A local, headless macOS performance recorder, maintained independently from
[Mac Performance Monitor](https://github.com/Zesty0wl/mac-performance-monitor).
Requires macOS 15+, Apple silicon and Swift 6 to build. No GUI, telemetry,
automatic updater, cloud model or root helper.

## Build and install

```sh
Scripts/build.sh
Scripts/install-cli.sh
mpml install
```

The CLI installer uses `~/.local/bin`; add it to PATH if needed, or pass another
command directory to the script. `mpml install` starts a per-user login service,
without sudo. Running it again leaves an already-loaded service unchanged.

```sh
mpml uninstall
```

This stops the service and removes login startup. History, logs and the CLI remain
available. The executable manages the service itself and needs no source checkout.

## Query history

```sh
mpml status
mpml summary --last 7d
mpml summary --last 7d --activity background_busy
mpml processes --last 7d
mpml export --last 7d --format jsonl --output week.jsonl
mpml sql 'SELECT pressure_level,COUNT(*) FROM recorder_samples GROUP BY pressure_level'
```

Use `--from` and `--to` with Unix seconds or ISO 8601 timestamps for exact windows.
SQL queries are read-only and row-limited; exports stream the selected snapshots.
Use `mpml help` for all options. Old command names `mpm-lite` and `mac-recorder`
remain available as build products for compatibility.

To try a bounded capture without enabling login startup:

```sh
.build/release/mpml record --duration 65 --db /tmp/mpml-test.sqlite
.build/release/mpml summary --last 5m --db /tmp/mpml-test.sqlite
```

## What is recorded

System snapshots default to every 10 seconds, process scans and per-process
network accounting to every 30 seconds. The recorder attempts CPU, memory,
GPU/ANE activity, disk/network I/O, battery, power and thermal measurements.
Unsupported or permission-restricted fields are marked unavailable. ANE watts
and some system-process footprints cannot be read without a privileged provider.

Native memory pressure is recorded as normal, warning, critical or unknown.
Summaries report time in each state, split into estimated user-active,
background-busy, idle and unknown periods. They do not count sleep or collection
gaps as normal pressure. See [metric semantics](docs/metrics.md) for units,
classification, coverage and the separate custom pressure index.

## Data and compatibility

History stays in `~/Library/Application Support/MacPerformanceRecorder/history.sqlite`.
Startup/errors go to `service.log` beside it. The legacy directory and LaunchAgent
label `org.joernzheng.mac-performance-recorder` are intentional compatibility IDs.
Updating the CLI does not migrate history or restart an existing recorder.

Detailed system snapshots keep 30 days by default. Process data keeps two hours
of raw samples, 30 days of minute aggregates and 90 days of hourly aggregates.
The default 2 GiB logical database budget can shorten retention. Exports contain
process names and paths; review them before sharing. See [privacy](SECURITY.md).

## Development

`main` is the maintenance branch. There is no hosted CI; validation is local.
See [CONTRIBUTING.md](CONTRIBUTING.md) for checks and module boundaries.
The original MIT license and attribution are preserved in [LICENSE](LICENSE).
