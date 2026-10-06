# BlitzClean features

A detailed reference for what each part of BlitzClean does.
The [README](../README.md) has the overview; [Privacy](PRIVACY.md) covers data and permissions.

## Pages

| Page | Controls |
| --- | --- |
| Overview | CPU, RAM, storage, pressure guidance, and the largest AI threads. |
| Memory | Apps and AI sessions ranked by memory; Quit, Force Quit, Pause/Resume, and pressure history. |
| CPU | Current process usage; values can exceed 100% when a process uses multiple cores. |
| Storage | **Browse**, **Inventory**, and **Cleanup**, with no nested tab bar. |
| Revive apps | Live app checks, direct Revive/Force Quit, bulk recovery for stopped apps, and recent crashes. |
| Projects | Servers and background workers grouped by project, memory/CPU, Stop, Pause/Resume, and Keep running. |
| Settings | Permissions setup, menu-bar metrics, notifications, login launch, and project locations. |

## Menu bar

The menu bar shows CPU, RAM, and free storage. Its panel adds a memory chart, CPU and storage tiles,
the apps using the most memory, and shortcuts into the dashboard.
Resource samples update every two seconds; project, disk, and window checks have their own bounded refresh cycles.
Closing the dashboard with its red button, Command-W, Command-Q, or Dock Quit keeps the menu-bar monitor running.
To exit completely, open the panel's gear menu and choose **Stop monitoring and quit**.
Settings offers **Available GB**, **Used GB**, and **Used %** for RAM; the choice persists across relaunch.
Available memory includes memory macOS can reclaim for apps. CPU remains a utilization percentage.
Process and AI-session snapshots refresh every two seconds while BlitzClean is active, without overlapping scans.
Background process checks slow to roughly eight to ten seconds to reduce idle work.

## Permissions

Settings → **Finish setup** lists the permissions that are still missing and disappears once all are granted:

- **Notifications** for memory and disk warnings.
- **Accessibility** to detect frozen app windows. Without it, BlitzClean still reads process state.
- **Full Disk Access** to measure protected folders such as Mail and Safari data.

## Recover apps

Open **Revive apps** from the sidebar, menu bar, or **Tools** menu (`Shift-Command-R`).
Stopped and unresponsive apps appear first, and each Revive action runs independently of the full scan.

Revive resumes stopped processes and checks whether their windows respond; it does not restart a running app.
A deadlock can remain unresponsive, in which case Force Quit stays available with an inline unsaved-work confirmation.

Accessibility permission (Settings → Finish setup) enables frozen-window checks; without it, BlitzClean still inspects process state.
Recent crashes can be reopened or dismissed, and a successful recovery never masks a later stopped state.

## Find and remove storage

- **Browse:** navigate drives and folders without opening another window; select files/folders for Move to Trash.
- **Largest files:** scan all connected local drives, including hidden files, app packages, and dependency trees.
  Results retain the largest 5,000 files with progress, cancellation, and unreadable-location reporting.
  The prominent Browse action opens file results directly and remembers your preferred mode across relaunch.
- **Inventory:** inspect installed apps, vendor app folders, Xcode, simulator data, caches, and developer storage.
- **Cleanup:** review caches, dependencies, build outputs, simulators, Docker, worktrees, and previously removed folders.
- **Simulated devices:** shut down an iPhone simulator, then delete that device's apps and data after inline review.
  BlitzClean uses Apple's simulator service, verifies removal, and records it in history; installed runtimes stay available.
- **Remove again:** see when rebuildable folders grow back, with fresh activity and file checks before another removal.

Normal directory browsing runs separately from recursive size calculation.
Folder sizes and comparison bars stay visible on return and during background refresh.
The last 60 folder listings persist across relaunch, including interrupted measurements.
Largest-file traversal has no fixed 32-level depth or 20-second cutoff; denied locations remain visible as incomplete.

## Review media

- Filter videos, images, MP4/MOV and other extensions by age, size, and path; sort by size or date.
- Find exact duplicates with streaming SHA-256 comparison, excluding hard links and retaining one copy per group.
- Use an installed FFmpeg to create smaller SDR MP4/JPEG copies, lossless PNG, or joins of compatible clips.
  Exports preserve originals, check free space, and verify the output with a full decode.

FFmpeg is optional and is not downloaded automatically.
HDR video, animated images, transparent JPEG conversion, and joins with incompatible streams are rejected.

## History and pressure

CPU/RAM charts retain two-second detail for 15 minutes and five-minute points for seven days.
The chart file is capped at 512 KiB; scan results, filters, export history, and cleanup receipts also persist locally.

Pressure warnings consider memory pressure, compression, swap, disk reserve, and CPU.
Opt-in project pausing stops CPU work but keeps its memory allocated; it never automatically kills apps or deletes files.

## Removal and process rules

Personal files and folders use **Move to Trash**, with an inline review and fresh identity checks.
They remain recoverable; disk space is reclaimed when you empty Trash in Finder.

Cache and developer cleanup can **permanently delete** explicitly reviewed rebuildable data.
Running tools, open files, recent changes, protected paths, and incomplete checks can block removal.

Scans never select candidates automatically, and BlitzClean never empties Trash for you.
Folder size is not a guaranteed space gain: APFS shared blocks and concurrent writes affect available storage.

Individual Quit/Stop actions run immediately and preserve native save dialogs where supported.
Force Quit and bulk termination require inline confirmation; normal Stop never escalates automatically to Force Quit.

AI sessions have direct **Pause / Resume** controls in Overview and at the top of Memory.
Pause stops local workers and keeps their RAM; remote generation may continue.
Rows show verified session names when available, the provider, project, process ID, and delegated tools.
Claude delegating to Codex appears as Claude Code with **includes Codex CLI**; cmux is shown as the terminal host.
Shared desktop workers cannot always be mapped to individual chat titles and remain labeled as worker groups.

Pressure protection honors Keep running projects and protects AI/tool sessions from automatic pausing.
No forced memory purge or synthetic memory-pressure allocation is used.
