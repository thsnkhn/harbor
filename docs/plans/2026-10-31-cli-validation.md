# CLI validation — 31 October 2026

The feature is implemented in version 2.0.0 (47). No release was published.

## Verified

- The signed Apple Silicon app builds in the canonical DerivedData folder.
- The native Intel CLI builds, runs under Rosetta, and communicates with the same app.
- App and CLI code signatures pass validation. Release checks now include the
  CLI architecture and signing identity.
- `Scripts/test-cli.py` passes against a real app, isolated preferences and files,
  and the existing local HTTP/media/torrent fixture server.
- Access starts disabled. The socket directory and file have private permissions.
  Background app startup, stale socket recovery, and restart persistence pass.
- Direct download pause/resume, checksum, retry, cancel, timeout, and status pass.
- Replayed add request IDs return the original download and survive restart.
  Reusing the ID for different options fails. Removing the download does not
  permit the original request to create a duplicate.
- Remove preserves downloaded files. Trash requires the explicit flag and moves
  only the selected test file. Normal list output omits private request headers.
- Manifest import, duplicate torrent detection, torrent preview and selection,
  webseed download checksum, tracker changes, and seeding controls pass.
- Media preview and download pass. The local fixture has no selectable format
  catalog; this run does not verify a live provider's format variants.
- Browser continuation reports user interaction rather than completion.
- Invalid settings, unknown IDs/options, protocol rejection, concurrent clients,
  split stdin, oversized messages, and linked endpoint rejection pass.
- Skill install, repeat install, modified-file preservation, symlink rejection,
  partial failure reporting, and owned-file removal pass in temporary homes.
- Computer Use verifies command installation and all four offered skill folders.
  It also verifies CLI disable/re-enable with the main window closed, the Settings
  handoff, CLI-to-GUI Quiet mode, and GUI-to-CLI connection-count changes.
- Release script tests pass (2 tests); Python compilation and diff checks pass.

The full end-to-end run log is `/tmp/harbor-cli-e2e-verified.log`. Its temporary
app state and fixture report are in `/tmp/harbor-cli-e2e-11cdsb_k`. These local
paths are evidence from this development session, not release resources.

## Limits

The existing core suite could not run in this session. Xcode built the test host
but stalled before starting tests, including a retry without parallel workers and
with the previously verified signing settings. Both runners were stopped. No new
core-test pass is claimed. Logs: `/tmp/harbor-cli-core.log` and
`/tmp/harbor-cli-core-final.log`.

The full Intel app package and notarization were not rerun. This work verifies
both native CLI executables and the signed Apple Silicon app. Run the normal
release preparation and packaging checks before publishing.

System permission dialogs, real VPN credentials, and live media providers were
not exercised. Those operations remain interactive in Harbor. Cross-user denial
uses peer UID verification and private socket permissions; a second macOS user
was not created for a runtime test.
