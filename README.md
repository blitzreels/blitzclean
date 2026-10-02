<p align="center"><img src="assets/brand/app-icon.png" width="112" alt="BlitzClean icon"></p>
<h1 align="center">BlitzClean</h1>
<p align="center">A little breathing room for your Mac.</p>
<p align="center">By <a href="https://blitzreels.com">BlitzReels</a> · Native SwiftUI · macOS 14+ · MIT</p>
<p align="center"><a href="https://github.com/blitzreels/blitzclean/releases">Downloads</a> · <a href="CHANGELOG.md">What's new</a> · <a href="#build-from-source">Build from source</a></p>

BlitzClean shows CPU, RAM, and free disk space in your menu bar, with one window for taking action.
Find large files, inspect running projects, recover stopped apps, and review what can be removed.

Everything runs locally: no account, subscription, telemetry SDK, or cloud inference.
Closing the window keeps the menu bar and monitoring running; **Quit BlitzClean** exits the app.

## New in 1.1.0

- **Faster Revive:** direct Revive and Force Quit buttons, including on already-running apps.
  The list follows app launches/exits and refreshes every two seconds while open; old results no longer hide new freezes.
- **Browse first:** Storage opens into a directory browser with drive buttons, breadcrumbs, named Back/Forward controls,
  clickable rows, recursive folder sizes, and reviewed Move to Trash.
- **Largest files across drives:** cancellable scans cover connected local drives and progressively rank the largest files.
  The old Files tab and nested storage tabs are gone.
- **Pressure warnings:** see the limiting resource and when to avoid new builds or threads.
  Projects can opt into automatic pausing during sustained pressure, with explicit Resume.
- **Persistent charts:** CPU and RAM history survives relaunch, with up to seven days of bounded local history.
- **Consistent controls:** one dashboard, inline reviews, app icons, a revised logo, and direct Quit/Stop actions.

See the [changelog](CHANGELOG.md) for the full release notes.

## Download

