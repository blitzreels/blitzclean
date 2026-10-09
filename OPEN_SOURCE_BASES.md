# Open-source bases

BlitzClean combines a small menu-bar monitor with existing cleanup tools.
Its feature direction draws from these projects.

## ClearDisk

- Source: <https://github.com/bysiber/cleardisk>
- License: MIT
- Adopt: developer-cache catalog, risk levels, cache descriptions, storage-pressure alerts,
  project-artifact detection, and storage forecasting.
- Keep different: BlitzClean also shows available RAM and delegates cleanup to Mole and Docker.

## Stats

- Source: <https://github.com/exelban/stats>
- License: MIT
- Adopt: low-overhead native metric collection and configurable menu-bar presentation.
- Keep different: BlitzClean exposes one compact storage label instead of one item per metric.

## Purge

- Source: <https://github.com/jithin-sabu/purge-app>
- License: MIT
- Adopt: allowlist-based cleanup, safety explanations, stale-project thresholds,
  lockfile checks, and streamed scan results.
- Keep different: BlitzClean remains a tray-first utility and keeps interactive cleanup commands in Terminal.

## Radix

- Source: <https://github.com/colinvkim/Radix>
- License: MIT
- Adopt later: actor-based scanning, progress reporting, scan snapshots, exclusions, and incremental rescans.
- Keep different: no treemap in the tray utility unless the simple category view stops being sufficient.

## OrphanBar

The original MIT notice is preserved in [licenses/OrphanBar-LICENSE.txt](licenses/OrphanBar-LICENSE.txt)
and included in packaged apps.

- Source: <https://github.com/scr2em/orphan-bar>
- License: MIT (same author as the BlitzClean change that adapted it)
- Adopt: leftover-process rules (launchd parent, not a launchd job, app, XPC service, or system component,
  and not a helper of a running app) and interpreter titles such as `python http.server`.
- Keep different: BlitzClean reuses its own process snapshot, identity checks, and Projects page instead of
  a second menu bar item and polling loop.

## License policy

- Preserve copyright and MIT license notices for copied or substantially adapted source.
- Prefer clean-room implementations of ideas when importing a full subsystem is unnecessary.
- Do not copy GPL or non-commercial source into BlitzClean without changing the app's license strategy.
