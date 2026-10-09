# Product design

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
Each row has direct Revive and Force Quit actions; there is no action dropdown. Normal Quit stays in Memory.
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
Settings has "Show Dock icon" (`app.showsDockIcon`, on by default), grouped with Launch at login in one card.
When off, the dashboard opens in accessory mode and the app stays menu-bar only.

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
