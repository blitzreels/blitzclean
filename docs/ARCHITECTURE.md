# Architecture

BlitzClean is a SwiftPM macOS app with no external package dependencies.
The `BlitzClean` target in `Sources/BlitzClean` builds the executable; tests live in `Tests/BlitzCleanTests`.

## Main experience

- `BlitzDashboardView`: one window for Overview, Memory, CPU, Storage, Revive apps, Projects, and Settings.
- `BlitzStorageView`: Browse (the default), Inventory, and Cleanup, without nested tabs.
- `FolderExplorerView` / `FolderExplorerModel`: clickable directory rows, navigation history,
  asynchronous listings and recursive sizes, and reviewed Move to Trash.
- `BlitzDesign`: shared buttons, search fields, and neutral selection controls matched to BlitzRecorder.
- `BlitzTrayView`: compact live status and actions. Opening it never starts a disk scan.
- `SystemMonitor`: two-second host CPU/VM samples; bounded CPU and memory histories.
- `CPUProcessReader`: per-process CPU deltas from `proc_pid_rusage`, with process-start identity checks.
- `MemoryControlView`: apps and AI sessions, direct normal Quit, inline Force Quit review, and pressure history.
- `AppRecoveryModel`: current macOS app roster, expiring health checks, independent recovery, and recent crashes.
- `QuickCleanModel` / `CacheCleaner`: bounded allowlist scan, age and activity checks, reviewed cache deletion.
- `LargeFileReviewView`: persistent file review, media filters, and identity-checked Move to Trash.
- `MediaDuplicateScanner`: size bucketing and streaming SHA-256, excluding hard links.
- `MediaExportEngine`: isolated FFmpeg staging, stream checks, full output decode, and unique final names.
- `MediaLibraryModel`: shared in-flight operations across navigation, with bounded export history.

## Developer tools

Projects owns server/worker controls; Storage Cleanup owns worktrees, dependencies, Docker, and rebuildable data.
Memory owns pressure history and AI sessions, while Storage Browse owns directory and large-file review.

These tools share the dashboard instead of opening a separate developer window.
Deeper scanners run on demand or under their own refresh policies.

## Safety boundaries

Cache trees are fingerprinted from file identity, size, type, and modification metadata.
Symlinks and special files are rejected. The exact direct-child target, internal volume,
running owner tools, open files, and the fingerprint are checked again before deletion.
A failed or incomplete check preserves the candidate and produces a visible explanation.
A small filesystem race remains between final validation and removal. Deletion runs as the current user,
without privileges or hardening against a deliberate attacker.

Personal-file review rechecks inode, device, size, nanosecond modification time, and allowed roots.
Storage Browse and its largest-file review use Trash. Separate developer workflows keep their reviewed deletion policies.

RAM release revalidates PID, bundle identity, launch date, protection policy, and foreground activity.
It sends a normal quit request, waits for the app, respects save dialogs, and samples actual available RAM.
No memory-pressure allocation tricks or forced purges are implemented.

## Persistence

Local files live in `~/Library/Application Support/BlitzClean`, built through `AppData`.
On launch, `AppData.migrateLegacyFiles` moves files from the pre-1.2.0 `~/Library/Application Support/FreeSpace`
folder without overwriting existing ones, and cleanup reports are still imported from that folder's `reports`.
`BrandMigration` copies selected preferences once from the legacy `fr.algomax.FreeSpace` domain to
`com.blitzreels.BlitzClean`.
Navigation and selected storage tab use UserDefaults. File review is an atomic JSON snapshot
beside the cleanup ledger (8 MiB / 5,000 files maximum), with filters saved separately.
The chart store keeps two-second samples for 15 minutes and five-minute points for seven days.
It is capped at 512 KiB, and the week-long chart is reduced to about 450 visible points.
Export history keeps at most 100 entries / 512 KiB. Incident history retains at most 1,440 events
from the last 24 hours; cleanup history keeps 1,000 records. JSON files use owner-only permissions.
No local incident log, preference export, build artifact, or machine screenshot belongs in Git.

## Media processing

