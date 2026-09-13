# Architecture

BlitzClean is a SwiftPM macOS app with no external package dependencies.
The legacy `FreeSpace` target produces the `BlitzClean` executable.

## Main experience

- `BlitzDashboardView`: navigation for Overview, Memory, CPU, and Storage.
- `BlitzStorageView`: shared Caches, Large files, and Dependencies workspace.
- `BlitzDesign`: shared buttons, search fields, and neutral selection controls matched to BlitzRecorder.
- `BlitzTrayView`: compact live status and actions. Opening it never starts a disk scan.
- `SystemMonitor`: two-second host CPU/VM samples; bounded CPU and memory histories.
- `CPUProcessReader`: per-process CPU deltas from `proc_pid_rusage`, with process-start identity checks.
- `MemoryControlView`: selected normal app quits, protected apps, and measured available-RAM changes.
- `QuickCleanModel` / `CacheCleaner`: bounded allowlist scan, age and activity checks, reviewed cache deletion.
- `LargeFileReviewView`: existing bounded file discovery with identity-checked Move to Trash.

## Existing developer tools

The separate developer window retains project and worker controls, worktree/dependency review,
folder size exploration, Docker tooling, storage accounting, and pressure incident history.
These deeper scanners run on demand or under their existing refresh policies.

## Safety boundaries

Cache trees are fingerprinted from file identity, size, type, and modification metadata.
Symlinks and special files are rejected. The exact direct-child target, internal volume,
running owner tools, open files, and the fingerprint are checked again before deletion.
A failed or incomplete check preserves the candidate and produces a visible explanation.
There is still a small filesystem race between final validation and removal; this is not a
privileged or adversarially hardened deletion service. The app runs as the current user.

Personal-file review rechecks inode, device, size, nanosecond modification time, and allowed roots.
The primary Large files page uses Trash. Separate developer workflows keep their reviewed deletion policies.

RAM release revalidates PID, bundle identity, launch date, protection policy, and foreground activity.
It sends a normal quit request, waits for the app, respects save dialogs, and samples actual available RAM.
No memory-pressure allocation tricks or forced purges are implemented.

## Persistence

`BrandMigration` copies selected legacy preferences to `com.blitzreels.BlitzClean` once.
The compatibility history directory remains `~/Library/Application Support/FreeSpace`.
No local incident log, preference export, build artifact, or machine screenshot belongs in Git.

## Verification

`./scripts/check.sh` builds/typechecks, runs Swift Testing suites, lints Swift,
validates property lists, and checks shell syntax.
`./scripts/build-app.sh` produces and verifies a release app bundle.
`./script/build_and_run.sh --verify` installs, launches, and verifies the process.

Tests exercise CPU deltas and PID reuse, bounded histories, launch routing, cache identity,
symlink refusal, recent/open-file protection, successful fixture deletion, app protection,
worktree/dependency safety, and the existing developer features.
