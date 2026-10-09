# Changelog

## 1.3.0 - 2026-10-07

### Updates

- Add automatic updates with Sparkle. Release builds check GitHub once a day, download signed updates in the
  background, and show Restart to update in the menu bar panel and in Settings > Updates.
  Automatic checks can be turned off there. Versions 1.2.0 and earlier must download this release by hand once.

### Overview

- Check my Mac runs five checks in parallel: memory and CPU, caches, project data and regrown folders, Docker,
  and app responsiveness. Findings are ranked as Next moves, each with one action. Only Clean removes anything
  from Overview; other findings open the page and section that owns them.
- Show memory, CPU, and storage load as rings beside the check, with the busiest resource in the center.
  Warnings color the value in the legend. A successful cache cleanup shows the space removed.
- Opening Overview no longer starts storage scans. A short line shows the last cleanup and space recovered.

### Menu bar panel

- Rebuild the panel around the same rings, last-minute memory and CPU charts, and the three apps using the most
  memory with their share of RAM. The gear menu adds Check for updates and links to other BlitzReels apps.

### Memory and Storage

- Add Memory > Processes with each process's own RAM footprint, owner, and PID, searchable by name or PID.
- Start Storage Cleanup with System Data cleanup: eligible browser and developer caches, plus diagnostic reports
  older than 30 days after explicit review. Overview's Clean never removes reports.
- Make cleanup scans faster: Overview and Cleanup measure only cleanup locations; the full inventory runs when
  Inventory is opened. Project age checks are time-bounded and report Unknown instead of an old date.

### Settings and design

- Add Not needed to each Finish setup permission. Skipped permissions leave the list and the sidebar badge;
  Ask again brings them back.
- Add Our other apps with links to BlitzRecorder and BlitzReels.
- Remove gradients and glows, keep one accent color per view, and raise faint text to meet AA contrast.

## 1.2.0 - 2026-10-06

### Menu bar panel

- Redesign the panel around three tiles: memory with a 60-second chart, CPU, and free storage.
  Below them are the three apps using the most memory, then Revive apps and Open dashboard.
- Show the pressure alert only when a resource is limited. Disk alerts open Storage Cleanup with disk advice;
  memory and CPU alerts open Projects.

### Dashboard

- Request permissions in one place, Settings > Finish setup. It lists only what is missing, the Settings item
  shows the count, and the section disappears once everything is granted. Pages no longer ask on their own.
- Give each pressure warning one instruction and a separate line of numbers, colored by severity.
  When nothing is limited, Overview shows a single status line.
- Make the Storage, Memory, and CPU cards on Overview open their page when clicked.
- Give Storage one toolbar row in both modes: drives on the left, Largest files or Browse folders on the right,
  plus a free-space meter beside the tabs and a labeled Stop button.
- Refresh Storage Cleanup with one Scan again button. Empty sections shrink to their title, worktrees that
  can't be removed sit behind a toggle, and each simulator shows the one action that applies to it.
- Keep one accent button per page and align project rows that have no Start or Stop action.

### Speed

- Filter and sort each list once per render instead of several times.
- Cache app icons instead of reloading them from disk on every redraw.
- Stop rebuilding the duplicate list for every file in Largest files.
- Find the visible chart window with a binary search over the seven-day history.

### Name and data

- Rename the Swift module, folders, and scripts to BlitzClean.
- Keep local data in `~/Library/Application Support/BlitzClean`. On first launch, files from the older
  `FreeSpace` folder move there without replacing anything, and cleanup reports dropped in the old
  `reports` folder are still imported.

### Repository

- Rewrite the README with screenshots, install steps, safety rules, and a repository map.
- Move the detailed feature reference to `docs/FEATURES.md`.
- Add issue forms, a pull request template, release-note categories, and labels.
- Expand the contributing and security guides.

### Menu bar monitoring

- Keep monitoring after closing the dashboard, pressing Command-Q, or choosing Dock Quit.
- Add a dedicated Stop monitoring and quit action in the tray; allow macOS logout, restart, and shutdown normally.
- Offer Available GB, Used GB, and Used % for menu-bar RAM, with available memory as the default.
- Keep the selected memory display across relaunch and use it in the tray dashboard too.

### AI sessions

- Make Pause/Resume direct actions and place AI sessions above apps in Memory.
- Read verified local Claude, Codex CLI, and Cursor session titles with bounded, read-only lookups.
- Show delegated tools, terminal host, and PID; include them in search.
- Label shared Codex desktop worker groups without guessing chat titles.
- Deliver Quit to paused workers and avoid reporting unverified pause/resume requests as completed.
- Refresh process and AI-session snapshots every two seconds while BlitzClean is active, with non-overlapping scans.

### Storage browsing

- Restore proportional size bars in Browse and keep saved sizes visible while refreshing.
- Cache interrupted and partially readable folder scans across navigation and app relaunch.
- Reuse completed scans for five minutes; refresh older results without clearing the list.
- Retain saved results when a folder is unavailable and discard sizes for replaced folder identities.
- Make Largest files a prominent Browse action and remember the chosen mode across relaunch.
- Show file results directly below drive scope controls, without an extra directory list.
- Add verified simulator-device shutdown and deletion through Apple's simulator service, preserving installed runtimes.
- Route managed simulator folders to device controls instead of generic Trash.

## 1.1.0 - 2026-10-02

### App recovery

- Replace each action dropdown with direct Revive and Force Quit buttons.
- Keep Revive available on eligible running apps, including apps awaiting their first memory measurement.
- Refresh the app roster on launch/exit and every two seconds while the recovery screen is open.
- Refresh cached window health; a new stopped/frozen state supersedes an earlier successful recovery.
- Remove the ten-second retry lock and allow independent or bulk recovery of stopped apps.
- Bound concurrent window checks, shorten stalled-window waits, and throttle crash-report scans.
- Distinguish a resumed process from a confirmed responsive window; retain inline Force Quit confirmation.

### Storage and media

- Default Storage to Browse, with Inventory and Cleanup beside it; remove the separate Files tab.
- Add direct drive/Home controls, named Back/Forward controls, parent breadcrumbs, and clickable directory rows.
- Calculate recursive folder sizes off the main thread and cancel previous traversal when navigating away.
- Rank the largest 5,000 files across connected local drives, with progressive results and unreadable-path reporting.
- Support reviewed Trash actions, media filters, exact duplicate detection, and optional verified FFmpeg exports.
- Show rebuilt folders in Remove again, with fresh safety checks and imported local cleanup receipts.

### Monitoring and projects

- Persist CPU/RAM charts across relaunch with bounded seven-day history.
- Show pressure guidance based on memory pressure, swap, compression, CPU, and available disk space.
- Detect project background workers as well as listening servers; expose incomplete process scans.
- Add explicit Pause/Resume and opt-in project auto-pause during sustained pressure.
- Keep normal Quit/Stop immediate while preserving identity checks, native save dialogs, and bulk confirmations.

### Design and development

- Unify navigation, inline reviews, controls, app icons, and the BlitzClean brand assets.
- Preserve the menu bar when the dashboard closes.
- Update the README, privacy, architecture, roadmap, and release documentation.
- Add universal release packaging and explicit ad-hoc signing for certificate-free CI checks.
- Keep command-deadline timers off shared worker queues and make cancellation tests independent of CPU count.
- Install FFmpeg in CI so media export integration tests run on clean hosts.
- Exclude local storage-cleanup reports from source control.

Earlier local 1.0.x builds were not published as GitHub releases.
