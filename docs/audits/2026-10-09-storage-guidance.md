# Storage ownership and cleanup guidance

## Changes

- Storage Browse, folder rows, Inventory, and cleanup rows use installed app icons when ownership is known.
- Codex and Claude icons also resolve when the corresponding app is not running.
- Rows distinguish checked rebuildable data, app-managed data, protected data, and personal review.
- Raw deletion rejects Docker disks, Claude VM data, Codex history, Git metadata, credentials,
  application bundles, system data, and app-support parent folders.
- Inventory provides a Can clean filter and a per-item review confirmation for eligible rebuildable data.
  The existing cleanup service checks activity and rebuild eligibility again before deletion.
- Inventory can scan a mounted external drive or a selected folder on demand.
  Discovery is bounded to 15 seconds / 150,000 entries; measurements share a 45-second deadline.
  Partial discovery and unmeasured folders are identified. Top-level inventory lists up to 64 visible entries.
  Symlinks are not followed, and generated cleanup targets cannot expand outside the selected folder.
- The capacity meter follows the selected external drive.

## Automated verification

- Build and typecheck passed through `scripts/check.sh`.
- 353 tests in 63 suites passed.
- Eight focused storage-guidance tests passed again after tightening app-data parent protection.
- Strict swift-format lint, plist validation, shell syntax checks, and git diff whitespace checks passed.
- Tests cover screenshot payload protection, installed-app ownership classification, personal-file review,
  project cleanup routing, eligibility reasons, scope containment, bounded discovery, and symlink exclusion.

## Boundaries

An app icon is an ownership hint from known locations, not proof that every file in a similarly named project
belongs to that app. Personal media and source files never acquire a safe-delete label based on size or age.
Reviewing cleanup does not delete anything. User files, Docker volumes, and live projects were not deleted in this work.

## Native app verification

Installed locally with `script/build_and_run.sh --verify` and inspected the running macOS app.

- Browse showed Docker, Claude, Xcode, Codex, and Chrome icons beside the screenshot's matching files.
  Their Trash toggles were disabled and the owner/safety explanations were visible.
- Inventory's Can clean filter exposed checked dependency data. Opened its inline deletion review and cancelled it.
- Selecting harddrive changed capacity to approximately 350 GB free of 2,000 GB.
- The bounded external scan found 34 project folders: 2 eligible (31.9 GB allocated), 32 in use.
  It reported partial discovery rather than claiming a complete drive audit.
- Recordings and other personal folders displayed Review first / Review files.
  Opening recordings retained the original-data guidance and reviewed Trash flow.
- Review safe cleanup opened the existing Dependencies section with the selected external-drive candidates.
- Memory rows and the independent emergency panel displayed Codex icons.
- UI inspection caught an unfiltered section size in Can clean; the total was corrected to sum filtered candidates.

The 31.9 GB figure is allocated candidate data, not a measured free-space gain.
No cleanup confirmation was accepted. The new flow was reviewed using actual inventory data and deletion behavior
was exercised only by automated disposable-fixture tests.

The final local build also passed nine focused guidance/render tests and strict lint.
After reinstall, the running Inventory showed 3.5 GB for checked internal dependencies instead of 11.6 GB
for the full category; searching a project reduced the displayed total to its matching eligible folders.
The final application bundle passed deep/strict code-signature verification.
The final harddrive Inventory also displayed the corrected 31.9 GB eligible total, with two matching rows.
The revised “Delete this rebuildable folder?” confirmation was verified and cancelled in the installed app.
