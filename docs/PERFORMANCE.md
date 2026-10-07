# Scan performance

Measured on the development Mac on October 7, 2026, using optimized Swift builds and real local data.
These are local measurements under normal machine load, not customer telemetry or universal latency guarantees.
No cleanup operations were performed by the benchmark.

## Baseline

The storage scan previously launched by Overview and Cleanup took **157.7 seconds**.
Category callback timings identify these sequential costs:

| Operation | Time |
| --- | ---: |
| Dependency discovery, sizing, project activity and safety | 93.5 s |
| System-folder sizes | 34.7 s |
| Library and app-data sizes | 11.0 s |
| Installed-application sizes | 4.7 s |
| Package-cache sizes | 3.6 s |
| User-cache sizes | 3.5 s |

Three separate runs of smaller queries measured:

| Operation | Observed range |
| --- | ---: |
| Docker storage report | 0.11–0.53 s |
| Process snapshot (about 685–701 processes) | 0.17–0.33 s |
| Eligible cache scan (no candidates on this run) | 0.05–0.09 s |
| System metrics | below 1 ms |

A live three-second sample showed the UI thread mostly waiting for events, while the storage worker spent
most of its samples recursively enumerating files in `ProjectActivityResolver.latestChange`.
This establishes a slow-results path; it does not prove that every reported UI stall has the same cause.

## Changes

- Overview and Cleanup request project cleanup and simulator data without first scanning the full inventory.
  Inventory still performs the full app, Library, system-folder and Spotlight scan on demand.
- Project-age reads use native filesystem traversal, skip generated tool trees, and have time and entry budgets.
  Incomplete or unreadable results are Unknown and remain excluded from age-based recommendations.
- Dependency discovery skips Git internals and generated Swift/Python/Gradle/CocoaPods trees while preserving
  actual project roots and worktrees. Overlapping requested roots are scanned once.
- Allocated and apparent dependency sizes are measured together, using four dynamically assigned workers.
  This replaces two recursive `du` passes. Hard links count once per target; symlinks are not followed.
- Unknown activity results are memoized within each scan, so related dependency folders do not repeat the same work.
  Age checks have a 150 ms / 20,000-entry per-project budget and a five-second shared scan budget;
  filesystem calls already in progress can overrun those deadlines.
- Inventory timestamps are independent of cleanup refreshes.

## Result

The final cleanup scope completed in **17.02 seconds**, versus **157.70 seconds** for the full scan previously
triggered from Overview/Cleanup: about **9.3 times faster**, or an **89% reduction** in that wait.
This comparison includes moving unrelated inventory work out of the automatic cleanup path; the full inventory
has not become a 17-second operation.

| Revised cleanup stage | Time |
| --- | ---: |
| Simulator state/cache | 0.26 s |
| Dependency discovery | 6.28 s |
| Dependency context resolution | 0.02 s |
| Combined allocated/apparent sizes | 6.60 s |
| Project activity and safety | 3.58 s |
| Entire cleanup scope, including process checks | 17.02 s |

Dependency analysis itself fell from 93.48 seconds to 16.49 seconds.
The full inventory's large system/Library reads remain expensive and now run on demand.
Filesystem caches, other apps, permissions, and the number of projects affect repeat timings.
Normal polling and Docker were not changed based on these measurements.

## End-to-end dashboard audit

The five-check dashboard was measured separately with the real project roots and a disposable copy of the
152-entry removal history. No files were cleaned. The initial audit took **66.91 seconds**, while resources,
caches, Docker, and app responsiveness each completed within **0.67 seconds**.

Sharing folder measurements first reduced the audit to 30.59 seconds. Another run under concurrent disk/build
load took 77.99 seconds, so one favorable run was not sufficient evidence of reliable latency.

The final implementation:

- Shares one native measurement per exact path between dependency and regrowth checks, with four readers.
  Measurements, including unavailable results, live only for that audit; removals revalidate independently.
- Makes eligible cache actions available when their own check completes. A successful cleanup queues one
  fresh audit and retains the actual removal result while other checks finish.
- Gives new dashboard folder measurements a shared 20-second traversal budget. Expired or unreadable folders
  contribute no partial bytes. The dashboard reports incomplete checks; Storage can run a deeper scan.
  This is not a hard real-time deadline: discovery, activity checks, existing full scans, and filesystem calls
  already in progress can extend the overall wait.
- Leaves the pnpm store's full-size measurement to detailed cleanup, since its entire size is not reclaimable.
- Removes filesystem existence reads from the display-derived ready-item list. Removal retains fresh checks.
- Bounds Docker inspection at 12 seconds and drains stdout/stderr concurrently, preserving warnings separately
  from JSON. Docker cleanup has a separate 600-second command budget.

Two final local audits completed in **15.95 seconds** and **28.88 seconds**. The first finished all requested
folder measurements; the second reported **261 incomplete shared measurements** under heavier disk load.
Both finished the other four checks within **0.57 seconds**, allowing early actions without waiting for projects.
These runs show a responsive incremental audit with an explicit partial-result fallback, not a guarantee that
every Mac can fully inspect all project folders in 20 seconds. The separate full inventory remains on demand.

The live benchmark copies the removal ledger before constructing models and logs incomplete measurement counts.
It requires the first result within three seconds and the overall local audit within thirty seconds.

The installed macOS app was checked while scanning: four outcomes and an enabled review action appeared in
the first native UI observation, and switching to Memory and back retained the audit. A three-second sample
found 1,403 of 1,624 main-thread samples waiting for events (about 86%), with no display-time file-existence
walk in the ready-item list. This is a responsiveness sample, not a frame-rate or battery benchmark.
Compact and standard fixture renders covered scanning, results, empty, cleaning, and completion states.
The full suite passed 297 tests; strict formatting, plist, shell checks, and the local release build passed.

## Repeat the measurements

These opt-in tests read real machine data and are skipped in ordinary test runs:

```sh
BLITZCLEAN_BENCHMARK=storage swift test -c release --filter PerformanceBenchmarks
BLITZCLEAN_BENCHMARK=inventory swift test -c release --filter PerformanceBenchmarks
BLITZCLEAN_BENCHMARK=fast swift test -c release --filter PerformanceBenchmarks
BLITZCLEAN_BENCHMARK=audit swift test -c release --filter liveDashboardAudit
```

The storage mode runs the cleanup path and asserts its 25-second local scan budget.
Inventory reports the full scan without imposing that smaller budget.
Category progress is cumulative; dependency-phase measurements are individual stage durations.
Run modes sequentially to avoid competing benchmark disk scans.
