# Product design history

Dated decisions, newest first. Later entries override earlier ones. The current rules are in
[DESIGN.md](DESIGN.md); read this file only to learn why a rule exists.

## October 24 confirmation card

The user found the bottom confirmation bar "super ugly": an edge-to-edge strip with a plain text list, a clipped
scroll area and a small tinted Delete. It is now a floating card with a table of what goes, a note on what stays
and a solid red confirm button.

## October 24 Overview as problems with one button each

The user still could not tell what to do on Overview, even after a vitals strip and a ranked list, and asked for
something simpler. Overview now shows only problems, one card each, worst first (`OverviewProblems.order`):
the problem in plain words ("Your disk is almost full"), one sentence on why it matters and what the button
does, one large button with the amount ("Free 32 GB", "Close idle · 9 GB", "See agents"), a quiet line naming
what it deletes or closes, and at most a few quiet links for things that need a look first. Only the first
card's button is mint. While deleting, the disk card swaps its button for a progress bar naming the item being deleted
("Deleting iOS 18.4 · 1 of 7"), the space freed so far and the free space now. Caches keep open and recently
used items, so their button reads "Free up to N". iOS downloads the simulator service no longer lists are
protected by macOS and can only be removed by registering them again, which macOS refuses below roughly 10 GB
more free space; they are left out of Free and named in the card instead. Free N GB deletes old iOS simulators, caches and the Trash together after one inline
confirmation; personal files are never part of it. When nothing is wrong, one card says so. Numbers live in the
sidebar and on each page; Overview has no vitals strip, tiles or Quick wins. The deep checkup is a quiet
"Run a full checkup" link until it runs. The agent budget has no room while memory pressure is warning or worse,
since free memory overstates room during swapping.

## October 24 calmer color, repositories and agents

The user found the interface too colorful and inconsistent, and the Mac crashed twice after six Claude Code
sessions ran at once. Inspiration came from Linear, hilos, Railway and Render on Mobbin: monochrome navigation,
one accent, and color only for state. `BlitzIconTile` (neutral fill and glyph, tinted only for warning or
critical, mint glyph for good) replaces `BlitzColorTile` everywhere; the sidebar shows plain outline glyphs
that fill when selected, and its captions stay gray with the status dot carrying severity. Charts use
`BlitzPalette.data` and `BlitzPalette.ink(tone)`; per-resource identity colors are gone, superseding the
October 18 squircle and identity-color rules. The drive bar keeps categorical colors, muted to one lightness,
with a dot beside each group title; Trash and system data are gray.

Projects leads with an agent card (sessions per tool, their memory, room for more with 4 GB kept free) and then
Repositories: one card per Git repository, one row per worktree with work in it (branch in monospace, changed
and ahead/behind counts, agents and programs, ports, memory, Stop and a menu with agent Pause/Quit), and the
idle worktrees folded into one line that expands. Folders outside Git stay under Other running folders.

Revive apps reads the WindowServer's own not-responding flag (`WindowServerHangProbe`, the signal behind the
Force Quit window), which needs no permission; the Accessibility window probe is a second signal when granted.
The list shows regular apps, plus any background app while it is paused or not responding, and never a copy
of BlitzClean.

## October 18 stable layouts

The user asked for no layout shifts or disappearing items. A rescan keeps the last complete Drive breakdown and
worktree list on screen and swaps the result in once; live partial results appear only on the very first scan.
Groups and rows keep the order of the last complete scan, and a row emptied by a deletion stays in place with its
action disabled. Controls that change state keep a fixed width, and spinners occupy a reserved slot. Pages no
longer repeat the capacity bottleneck in a banner; the sidebar caption and the Overview header carry it.

## October 18 buttons

The user disliked flat gray buttons and the generic "Do it" label. Accent buttons use a mint gradient with a
top highlight and a soft glow; secondary buttons are raised (light top edge, hairline border, drop shadow);
destructive secondary buttons are tinted red. Labels name the action and carry its glyph through
`BlitzActionLabel` (Stop, Pause, Delete, Review…); never use vague labels such as "Do it" or "OK".

## October 18 tray and Projects follow the new language

The tray drops the rings and alert banner: a header with a status dot, one issue row when capacity is at risk,
Resources (Memory, CPU, Storage rows with their squircle, value and bar or sparkline, each opening its page), one
Suggested fix the tray can run directly (pause a runaway task, stop the largest idle item), and the three largest
memory users with Stop or Quit on hover. Emergency controls moved to a footer icon button with its shortcut in the
tooltip; Open BlitzClean is the accent only when no fix is suggested.

