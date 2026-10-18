# Project lifecycle audit — 9 October 2026

- Project discovery and coordinated Stop/Start are feasible with the data already available on this Mac.
- A useful RAM-saving action must stop workloads and restart them later.
  OS suspension keeps allocations and sockets; it cannot provide the expected RAM savings.
- Audit only: no application changes, process signals, container stops, cleanup, or permission changes were made.

## Live evidence

- Samples taken at approximately 13:19–13:23, Europe/Paris.
- Hardware: 36 GiB RAM.
  Swap in use fell from 26.0 GiB to 20.6 GiB while other work changed during this audit.
- Internal free space changed from approximately 21 GiB to 27 GiB.
  This audit did not cause those changes.
- The first snapshot contained a suspended TypeScript compiler, PID 64070, with an 11.0 GiB footprint.
  A suspended BlitzReels Node server, PID 17258, held 5.63 GiB and still owned port 3100.
- Those PIDs exited before the second snapshot, and a replacement server appeared on port 3100.
  They are historical evidence of suspension retaining memory, not current termination targets.

The table uses the 13:22:45 snapshot and macOS `proc_pid_rusage` physical footprint.
Footprint includes compressed memory; it is not resident RAM or a promise of immediately reclaimable bytes.
Folder association includes agent tools and browser helpers, and does not establish exclusive ownership.

| Project folder | Processes | Footprint | Association evidence |
| --- | ---: | ---: | --- |
| BlitzReels | 74 | 12.61 GiB | Web :3100, another listener :3401, tool workers; 24 processes suspended |
| Elshaddai / agent | 83 | 5.06 GiB | Primarily agent/tool runtimes; 22 processes suspended |
| BlitzClean | 64 | 3.83 GiB | Agent/tool runtimes, including this audit; separate from the installed app |
| FMX website | 4 | 3.34 GiB | Angular :1111, npm launcher, esbuild workers |
| Philadirect | 50 | 2.82 GiB | Agent tools and automation browsers |
| OpenSEO | 3 | 2.10 GiB | Vite :3001, Cloudflare workerd, esbuild |
| Affonso | 23 | 1.58 GiB | Agent/tool runtimes |
| FMX API | 33 | 1.25 GiB | API :3000 plus browser helpers |
| ITDM root | 20 | 1.22 GiB | Agent/tool runtimes |
| Algomax Studios | 2 | 0.65 GiB | Vite :5173, npm launcher, external-drive checkout |

- The second snapshot still had about 3.02 GiB attributed to suspended project processes.
- The shared Codex host alone accounted for approximately 2.27 GiB, outside the project totals.
  It must not be terminated as though it belonged to one chat.
- Port numbers in the 10000 range mostly belonged to tool services in this sample.
  A listening port is evidence of a service, not proof of a product dev server.

## Docker association

Verified local endpoint: `unix:///Users/algomax/.docker/run/docker.sock`, context `desktop-linux`.
Seven containers were running and one was stopped.

| Workload | Containers | State | Published ports | Ownership evidence |
| --- | ---: | --- | --- | --- |
| BlitzReels Electric | 1 | Running | 3130 | Compose project, working directory, config file |
| EasyMix launch QA | 4 | Running | 54321, 54322 | Supabase project and workdir labels |
| FMX Community database | 1 | Running | 35432 | Local verification document names the container and port |
| Trigger BuildKit | 1 | Running | None | Buildx builder metadata; project exclusivity unproven |
| Chroniques Postgres | 1 | Stopped | None | Compose project, working directory, config file |

- EasyMix QA lives under `~/Documents/Codex/2026-09-27/imp/work/supabase-qa`.
  Scanning only `~/dev` misses it.
- FMX's database has no project labels and uses an anonymous data volume.
  The name alone is insufficient for automatic destructive ownership decisions.
- The Trigger builder is infrastructure and should be shown separately until its consumers are known.
  Its container was using about 174 MiB in `docker stats` despite having no listening port.
- Container memory across the seven running containers was approximately 1.10 GiB.
  Linux container accounting must remain separate from macOS VM footprint.
