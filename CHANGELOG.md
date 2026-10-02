# Changelog

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
- Exclude local storage-cleanup reports from source control.

Earlier local 1.0.x builds were not published as GitHub releases.