Projects show the project's own logo: an app it builds (matched by name in Applications or its dist folder), then
apple-touch, app and asset-catalog icons, then logos and favicons anywhere in the repository or its monorepo apps,
skipping dependencies, build output and fixtures; wordmarks are skipped. Framework badges remain the fallback.
Terminal workloads on Memory, CPU and the tray use the same logo. Each running project states what Stop ends, the
memory those processes hold, and that code, files and database volumes stay. Listening ports are localhost links.
Revive rows for helper binaries such as chrome-headless-shell name their origin: the tool that installed them
(Remotion, Puppeteer, Playwright), the project, the launcher, uptime, and whether the launcher already exited;
hovering shows the parent chain.

## October 18 Apple and Linear visual language

The user found the interface ugly and asked for visuals, icons and an Apple/Linear feel. The app now uses
System Settings–style colored squircles (`BlitzColorTile`) in the sidebar, page headers, Drive groups and Quick
wins; each resource keeps one identity color (Storage blue, Memory purple, CPU orange) for its icon and chart.
Cards share one surface (`blitzCard`: panel fill, hairline border, 12-point corners) with no tinted washes or glows.
Large figures use the rounded face. Group labels are small uppercase text. One mint button per view at most marks
the recommended fix; tile and row actions are secondary. This supersedes the mint-only chart rule and the earlier
"dark utility" restraint on color, and replaces the October 12 Overview: a status header, three resource tiles
(value, bar or sparkline, what drives it, one action) and a Quick wins list that acts directly, with the original
checkup below as Deep checkup. The Overview rings the user rejected stay out; bars and sparklines replace them.

Everything that shows storage can be clicked: a Drive bar segment or legend entry scrolls to its group, and a row
opens its folder in Browse, where Delete permanently is available. Browse may delete app-managed data the user
picks (Codex, Claude, app support folders) after a warning; macOS, Git history, credentials, app bundles and
top-level Library folders stay protected, and automatic lists keep the stricter rule. Git worktrees from project
folders and Codex/Claude sessions are listed on Drive and Overview; merged ones are removed through Git, and ones
blocked only by local files can be removed anyway after a warning that the branch and its commits stay.

## October 18 actionable Memory and CPU

The user found Memory and CPU informative but not useful. Both pages now open with a verdict card: one state
title that matches the sidebar (Memory uses the same pressure assessment), the numbers that explain it, and one
recommended fix with its button (stop the largest idle item, or pause a runaway task). Below it, one ranked list
replaces the separate AI and Apps sections: each row is a consumer the user recognizes (an AI session, an app with
its helpers, a terminal tool grouped by program and project such as `node · fmx_ws`, or macOS services) with one
primary action and a menu. Memory rows stop or quit; CPU rows pause, since pausing frees the CPU at once and keeps
state. Every row also offers Run in background (Darwin background priority, reversible), Force Quit with
confirmation, and Show in Finder. Consumers are tracked across refreshes and relaunches: no CPU for 30 minutes earns
an Idle badge, sustained 80% CPU for 5 minutes earns a Busy badge. Free N GB stops every idle item after an inline
review. macOS daemons get plain names and no buttons. History spike rows offer Stop or Pause while that program
still runs. This supersedes the Suspend-others header action.

## October 18 Drive breakdown and permanent delete

The user could not see what filled the main drive, could not delete folders, and did not want to review
simulators or caches file by file. Storage now opens on Drive (replacing Inventory): one bar for the whole
Macintosh HD, then groups (your files, projects, caches, simulators, AI tools, Docker, apps, messages, app data,
Trash, macOS and system) whose units are logical things such as "Simulator devices" or "App caches", never files.
Groups plus macOS, swap and unreadable System Data add up to used space. The scan stays on the Data volume, so
mounted iPhones (DeviceFS), simulator runtime images and disk images are never counted; folder measuring in
Browse and Cleanup now also stops at mount points.
Each unit has one action matching its consequence: Delete (permanent, for rebuildable data; open and recently used
items are kept), Delete all for caches, Empty Trash, Delete devices through `simctl` (running ones shut down
first), Delete per iOS simulator version (`simctl runtime delete`, or an administrator prompt for versions Xcode no
longer lists), Move to Trash for apps,
Review for project caches and Docker, and Browse for personal folders. Data an owning app manages (Messages, Mail,
WhatsApp, Claude, Codex history) is shown with where to remove it, not deleted here. Every removal is confirmed
inline with its size and written to the removal log. Browse adds Delete permanently beside Move to Trash and allows
selecting rebuildable caches.

## October 12 sidebar insights, simpler Overview, large personal files

The user asked for a sidebar that shows what is slow and what needs attention, rejected the Overview rings
("the rounded thing") and asked for a simpler Overview. Each sidebar page now has one live caption: the limiting
resource on Overview, free RAM and its top app, CPU load and its top app, free disk, apps not responding, and
running projects or leftovers. Warning and critical captions take their tone color and a dot; this replaces the
Revive apps count badge. Overview drops the rings and the resource strip, since the sidebar now owns those values,
and shows one headline, one line, Check my Mac and a progress bar while checks run. The tray keeps its rings.

