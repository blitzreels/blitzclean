# Resource recovery implementation and verification

Local implementation, 9 October 2026. No production release or Git push.

## Implemented

- Memory makes Stop primary. Suspend/Resume explicitly retains worker memory.
- Local Codex worker groups are distinguished from individual remote chats.
- Process controls validate executable, owner and start time, expand the live child tree,
  stop supervisors before children, resume suspended workers for graceful termination,
  and report remaining processes. Force Stop remains explicit.
- Native project runtimes include compilers and runtime children previously omitted from project Stop.
- Projects includes Compose/Supabase container associations and explicit folder assignment.
- Container Stop/Start preserves containers and database volumes. Slow graceful shutdown is reported.
- Docker cleanup estimates include eligible dangling images and build cache, and report Docker's actual result.
- Container RAM is marked unavailable instead of displaying zero. Mixed project memory measures host workers.
- Dashboard process scanning slows under pressure and unchanged arrays are not republished.
- A separate signed AppKit helper runs before dashboard models, reads native process data,
  and provides emergency controls through Control–Option–Command–R, the tray and Tools.
- The fallback uses BlitzClean's design tokens. Normal project work remains in Memory and Projects.

## Automated verification

- Full build/typecheck, strict Swift formatting lint, plist and shell validation passed.
- Full suite: 345 tests across 62 suites passed in 68.835 seconds.
- After helper integration and styling, 45 focused tests across 5 suites passed in 6.535 seconds.
- Added coverage for late-spawned children, changed identities, stopped workers and failed graceful shutdown.
- Added Docker ownership, container replacement, non-destructive shutdown and dangling-image estimate coverage.
- Native emergency inventory completed in 55 milliseconds in one local test sample.
- Installed release and embedded helper passed deep, strict code-signing verification.

## Installed app verification

- Inspected Memory and Projects in the installed macOS app.
- Observed BlitzReels, EasyMix QA, unassigned FMX and shared BuildKit containers in Projects.
- Inspected Storage Cleanup: 1.1 GB eligible, separately from Docker's 2.7 GB image estimate;
  containers and volumes remained protected. No cleanup was executed.
- Inspected emergency selection, disabled controls, suspend action and stop results.
- A disposable Node worker allocated 64 MiB; its measured footprint was about 79 MB.
- Froze only the BlitzClean dashboard process with SIGSTOP and a 55-second automatic resume watchdog.
- While the dashboard was confirmed stopped, the helper suspended the fixture and reported 79.2 MB retained.
- The helper then stopped that suspended fixture and reported a zero retained footprint.
- The fixture PID was gone while the dashboard PID was still stopped; the watchdog then resumed the dashboard.
- Exercised the shortcut from the dashboard and Finder; inspected the separate helper's native window.
- Real project workers, containers and database volumes were not stopped or deleted during verification.

## Limits

- The controlled dashboard freeze is not a synthetic 80 GB memory-pressure or OS-wide stall test.
- macOS cannot promise immediate scheduling during kernel, disk or swap stalls.
- Stopping local workers does not cancel remote model generation or checkpoint a chat's in-memory state.
- A shared Codex app target affects every chat in that app and requires inline confirmation.
- Live database containers were inspected, not stopped for testing; lifecycle tests use a fake Docker executor.
- Physical RAM, compressed footprint, swap use and reclaimed disk space are distinct measurements.
