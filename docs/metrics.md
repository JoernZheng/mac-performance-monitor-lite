# Metric semantics

## Memory and pressure

Native pressure comes from `kern.memorystatus_vm_pressure_level`:
`1` normal, `2` warning, `4` critical. Failed reads remain unknown, not normal.
These are system states, not an official percentage or the exact height of the
Activity Monitor graph. Pressure notifications request an extra sample; the
kernel reading remains the recorded value.

The inherited custom index is stored separately as `custom_pressure_index` in the
SQL views. Its formula uses floors 0/34/67 for normal/warning/critical, plus 33 times
`0.5 * compression + 0.3 * swap + 0.2 * trend`, clamped to 0 through 100.
Compression normalizes against half of RAM, swap against total RAM, and trend
against 50 MB/s growth of compressed memory plus swap. It is not an Apple metric.

Memory counters use the kernel page size and are stored in bytes:

| Field | Meaning |
| --- | --- |
| Wired | Resident pages that cannot be paged out |
| Compressed | Pages held by the memory compressor |
| App memory | `max(internal - purgeable, 0)` |
| Cached files | `external + purgeable`, reclaimable memory |
| Free | The sampled free-page counter |
| Swap used | Disk-backed swap usage, separate from physical RAM |

These categories approximate Activity Monitor and can overlap. They are not forced
into a chart that sums to total RAM. Used-memory summaries combine app memory,
wired and compressed memory. Cached memory alone does not imply pressure.

## Activity and coverage

- `user_active`: recent input (under five minutes), with no known locked/away session.
- `background_busy`: idle/locked/away, with CPU, GPU, disk or network above threshold.
- `idle`: idle/away with sufficiently low measured resource load.
- `unknown`: insufficient signals to classify.

Busy defaults are 15% of whole-machine CPU, 20% GPU, 5 MB/s disk or 1 MB/s network.
Reading without input may become idle; a waiting job or allocated memory alone
is not evidence of active work. Configuration and underlying signals are saved.

Durations use real covered intervals, clipped to the query window. Summaries show
unrecorded time separately and include unknown pressure in the percentages.
Sleep, restarts, long timer gaps and clock disagreements establish new baselines.
Transitions and activity durations are sampled estimates, not exact event times.

## Units and availability

CPU fractions represent the whole machine; process CPU can exceed 100% of one core.
GPU utilization is a percentage; GPU bandwidth uses estimated GB/s. Network and
disk rates use bytes/second. Snapshots retain raw fields and availability annotations. Process
identity combines PID and start time. Permission failures must not become zero
memory usage. The first rate sample needs a baseline and may be unavailable.

Per-process network rates use nettop on the slower process cadence. Disable them
with `record --no-per-app-network` while retaining whole-machine traffic. Full
nested metric fields are available through JSONL export; SQL views expose retained
process rollups. Database schema and stored enum values remain compatible across
source-code cleanup.