The user could not find big videos, images or folders to remove. Storage Cleanup adds Large personal files after
old files: files over 50 MB and top-level Downloads, Desktop and Movies folders over 300 MB, filtered by type.
Git working trees and apps are excluded. Each row has Move to Trash, with Undo, after an identity and open-file check.
Search every drive links to Browse → Largest files, which still owns the all-drive ranking.

## October 12 old files and spike causes

The user could not tell what to delete or what caused CPU and RAM spikes, and asked to remove old downloads in one click.
Storage Cleanup now opens with Old downloads and screenshots: top-level Downloads items and screenshots unused for
3 months, 6 months (default) or 1 year. Added, changed (anywhere inside a folder) and last-opened dates all count as use.
Move N to Trash is a single click without `BlitzConfirmation`, an exception to the bulk-review rule at the user's request:
items go to the Trash, each is rechecked for identity, age and open files first, and Undo puts the batch back.
Rows have Keep as their action; kept items persist and collapse to one caption line with Show again.
Overview's check gains Old files and links its finding to this section; it never moves files from Overview.

CPU and Memory show the biggest users for the chart's selected range below the chart. Each sample stores the top app
by CPU and by RAM; helpers count toward their app, and command-line tools are split by repository (node · project).
The seven-day archive keeps each five-minute bucket's peak and its cause rather than the last reading.

## October 9 storage ownership and cleanup

Storage rows show the owning app icon when known, including installed apps that are not running.
Codex history, Claude VM data, Docker disks, Git history and system data are kept out of raw file deletion.
Rows explain whether data is rebuildable, app-managed or needs personal review; size alone is never a safe-delete claim.
Inventory offers direct review of checked rebuildable data and links other managed data to its cleanup flow.
Inventory includes on-demand drive and folder scans. External scans are bounded and report partial results.
The capacity display follows the selected external drive. Personal files retain the reviewed Trash flow.

## October 9 resource recovery

The user needs controls when memory pressure makes the dashboard unusable.
Emergency controls therefore run in a separate process with a small native AppKit panel and a global
Control–Option–Command–R shortcut, available from the tray and Tools menu.
This is an intentional exception to the single-dashboard rule and SwiftUI component rules below:
the recovery path must not depend on that dashboard's main thread, scans, or view graph.
The panel uses one selection, Stop and a secondary action menu, with confirmation text inline.
The user rejected the initial grey utility styling: the fallback shares BlitzClean's canvas,
panel surfaces, mint action, type sizes and rounded controls. Normal work stays in Memory and Projects.
Shared Codex app actions require confirmation and explicitly affect all chats.

Memory rows make Stop primary while running and Resume primary while paused.
The October 9 paused-Codex report exposed an unconditional Stop button; paused rows keep Stop in the menu.
Running rows keep Suspend in the menu.
Suspend keeps memory; Stop ends local work. Worker groups must not claim to cancel remote Codex turns.
Projects include Docker-only workloads, with manual association for unlabeled containers.
Project Stop preserves database volumes and reports incomplete shutdowns instead of forcing termination.
Docker cleanup shows eligible dangling images and build cache, separately from Docker's broader estimates.
These decisions supersede earlier Pause-first and single-window instructions for these controls.

## User requirements

