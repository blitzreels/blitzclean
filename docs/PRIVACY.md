# Privacy and permissions

BlitzClean runs locally, without a telemetry SDK, account service, or remote AI inference.
App/process names, directory paths, and local history remain on your Mac unless you choose to share them.

## Local data

The compatibility directory is `~/Library/Application Support/FreeSpace`.
New chart and export stores use `~/Library/Application Support/BlitzClean`.

| Store | Retention and contents |
| --- | --- |
| Cleanup ledger | At most 1,000 records, including reviewed paths and measured space changes. |
| Memory incidents | At most 1,440 events from the last 24 hours, including app/tool and project names. |
| Pressure trace | Up to 240 recent samples/actions and top project summaries. |
| CPU/RAM charts | Two-second detail for 15 minutes and five-minute points for seven days; at most 512 KiB on disk. |
| File review | At most 5,000 entries / 8 MiB, including paths, sizes, identity metadata, and scan time. |
| Media exports | At most 100 completed records / 512 KiB, including input/output paths and results. |

Persisted JSON files have owner-only permissions.
File filters, navigation, dismissed crash reports, project choices, and selected scan roots also survive relaunch.

The `com.blitzreels.BlitzClean` preference domain stores notification choices, project settings, and start commands.
Selected preferences migrate once from `fr.algomax.FreeSpace`; the original domain remains unchanged.

Do not put secrets directly in saved commands; use the project's environment setup instead.
Process arguments are read locally to identify tools, but incident histories do not retain arguments or credentials.

Developer browsing reads package manifests and Git metadata without fetching remote branches, querying GitHub, or running npx.
Directory listings, recursive scans, duplicate hashing, and media processing run locally.

No conversation contents, window text, environment variables, or stack dumps are collected into the monitoring history.
A project or app name can itself be sensitive, so review exports before sharing.

## Permissions and connections

- Notifications are optional and used for resource-pressure alerts.
- Files and Folders access can be required for protected locations; denied paths are reported.
  Full Disk Access may be needed to inspect more protected macOS data, and does not bypass every system restriction.
- Accessibility enables window-response checks; no window text is logged for recovery.
- Local HTTP probes identify listening ports and can cause a development server to serve or compile a page.
- Opening a port launches its local address in your browser.
- Package tools, saved server commands, Docker, and external cleanup tools follow their own network/permission behavior.
- FFmpeg/FFprobe are optional local installations, not bundled downloads.

The app's code signature affects how macOS remembers permissions.
Ad-hoc rebuilds or a changed signing identity can require granting access again.

## Actions and lifetime

Personal-file removal uses Trash; BlitzClean never empties it.
Confirmed cache/developer cleanup can permanently delete rebuildable items after revalidation.

Normal Quit/Stop actions are immediate; Force Quit and bulk termination require inline review.
Automatic project pausing requires per-project consent and never deletes data or kills apps.

Monitoring continues when the main window closes; quit BlitzClean to stop it.
Saved server commands are not automatically stopped when BlitzClean quits.

A system-wide stall can stop BlitzClean too: it is not a separate recovery daemon.
Local pressure traces cannot establish the cause of a kernel panic.