- Stopping containers releases their guest workloads; Docker Desktop may retain VM memory.
  Resource Saver can stop the VM after all containers are stopped and the idle period passes.

## Why the current controls fall short

1. **AI Pause is process suspension, not Codex turn cancellation.**
   `AIThreads.swift:292` maps Pause to `SIGSTOP`.
   `AIThreads.swift:241` groups shared-host children by a ten-second launch-time gap.
   This is a heuristic worker group, not an authoritative chat-to-process mapping.
   The shared host is excluded, so remote generation and future host-launched work are not paused by that action.
   This audit did not click Pause on an active chat or prove a specific chat-cancellation failure.

2. **Project Stop does not encompass the full project workload.**
   `DevProcesses.swift:652` excludes all PIDs assigned to AI groups from the primary project target.
   Real project servers launched by Codex can therefore fall outside that target.
   `WorkspaceView.swift:139` has a fallback for recognized servers, but it is not a complete workload shutdown.

3. **The primary target uses a short executable allowlist.**
   `PressurePrevention.swift:114` accepts selected Node-related names and FFmpeg.
   It omits the native `tsc`, `pnpm-native`, `workerd`, and `esbuild` executables observed here.
   Stopping a listed parent does not establish that every child has exited.

4. **Docker lifecycle is separate from project lifecycle.**
   `WorkspaceProject` contains host resources and servers, without container membership.
   Docker is inspected through aggregate storage categories, not a project/container/volume relationship.

5. **The image cleanup estimate and removal scope disagree.**
   `DockerStorage.swift:27` counts all image reclaimability reported by `docker system df`.
   `DockerStorage.swift:87` runs `docker image prune --force`, which removes dangling images only.
   Docker reported 2.687 GB of reclaimable images, while the dangling-image listing was empty.
   The image phase therefore had nothing eligible to remove at this snapshot.

6. **Container and volume cleanup is intentionally absent.**
   `DockerStorage.swift:12` protects these categories.
   The cleanup command prunes dangling images and engine build cache, with no volume removal.
   Separate container-backed Buildx builders also need separate inspection and ownership checks.

## Disk findings

These are allocated-size observations, not approved deletion targets.
Hardlinks, filesystem allocation units, snapshots, and ongoing writes can change actual reclaimed space.

| Location | Allocated size | Volume / significance |
| --- | ---: | --- |
| Algomax Studios `node_modules` | 24.03 GiB | External `/Volumes/harddrive`; does not free internal storage |
| BlitzReels `node_modules` | 5.81 GiB | Internal; active project |
| BlitzReels `.next` | 2.41 GiB | Internal; active project output |
| OpenSEO `node_modules` | 1.53 GiB | Internal; active Vite/workerd project |
| FMX website `node_modules` | 0.78 GiB | Internal; active Angular project |
| FMX API `node_modules` | 0.59 GiB | Internal; active API project |
| Docker disk image | 12.58 GiB | Actual allocated blocks; logical maximum is 1 TiB |
| Docker volumes, aggregate | 853.9 MB | Databases and builder state; not generic cache |
| Docker volumes reported reclaimable | 552.4 MB | Unattached does not mean disposable |
| Engine build cache reported reclaimable | 1.052 GB | Separate from project folders and database volumes |

- Elshaddai's `node_modules` is a symlink into a temporary runtime; do not follow it for project cleanup.
- Chroniques dependency sizing exceeded the 18-second bound and remains unknown.
- The empty EasyMix root `node_modules` measurement does not establish zero dependency storage in its monorepo.
  Nested package dependencies were outside this bounded scan.
- `/Volumes/BuildkeepArchive` had approximately 8.7 GiB free.
  `/Volumes/BuildkeepArchive2` had approximately 83 GiB free.
- A project cleanup needs a volume selector and must show which filesystem gains space.
  A large external dependency folder does not explain internal disk pressure.

## Recommended BlitzClean behavior

Use one project inventory with explicit relationships and three distinct actions.