The September 26, 2026 redesign brief asks for Apple/Linear-level restraint,
a consistent interface, less repetition, and at most two visible actions per row.
The process follows [Vercel's product-design guidance](https://vercel.com/blog/teaching-agents-product-design-at-vercel):
resolve the user's task, use shared components, preserve consequential states, and inspect the rendered result.

## Shared patterns

- Use `BlitzPageHeader` for one page title. Put at most two actions beside it.
- A data row has one primary action and, when necessary, `BlitzActionMenu` for secondary actions.
  A selection checkbox also counts as an interaction; selection rows use at most one other control.
- Use `blitzRow` inside one `blitzTable` for a list. Use `panelCard` for a distinct summary or result.
- Use `BlitzUI` and `BlitzType` for surfaces, text, accent, and spacing. They mirror BlitzRecorder's
  `BlitzUI`/`BlitzType`: a dark-only near-black canvas, 0.105 panel surfaces, white-opacity fills and text tiers,
  and the bright mint accent with dark text. Green identifies actions and charts; warning and destructive states
  keep their semantic colors.
- Buttons use `BlitzButtonStyle` (`.accent`, `.emphasized`, `.secondary`, `.quiet`) with BlitzRecorder's
  control metrics: 8-point radius; 24/28/34/40-point heights for mini/small/regular/large.
  Toggles use `BlitzSwitchStyle` (38 × 22 track) or `BlitzCheckboxStyle` (18-point square), never native styles.
  Status uses `BlitzStatusBadge` or `BlitzStatusDot` with a `BlitzStatusTone`; do not draw custom pills.
- The window has a hidden titlebar. `BlitzSidebar` sits on the panel surface with a 52-point drag area for the
  window controls; destinations use quiet/secondary buttons, a filled symbol when selected, and ⌘1 to ⌘6.
  Use `BlitzSegmentedPicker` for value choices and filters; the user dislikes dropdowns in settings and storage.
  History ranges use direct segmented choices. Secondary action menus have 36-point rows and
  `blitzDropdownHost` draws them inside the current window without opening an NSMenu or popover window.
  Titled menus align with the left of their trigger; row action menus align to the right.
  Menu actions dismiss after activation, never via a competing container tap gesture.
  Navigation choices are not action buttons; keep category navigation separate from actions.
- Align values on the trailing edge with monospaced digits. App and file names truncate before values or actions.
- Keep a control's label stable while it runs. Show progress beside it and disable conflicting actions.
- Permissions (Notifications, Accessibility, Full Disk Access) are requested only from Settings → Finish setup,
  which lists the missing ones and disappears when all are granted; the Settings sidebar item badges the count.
  Pages never show their own permission prompts. Individual rows show their measured state.
- Use the action's actual consequence: Quit selected apps, Force Quit, Move to Trash, Delete selected caches.
  Single-app Quit, single-thread Quit, and single-project Stop run immediately, per the October 2 request.
  Keep identity checks and native save dialogs; confirm Force Quit, bulk termination, and file removal inline.
- Keep advanced file controls in Filters and Media tools. Preserve their selection and filter state.
- Keep all app sections in the single `dashboard` window. Sidebar navigation remains visible during recovery,
  project work, settings, and storage tasks. Tray actions, notifications, and legacy launch flags route there too.
- Storage opens directly into Browse, followed by Inventory and Cleanup. The separate Files tab was removed.
  Cleanup and inventory sections are always open in one scrolling list, with no collapse chevrons or
  disclosure groups; long lists cap their rows and offer Show all. Never add another tab bar inside a storage view.
  Browse owns drives, directory navigation, largest files and media review; Inventory owns category sizes; Cleanup owns rebuildable data.
- Open filters, project setup, and media export inline. Use `BlitzConfirmation` for an inline destructive review;
  use it for irreversible and bulk actions, not routine individual Quit/Stop. System choosers and permissions stay native.
- Use real app icons for processes and app-owned data when available; use a neutral fallback for unknown tools.
- Define each feature once. A second entry point may link to the owner (an Overview suggestion row) but never
  re-render its list or controls.
- Badges report exceptions only: Not responding, Detached, Paused, Not back, Revived. Normal states (Running, Normal,
  Shutdown, Not checked) get no badge. No "needs attention" labels, no live/status pills in headers, and no header
  subtitle that repeats a section count. Empty states are one line of text, with no icon, title, or blurb.

## Implementation decisions

The redesign replaces the storage dial with a capacity bar and explicit free/used values.
The sidebar has six pages (Overview, Memory, CPU, Storage, Revive apps, Projects) plus Settings. Pages removed in
1.0.12 and where they went: AI workers and Processes into Memory (AI threads) and CPU, History into Memory's
pressure section, Worktrees and Developer storage into Storage Cleanup, Project folders into Settings. Saved page
names from older versions redirect through `CleanPage.restored`. The tray gear menu has Settings and Stop monitoring and quit.
Overview shows storage, memory, CPU, then the AI sessions using the most RAM. Pause (SIGSTOP) and
Resume (SIGCONT) are direct row actions. Quit and Force Quit are in the secondary menu.
A header action pauses every thread except the largest. Suggestion rows only appear when something else
is actionable: stopped or frozen apps, and folders that grew back.
Recovery lists Stopped or frozen apps first, Running apps next, and Quit or crashed apps last. Each row shows its own
live status and owns its action, so a revive never waits for the full scan. Process state is read first, so stopped
apps and the bulk Revive action appear before window checks finish. A revive reports a definite result: Revived,
Not responding, Still stopped, Quit, or Crashed (confirmed by a macOS crash
report written after the attempt). Recent app crashes from DiagnosticReports stay listed with Reopen until dismissed.
Revive remains available for every eligible running app, including apps with no health result yet.
Built-in user apps such as Mail, Terminal, and Safari are included. Resume eligibility is separate from Quit
eligibility: protected built-in apps have Revive, while Force Quit stays disabled. Core macOS services remain hidden.
A successful single-app Revive brings that app to the front; bulk revive keeps the dashboard visible.
Each row has a direct Revive action; Force Quit appears only on rows that are stopped or not responding, and there is no action dropdown. Normal Quit stays in Memory.
A responsive window returns an explicit result instead of silently removing the Revive action.
The sidebar badge counts stopped and unresponsive apps from background process-state reads.
Memory lists AI threads before apps, with a persistent search field above the scroll area. An AI thread is one agent session (Claude Code, Codex CLI, Cursor agent, or a
Codex desktop thread grouped by launch time) with its tool servers, ranked by RAM. Its row has direct Pause/Resume; Quit (SIGTERM) lives in its menu.
Pause keeps the RAM. Force Quit (SIGKILL) stays in the menu. A thread whose root was reparented to launchd without
a terminal is marked Detached, and the section header offers to quit all detached threads. Each app row has Quit
as its primary action and Force Quit in its menu. An explicit Quit skips suggestion-only guards (active, pinned,
AI app) and still re-checks the process identity; macOS system apps and BlitzClean keep a lock instead of Quit.
Storage Cleanup includes Removed before: every folder removed earlier that tools rebuild (build output,
dependencies, shared caches), its current size, and Remove again. Cleanup reports written by agents to
`~/Library/Application Support/BlitzClean/reports/` are imported into the same history. The Removal log closes
the page with every recorded removal.
History ranges are direct segmented choices. Folder navigation uses visible drive and Home buttons,
breadcrumbs and back/forward buttons. Secondary actions alone use menus.

These decisions implement this brief; a later user request can change them.
Record the reason beside a changed pattern instead of adding another competing component.

## Verification

Inspect the changed surface at compact and standard window sizes.
Check loading, empty search, populated rows, long names, large values, menu actions, and disabled states.
`BLITZCLEAN_DESIGN_DIR=/tmp/shots swift test --filter DesignRenderTests` hosts the dashboard in an offscreen
window and writes Overview, Revive apps, Memory, and Settings screenshots with scripted recovery states.
Verify the installed app too, because offscreen rendering can omit native controls and composited layers.
A successful build does not count as visual acceptance.

## October 2 pressure prevention

Overview now leads with the limiting resource and a clear instruction to avoid new threads/builds under pressure.
A missing desktop-notification permission appears inline with Enable alerts. A compact Running projects row links
into Projects, which owns searchable project groups, aggregate memory/CPU, child-process counts and Pause/Resume.
Projects distinguish active background workers from saved inactive projects without requiring a listening port.
The row menu owns per-project automatic-pause consent, Keep running and Stop servers; no extra window is opened.

## October 2 immediate actions and drive browsing

Applies [UI Skills Baseline UI](https://www.ui-skills.com/skills/baseline-ui) to the existing native controls:
strong hierarchy, monospaced values, stable labels, larger hit targets, and errors beside the action.
The user explicitly asked to skip routine confirmations. Quit and Stop are single clicks; Force Quit and bulk
termination still use inline confirmation. Apps appear ahead of AI threads in Memory. Search stays visible on
Memory, Revive apps, and Projects. Project Stop includes eligible background runtimes and handles paused workers.

Browse opens on all mounted local drives, with drive cards, same-page directory navigation, and largest files
across the selected roots. Hidden files, app packages, and dependency trees are visible. Directory listing is
separate from recursive file ranking, so navigation does not wait for folder-size subprocesses. A streaming
scan shows file count, elapsed time, and unreadable paths. Results are capped at the largest 5,000, not the first
5,000 encountered; rows are paged. Cancellation keeps current results. Browse adds no nested tabs or windows.

Browse defaults to the directory browser. A folder's full row and its arrow are a single Button, opened in one
click. Files and folders have selection checkboxes and an inline Move to Trash review; files can be revealed in
Finder. Visible drive buttons switch locations, and breadcrumbs navigate parents. Largest files across all drives
is a secondary action within Browse and has no tab of its own. Inventory links route into this same browser.
Folder listings run off the main actor, then one native scan fills in child-directory sizes. Partial folder totals
use a lower-bound indicator. Navigating away cancels the previous traversal. Closed dropdown hosts do not hit-test.

## October 2 interaction simplification

The user rejected the dropdowns and click behavior. Drive and Home navigation, hidden-file visibility,
refresh, sorting and select-all are now direct controls. Each directory row has a full-height 52-point
button covering its name, size and arrow, with hover and pressed feedback. Navigation supports bounded
back/forward history. Checkboxes have at least 34-point hit targets. History range choices are visible
segments. Secondary action menus use quieter shadows, consistent spacing, left alignment for titled
triggers, and action-driven dismissal; disabled items cannot dismiss a menu or invoke an action.

The unlabeled back/forward/up arrow cluster was rejected. Back and Forward now have text labels;
Forward appears only when there is forward history. Parent navigation uses named breadcrumbs.
Navigation never opens Finder; Show in Finder is an explicit secondary action.

The browser groups folders before files, preserving size ordering within each group. Clicking a file
selects it or shows its path inline without opening Finder.
Home-folder files and user-created folders can be selected; core home folders and credential roots stay protected.

Directory rows show proportional size bars against the largest item in the folder. Returning to a folder
restores its saved listing immediately, including interrupted measurements. Refresh keeps prior sizes and
bars until the new traversal finishes; a saved estimate uses ~ and a measured minimum uses ≥.
Completed listings are reused for five minutes. Older or interrupted listings refresh in the background.
The last 60 listings persist across app relaunch. Identity checks prevent replaced folders inheriting old sizes,
and unavailable folders retain their saved listing with an inline explanation.

## October 2 live app recovery

Revive uses the current macOS app roster, independent of the slower memory scan. Launch/exit notifications
refresh it immediately and a two-second loop reads process states while the screen is open. Window checks
expire after two seconds, run at bounded concurrency, and never disable a manual Revive. Rows stay sorted
by app name within their status group. A new health observation supersedes an old recovery outcome.
Repeated Stop/Revive cycles are allowed without an arbitrary ten-second lock. Window messages time out
after half a second, with two observations before reporting a frozen window; recovery verification has a
three-second budget. A resumed process is distinguished from a confirmed responsive window. Crash-report
lookups run at most every 30 seconds. Force Quit keeps the inline unsaved-work confirmation.

## October 3 AI session identity and direct pause

Pause/Resume is the primary action in both Overview and Memory, with Quit and Force Quit in the row menu.
Memory puts AI sessions immediately after its summary so the controls are easy to find.
Rows show a verified local session title when available, then provider, project, delegated providers, terminal
host and process ID. Search includes those identities. Claude launching Codex remains a Claude session
labeled "includes Codex CLI"; cmux is the terminal host, never the AI provider.

Claude PID metadata must match the process start time. Codex CLI titles require an explicit session ID or
a single open rollout file. Cursor titles require an explicit session ID matching local metadata.
Shared Codex desktop children remain launch-time worker groups, labeled Codex workers; the app does not
guess individual chat titles from their folder or launch time. Pause affects local processes only; cloud
generation can continue. No conversation bodies or encrypted message blobs are inspected for naming.

## October 3 direct file ranking and simulator devices

Browse keeps its initial directory default and remembers the last chosen folders/largest-files mode across relaunch.
Largest files is a prominent action; file results follow a compact drive-scope header without a duplicate directory list.
Process and AI-session snapshots refresh every two seconds in the foreground, with non-overlapping scans and slower
background polling. Large-file rows use the shared icon cache.

Cleanup starts with Simulated devices, loaded independently of the slower storage inventory.
A booted device has Shut down; a shutdown device has Delete device with inline permanent-removal review.
Deletion uses Apple's simulator service for the exact current device identity, verifies disappearance, and records
the removal. Installed iOS runtimes stay available. Managed simulator directories link here with Manage devices;
generic Trash is unavailable for those directories and their contents.

## October 3 resident menu bar monitor

The dashboard and monitoring have separate close actions, per the user's request.
The red window button, Command-W, Command-Q, and Dock Quit close the dashboard while the monitor stays resident.
The app menu calls Command-Q Close dashboard. Only the tray gear menu offers Stop monitoring and quit.
System logout, restart, and shutdown remain normal termination paths; no relaunch loop or quit confirmation is added.

The October 7 request makes Dock and app-switcher presence follow the dashboard lifecycle.
Launch starts as a menu-bar accessory. Opening the dashboard switches to a regular app; closing it restores
accessory mode. Opening the tray alone never adds a Dock entry. A minimized dashboard remains open.

Settings uses direct segments for the RAM value: Available GB, Used GB, or Used %.
Available memory is the default, labeled free in the menu bar; used bytes are explicitly labeled used.
The tray card follows the same saved choice, and unavailable readings use a dash.
CPU remains a utilization percentage. Available RAM includes reclaimable memory, as described in the control's help.

## October 6 tray and dashboard polish

Applies [UI Skills](https://www.ui-skills.com/) baseline-ui and better-ui: one accent per view, tabular values,
exceptions only, errors beside the action, and nested radii that match their padding.
The tray is a 340-point panel: header with the gear menu, a pressure alert only when `PressureAssessment.risk`
is above normal, a Memory tile (saved RAM display, 60-second plot, pressure badge only at warning or critical),
CPU and Storage tiles, the three apps using the most memory (rows link to Memory without controls), and a footer
with Revive apps (attention count) and Open dashboard. Every tile opens its page.
`PressureAssessment.limit` names the limiting resource; disk alerts lead to Storage Cleanup with disk advice,
memory and CPU alerts lead to Projects. The Overview banner is tinted by severity when actionable and a single
status line otherwise. Storage location choices use `BlitzChip` inside `blitzChipGroup`; both Browse modes
share one toolbar row with chips on the left and the mode switch on the right, and every Storage surface uses
`BlitzUI.pagePadding`. Status text for a scan stays on one caption line.

## October 6 shared components and permissions

Shared views live in `BlitzComponents.swift`: `BlitzSectionHeader`, `BlitzEmptyRow`, `BlitzShowAllButton`,
`BlitzStatusLine`, `BlitzTrailingValue`, `BlitzCountBadge`, `AppRowIdentity`, `PageSearchBar`, `MenuCheckLabel`,
`StorageActionBar`, and the `Finder`/`Pasteboard` helpers. Row buttons use `BlitzRowButtonStyle`; whole cards use
`BlitzCardButtonStyle` with `BlitzChevron`; alerts use `blitzToneCard`. Add to these before writing a new variant.
Views derive filtered/sorted lists once per render and pass them down; app icons go through `ApplicationIcon`.
`PermissionsModel` probes Full Disk Access; permission state refreshes whenever BlitzClean becomes active.
Storage Cleanup has one page-level Scan again; sections do not carry their own refresh buttons.

## October 6 one-click cleanup

At the user's request, Overview owns a Quick clean summary with a direct Clean action for the known,
rebuildable cache allowlist. This explicit action replaces the extra confirmation for this narrow batch only;
the consequence is visible beside it. Storage Cleanup keeps item selection and its existing inline review.
Both entry points share one model, activity checks, deletion checks, progress, and removal history.
Overview scans on first appearance. Scan again refreshes the estimate; Details opens Storage Cleanup.
Caches now lead Storage Cleanup so this link lands at the relevant section. Skipped locations and cleanup
results remain visible even when no candidates remain; simulated devices follow caches.
The mint orbit runs only while work is active, honors Reduce Motion, and becomes a check after real removals.
Progress counts checked candidates. Removed cache bytes and observed free-space changes remain separate.

## October 6 process memory and System Data

Launch feedback requested individual process RAM and System Data cleanup. Memory now has an Apps & AI /
Processes choice below its summary, using the existing live resource snapshot rather than a second polling loop.
Process rows show a single PID's footprint, owner, and unavailable readings explicitly; search includes PIDs.
Storage Cleanup starts with System Data cleanup, replacing the narrower Caches heading. This section owns
selection, review, retention rules, and skipped-item explanations for browser/developer caches and old diagnostic
reports. Overview's direct Clean action excludes reports. Its Details link leads to this section.
Inventory labels the shared-folder scan System folders to avoid presenting it as Apple's System Data total.

## October 6 cleanup overview correction

The user rejected the prominent 0 B cache card because it hid available Docker and project cleanup.
Overview now summarizes eligible caches, diagnostic reports, project data, regrown folders, shutdown simulators,
and Docker images/build cache, using the existing scanners. Overlapping filesystem paths count once; a pnpm
store's full size is excluded because pruning cannot reclaim it all. Values are estimates for review, not a promise
of freed space. Review cleanup opens the existing Storage flow. One-click Clean caches names its narrower size.
An empty result is a compact sentence with Scan again; skipped/unavailable locations retain a Details link.
No large zero, disabled Clean button, or decorative empty-state animation. Scans start from Overview, with cached
estimates retained and labeled while refreshing. Docker failures do not contribute stale reclaimable bytes.

## October 7 scan responsiveness

Overview and Storage Cleanup request the cleanup scope only: simulator status/cache and project dependencies.
The broad app, Library, system-folder, and Spotlight inventory runs when Inventory is opened or Scan Mac is used.
Its completion timestamp is separate, so a cleanup refresh cannot label old inventory as freshly measured.
Project age reads skip generated tool directories and stop at a time/entry budget. A partial read is Unknown,
never an old date; age-based recommendations exclude it. Cached category results stay visible during refresh.

## October 7 audit and action dashboard

The user approved replacing the Overview stack with one audit-and-action flow. Check my Mac starts five
independent checks: resources, eligible caches, project data and regrown folders, Docker, and app responsiveness.
The dashboard no longer starts expensive storage work merely by opening. Findings appear as their checks finish;
a check still running never inherits a previous run's findings. The audit survives sidebar navigation.

Show three ranked findings by default, with Show all for the rest. Resource pressure and stopped/frozen apps
lead, followed by eligible caches, detached AI sessions, Docker, project data, simulators, and diagnostic reports.
Only Clean [size] removes anything from Overview, using the existing cache allowlist and deletion revalidation.
Other actions open the owning page; storage actions jump directly to the matching section.

After cleanup, keep actual removed bytes, skipped reasons, and measured free-space change visible while fresh
checks run. The empty result is compact text; partial checks disclose their limits and never report an all-clear.
Check details contains the per-check outcomes and reasons. The last-checked time changes only after all checks
finish. One compact resource strip links to Storage, Memory, and CPU; detailed charts and process lists stay in
their sidebar pages. Progress is driven by completed checks/items and respects Reduce Motion.

## October 7 audit latency and ready actions

Eligible cache actions become available as soon as their own check finishes, while project checks continue.
Conflicting mutations stay disabled; every removal still performs the existing fresh activity and identity checks.
A successful cleanup queues one fresh audit if a check is still running, preserving the actual cleanup result.

Project and removal-history scans share measurements only within one audit, with at most four folder readers.
New audit measurements share a twenty-second traversal budget. A timed-out folder contributes no guessed or
partial size; Check details discloses unfinished folders, and Storage offers a deeper scan. Filesystem calls
already in progress may overrun the budget. Full scans started separately retain their own lifetime.
The pnpm store's full size is not a reclaimable estimate, so its separate measurement runs in detailed cleanup.
Opening that detail during an audit queues the full history check; unchecked folders never say Not back.
Docker inspection has a twelve-second deadline, and unavailable Docker never contributes stale cleanup bytes.

## October 7 Overview and tray revamp

The user asked for a more playful, game-like Overview and tray, using [UI Skills](https://www.ui-skills.com/),
Emil Kowalski's motion guidance, Raycast, Shotbase, and DreamCut as references. They rejected eyebrows,
decorative or "AI" icons such as sparkles, and gradients; surfaces use flat fills and no glows.
A later pass removed common AI-generated design tells (from the "Signs of AI design" guide and Adrian Krebs'
list of 16 patterns): violet accents, multicolor icon tiles, stat banner rows, connected step sequences,
colored accent words in headlines, and cards inside cards. Tertiary text rose from 0.38 to 0.46 white for AA contrast.

- `BlitzVitalRings` draws memory, CPU, and storage load as thin concentric rings: mint, then two white
  opacities. Ring colors never change with severity, because two amber rings merged into one shape; warnings
  color the legend value instead. The Overview center shows the busiest resource ("97% storage"); the tray
  center stays empty because its legend sits beside the rings. Rings show measured load only and never a composite score.
  `MacVital` holds each ring's value, compact value, caption, and page. The legend rows open that page.
- The Overview hero puts the rings beside the audit state and Check my Mac. When findings have reclaimable
  space, the headline reads "Up to [size] to reclaim". `AuditRecommendation.reward` carries each estimate.
- After the first check, one status row lists the five checks. They run in parallel, so they have no connecting
  path or numbering: a spinner while running, then a check mark or a warning mark.
- Findings are "Next moves": a neutral category tile (amber or red only for warnings), title, detail, and one action.
- A removal that frees space shows its size large, with a single short particle burst. This is the only
  celebratory motion, honors Reduce Motion, and does not play for unchanged or failed cleanups.
- One caption line below the card gives the last cleanup, space recovered, and cleanup count from the removal log.
- The tray uses the same rings and legend, followed by last-minute memory and CPU plots and the top three
  apps with share-of-RAM bars. Open dashboard is the panel's one accent button.
- Motion: no ring entrance animation (Overview opens many times a day). Value changes ease out over
  0.3 seconds, list changes over 0.22 seconds, and buttons scale to 0.97 when pressed.

## October 7 automatic updates

Settings > Updates shows the update status in one line, a single action (Check for updates, Update to [version],
or Restart to update to [version]) and the automatic-check switch. Builds without a feed say so and link to
GitHub releases. The tray shows the update action beside the gear only when an update is found or downloaded;
otherwise Check for updates lives in the gear menu. Scheduled updates never open a window on their own
(Sparkle's gentle reminders); a check the user starts uses Sparkle's native update window.

## October 7 BlitzReels family

Settings ends with Our other apps: the BlitzReels wordmark beside the heading, then one full-row link per product
(icon, name, one-line description, domain, and an outbound arrow) for BlitzRecorder and BlitzReels. The version,
license, and source link follow as one caption line. The tray gear menu lists the same products under
More from BlitzReels. Links open in the browser; there is no in-app promotion elsewhere.

## October 7 leftover processes

Confirmations retain the process identity from the selected row even when the list refreshes.
Each signal rechecks the current folder and protections. Action feedback stays visible after the last row exits.

Projects adds Leftover processes between Active and Saved projects, shown only when there is one.
The section owns processes whose parent exited, without a project or AI session to own them;
it does not repeat AI sessions, which Memory owns, or projects marked Keep running. Each row has Quit as its
primary action. Force Quit, Show folder in Finder, Copy process ID, and Hide are in its menu.
Quit runs at once, like single-project Stop; Force Quit and the header's Quit all use `BlitzConfirmation`.
Hidden names collapse to one caption line with Show again, following the skipped-permissions pattern.
No badge is added: a leftover is not an exception on a normal row, it is the reason the row exists.

## October 7 skippable permissions

The user asked why the Settings badge kept counting a permission they did not want. Each Finish setup row now
has Not needed (quiet) beside Allow…. A skipped permission leaves the list and the sidebar badge, and the section
shrinks to one caption line, "Not needed: …", with Ask again. Skips persist in `permissions.skipped`;
a permission granted later no longer counts as skipped. Features that need the permission keep their own
inline state, so skipping never hides why something is unavailable.
