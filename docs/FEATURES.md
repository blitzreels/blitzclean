# BlitzClean features

This is the detailed reference for each part of BlitzClean.
The [README](../README.md) has the overview, and [Privacy](PRIVACY.md) covers data and permissions.

## Pages

| Page | What it does |
| --- | --- |
| Overview | CPU, RAM, storage, pressure guidance, and the AI threads using the most memory. |
| Memory | Apps and AI sessions ranked by memory, with Quit, Force Quit, Pause and Resume, and pressure history. |
| CPU | Current usage per process. A process using several cores can exceed 100%. |
| Storage | Browse, Inventory, and Cleanup, with no nested tab bar. |
| Revive apps | Live app checks, Revive and Force Quit on each app, bulk recovery for stopped apps, and recent crashes. |
| Projects | Servers and background workers grouped by project, with memory, CPU, Stop, Pause and Resume, and Keep running. |
| Settings | Permission setup, menu bar values, notifications, launch at login, and project locations. |

## Menu bar

The menu bar shows CPU, RAM, and free storage. Clicking it opens a panel with a memory chart, CPU and storage
tiles, the apps using the most memory, and shortcuts into the dashboard.

Resource samples update every two seconds. Project, disk, and window checks run on their own, slower schedules.
Process and AI-session snapshots also refresh every two seconds while BlitzClean is in front, and never overlap.
In the background, process checks slow to about every eight to ten seconds.

Closing the dashboard with its red button, Command-W, Command-Q, or Dock Quit keeps the menu bar monitor running.
To exit completely, open the panel's gear menu and choose Stop monitoring and quit.

Settings offers Available GB, Used GB, and Used % for RAM, and remembers the choice.
Available memory includes memory macOS can reclaim for apps. CPU is always a utilization percentage.

## Permissions

Settings > Finish setup lists the permissions that are still missing, and disappears once all are granted.

- Notifications, for memory and disk warnings.
- Accessibility, to detect frozen app windows. Without it, BlitzClean still reads process state.
- Full Disk Access, to measure protected folders such as Mail and Safari data.

## Recover apps

Open Revive apps from the sidebar, the menu bar, or the Tools menu (`Shift-Command-R`).
Stopped and unresponsive apps are listed first, and each Revive runs without waiting for the full scan.

Revive resumes stopped processes and checks whether their windows respond. It does not restart a running app.
An app stuck in a deadlock can stay unresponsive; Force Quit is then available, after an inline warning about
unsaved work.

Recent crashes can be reopened or dismissed. A successful recovery never hides a later stopped state.

## Find and remove storage

### Browse

Move through drives and folders in the same window, and select files or folders to move to the Trash.

### Largest files

Scan every connected local drive, including hidden files, app packages, and dependency folders.
BlitzClean keeps the 5,000 largest files, shows progress, can be cancelled, and lists locations it could not read.
It remembers whether you last used Browse or Largest files.

### Inventory

See installed apps, vendor app folders, Xcode, simulator data, caches, and developer storage.

### Cleanup

Review caches, dependencies, build output, simulators, Docker, worktrees, and folders removed before.

### Simulated devices

Shut down an iPhone simulator, then delete that device's apps and data after an inline review.
BlitzClean uses Apple's simulator service, checks that the device is gone, and records the removal.
Installed iOS runtimes stay.

### Remove again

See when rebuildable folders grow back. Activity and file checks run again before each removal.

### Measuring folders

Listing a folder is separate from measuring it, so navigation never waits for sizes.
Sizes and comparison bars stay visible when you come back to a folder and while it refreshes.
The last 60 folder listings survive a relaunch, including measurements that were interrupted.
Largest files has no depth limit or time cutoff, and folders it cannot read stay marked as incomplete.

## Review media

- Filter videos, images, and other file types by age, size, and path, and sort by size or date.
- Find exact duplicates by comparing SHA-256 hashes as files stream in. Hard links are skipped, and one copy
  per group is always kept.
- With FFmpeg installed, make smaller SDR MP4 or JPEG copies, lossless PNGs, or join compatible clips.
  Originals are kept, free space is checked first, and every output is fully decoded to verify it.

FFmpeg is optional and never downloaded automatically.
BlitzClean refuses HDR video, animated images, transparent images converted to JPEG, and joins of clips
with incompatible streams.

## History and pressure

CPU and RAM charts keep two-second detail for 15 minutes and five-minute points for seven days.
The chart file is limited to 512 KiB. Scan results, filters, export history, and the removal log are also saved locally.

Pressure warnings look at memory pressure, compression, swap, the disk reserve, and CPU.
Projects can opt in to automatic pausing. Pausing stops CPU work but keeps the memory allocated,
and BlitzClean never kills apps or deletes files on its own.

## Removal and process rules

Personal files and folders go to the Trash after an inline review and a fresh identity check.
You can still recover them, and the space is freed when you empty the Trash in Finder.
BlitzClean never empties the Trash for you.

Cache and developer cleanup can permanently delete rebuildable data that you reviewed.
Running tools, open files, recent changes, protected paths, or an incomplete check block the removal.
Scans never select anything automatically.

A folder's size is an estimate of the space you get back. APFS shared blocks and files written in the
meantime change the real result.

Quit and Stop on a single item run immediately and keep the app's own save dialogs.
Force Quit and bulk actions ask for confirmation first. Stop never turns into Force Quit on its own.

AI sessions have Pause and Resume buttons in Overview and at the top of Memory.
Pausing stops local workers and keeps their RAM; generation running on a remote server can continue.
Each row shows the verified session name when there is one, plus the provider, project, process ID,
and any tools it started. Claude running Codex appears as Claude Code that includes Codex CLI,
and cmux appears as the terminal host. Shared desktop workers can't always be matched to a chat title,
so they are labeled as worker groups.

Automatic pausing skips projects marked Keep running and never touches AI or tool sessions.
BlitzClean uses no memory purge commands and no artificial memory pressure.

### Conservative cleanup boundaries

Docker inspection and cleanup require a local Unix socket; SSH and TCP contexts are rejected.
Each operation pins its endpoint so a context switch cannot redirect its commands. Image pruning
preserves tagged images and removes only dangling images; build-cache pruning remains available.
Docker's displayed reclaimable estimate can therefore exceed the amount this conservative cleanup removes.

Repeat folder removal honors Keep running and refuses recent files (seven days), tracked files,
open files, symbolic links, incomplete checks, and trees that change during validation.
This can keep dependency folders containing symlinks; review those with their package manager instead.

Automatic HTTP probes use literal loopback addresses only. External redirects and external favicon
URLs are rejected, and probes do not use configured HTTP proxies.
