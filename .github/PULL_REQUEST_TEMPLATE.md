## Summary

What does this change do, and why?

## Scope

- [ ] Bug fix
- [ ] UI or behavior change
- [ ] Cleanup, deletion, or process-control logic
- [ ] Documentation
- [ ] Tests
- [ ] Build, release, or packaging

## Checks

- [ ] I kept the PR focused on one change.
- [ ] `./scripts/check.sh` passes, or I explained why I could not run it.
- [ ] For UI changes: I attached before/after screenshots made with synthetic data
      (`BLITZCLEAN_DESIGN_DIR=/tmp/shots swift test --filter DesignRenderTests`) and followed `docs/DESIGN.md`.
- [ ] For cleanup or process changes: I added tests against disposable fixtures and kept the safety rules in
      `CONTRIBUTING.md`.
- [ ] I did not include secrets, private paths, process command lines, or personal data.

## Notes

Larger changes should start with an issue so we can agree on the approach first.
