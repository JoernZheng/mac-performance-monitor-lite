# Performance budget report

## Current recorder and menu-bar results

Build 281 cuts steady menu-panel memory use by about 70% in this test.
It does not yet meet the 60 MB idle target after all panels have been used.
Short-lived peaks also remain. These results are not a memory ceiling.

Measured on 12 October 2026 with a signed, notarized release build:

- MacBook Pro, M3 Pro, 18 GiB RAM, macOS 27.2.
- All seven menu metrics visible. The main dashboard was never opened.
- Recording at one-second resolution, with the existing history database.
- Full Coverage helper running. Per-app network tracking off.
- Physical footprint from `vmmap`, not resident memory (RSS).

The baseline is version 2.3.1, build 280. The test build is version 2.3.1,
build 281 on the `memory-optimisations` branch. The workload was live, not
a fixed replay, so readings can vary.

| State | Build 280 | Build 281 |
| --- | ---: | ---: |
| Fresh launch, recording on, menu closed | Not measured | 37.0 MiB |
| Warm idle, menu closed | 152 to 166 MiB | 68 to 76 MiB |
| RAM panel open | About 271 MiB | 73.0 MiB |
| CPU panel open | Not measured | 74.0 MiB |
| GPU panel open | About 276 MiB | 81.5 MiB |
| Energy panel open | Not measured | 74.7 MiB |
| Temperature panel open | Not measured | 72.3 MiB |
| Network panel open | About 285 MiB | 79.0 MiB |
| Disk panel open | Not measured | 83.4 MiB |

Each build-281 panel reading followed at least 15 seconds of live updates.
After the first sweep, closed-menu readings were 76.1 MiB at ten seconds
and 75.2 MiB later. Four further GPU open/close cycles settled at
88 to 89 MiB open and 68 to 69 MiB closed, without steady growth.
The process recorded a **231.4 MiB peak** during the sweep and close.
That peak is distinct from the steady readings in the table.

With recording off, a fresh launch used 29.8 MiB. The RAM panel used
70.2 MiB after 15 seconds, then 57.1 MiB after closing. The database's
latest sample timestamp stayed unchanged. We restored recording after
this check, and new samples appeared without opening the dashboard.

After that restart, idle memory was 38.0 MiB. A one-minute idle CPU
check averaged 5.73%, with a 17.2% sample peak. It used 30 two-second
samples, excluding the first reading. These figures cover the main app,
not the helper, at this machine's one-second recording setting.

## What changed

1. **Small charts use CPU bitmaps.** Menu headers, process-row lines, and
   GPU and temperature charts display small images instead of live drawing
   commands. The two ANE charts use the same bitmap path while keeping
   their axes, missing-data gaps, hover and scrubbing. Dashboard chart
   rendering stays on its existing path. The change preserves sample rates
   and history lengths.
2. **Idle cleanup waits for the last live consumer.** Closing a menu or
   window starts a 1.5-second delay. Reopening cancels cleanup. Once idle,
   the app drops unused UI lists, trails, table state and icons, clears
   history-query caches, and asks GRDB and the allocator to release memory.
   Recording, alert state, sampling baselines and system history stay intact.
   Memory-pressure events also request this cleanup when the UI is idle.
3. **A menu no longer rebuilds the full process table.** It ranks only the
   lists it needs. A full process consumer still gets the table and other
   lists at the existing cadence. Process icons share an app-level cache
   key; menu rows use small, pre-rendered icons.
4. **Leak scans hold one process series at a time.** Live identity checks
   happen before series reads. A scan reads raw fallback data only when
   minute history lacks enough coverage. One read snapshot keeps metadata,
   trend and latest footprint consistent. A running periodic scan prevents
   more scans from queuing behind it.
5. **Path caches have fixed limits.** Bundle IDs, signing team IDs and
   names of signing organizations each use a 1,024-entry LRU cache.
   The caches also store missing results. Reset clears these caches.

Cleanup cannot force the OS or frameworks to release every cached page.
Remaining warm-idle memory includes framework caches and allocator space.
The earlier popover retain-cycle fix remains in place. No popover appeared
in the closed-menu heap check.

## Leak-scan check

A separate release-linked probe opened the live database read-only. It
checked 734 recently seen identities in 0.339 seconds. The full historical
scan took 1.912 seconds. Filtering its results to those identities exactly
matched the live scan.

The probe's peak physical footprint was 12,222,896 bytes, about 11.7 MiB,
including both scans. This is a short query test, not the whole recorder's
memory use or an equal-workload speed comparison with build 280.
Query plans used the process/minute index and the raw covering index.

## Memory after closing the main window

Opening the dashboard raises the later idle footprint. Build 281 does not
return to its fresh-launch or menu-only baseline after closing it.
This follow-up used the same Mac and recording settings as the menu tests.

Three open/close cycles in one process gave these readings, 20 seconds
after each close:

| Cycle | Physical footprint | Live main heap | Charged unused main heap |
| --- | ---: | ---: | ---: |
| 1 | 135.6 MiB | 43.5 MiB | 27.2 MiB |
| 2 | 143.9 MiB | 43.7 MiB | 34.2 MiB |
| 3 | 140.0 MiB | 42.7 MiB | 34.0 MiB |

