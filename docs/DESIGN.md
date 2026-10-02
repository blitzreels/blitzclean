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
  Status uses `BlitzStatusBadge` or `BlitzStatusDot` with a `BlitzStatusTone`, not a custom pill.
- The window has a hidden titlebar. `BlitzSidebar` sits on the panel surface with a 52-point drag area for the
  window controls; destinations use quiet/secondary buttons, a filled symbol when selected, and ⌘1–⌘6.
  Use `BlitzSegmentedPicker` for value choices and filters; the user dislikes dropdowns in settings and storage.
  History ranges use direct segmented choices. Secondary action menus have 36-point rows and
  `blitzDropdownHost` draws them inside the current window without opening an NSMenu or popover window.
  Titled menus align with the left of their trigger; row action menus align to the right.
  Menu actions dismiss after activation, never via a competing container tap gesture.
  Navigation choices are not action buttons; keep category navigation separate from actions.
- Align values on the trailing edge with monospaced digits. App and file names truncate before values or actions.
- Keep a control's label stable while it runs. Show progress beside it and disable conflicting actions.
- Show a shared permission explanation once. Individual rows show their measured state, not copies of the warning.
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
  subtitle that repeats a section count. Empty states are one line of text, not an icon with a title and blurb.

## Implementation decisions

The redesign replaces the storage dial with a capacity bar and explicit free/used values.
The sidebar has six pages (Overview, Memory, CPU, Storage, Revive apps, Projects) plus Settings. Pages removed in
1.0.12 and where they went: AI workers and Processes into Memory (AI threads) and CPU, History into Memory's
pressure section, Worktrees and Developer storage into Storage Cleanup, Project folders into Settings. Saved page
names from older versions redirect through `CleanPage.restored`. The tray gear menu has only Settings and Quit.
Overview shows storage, memory, CPU, then the AI threads using the most RAM. Pause (SIGSTOP) is the
available in the row menu so other threads can finish; it does not free RAM. Quit is the direct row action.
A header action pauses every thread except the largest. Suggestion rows only appear when something else
is actionable: stopped or frozen apps, and folders that grew back.
Recovery lists Stopped or frozen apps first, Running apps next, and Quit or crashed apps last. Each row shows its own
live status and owns its action, so a revive never waits for the full scan. Process state is read first, so stopped
apps and the bulk Revive action appear before window checks finish. A revive reports a definite result: Revived,
Not responding, Still stopped, Quit, or Crashed (confirmed by a macOS crash
report written after the attempt). Recent app crashes from DiagnosticReports stay listed with Reopen until dismissed.
Revive remains available for every eligible running app, including apps with no health result yet.
Each row has direct Revive and Force Quit actions; there is no action dropdown. Normal Quit stays in Memory.
A responsive window returns an explicit result instead of silently removing the Revive action.
The sidebar badge counts stopped and unresponsive apps from background process-state reads.
Memory lists apps before AI threads, with a persistent search field above the scroll area. An AI thread is one agent session (Claude Code, Codex CLI, Cursor agent, or a
Codex desktop thread grouped by launch time) with its tool servers, ranked by RAM. Its row has direct Quit (SIGTERM); Pause (SIGSTOP) and Resume (SIGCONT) live in its menu.
Pause keeps the RAM. Force Quit (SIGKILL) stays in the menu. A thread whose root was reparented to launchd without
a terminal is marked Detached, and the section header offers to quit all detached threads. Each app row has Quit
as its primary action and Force Quit in its menu. An explicit Quit skips suggestion-only guards (active, pinned,
AI app) and still re-checks the process identity; macOS system apps and BlitzClean keep a lock instead of Quit.
Storage Cleanup opens with Removed before: every folder removed earlier that tools rebuild (build output,
dependencies, shared caches), its current size, and Remove again. Cleanup reports written by agents to
`~/Library/Application Support/FreeSpace/reports/` are imported into the same history. The Removal log closes
the page with every recorded removal.
History ranges are direct segmented choices. Folder navigation uses visible drive and Home buttons,
breadcrumbs and back/forward buttons. Secondary actions alone use menus.

These decisions implement this brief; a later user request can change them.
Record the reason beside a changed pattern instead of adding another competing component.

## Verification

Inspect the changed surface at compact and standard window sizes.
Check loading, empty search, populated rows, long names, large values, menu actions, and disabled states.
`FREE_SPACE_DESIGN_DIR=/tmp/shots swift test --filter DesignRenderTests` hosts the dashboard in an offscreen
window and writes Overview, Revive apps, Memory, and Settings screenshots with scripted recovery states.
Verify the installed app too; offscreen rendering can omit native controls and composited layers.
Successful compilation alone is not visual acceptance.

## October 2 pressure prevention

Overview now leads with the limiting resource and a clear instruction to avoid new threads/builds under pressure.
A missing desktop-notification permission appears inline with Enable alerts. A compact Running projects row links
into Projects, which owns searchable project groups, aggregate memory/CPU, child-process counts and Pause/Resume.
Projects distinguish active background workers from saved inactive projects rather than requiring a listening port.
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
5,000 encountered; rows are paged. Cancellation keeps current results. No new nested tabs or windows.

Browse defaults to the directory browser. A folder's full row and its arrow are a single Button, opened in one
click. Files and folders have selection checkboxes and an inline Move to Trash review; files can be revealed in
Finder. Visible drive buttons switch locations, and breadcrumbs navigate parents. Largest files across all drives
is a secondary action within Browse, not a separate tab. Inventory links route into this same browser.
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
selects it or shows its path inline; it never launches Finder implicitly. Show in Finder is explicit.
Home-folder files and user-created folders can be selected; core home folders and credential roots stay protected.

## October 2 live app recovery

Revive uses the current macOS app roster, independent of the slower memory scan. Launch/exit notifications
refresh it immediately and a two-second loop reads process states while the screen is open. Window checks
expire after two seconds, run at bounded concurrency, and never disable a manual Revive. Rows stay sorted
by app name within their status group. A new health observation supersedes an old recovery outcome.
Repeated Stop/Revive cycles are allowed without an arbitrary ten-second lock. Window messages time out
after half a second, with two observations before reporting a frozen window; recovery verification has a
three-second budget. A resumed process is distinguished from a confirmed responsive window. Crash-report
lookups run at most every 30 seconds. Force Quit keeps the inline unsaved-work confirmation.
