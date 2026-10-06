# Security

Please don't report security issues in public GitHub issues.

Use the private Report a vulnerability form under this repository's Security tab, or email `support@blitzreels.com`.

BlitzClean inspects local processes, signals them, and can permanently delete reviewed files, so these count as
security issues:

- Removing, trashing, or signaling something other than what the user reviewed.
- Bypassing protected paths, process-identity checks, or Keep running settings.
- Exposing credentials, process arguments, conversation contents, or private paths.
- Unsafe path handling such as symlink or race-condition tricks during cleanup.

Useful details to include:

- BlitzClean version (bottom of Settings) and macOS version.
- Whether you used a GitHub release or a source build.
- Steps to reproduce, ideally with disposable test folders.
- Logs or screenshots with secrets and private paths removed.

BlitzClean is maintained by a small team, so response times vary.
We confirm receipt when we can and follow up once there is a fix or a clear mitigation.
