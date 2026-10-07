# Releasing BlitzClean

## Prepare

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `support/Info.plist`.
2. Update `CHANGELOG.md`, the README, and any affected architecture/privacy documentation.
3. Run `./scripts/check.sh`, then verify the changed screens in the installed app.
4. Review the exact files being committed; exclude local reports, credentials, screenshots with personal data, and builds.

## Update signing key (once per Mac)

Updates are signed with an EdDSA key kept in the login keychain, never in the repository or GitHub secrets.

```sh
./scripts/sparkle-key.sh
```

The script creates the key under the keychain account `blitzreels-blitzclean` if it is missing and prints the
public key. The private key is backed up in Infisical: BlitzReels project, `prod`, folder `/blitzclean`,
secret `SPARKLE_PRIVATE_ED_KEY` (with `SPARKLE_PUBLIC_ED_KEY` beside it).

Installed copies trust only this key. Losing it means every existing install has to download the next release
by hand. To set up another Mac, restore it from Infisical into the keychain:

```sh
infisical secrets get SPARKLE_PRIVATE_ED_KEY --projectId <BlitzReels project id> --env prod \
  --path /blitzclean --plain --silent > /tmp/sparkle-key && chmod 600 /tmp/sparkle-key
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account blitzreels-blitzclean -f /tmp/sparkle-key
rm /tmp/sparkle-key
```

## Package a download

Use a Developer ID Application identity installed in the login keychain.
The packaging script builds both arm64 and x86_64, verifies the signature, and creates a ZIP and SHA-256 checksum.

```sh
BLITZCLEAN_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
  ./scripts/package-release.sh
```

Outputs are `dist/BlitzClean-<version>-macOS.zip` and the matching `.zip.sha256` file.
The script embeds the public update key and the feed URL in the app. When the build is notarized it also writes
`dist/appcast.xml`, signed with the keychain key, with the version's `CHANGELOG.md` section as release notes.
Rename `## Unreleased` to `## <version> - <date>` before packaging so the notes are found.
`BLITZCLEAN_SKIP_UPDATES=1` packages a build without an updater.
The app requires macOS 14+; local build concurrency defaults to two jobs.

Signing alone does not notarize the app.
Without a notarization profile, publish only as a clearly labeled preview and state that Gatekeeper may block it.

## Notarize

Configure an Apple notarization keychain profile outside the repository, then pass its name:

```sh
BLITZCLEAN_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
NOTARY_PROFILE='your-notarization-profile' \
  ./scripts/package-release.sh
```

Alternatively, use an existing `asc` CLI authentication profile without exporting its credentials:

```sh
BLITZCLEAN_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
BLITZCLEAN_ASC_PROFILE='your-asc-profile' \
  ./scripts/package-release.sh
```

The script requires an Accepted result, staples and validates the ticket, checks Gatekeeper, and recreates the archive.
The checksum is calculated after stapling; the submission receipt stays in ignored `dist/`.

Never commit certificates, private keys, app-specific passwords, or notarization credentials.
Do not disable Gatekeeper or remove quarantine as an installation workaround.

## Publish and verify

Push the reviewed commit and confirm its GitHub checks pass.
Tag that exact commit as `v<version>`, then create a GitHub release with the ZIP, checksum, `appcast.xml`, and
version-specific release notes. The tag must match: the appcast points at
`https://github.com/blitzreels/blitzclean/releases/download/v<version>/BlitzClean-<version>-macOS.zip`.

Installed apps read `https://github.com/blitzreels/blitzclean/releases/latest/download/appcast.xml`, which always
resolves to the newest non-prerelease release. Publishing the release is what ships the update, so upload
`appcast.xml` last, after checking the ZIP downloads and its checksum matches. A prerelease is never offered.
To pull a bad update, delete `appcast.xml` from that release or mark it as a prerelease.

Use a prerelease for a build whose notarization or required release validation is incomplete.
For a stable release, require a stapled ticket and successful Gatekeeper assessment.

Download the published assets, verify the checksum, and inspect the extracted app's version, architectures, and signature.
Record signing/notarization status and any known limits in the release notes, separately from test results.

CI uses explicit ad-hoc signing because hosted runners have no developer certificate.
Its downloadable build artifact is a development check, not the signed public release.
