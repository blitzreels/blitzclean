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

## License policy

- Preserve copyright and MIT license notices for copied or substantially adapted source.
- Prefer clean-room implementations of ideas when importing a full subsystem is unnecessary.
- Do not copy GPL or non-commercial source into BlitzClean without changing the app's license strategy.
