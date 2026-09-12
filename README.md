<p align="center"><img src="assets/brand/app-icon.png" width="112" alt="BlitzClean icon"></p>
<h1 align="center">BlitzClean</h1>
<p align="center">A little breathing room for your Mac.</p>
<p align="center">By <a href="https://blitzreels.com">BlitzReels</a> · Native SwiftUI · macOS 14+ · MIT</p>

BlitzClean puts CPU, RAM, and disk space in your menu bar, with a dashboard for taking action.
See what is using your resources, quit the apps you choose, and review files you can remove.
Everything runs locally. No account, subscription, telemetry SDK, or cloud inference.
The dark interface and mint-green controls share the BlitzReels / BlitzRecorder design system.

## What it does

- **Readable menu bar:** labeled CPU and RAM percentages, free disk space, pressure colors,
  and a compact panel with graphs and direct actions. Choose which metrics appear.
- **Live monitoring:** CPU and RAM readings every two seconds; one, five, and fifteen-minute
  graphs; compressed memory, wired memory, swap, and memory pressure.
- **CPU activity:** process CPU measured between samples, ranked by current use.
  System CPU is normalized across all cores; a process can exceed 100% when it uses multiple cores.
- **Free RAM:** select apps, review their footprint, send normal quit requests, and measure
  the change in available RAM. Save dialogs are respected. Apps stay closed.
- **Cache cleanup:** review older npm, Homebrew, pip, Yarn, and Xcode caches.
  Each item explains how it is recreated. Deletion requires confirmation and fresh safety checks.
- **Large files:** review Downloads, Desktop, Movies, Documents, and temporary files above 256 MiB.
  Choose another folder or lower the threshold to 100 MiB. Slow scans stop after 20 seconds;
  cancel at any time to change folders.
  Reveal them in Finder or move them to Trash. You decide which personal files you need.
- **Developer tools:** existing project controls, AI-worker ownership, worktree and dependency
  review, Docker storage, folder exploration, and local incident history.

## Install from source

Requires macOS 14 or later and a Swift 6 toolchain (Xcode 16+).

```sh
git clone https://github.com/blitzreels/blitzclean.git
cd blitzclean
./script/build_and_run.sh
```

The script builds and installs `~/Applications/BlitzClean.app`, then opens the dashboard.
Use Settings to enable launch at login. Close the window to keep menu-bar monitoring running.

```sh
./scripts/check.sh
./scripts/build-app.sh
```

The build script creates `dist/BlitzClean.app`. Local builds use an ad-hoc signature.
A downloaded ad-hoc build is not Developer ID signed or notarized; build from source for now.
No administrator password is needed by BlitzClean's native cleanup actions.

## Cleanup rules

Quick cleanup examines only its explicit cache allowlist on the internal disk.
It keeps caches belonging to running tools and any item modified within seven days.
It refuses symlinks, unknown file types, changed trees, unverified activity, and open files.
Scans have time and entry limits; skipped items are reported. No item is selected automatically.

Selected caches are **permanently deleted** after a review dialog.
They can be downloaded or rebuilt by their package manager or Xcode.
The next install or build can take longer. Cleanup measures disk availability before and after;
APFS, shared blocks, and concurrent writes mean a folder's size is not a guaranteed gain.

Personal files use **Move to Trash** in Large files. They remain recoverable there.
Disk space is reclaimed when you empty Trash in Finder. BlitzClean never empties Trash for you.
The separate developer tools retain explicit permanent-delete workflows for individually reviewed artifacts.

AI apps, terminals, system apps, and active apps stay protected in the RAM release workflow.
There is no forced memory purge, synthetic memory pressure, or automatic quitting.
macOS already reclaims caches as needed. Closing an app releases its allocations, but its footprint
can include helpers and swapped memory, so it is not a promise of recovered physical RAM.
See [Apple's memory metrics guide](https://support.apple.com/guide/activity-monitor/view-memory-usage-actmntr1004/mac).

## Privacy and development

[Privacy and permissions](docs/PRIVACY.md) · [Architecture](docs/ARCHITECTURE.md) ·
[Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT license](LICENSE)

BlitzClean grew from FreeSpace / Buildkeep. The `FreeSpace` Swift target and local history
folder remain compatible with that app. The new bundle identifier is `com.blitzreels.BlitzClean`;
existing monitor, protection, workspace, and menu-bar preferences are copied once on first launch.
The original app and its preferences are preserved.

No third-party cleaner source is embedded. See [source and license notes](OPEN_SOURCE_BASES.md).
