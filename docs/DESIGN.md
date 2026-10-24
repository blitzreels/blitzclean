# Design rules

The rules BlitzClean follows today. When a user request changes one, edit the rule here and add a dated entry
explaining why to [DESIGN-HISTORY.md](DESIGN-HISTORY.md). Never leave two rules that disagree.

## Principles

- Say what is wrong and offer the one action that fixes it. Numbers support a decision; they are not the page.
- Promise only what an action will do. Show what it actually did, measured afterwards.
- Calm by default: neutral ink, one mint accent, amber and red only for state that needs attention.
- Define each feature once. Other places link to its owner; they never re-render its list or controls.
- No layout shifts: rescans keep the last result on screen and swap in once; rows keep their order; spinners
  have a reserved slot; controls that change state keep a fixed width.

## Tokens

- Surfaces: one dark canvas (`BlitzUI.canvasBackground`); every card, table and panel uses `blitzSurface()`
  (panel fill, hairline border, 12-point corners). `blitzCard(padding:)` adds padding. Nothing else draws a card.
- Text: `BlitzType` sizes; `BlitzUI.primaryText`, `supportingText`, `secondaryText`, `tertiaryText` tiers.
  Large figures use `BlitzNumberFont` (rounded). Values align trailing with monospaced digits.
- Status: `BlitzStatusTone` is the only status type (`good`, `working`, `warning`, `critical`, `muted`).
  `MemoryRisk.tone` maps memory risk to it; rising memory stays gray.
- Color: `BlitzUI.mint` marks the recommended action and finished fixes; `BlitzUI.warning` and
  `BlitzUI.recordRed` mark warning and critical state. Charts draw in `BlitzPalette.data` and switch to
  `BlitzPalette.ink(tone)` only at warning or critical. The drive bar is the one categorical chart
  (`DriveGroup.color`, muted hues of equal lightness, gray for Trash and system).
- Icons: `BlitzIconTile(symbol:tone:size:)` is the only icon square: neutral fill and glyph, tinted at warning
  or critical, mint glyph for good. Real app icons (`ApplicationIcon`) and project logos (`ProjectIcon`) are
  used where they exist; the sidebar uses plain outline glyphs that fill when selected.

## Components

- Pages: `BlitzPageHeader` with at most two actions. Group labels: `BlitzGroupLabel` or `BlitzSectionHeader`
  with a count.
- Lists: rows (`blitzRow`) inside one `blitzTable`, divided by `BlitzRowDivider`. A row has one primary action
  and, when needed, `BlitzActionMenu` for the rest. Long lists cap and offer `BlitzShowAllButton`.
- Buttons: `BlitzButtonStyle` via `.blitzButton(.accent | .emphasized | .secondary | .quiet)`. One mint
  (`.accent`) button per view at most, on the recommended fix. Labels name the action with its glyph through
  `BlitzActionLabel` (Delete, Stop, Pause, Revive…), never "OK" or "Do it". A running action keeps its label
  and shows progress beside it.
- Controls: `BlitzSegmentedPicker` for choices (no dropdowns in settings or storage), `BlitzSwitchStyle`,
  `BlitzCheckboxStyle`, `BlitzSearchField`. Menus draw inside the window through `blitzDropdownHost`.
- Status: `BlitzStatusDot`, `BlitzStatusBadge`, `BlitzStatusLine`. Badges report exceptions only (Paused,
  Not responding, Detached); normal states get none. Empty states are one line of text.
- Confirmation: `BlitzConfirmation` for irreversible or bulk actions: a floating card (max 560 points wide,
  14-point corners, shadow) at the bottom of the page with the action's icon in red, the items as a table of
  name and size, one note on what stays, Cancel and a solid red confirm button (`.destructive`). Callers write
  "name · size" lines, a blank line, then the note. Single Quit, Stop and Pause run immediately.

## Pages

- **Sidebar**: Overview, Memory, CPU, Storage, Revive apps, Projects (⌘1–⌘6), Settings. Each item has one gray
  caption (free disk, free RAM and its top app…) and a status dot at warning or critical.
- **Overview**: only problems, one card each, worst first (`OverviewProblems.order`). A card states the problem,
  one sentence on why it matters and what the button does, one large button with the amount ("Free up to
  10 GB", "Close idle · 9 GB", "See agents", "Pause", "Revive"), a quiet line naming what it touches and a few
  quiet links for things that need a look first. Free deletes old iOS simulators the simulator service lists,
  caches and the Trash together after one confirmation; personal files are never part of it. While deleting,
  the button becomes a progress bar with the current item, the space freed so far and the free space now. When
  nothing is wrong one card says so. The deep checkup is a quiet link until it runs.
- **Memory / CPU**: a verdict card (state, the numbers that explain it, one recommended fix) above one ranked
  list of things a person recognizes (an AI session, an app with its helpers, `node · project`). Memory rows
  Stop or Quit; CPU rows Pause. Menus hold Run in background, Force Quit (confirmed) and Show in Finder.
- **Storage**: Drive (whole disk by logical groups, each unit with one action matching its consequence),
  Browse (folders and largest files, Move to Trash or Delete permanently) and Cleanup. Data an owning app
  manages is shown with where to remove it. iOS downloads macOS protects are named, not offered.
- **Revive apps**: regular apps plus any app that is paused or not responding; never a BlitzClean copy. Hangs
  come from the WindowServer flag (`WindowServerHangProbe`), with the Accessibility probe as a second signal.
  Each row has Revive; Force Quit appears only on rows with a problem.
- **Projects**: an agent card (sessions per tool, memory held, room for more; no room while memory is at warning
  or worse), then Repositories (one card per Git repository, one row per active worktree with branch, changes,
  agents, programs, ports, memory, Stop and agent Pause/Quit; idle worktrees folded), Other running folders,
  Leftover processes and Saved projects.
- **Tray**: header with status dot, one issue row when capacity is at risk, Memory/CPU/Storage rows, one
  suggested fix it can run, the three largest memory users. The dev build shows only its mark and DEV while the
  released app runs.

## Safety

- Every removal passes `RemovalGate`; every signal re-checks the process identity. Failure to read state means
  do nothing and say why.
- Caches and rebuildable data may be deleted after one confirmation; personal files go to the Trash with Undo.
- Permissions are requested only from Settings → Finish setup.

## Verification

Inspect changed screens in the installed app (`./script/build_and_run.sh`), at compact and standard sizes, with
loading, empty, long-name and busy states. `BLITZCLEAN_DESIGN_DIR=<dir> swift test --filter DesignRenderTests`
writes offscreen screenshots. A successful build is not visual acceptance.
