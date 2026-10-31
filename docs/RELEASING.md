# Prepare Intel and Apple Silicon releases

Release preparation does not publish files, create tags, or change the live update feed.

## Local preparation

Run:

```sh
Scripts/release-sparkle.sh prepare --notes-file docs/releases/<version>.md
```

This command uses the existing Developer ID certificate and Sparkle key. It does not create or rotate keys. It signs both local packages, but does not submit them to Apple unless you add `--notarize`.

The command builds Intel first and Apple Silicon second. Both use `build/HarborDerivedData`. Each build removes the previous unpacked app and compiler outputs. Only the final unpacked Apple Silicon app remains. The two requested DMGs remain in `build/release`.

The output contains:

- `Harbor-<version>-Intel.dmg`
- `Harbor-<version>-Apple-Silicon.dmg`
- `appcast.xml`, for existing installations
- `appcast-x86_64.xml` and `appcast-arm64.xml`, for subsequent updates
- `release.json`, with processor, build, size, signature, hash, and source-commit information
- `homebrew-urls.rb`, with the processor URLs and hashes for the existing cask

Each package is mounted read-only and checked before preparation completes. The check verifies the app name, bundle identifier, version, update key, signing, processor, Safari extension, and included runtime folders. The shared yt-dlp binary remains universal because its appended Python payload must not be removed. It is signed with the existing Developer ID and library-loading entitlement.

Keep `CURRENT_PROJECT_VERSION` as an increasing integer in the project. Preparation adds `.1` for Intel and `.2` for Apple Silicon. For example, source build `46` produces builds `46.1` and `46.2`. Both show the same public version, such as `1.8.8`. Increment the source build for the next release; do not reuse a published build number.

## Existing installations

Keep `Harbor.app`, `co.hapy.harbor`, the Developer ID identity, and the existing Sparkle public key unchanged. Do not add a processor suffix to the app name or bundle identifier.

The old feed URL remains in `Info.plist`. It offers both packages. Sparkle 2.9 selects the newer Apple Silicon item only on supported hardware; Intel Macs select the Intel item. All official versions in the repository's updater history pin Sparkle 2.9.0. Do not use this direct transition for a separately built older client that lacks the hardware filter; such a client needs a universal transition update first.

After the first update, the updater delegate selects the matching processor feed. An Intel process running through Rosetta selects the Apple Silicon feed, so it can move to the native build. The release feeds preserve previous compatible releases. Full packages are used for the transition; processor-specific delta updates are not generated yet.

The update replaces the app bundle. Settings remain in the same preferences domain. History, recovery files, and download files remain in their existing locations. The updater does not move, rename, or remove those data directories.

Users keep the normal **Install Update** flow. They do not select a processor or uninstall Harbor during an in-app update.

## Validation before publication

Run the focused update checks:

```sh
python3 Scripts/test_release.py
```

Run `AppUpdateFeedTests` with the existing Xcode test target. Check an existing universal installation on Intel and Apple Silicon. Include Rosetta when checking Apple Silicon. Verify the first update, the next update, settings, history, a paused download, and each bundled download engine. Rosetta execution alone does not replace a check on an Intel Mac.

The existing release smoke test must also pass for each package. Quit Harbor before enabling that test so it cannot stop a live download. Use the existing test flag when preparing the final release:

```sh
HARBOR_SMOKE_CONFIRM_NO_RUNNING_HARBOR=YES \
  Scripts/release-sparkle.sh prepare --notarize --smoke --notes-file docs/releases/<version>.md
```

This step submits the app and DMG to Apple. It still does not publish them. Keep it separate from ordinary local preparation.

## Publication

Publish only after the user authorizes a release:

```sh
Scripts/release-sparkle.sh publish build/release
```

Publication requires packages prepared from the current clean commit, matching file hashes and signatures, completed notarization, and completed smoke tests. It refuses to overwrite an update feed that changed after preparation. It uploads the two packages before publishing all three feeds together.

Update the existing Homebrew cask with `homebrew-urls.rb`. Keep its app name and existing data rules. Update manual download links to the two named packages in the same release. Do not point the current generic `Harbor.dmg` URL at a processor-specific package: that would break manual downloads on the other processor. Until the split is published, the current public download links remain unchanged.
