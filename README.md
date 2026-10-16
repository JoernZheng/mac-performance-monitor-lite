# Mac Performance Monitor Lite

A lightweight, headless fork of [Mac Performance Monitor](https://github.com/Zesty0wl/mac-performance-monitor).
It records locally in the background and provides read-only command-line analysis.
macOS 15+, Apple silicon, Swift 6. No dashboard, embedded AI, automatic updater, telemetry,
network scanning, or disk cleanup tools. The upstream MIT license is preserved.

## Capture

Retains the available CPU, memory, GPU/ANE, disk, network, battery, thermal, and
per-process performance readers. Records macOS native memory pressure separately
from the upstream custom pressure index:

- `1`: normal
- `2`: warning
- `4`: critical
- `NULL`: pressure unavailable

The primary analysis uses these native states. The Activity Monitor graph's exact
height is not claimed as an official percentage. Pressure source notifications
request an extra sample; the global kernel reading remains authoritative.
Apple's [kernel implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c)
converts internal pressure levels to the 1/2/4 notification values before returning
this sysctl. These values are not the internal enum's 0/1/2/3 numbering.

System snapshots default to every 10 seconds, process scans every 30 seconds.
GPU/ANE and sensors are enabled without keeping any UI open. Per-app network
tracking uses `nettop` on the slower process cadence; `--no-per-app-network`
disables that subprocess while retaining whole-machine traffic.

All families are attempted, not all fields are guaranteed: unsupported hardware,
private API changes, missing permissions and first-sample baselines leave gaps.
There is no root helper. ANE watts and some system-process footprints may therefore
be unavailable. CPU fractions cover the whole machine; per-process CPU can exceed
100% of one core. GPU bandwidth from macOS buckets remains an estimate.

## Build and test

```sh
Scripts/build.sh
Scripts/test.sh
.build/release/mpml help
```

The scripts prefer the selected Xcode Git, avoiding an incompatible Intel-only
Git found earlier on the development Mac. SwiftPM resolves the pinned GRDB 7.11.0
dependency normally. They default to two compilation jobs to limit build-time
memory use. `CONFIGURATION=debug Scripts/build.sh` selects a debug build.

## Install the command

```sh
Scripts/install-cli.sh
mpml status
mpml summary --last 7d
```

This installs the command in `~/.local/bin` using a stable executable in the data
directory. Ensure `~/.local/bin` is on your PATH, or pass an existing command
directory as the first argument. It does not restart or reconfigure a running
recording service, change the database, or enable login startup.

## Use without installing

```sh
# A bounded test; exits cleanly after 65 seconds.
.build/release/mpml record --duration 65 --db /tmp/recorder-test.sqlite
.build/release/mpml status --db /tmp/recorder-test.sqlite

# An ordinary long-running capture; SIGINT or SIGTERM stops it cleanly.
.build/release/mpml record
.build/release/mpml summary --last 7d
.build/release/mpml summary --last 7d --activity background_busy
.build/release/mpml processes --last 7d
.build/release/mpml export --last 7d --format jsonl --output week.jsonl
.build/release/mpml sql 'SELECT pressure_level,COUNT(*) FROM recorder_samples GROUP BY pressure_level'
```

The default data directory is `~/Library/Application Support/MacPerformanceRecorder`,
separate from the upstream app. Queries open history read-only and cannot create
an empty database. SQL results are row-capped and explicitly report truncation;
export streams the selected range without loading the entire history into memory.
`--from` and `--to` accept Unix seconds or ISO 8601 timestamps with timezones.
Exports contain app/process names and performance history; battery serial fields
are omitted from the detailed snapshot payload.

## Activity and coverage

Each sample stores the underlying resource readings and input-idle/session signals.
No key contents, event streams, screenshots, browser contents, or Apple knowledge
history are recorded. The default activity estimate is:

1. **user_active**: this console session is not known to be locked/away and input
   idle is under five minutes. Reading without input can exceed this timeout.
2. **background_busy**: the user is idle/locked/away and CPU, GPU, disk or network
   crosses a configurable threshold. It does not identify the semantic task.
3. **idle**: the user is idle/away and measured resource load is low.
4. **unknown**: required activity signals are unavailable.

Thresholds and sampling rates are stored with each recording run. Busy defaults:
15% of whole-machine CPU, 20% GPU, 5 MB/s disk or 1 MB/s network.
A waiting job or high memory allocation alone does not prove that a task is busy.

Summary durations are weighted by the actual recorded interval and clipped to the
query window. Native-pressure percentages include an explicit unknown category.
Sleep, long timer gaps, restarts and wall/monotonic clock disagreements start new
baselines instead of backfilling time. Durations are estimates at sampling
resolution, not exact human work or pressure-transition times. Unrecorded time
is shown separately and is never counted as normal pressure or idle.

Detailed system/CPU/GPU/battery/network/disk snapshots and native-state intervals
are retained for 30 days by default. Process raw history keeps two hours, minute
aggregates 30 days, and hourly aggregates 90 days. Process leaderboards appear as
minutes complete and describe retained resolution. A configurable database budget
can shorten history. Check `status` and query coverage before interpreting absence
of readings. A recent timestamp is a freshness signal, not proof a process is alive.

## Optional login startup

After reviewing a bounded capture, explicitly run:

```sh
Scripts/install-service.sh
```

This copies the release executable to the recorder data directory and installs a
per-user LaunchAgent. It uses no root daemon and has no window or menu icon.
`Scripts/uninstall-service.sh` stops it and removes login startup while preserving
history. Startup and error messages go to `service.log` beside the database.
Configuration changes can be made to the LaunchAgent arguments.
Service errors end the current run and launchd restarts it with a 30-second throttle.
This fork does not install or enable the upstream privileged helper.

## Naming and existing installations

The project and fork are named **Mac Performance Monitor Lite**
([mac-performance-monitor-lite](https://github.com/JoernZheng/mac-performance-monitor-lite)).
The command is `mpml`. The `mpm-lite` and `mac-recorder` build products remain available for
existing integrations. For continuity, the data directory stays
`MacPerformanceRecorder`, the LaunchAgent label stays
`org.joernzheng.mac-performance-recorder`, and its executable path stays
`bin/mac-recorder`. These are intentional compatibility identifiers. Renaming the
project does not migrate the database or restart an existing recording service.
The service installation script also provides `bin/mpml` and `bin/mpm-lite` commands.

## Development

Architecture and scope: [design notes](docs/personal-recorder-design.md).
Core readers and SQL retention originate in the upstream project. The new
`RecorderKit` owns background lifecycle, native-state coverage, activity signals,
configuration and read-only queries. `mpml` is the primary executable; `mpm-lite` and `mac-recorder` remain compatibility products.
Installation scripts are not run by building or testing.
