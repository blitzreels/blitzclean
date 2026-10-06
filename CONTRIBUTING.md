# Contributing to BlitzClean

Thanks for your interest in BlitzClean. Issues, ideas, and pull requests are welcome.
BlitzClean is also a focused product with strict safety rules, so opening a PR does not guarantee it will be merged.

## What to contribute

Good first contributions:

- Bug reports with clear reproduction steps.
- Small bug fixes with a test.
- Documentation and wording improvements.
- New rebuildable cache or build-output locations, with tests proving what is and isn't removed.
- Test coverage for existing behavior.

Look for issues labeled `good first issue` or `help wanted`.
For anything larger, such as a new page, a new kind of cleanup, or a change to process control,
open an issue first so we can agree on the approach.

## Pull requests

Keep each PR to one change. A PR may be closed if it:

- Adds automatic deletion, automatic force-quit, or memory-purge behavior.
- Changes the UI without following [docs/DESIGN.md](docs/DESIGN.md).
- Adds dependencies, network calls, or telemetry.
- Includes secrets, private paths, process command lines, or personal data.
- Is too large to review confidently.

Closing a PR is not a judgment on the contributor; it usually means the change does not fit right now.

## Setup

Use macOS 14+ and a Swift 6 toolchain. Run `./script/build_and_run.sh` to build and install the native app.
Install FFmpeg/FFprobe with `brew install ffmpeg` to run the media integration tests.
Run `./scripts/check.sh` before opening a pull request, followed by `./scripts/build-app.sh` for packaging changes.
Without a local signing certificate, use `BLITZCLEAN_SIGNING_IDENTITY=-` for an ad-hoc development build.
See [Releasing](docs/RELEASING.md) for signed universal downloads and notarization.

The check script runs native integration cases sequentially so timing-sensitive fixtures do not compete on small runners.
Concurrency behavior is still exercised inside the relevant tests.

Keep changes focused. Explain the user-visible behavior and include the relevant validation.
For UI changes, render every screen with `FREE_SPACE_DESIGN_DIR=/tmp/shots swift test --filter DesignRenderTests`
and attach before/after images. Screenshots must use synthetic project names and data;
do not publish a contributor's running processes or history.

## Safety requirements

- Never infer that low CPU means a process is abandoned.
- Revalidate process identity, owner and project policy immediately before signaling it.
- Keep AI apps, active sessions, booted simulators and data-bearing Docker resources protected.
- Never add silent deletion, automatic force-quitting or memory-purge commands.
- Verify cleanup against disposable fixtures, not a contributor's real files.
- Keep persisted history bounded and exclude commands, environment variables, tokens and conversation contents.
- Preserve compatibility with existing FreeSpace preferences and receipts.
- Default to small build concurrency and avoid repeated full-disk scans.

Use one input structure for functions with multiple domain parameters.
Add focused tests for deletion boundaries, process identity, launch validation and persistence migrations.
Use `xcrun swift-format format --in-place <changed files>` for Swift formatting.

See `OPEN_SOURCE_BASES.md` before adapting source from another project and preserve all required notices.

## License

By contributing, you agree that your contribution is licensed under the [MIT License](LICENSE).