| Action | Effect | Return path |
| --- | --- | --- |
| Suspend | Stops local CPU execution; retains allocations and bound ports | Resume existing processes |
| Stop | Gracefully stops selected project services, workers, and containers | Start saved service recipes |
| Clean storage | Removes reviewed rebuildable files after their users stop | Reinstall dependencies / rebuild |

- Make **Stop** the primary RAM-saving action.
  Offer **Stop for 30 minutes** only where a verified restart recipe exists.
- Timed restart means a fresh service launch, not recovery of an interrupted compiler or process heap.
  Persist the timer, handle sleep/relaunch, and check for port conflicts before starting.
- Keep database volumes during Stop and Start.
  Database deletion or reset needs a separate, explicit data review.
- Display application services, agent tools, and shared infrastructure within each project's breakdown.
  Preserve the distinction even when their working directories match.

Discovery should combine:

- Canonical checkout/worktree roots, package manifests, lockfiles, and configured project locations.
- PID identity, start time, executable path, working directory, parent tree, and listening sockets.
- npm/pnpm scripts as candidate restart recipes, validated against the actual launcher and environment source.
- Compose project/workdir/config labels, Supabase labels, container mounts, and published ports.
- Explicit user mapping for shared or ambiguous containers; names and ports are weak evidence alone.

Stop execution should:

- Capture the selected scope and restart recipes before stopping anything.
- Identify supervisors and watchers so they cannot immediately respawn stopped children.
- Stop service workloads without terminating the shared Codex host or unrelated browser sessions.
- Revalidate process identity and local Docker endpoint immediately before each action.
- Handle already-suspended processes so graceful termination can be delivered.
- Rescan for descendants, replacement PIDs, bound ports, and container state.
- Report Stopped, Partially stopped, or Failed from observed results, not signal delivery alone.
- Measure footprint, pressure, and free storage afterward; never promise the sum of estimates as savings.

Storage cleanup should:

- Require confirmed inactivity for the selected project's artifacts.
- Keep source, uncommitted work, configuration, database volumes, and shared package stores separate.
- Match displayed eligibility to the exact cleanup operation, including Docker image scope.
- Record removed allocated bytes and measured free-space change on the affected volume.
- Import manual removal receipts through BlitzClean's existing storage-cleanup report format.

## Implementation boundary and verification

- No implementation, build, tests, installed-app changes, or destructive reproduction was performed.
  The evidence is live read-only inspection plus the checked-out source.
- A first implementation should cover npm/pnpm services, Compose/Supabase association, and truthful Stop results.
  Reliable Codex turn cancellation requires a supported Codex integration, not a process-group guess.
- Acceptance must include a real dev server plus child watcher, a container with a preserved database volume,
  an already-suspended worker, PID replacement, shared tooling, and a service that respawns after Stop.
- Changed UI must be compiled and exercised in the running macOS app, per the repository instructions.

## Supporting material

- Initial local snapshot: `/tmp/blitzclean-project-audit-20261009-131930.json`.
- Later local snapshot: `/tmp/blitzclean-project-audit-current-20261009.json`.
- Docker associations: `/tmp/blitzclean-project-audit-docker-20261009.json`.
- Bounded storage scan: `/tmp/blitzclean-project-audit-storage-20261009.json`.
- FMX mapping: `~/dev/itdm/.task-runs/FMX-COMMUNITY-UX-LOCAL-20261008/verification.md:58`.
- Docker documents that [Pause suspends container processes][pause].
- Docker documents that [Compose Stop preserves containers for Start][stop].
- Docker documents [image-prune eligibility][prune] and [VM Resource Saver behavior][saver].
- Docker explains [allocated disk-image size on macOS][disk] and [separate Buildx builders][builders].

[pause]: https://docs.docker.com/reference/cli/docker/container/pause/
[stop]: https://docs.docker.com/reference/cli/docker/compose/stop/
[prune]: https://docs.docker.com/reference/cli/docker/image/prune/
[saver]: https://docs.docker.com/desktop/use-desktop/resource-saver/
[disk]: https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/
[builders]: https://docs.docker.com/build/builders/manage/
