# Changelog

## 1.7.0 - 2026-10-25

### Memory protection

- Settings adds "Pause builds before memory runs out", on by default. It pauses a fast-growing build, agent
  builds included, before macOS starts warning.
- Builds and agents' scripts run at background priority, so apps keep the performance cores.
- A paused build keeps its memory. After two minutes of short memory, Stop becomes its main action on Memory
  and on Overview.
- Memory lists background load nobody started on purpose: login services that hold memory or keep failing
  (Turn Off), virtual machines, tool servers every agent session starts again, memory cleaner apps, and apps
  macOS flagged for heavy disk writes.
- After a restart caused by memory running out, Overview names what held the memory, read from the panic
  report before macOS deletes it.

### Design

- Overview opens with Memory, CPU and Disk as ring gauges with a 15-minute trend; each opens its page.
- Memory and CPU show a live ring gauge, Memory splits RAM into apps, compressed and free, and the history
  charts gain percent gridlines, a dot on the latest value and a readout on hover.
- Every row on Memory and CPU, and every resource in the sidebar, has a small meter.
- Drive scans show a moving progress bar instead of a spinner, the drive bar grows in, numbers roll when they
  change, and pages cross-fade.
- The menu bar panel leads with three ring gauges and puts the problem and its fix in one card. Revive apps
  appears only while an app needs it.
- The menu bar shows the color app icon, with an amber or red dot when memory is at risk and a mint dot when
  an update is ready.

### Updates

- BlitzClean checks for updates every time it opens, as well as once a day, and installs them on quit.

### Fixes

- Storage showed the free space from its last scan instead of the free space now.
- Processes outside Apple's system folders were labeled "Part of macOS"; they now show their app and location.
- CPU and disk use the same thresholds everywhere, so the sidebar, Overview, the CPU page and the menu bar
  never color the same reading differently.

## 1.6.0 - 2026-10-24

### Overview

- Overview shows only what is wrong, one card per problem, worst first, each with one button that fixes it:
  Free 32 GB (old iOS simulators, caches and Trash after one confirmation), Close idle apps, See agents, Pause,
  Revive. When nothing is wrong it says so.
- While deleting, the disk card shows each step, the space freed so far and the free space now. Caches read
  "Free up to", since items apps have open or used recently are kept.
- Every removal and stop reports what it measured afterwards, such as "Free disk space went from 12 GB to 26 GB",
  instead of the size it expected to free.
- The delete review is a floating card with a table of what goes, a note on what stays and a red confirm button.

### Revive apps

- Frozen apps are detected without Accessibility permission, from the same flag the Force Quit window uses.
- The list shows regular apps plus any app that is paused or not responding, never a BlitzClean copy, and offers
  Force Quit only on rows with a problem.

### Projects

- Projects groups running work by Git repository: each worktree shows its branch, uncommitted and unpushed
  changes, the agents working in it (Claude Code, Codex, Cursor), its programs such as `node ×4`, its ports and
  its memory, with Stop and agent Pause or Quit. Idle worktrees are listed by branch under their repository.
- An agent card counts every agent session, the memory they hold and how many more fit before macOS starts
  moving memory to disk. A notification warns when a new session starts with no room left.

### Storage

- Delete old iOS simulators now removes every installed copy of that version, waits for the simulator service
  to finish, and reports a version macOS kept instead of claiming success. A deletion started during a scan
  stops the scan instead of being ignored.

### Design

- One neutral icon style replaces the colored squares in the sidebar, page headers, Overview and the tray.
  Charts are drawn in one ink and only turn amber or red when a reading needs attention.
- The drive bar uses muted colors of similar lightness, with a matching dot beside each group.

### Reliability

- Commands that fail, time out or print something unexpected now say "Couldn't read …" with the reason instead
  of looking empty, and nothing is stopped or deleted on a reading that could not be checked.