The legacy narrow scanner remains for existing cleanup callers. Largest files uses `DriveFileScanner`: native
FTS metadata traversal with physical paths, no symlink following, and one filesystem per explicit root. Boot system
and Data roots are included separately; mounted external local drives are included. A single utility worker
round-robins roots in 2,048-entry batches and publishes at most about every 750 ms. A min-heap retains the largest
5,000 files in bounded memory. Scans are cancellable, include hidden/package/dependency trees, and report unreadable
locations. There is no 20-second or 80,000-entry cutoff in this mode. Stale/empty legacy snapshots migrate to the
new all-drive scope; nonempty snapshots are refreshed after an hour. Large saved lists revalidate off the main actor.

Content comparison is cancellable, reads 1 MiB chunks, and stops after two minutes.
The selected file's identity is checked before and after hashing. It detects exact copies only;
visually similar edits and separately encoded versions of a recording do not match.

FFmpeg and FFprobe are discovered in Homebrew or standard binary locations, with no automatic installation.
Inputs must pass identity and open-file checks. Each export uses its own hidden staging directory,
keeps originals, limits codec threads, checks free space, and terminates on cancellation or app quit.
Successful exports pass stream/duration checks and a complete decode before moving to a unique name.
SDR MP4 uses H.264 CRF 23 and AAC; image choices are JPEG quality 2 or lossless PNG.
Joining uses FFmpeg's [concat demuxer](https://ffmpeg.org/ffmpeg-formats.html#concat)
with matching stream signatures and controlled relative manifest entries. Mixed formats are rejected.
Completed jobs persist; interrupted encoding jobs are not resumed.

## Verification

`./scripts/check.sh` builds/typechecks, runs Swift Testing suites, lints Swift,
validates property lists, and checks shell syntax.
`./scripts/build-app.sh` produces and verifies a release app bundle.
`./scripts/package-release.sh` builds both Mac architectures and packages a Developer ID signed archive,
with optional notarization and a checksum; see [Releasing](RELEASING.md).
`./script/build_and_run.sh --verify` installs, launches, and verifies the process.

Tests exercise CPU deltas and PID reuse, bounded histories, launch routing, cache identity,
symlink refusal, recent/open-file protection, successful fixture deletion, app protection,
worktree/dependency safety, and the existing developer features.

## Pressure prevention

`PressureSentinel` samples memory pressure, compression, swap, real free disk capacity and CPU every two seconds
on a serial queue independent of SwiftUI. It identifies the limiting resource, forecasts a shrinking disk reserve,
and posts rate-limited notifications through the existing notification permission. It runs inside the app,
so it stops during a kernel stall, suspension, or app termination.

`DevProcessScanner` reads working directories with `proc_pidinfo`, uses bounded three-second process/port commands,
and resolves project ancestry off the main actor. The UI reuses the resulting directory map and groups workers
without listening ports with their project. Scans expose incomplete results instead of claiming full coverage.

Projects offer Pause/Resume and a per-project opt-in for automatic pausing after sustained pressure.
Automatic actions use a recent identity-checked process snapshot, protect Keep running projects and AI/tool sessions,
and pause at most one eligible project per 30 seconds. Pause sends SIGSTOP to the eligible project runtimes;
it prevents further CPU work but does not release their existing RAM. Resume is always explicit.
The guard never automatically kills apps or deletes data. A stopped project can be resumed from Projects after relaunch.

`pressure-latest.json` retains up to 240 pressure samples/actions and top project summaries across app restarts,
with owner-only permissions and no process arguments or credentials. This local incident trace survives the app UI
becoming busy; it cannot prove which process caused a kernel panic. macOS crash reports remain the authority.

Individual Quit/Stop actions run without a BlitzClean confirmation. Native application save dialogs still appear.
Manual project Stop validates PID, owner, start identity, executable, snapshot age, and Keep running protection;
it sends SIGTERM and resumes stopped workers to deliver that signal. It never escalates to SIGKILL automatically.
Auto-pause remains opt-in and never invokes Stop.

## Live app recovery

The recovery view merges the current NSWorkspace roster with matching cached memory measurements.
An app is actionable before RAM scanning finishes; launch/exit notifications and a two-second loop refresh the roster.

Health checks expire after two seconds, with at most eight concurrent window probes.
Each Accessibility message times out after 0.5 seconds; two failed observations are required for an unresponsive result.

Native identity validation uses the PID, owner, launch identity, and bundle before sending SIGCONT.
Recovery verifies the result within a bounded observation loop and never restarts a responsive app.

New health supersedes conflicting recovery results, and a completed attempt does not impose a retry lock.
Crash-report discovery is throttled to at most once per 30 seconds; the per-app Force Quit path keeps its inline review.