Get builds from [GitHub Releases](https://github.com/blitzreels/blitzclean/releases).
Release notes identify the supported architectures, signing, and notarization status for each download.

The 1.1.0 archive supports Apple silicon and Intel Macs running macOS 14 or later.
Extract `BlitzClean.app`, move it to Applications, and open it; use Settings to enable launch at login.

Notarization is separate from code signing: a Developer ID signature alone does not guarantee Gatekeeper acceptance.
Use the release's stated status before installing, or build locally with the steps below.

## What you can do

| Page | Controls |
| --- | --- |
| Overview | CPU, RAM, storage, pressure guidance, and the largest AI threads. |
| Memory | Apps and AI sessions ranked by memory; Quit, Force Quit, Pause/Resume, and pressure history. |
| CPU | Current process usage; values can exceed 100% when a process uses multiple cores. |
| Storage | **Browse**, **Inventory**, and **Cleanup**, with no nested tab bar. |
| Revive apps | Live app checks, direct Revive/Force Quit, bulk recovery for stopped apps, and recent crashes. |
| Projects | Servers and background workers grouped by project, memory/CPU, Stop, Pause/Resume, and Keep running. |
| Settings | Menu-bar metrics, notifications, login launch, and project locations. |

The menu bar shows CPU, RAM, free storage, compact charts, and shortcuts into the same dashboard.
Resource samples update every two seconds; project, disk, and window checks have their own bounded refresh cycles.

### Recover apps

Open **Revive apps** from the sidebar, menu bar, or **Tools** menu (`Shift-Command-R`).
Stopped and unresponsive apps appear first, and each Revive action runs independently of the full scan.

Revive resumes stopped processes and checks whether their windows respond; it does not restart a running app.
A deadlock can remain unresponsive, in which case Force Quit stays available with an inline unsaved-work confirmation.

Accessibility permission enables frozen-window checks; without it, BlitzClean can still inspect process state.
Recent crashes can be reopened or dismissed, and a successful recovery never masks a later stopped state.

### Find and remove storage

- **Browse:** navigate drives and folders without opening another window; select files/folders for Move to Trash.
- **Largest files:** scan all connected local drives, including hidden files, app packages, and dependency trees.
  Results retain the largest 5,000 files with progress, cancellation, and unreadable-location reporting.
- **Inventory:** inspect installed apps, vendor app folders, Xcode, simulator data, caches, and developer storage.
- **Cleanup:** review caches, dependencies, build outputs, simulators, Docker, worktrees, and previously removed folders.
- **Remove again:** see when rebuildable folders grow back, with fresh activity and file checks before another removal.

Normal directory browsing runs separately from recursive size calculation.
Largest-file traversal has no fixed 32-level depth or 20-second cutoff; denied locations remain visible as incomplete.

### Review media

- Filter videos, images, MP4/MOV and other extensions by age, size, and path; sort by size or date.
- Find exact duplicates with streaming SHA-256 comparison, excluding hard links and retaining one copy per group.
- Use an installed FFmpeg to create smaller SDR MP4/JPEG copies, lossless PNG, or joins of compatible clips.
  Exports preserve originals, check free space, and verify the output with a full decode.

FFmpeg is optional and is not downloaded automatically.
HDR video, animated images, transparent JPEG conversion, and joins with incompatible streams are rejected.

### History and pressure

CPU/RAM charts retain two-second detail for 15 minutes and five-minute points for seven days.
The chart file is capped at 512 KiB; scan results, filters, export history, and cleanup receipts also persist locally.

Pressure warnings consider memory pressure, compression, swap, disk reserve, and CPU.
Opt-in project pausing stops CPU work but keeps its memory allocated; it never automatically kills apps or deletes files.

## Build from source

Requires macOS 14+ and a Swift 6 toolchain, such as Xcode 16 or later.

```sh
git clone https://github.com/blitzreels/blitzclean.git
cd blitzclean
./script/build_and_run.sh
```

This builds, installs, and opens `~/Applications/BlitzClean.app`.
Local builds use an installed Apple Development signing identity so permissions can remain tied to a stable identity.

Without a signing identity, explicitly opt into an ad-hoc local build:

```sh
BLITZCLEAN_SIGNING_IDENTITY=- ./script/build_and_run.sh
```

Ad-hoc rebuilds can require granting Accessibility and Files and Folders permissions again.
They are for local development, not notarized distribution.

```sh
./scripts/check.sh
./scripts/build-app.sh
```

The media integration tests require FFmpeg/FFprobe (`brew install ffmpeg`).
Checks cover compilation, Swift tests, formatting, property lists, and shell syntax.
See [Releasing](docs/RELEASING.md) for universal packaging, signing, notarization, and checksums.

## Removal and process rules

Personal files and folders use **Move to Trash**, with an inline review and fresh identity checks.
They remain recoverable; disk space is reclaimed when you empty Trash in Finder.

Cache and developer cleanup can **permanently delete** explicitly reviewed rebuildable data.
Running tools, open files, recent changes, protected paths, and incomplete checks can block removal.

Scans never select candidates automatically, and BlitzClean never empties Trash for you.
Folder size is not a guaranteed space gain: APFS shared blocks and concurrent writes affect available storage.

Individual Quit/Stop actions run immediately and preserve native save dialogs where supported.
Force Quit and bulk termination require inline confirmation; normal Stop never escalates automatically to Force Quit.

Pressure protection honors Keep running projects and protects AI/tool sessions from automatic pausing.
No forced memory purge or synthetic memory-pressure allocation is used.

## Privacy and development

[Privacy and permissions](docs/PRIVACY.md) · [Architecture](docs/ARCHITECTURE.md) ·
[Product design](docs/DESIGN.md) · [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md) · [MIT license](LICENSE)

BlitzClean grew from FreeSpace / Buildkeep; the `FreeSpace` Swift target and compatibility history folder remain.
Selected legacy preferences migrate once to `com.blitzreels.BlitzClean`, preserving the originals.

No third-party cleaner source is embedded.
See [source and license notes](OPEN_SOURCE_BASES.md).