- Background readers share one schedule that slows down while another app is in front and under memory
  pressure, so BlitzClean adds no load to a Mac that is already swapping.
- Fix a hang when many commands ran at once.
- Git runs with fsmonitor, hooks, the untracked cache and the repository's own clean and smudge filters turned
  off, so a cloned repository's config can't make BlitzClean run a command while it reads branches and changes.
  Filters from your global config, such as Git LFS, keep working. Filters are read from the worktree's own
  config too, status never descends into submodules, and a worktree with submodules is left for you to review.

### BlitzClean Dev

- While the released app runs, the dev build's menu bar item shrinks to its mark and a DEV tag, so the two
  never show the same readings side by side.

## 1.5.0 - 2026-10-18

### Storage

- Open Storage on Drive: the whole disk grouped into units such as Projects, iOS simulators, App data and Caches,
  each with one action or a stated reason it stays. Browse and Cleanup sit beside it.
- Cleanup lists old downloads and screenshots, and large personal files, with Move to Trash and Undo.
- Drive, Browse, Largest files and Cleanup share one disk walker: sizes stay on their volume, hard-linked files
  such as pnpm stores count once everywhere, and folders with unreadable entries show a partial size.
- The unused full inventory scan, with its `du` and Spotlight passes, no longer runs.
- Protected locations (home, standard folders, system and volume roots, Git history) say why they stay.

### Memory and projects

- Emergency controls open with Control–Option–Command–R in a separate process, even while the dashboard is busy.
- Stop project dev servers together with their Docker containers; database volumes are kept, and each container
  gets 120 seconds to shut down.
- Fix a crash on the Memory page when two AI sessions shared an identifier.

### Safety

- Every removal passes one final check: plain absolute path, no linked parent, not a protected root, writable
  volume, and the same file that was reviewed.
- Every signal to a process checks the same PID, start time, executable and owner; Storage's Stop processes
  now does too, so a reused PID is never stopped.
- Commands run with a deadline and an output limit, and stop the processes they started on timeout.
- Unreadable Keep running settings now block stopping and removal instead of turning protection off.
- Emergency controls clear the selection when the selected workload exits, so Stop never acts on another row.

### Reliability

- Cleanup history that cannot be read is moved aside and new removals keep being recorded.
- Agent cleanup reports skip only malformed entries and accept decimal or string numbers.
- Browse resumes measuring after a removal; a stopped first Drive scan is not kept as a result;
  trashed large files no longer return when a scan finishes; Stop and Remove again refresh correctly.
- Recognise Claude Code installed under Application Support, and find session titles for accented folders.
- Docker projects with more than 256 containers work.
- Folder size caches are saved off the main thread.

## 1.4.0 - 2026-10-09

### Revive apps

- Include built-in user apps such as Mail, Terminal, and Safari in the recovery list, with separate rules
  for safe resume and destructive Quit. Core macOS services stay excluded; existing Quit protections remain.
- Bring a responding or resumed app to the front after a single Revive action.

### Dashboard lifecycle

- Keep BlitzClean in the menu bar after the dashboard closes, with no Dock or app-switcher entry.
  Opening the dashboard brings back the Dock entry; opening the tray alone does not.

### Cleanup safety

- Keep Docker inspection and cleanup on a local Unix socket, preserving tagged images and protecting
  changed, active, recent, tracked, and symlinked folders during repeat removal.
- Keep HTTP probes and icons on literal IPv4 or IPv6 loopback addresses, including redirects.
- Separate known Time Machine snapshot warnings from open-file records without ignoring other activity errors.

### Projects

- Add Leftover processes: processes that kept running after the app or terminal that started them closed,
  with RAM, CPU, folder, and uptime. Quit runs at once; Quit all and Force Quit ask first. Each signal checks
  the selected process identity, current folder, and protection rules again. Launchd jobs, apps, macOS services,
  AI sessions, and Keep running projects are never listed.

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
