# Changelog

## 1.2.0 — 2026-10-06

### Repository

- Rewrite the README around what BlitzClean does, with screenshots, install steps, safety rules, and a repository map.
- Move the detailed feature reference to `docs/FEATURES.md`.
- Add issue forms, a pull request template, release-note categories, and a label set.
- Expand contributing and security guidance.

### Tray and dashboard polish

- Redesign the tray: an alert only under pressure, a Memory tile with a 60-second plot, CPU and Storage tiles,
  the three apps using the most memory, and Revive apps (with its count) beside Open dashboard.
- Send disk-limited alerts to Storage Cleanup instead of Projects, with disk-specific advice.
- Tint the Overview pressure alert by severity; show a one-line status when capacity is fine.
- Make the Overview Memory and CPU cards fully clickable and keep one accent action per view.
- Give Storage one 28-point gutter, a free-space meter beside its tabs, and one toolbar row per mode:
  location chips on the left, the Largest files / Browse folders switch on the right.
- Merge Storage status messages into one line and replace the square stop icon with a labeled Stop.
- Move permission requests to Settings → Finish setup, shown only while something is missing,
  with a count on the Settings sidebar item; remove the Overview, Revive, and Largest files prompts.
- Merge duplicated rows, headers, empty states, action bars, and badges into shared components.
- Make Storage Cleanup refresh from one Scan again; simulators show one action per device.
- Collapse empty Cleanup sections to their header; list only removable worktrees, with the rest behind a toggle.
- Keep one accent action on Cleanup; Docker and cache bars use secondary buttons.
- Give each pressure alert one specific instruction plus a metrics line, without repeated advice.
- Keep project rows aligned when a project has no Start or Stop action.
- Speed up rendering: lists are filtered once per render, icons are cached, Largest files no longer
  rebuilds its duplicate set per file, and charts find their time window by binary search.

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

## 1.1.0 — 2026-10-02

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
