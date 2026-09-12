# Privacy and permissions

BlitzClean runs locally and has no telemetry SDK, account service or remote AI inference.

## Local data

The compatibility data directory is `~/Library/Application Support/FreeSpace`.
`cleanup-history.json` keeps at most 200 cleanup receipts and includes reviewed paths.
`memory-history.json` keeps at most 1,440 events over 24 hours and includes app/tool names,
project folder names, counts and memory measurements. Older events can lack worker details.
Files are restricted to the current user.

The `com.blitzreels.BlitzClean` preference domain stores notification choices, project settings,
start commands and additional scan locations. Selected preferences are copied once from the legacy
`fr.algomax.FreeSpace` domain; the original domain remains unchanged. Do not place secrets directly in saved commands;
use the project's local environment setup instead.

Process arguments are read locally to recognize tools. Memory history does not retain arguments,
environment variables, window text, conversation contents or stack dumps.
A project folder name or app name may itself be sensitive. Review exports before sharing.

Developer browsing reads local package manifests and Git metadata. It does not fetch remote branches,
query GitHub PRs or run npx. Folder listings stay in memory; completed deletions enter the cleanup ledger.
Framework badges are drawn locally and do not download logos.

CPU and RAM graphs keep at most 451 samples in memory (about fifteen minutes).
Quick-cleanup scans and large-file lists remain local. Quick cleanup deletes confirmed rebuildable
caches permanently; the Large files page moves files to Trash. It never empties Trash.

## Permissions and connections

- Notifications are optional; memory and disk banners have independent toggles.
- Files and Folders access can be required for selected locations. Denied access is reported.
- Accessibility is optional and requested for app-response checks. Recovery does not require window-content logging.
- Local HTTP probes identify listening ports and can cause a development server to serve or compile its page.
- Clicking a port opens its local address in your browser. Package tools and saved start commands
  can perform network requests according to their own configuration.
- Docker and Mole have their own behavior and permissions; they are not bundled dependencies.

Monitoring continues when the main window closes. Quit BlitzClean to stop monitoring.
Saved server commands are not automatically stopped when BlitzClean quits.