The live heap stayed near 43 MiB. It did not grow with each open.
An earlier 135 MiB reading fell to 114.3 MiB during a longer idle period.
These checks do not prove the absence of every leak. They show no large
per-open leak across these three cycles. Other windows sometimes covered
the dashboard, so the open-state readings were not a fixed rendering test.

A restart with allocation logging captured the real app's surviving
allocations. The heap graph contained no live dashboard timeline store or
native trend surface after close. Large retained groups included about
6.2 MiB of ColorSync allocations, 4.9 MiB of Swift runtime metadata, and
2.4 MiB of SwiftUI environment entries. These are allocation sizes, not
separate additions to physical footprint. Logging itself adds memory,
so do not compare that process's footprint with a normal launch.

After restoring a normal launch, one further close settled at 114.6 MiB.
The main heap held 34.3 MiB of live data and 27.3 MiB of charged unused
space. Another 28.6 MiB was dirty or swapped memory that `vmmap` called
`owned unmapped`. The label alone does not identify its owner. Other
heaps, framework data and graphics allocations made up the rest.
Heap fragmentation means that freeing an object does not always free
its page. Some framework caches and runtime metadata also remain alive.

### Repeatable teardown check

The chart benchmark now supports `--teardown`. It releases the synthetic
scenario, host and window, waits two seconds, and reports physical
footprint. It then purges app icon caches, requests allocator relief,
and reports again after 20 seconds. A weak-reference test checks that
the benchmark does not retain its host or window.

```sh
Scripts/build.sh --release
.build/release/MacPerfMonitor --benchmark-charts \
  --scenario dashboardPage --mode host --points 300 \
  --range fiveMinutes --span 300 --interval 1 --ticks 25 \
  --width 1280 --teardown
```

Both release runs passed:

| Run | Open | Host released | After allocator relief | After idle |
| --- | ---: | ---: | ---: | ---: |
| 1 | 65.33 MiB | 39.38 MiB | 39.38 MiB | 39.24 MiB |
| 2 | 66.25 MiB | 40.30 MiB | 40.30 MiB | 40.17 MiB |

The allocator returned zero bytes in both runs. This test gives no reason
to add another timed purge. It uses synthetic data in a transparent
window, not the real app's scene, tabs or recorder. It tests full host
release, not the content gate used by the real window.
Do not claim that these numbers show lower memory use in the real app.

This follow-up adds measurement and regression coverage, not a new
dashboard renderer or a claimed leak fix. The installed notarized app
remains build 281. We turned allocation logging off and closed the main
window. Database timestamps advanced after normal recording resumed.

Follow-up checks passed:

```sh
swift test --filter 'MenuMemoryTests|DashboardChartTests'
swift format lint --strict Sources/MacPerfMonitor/Util/ChartBenchmark.swift Tests/MacPerfMonitorTests/MenuMemoryTests.swift
Scripts/build.sh --release
git diff --check
```

The targeted test run passed all 30 tests with no failures.

## Build 283: stable process inspector

Build 283 keeps the Processes inspector at 360 points wide inside the
window. Selecting another process replaces its contents, not its scroll
container. Long names no longer widen the panel or let it overlap the
table. The inspector still scrolls to the top for each new selection.

Native layout tests check the minimum, default and wide window sizes.
They cover long names, stable table and inspector bounds, and scroll reset.
The memory and navigation checks also passed: 17 tests, no failures.
Build 283 passed signing, notarization and installed-app checks. Recording
and the helper resumed after installation. The memory figures above remain
measurements of build 281, not a new measurement of build 283.

## Validation

These commands passed for build 281:

```sh
swift test
swift format lint --strict --recursive Sources Tests Package.swift
Scripts/build.sh --release
```

The full suite ran 1,031 tests: 1,026 passed. It skipped five opt-in tests.
No tests failed. New checks cover bitmap reuse and scale,
missing-data gaps, consumer handoffs, idle cleanup, menu-only ranking,
overlapping leak scans, query edge cases, and cache churn.
Native ANE checks cover both light and dark appearances.

The installed app also passed:

```sh
codesign --verify --deep --strict '/Applications/Mac Performance Monitor.app'
spctl --assess --type execute --verbose=2 '/Applications/Mac Performance Monitor.app'
xcrun stapler validate '/Applications/Mac Performance Monitor.app'
```

Gatekeeper reported `Notarized Developer ID`. The helper was running, the
menu panels updated, and recording resumed after the recording-off test.
Long-duration soak testing and other Macs remain useful follow-up checks.

## Budget and measurement method

The PRD target is under 60 MB and under 2% average CPU on an M1.
It uses the default two-second cadence, with the menu bar active and no
main window.
Do not treat old Milestone 8 results (19.0 MB at launch, 47.4 MB after
window close, and 1.31% CPU) as proof that current builds meet that target.
The current test uses a different Mac, OS and sampling cadence.

Use the PID of the installed main app, not its helper or `mpm` process:

```sh
ps -axo pid=,command= | grep 'Mac Performance Monitor.app/Contents/MacOS/'
# Replace 12345 with the main app's PID from the output above.
vmmap -summary 12345
top -l 31 -s 2 -pid 12345 -stats cpu
```

Record both current and peak physical footprint. For CPU, discard the
first sample and average the next 30. Note the recording mode, sampling
rate, open panel, helper state, and time since launch or close.
Compare fresh launches separately from warm runs. Test repeated updates,
not a static chart, and keep the dashboard closed for this budget.
