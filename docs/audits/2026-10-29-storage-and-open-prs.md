# Download issues and open pull requests

Date: 29 October 2026. Repository: `thsnkhn/harbor`.

## Scope and order

1. Fix [issue #117](https://github.com/thsnkhn/harbor/issues/117): external-drive downloads.
2. Repair [PR #114](https://github.com/thsnkhn/harbor/pull/114): incoming torrent ports.
3. Revise [PR #118](https://github.com/thsnkhn/harbor/pull/118): community browser-extension links.

The user selected #117 as the first implementation. Keep the changes separate. Do not merge the pull requests as part of this audit.

Also reviewed [issue #116](https://github.com/thsnkhn/harbor/issues/116), **Too frequent updates**. Its statistics change is separate from the storage work. Implement it as a separate change after the storage patch is verified.

Also reviewed [issue #113](https://github.com/thsnkhn/harbor/issues/113), **Separate builds for Intel and Apple Silicon**. Existing installations can stay in place. The release process and update feed need changes before publishing separate builds.

## Reviewed versions

| Item | Commit | State at review |
| --- | --- | --- |
| Local and remote main | `90294f7a9225f921595bd81978605fbe795d5268` | Clean before this work |
| PR #114 | `014ebdbb609ded8dc73eaaf66574e3a54f8030b2` | Mergeable; no reviews or reported checks |
| PR #118 | `1bc9ca67ae62bb99236d0d6122344585132b9cf2` | Mergeable; no reviews or reported checks |
| Chrome extension | `12b548a2c8ba9a17fd6fefbcc309fa6f7da03a84` | Community project |
| Firefox repository | `3d598c7e94cdcdb72adfc4a2f4f16049a5ea26c5` | README and license; helper in a release asset |

No review or comment was posted on GitHub. No pull request was merged.

## Issue #117: findings

**Confirmed code cause:** the selected save folder and the working-file folder are separate. No explicit internal-disk capacity check was found in the app source. A real write to internal storage can produce the reported error.

- `AppSettingsStore.downloadStagingRootURL` defaults to Application Support. `HarborApp.init` gives that location to the direct-recovery and completed-file stores once, at launch.
- `DownloadCoordinator` streams HTTP data into `DirectDownloadRecoveryStore`. This is an owned partial file, not a current `URLSessionDownloadTask` temporary file.
- `BrowserDownloadCoordinator` stores its partial files in Application Support. The app does not pass the custom staging folder to it.
- `MediaDownloadService` gives yt-dlp a working folder in Application Support. The custom staging setting does not reach this engine either.
- `CompletedDownloadHandoffStore` moves complete payloads to its own root. Moving a payload from another volume can require a full copy.
- Torrents pass their selected destination to Aria2 Next as `dir`. Keep that path unchanged.

The reporter did not supply the Harbor version, download type, source URL, filesystem, or error text. The code explains the symptom; it does not prove which engine produced that report.

### Required behavior

- Put new working files on the selected destination volume by default.
- Apply an explicit custom staging folder to new downloads across the direct, browser, and media engines.
- Save the chosen storage location before an engine writes data. Reuse it on pause, retry, and app restart.
- Keep completed-file packages on that same volume. Do not copy a completed external payload back to internal storage.
- Keep existing recovery files where they are. Import old records once. Do not move or delete paused data during upgrade.
- If a drive is absent or a different drive uses the same mount path, stop new writes. Preserve recovery state. Do not create an internal replacement folder under an absent mount.
- A settings change applies to new downloads. It must not redirect an existing writer or hide its partial file.

### Implementation

Use a small storage-location index in Application Support. Store the working root, mount location, and volume UUID for each new download. Put payload files under `.harbor-downloads` in the selected destination folder. Keep the existing store layout and file validation within each root.

Route all four stores through the same saved location: direct partials, browser partials, media work files, and completed-file packages. Enumerate both old and registered roots during recovery. Check the volume before opening a new writer or removing recovery data.

Do not change capacity messages alone. Do not move old recovery roots based on the current default folder. Do not change torrent storage.

### Validation

| Check | Required result |
| --- | --- |
| Small legacy volume, larger destination volume | A payload larger than the legacy volume completes on the destination |
| Complete-file publication | Payload stays on the destination; same-volume rename preserves its identity |
| Pause and restart | Saved bytes and HTTP range continuation survive a new coordinator and storage-index load |
| Disconnect | Lookup reports unavailable; saved files and progress remain |
| Different volume at the same path | New writes fail; recovery data is retained |
| Drive reconnect | The same volume can resume its own download |
| Existing records | Old direct, browser, and media recovery remains discoverable |
| Change destination or custom staging | Existing downloads keep their root; new downloads use the new choice |
| Browser and media | Their working paths and completion packages use the saved root |
| Torrent regression | The existing `dir` behavior remains unchanged |

Run one local app build and focused recovery tests. Use disposable small volumes for storage checks. Do not fill the Mac's internal drive. Verify the app version and build number after the build.

## Issue #116: frequent progress updates and unstable ETA

Status: implemented locally on 31 October 2026; not released. The attached recording was not inspected. The findings below come from the issue text and source review.

### Confirmed causes

- `DownloadCoordinator.urlSession(_:dataTask:didReceive:)` writes each received chunk, then publishes a progress event for that callback. Its 0.35-second condition limits speed sampling, not progress-event publication.
- Each direct progress event schedules work on the main thread and changes the observable download item. The table and inspector read those changing values directly. There is no shared display refresh limit.
- `DownloadItem.etaText` passes the current speed to `DownloadFormatting.etaString`. The formula is remaining bytes divided by the latest speed. It does not use an average across several samples. For example, with 100 MB remaining, alternating samples of 10 MB/s and 2 MB/s produce estimates of 10 seconds and 50 seconds.
- Torrent refresh already waits one second between completed refresh passes. Its reported speed still reaches the same unsmoothed ETA formula. Slowing direct callbacks alone would not address ETA across engines.
- Media progress lines are passed to the model without a shared display policy. Browser-assisted downloads currently have no continuous progress event in `BrowserDownloadEvent`; do not add a new browser progress feature as part of this fix.
- The Dock already refreshes once per second and skips unchanged labels. It is not coupled to every transfer callback.

### Proposed change

1. Keep byte writes, recovery counters, and speed-limit enforcement at their current precision. Do not slow the transfer engine to calm the display.
2. Publish displayed speed, transferred size, and percentage at most once per second. Coalesce progress before it creates repeated main-thread work. Use the newest accumulated byte count when publishing.
3. Compute displayed speed and ETA from a time-based average over approximately 10 seconds. Treat that duration as a starting value to check with bursty transfers. Use one small statistics policy across direct, torrent, and media downloads. Do not use a lifetime average, which responds too slowly to a sustained speed change.
4. Show ETA only when total size is known and enough speed data is available. Include idle time in the average so a stalled transfer does not retain an old optimistic estimate. Let ETA increase when the connection remains slower; do not force a false countdown.
5. Use the same displayed values in the list, inspector, and aggregate speed display. Keep row ordering stable between display updates when sorting by speed or progress.
6. Apply start, pause, failure, cancellation, and completion immediately. Reset sample history for a new attempt and exclude paused time. Completion must not wait for the next display update.

### Validation

Use one focused statistics check with different callback rates and the same timed byte sequence. Check steady speed, short bursts, a sustained slowdown, a stall, unknown total size, and pause/resume. Verify that callback frequency does not change the average and that updates stay within the chosen display interval.

Then use the existing slow-download fixture to check the list and inspector together. Confirm that a short completed download appears complete immediately, and that speed limits and resumable byte counts remain correct. Record the display behavior before and after the fix. No build or test run was needed for this source-only issue review.

### Local implementation, 31 October

The display retains the latest direct and media progress for each attempt in a locked buffer. One main-thread task drains it once per second. This follows the latest-value throttling pattern described in [Apple's Combine documentation](https://developer.apple.com/documentation/combine/publisher/throttle(for:scheduler:latest:)). A separate entry per attempt prevents one busy download from suppressing another download. The existing torrent status poll already runs once per second. Lifecycle events bypass the buffer and keep their existing attempt checks.

Direct, torrent, and media downloads use a time-weighted moving average of engine speed samples from the last ten seconds. This applies the [moving-average smoothing method](https://www.itl.nist.gov/div898/handbook/pmc/section4/pmc421.htm) to display samples. Callback count does not determine sample weight. The ten-second window is Harbor's display choice, not an Apple requirement. Engine rates are used because media byte counters can restart between separate audio and video transfers.

The calculation waits for one second of samples before showing speed and ETA. It uses `ContinuousClock`, so wall-clock changes cannot change elapsed time. A rate report remains current for two seconds to allow the one-second torrent poll to finish. Missing reports then contribute zero, and the old rate leaves the average after the window expires. Lifecycle transitions, recovery resets, and new attempts clear the sample history. The list, inspector, and aggregate speed read the same model value. Unknown file sizes continue to hide ETA.

Network callbacks still write every byte and enforce speed limits at their original precision. The buffer only limits display events. It does not change browser-assisted download behavior or introduce a new dependency.

The live local HTTP fixture reproduced 256 displayed byte-count changes with the old event delivery. Its file completed correctly; the regression failed specifically on the display-update limit. Two earlier custom-protocol fixture attempts did not reach the app's network session and are not evidence of this bug. The final regression uses the existing `Scripts/harbor-fixture-server.py` and checks the actual saved 4 MiB payload and terminal state.

All six focused checks passed in `build/TestResults/Progress116Final.xcresult`: the real HTTP display limit and exact saved payload, burst/slowdown/stall smoothing, callback-frequency independence, direct range recovery, media completion recovery, and torrent pause failure. The same HTTP regression failed with 256 display changes before the buffer was enabled and passed after it was enabled. The next display tick did not alter the completed state. The app compiled and signed as version 1.8.8, build 46. No manual visual check of the list and inspector was made in this run.

## Issue #113: separate Intel and Apple Silicon builds

The issue has a title only, with no body or comments at review. This is a packaging and update-routing change. It does not require separate app identities or separate user-data stores.

### Setup before this change

- The source for the latest published release, v1.8.6, pins Sparkle 2.9.0. Inspection of the actual published DMG confirmed that it contains Sparkle 2.9.0. It also has the same bundle identifier, Developer ID team, public update key, and old feed URL as this source. Sparkle 2.9 supports the `arm64` hardware requirement in an update feed.
- Every current installation reads `https://thsnkhn.github.io/harbor/appcast.xml`. `AppUpdater` uses the standard Sparkle updater without custom feed selection.
- The release script archives one app and publishes one versioned DMG, a `Harbor.dmg` alias, and delta updates. The runtime copy phase includes both processor directories.
- The bundled media tools account for much of the size. Splitting only Harbor's main executable would leave the unused processor's media, torrent, and VPN tools inside the app.

### Migration plan

1. Build Intel (`x86_64`) and Apple Silicon (`arm64`) variants of the same `Harbor.app`. Keep the bundle identifier, signing identity, update-signing key, settings, and Application Support paths unchanged. The update replaces the installed app; it does not create a second app or remove user data.
2. Include only the matching processor's media, torrent, and VPN directories in each package. Build the Safari extension for the matching processor. Keep the shared yt-dlp executable intact unless its one-file packaging is separately verified; it is a universal binary reached through symlinks.
3. Produce clearly named downloads, such as `Harbor-Apple-Silicon.dmg` and `Harbor-Intel.dmg`. Sign and notarize each final package separately. Update manual download links and Homebrew's processor-specific URLs. Do not silently repoint the current generic DMG link to a build that cannot run on the other processor.
4. Keep the existing update-feed URL available for installed apps. For clients verified to use Sparkle 2.9, the transition feed can offer an Intel item and an Apple Silicon item marked with `sparkle:hardwareRequirements=arm64`. Use increasing internal build numbers, with the Apple Silicon item higher than the Intel item for the same visible release, so supported Macs select it without relying on feed order.
5. Give each new variant its own future update-feed URL. Keep the old feed's transition entries available for users who update later. If an older supported release lacks the required Sparkle support, serve a universal transition update on the old feed first; that update must select its future feed from the Mac's hardware before processor-specific releases are offered.
6. Use full update packages for the first split. Add delta updates only after testing each supported source and target combination. Update the release script's current requirement that every release generate delta files.
7. Test an existing universal installation upgrading to each variant, including an Apple Silicon Mac running the old Intel slice through Rosetta. Verify Intel selection on Intel hardware or an Intel CI host. Check settings, history, paused recovery, the Safari extension, media tools, torrent tools, and the next update on each new feed.

Sparkle selects the download, but Harbor currently disables silent automatic installation. Users can keep using the normal **Install Update** flow; they do not need to uninstall Harbor or choose a processor manually during an in-app update.

Reference: [Sparkle publishing and hardware requirements](https://sparkle-project.org/documentation/publishing/). The direct transition above depends on the installed updater supporting that field; the universal transition update is the compatible route when it does not. The local implementation and checks are recorded below. The public feed has not changed.

## PR #114: findings and repair plan

### 31 October implementation decision

The initial repair plan below is superseded. The bundled Aria2 Next source marks `listen-port` as a live global option. `aria2.changeGlobalOption` moves both TCP and UDP listeners without restarting the engine. Use this API for manual changes and Default (6881).

Remove the app's second NAT-PMP client. The engine already owns automatic router mapping through `synchronizePeerDiscovery`, and issue #78 treats automatic VPN discovery as a separate feature. The settings offer Default and Manual. Private VPN disables this control because it cannot accept incoming connections. External VPN users can enter a provider-supplied port; no automatic VPN mapping or external reachability is claimed.

The existing real-engine seeder test now changes ports while a seeder and paused download exist, restores the default, then changes ports with a resumed download. It checks status, payload preservation, discovery, and unchanged engine ownership. With the PR's original restart implementation, the test failed because active transfers became paused and the engine changed. With the live update, it passed. Separate isolated loopback checks passed for both bundled architectures: TCP and UDP sockets moved, default 6881 was restored, and session identity plus active/paused states remained unchanged. The Intel binary ran under Rosetta.

Evidence: `build/TestResults/PR114RestartRegression.xcresult` (expected failure), `build/TestResults/PR114Fixed.xcresult` (three passed), and `build/TestResults/PR114Settings.xcresult` (settings and VPN checks). The initial seven-test selection included four incorrect class names; those four were rerun separately. The source contract is [BitTorrentOptions.cc lines 594–599](https://github.com/QZGao/aria2-next/blob/c8cfa3b6afcecd8e417ae82077045a1e69f53eeb/src/options/BitTorrentOptions.cc#L594-L599).

### Initial audit (29 October)

The PR adds manual port selection and automatic NAT-PMP mapping, a protocol that requests an incoming port from a gateway. The original issue #78 treats automatic discovery as a separate feature. Both modes are included in this PR, so both need validation before merge.

### Merge blockers

1. **Active downloads pause after a port change.** `setListenPort` saves the session and stops the engine. The app starts the engine with `--pause=true`. The new code does not restore the running state. An isolated check with the bundled runtime returned `active` before restart and `paused` after restart. Preserve active downloads and seeders, while keeping user-paused downloads paused. Report a failed save before stopping the engine.
2. **Automatic requests do not bind to the selected VPN interface.** `requestMapping` uses an unbound UDP socket. `configureIncomingPort` accepts any bound interface and derives a `.1` gateway. This can contact a physical router or the wrong tunnel, particularly when the experimental private VPN is active. Require a supported VPN path and bind the request to it. Do not derive a general gateway from any IPv4 address.
3. **Mapping replies do not prove a usable port.** The parser reads only the external port. It accepts a different internal port and a zero-second lease. The mapper also accepts different TCP and UDP port numbers. The current client has no separate advertised-port support, so accept only a valid matching mapping and a live lease. An isolated probe accepted internal port 1 with external port 51234, and accepted a zero-second lease.
4. **A reply from another UDP sender is accepted.** The code sends with `sendto` and reads with `recv`, without checking the sender. A loopback probe returned a success packet from a different source port; the client accepted it. Connect the UDP socket to the selected gateway, or validate the reply source.
5. **The mapped status can remain stale across a network change.** Mapper identity is only the gateway string. A new tunnel with the same gateway does not trigger a new request. Switching from Manual to Automatic also retains the manual listen port until a mapping succeeds. Use the full binding identity and distinguish waiting, mapped, and failed state. Test expiry, reconnect, and mode changes.

### Additional changes

- Use the bundled Aria2 Next contract. Its native `--listen-port` controls TCP and UDP. `--dht-listen-port` is a legacy alias that emits a warning. Both bundled architectures accepted it, so this is not a startup failure. Remove the redundant alias and correct the UI claim that the default is a 6881–6999 range; the bundled runtime reports 6881.
- Review `synchronizePeerDiscovery`: it enables the engine's own `bt-port-mapping` when torrents run. Give one component control of automatic port mapping.
- Use the returned lease lifetime to schedule renewal and clear mapped status at expiry. Handle a temporary renewal failure without an unnecessary engine restart.
- Keep one commit per completed manual field edit. Do not restart the engine when a saved port or lease has not changed.
- Keep shutdown ordering explicit. Stop renewal, finish pending port changes, then stop the engine. Do not let queued settings work start or alter it during shutdown.
- Keep provider support explicit. Proton's documented macOS workflow uses a zero internal-port request; validate this against a live supported Proton session before claiming support for other gateways.

### Work batches

1. Repair manual port changes and active-transfer recovery. Test an active transfer, a paused transfer, and a seeder across one edit and one reset to Default.
2. Repair automatic mapping transport and reply validation. Use a local UDP gateway fixture for wrong senders, malformed packets, mismatched ports, zero or short leases, cancellation, and renewals.
3. Test selected-VPN reconnects, physical-interface rejection, experimental private-VPN interaction, sleep/wake, and shutdown.
4. Verify a live Proton mapping with an external peer. A displayed port or an outbound torrent alone does not prove incoming reachability.
5. Run the focused network/settings tests and inspect the settings UI. Update the PR description to state exactly which provider and runtime were verified.

Protocol references: [RFC 6886](https://www.rfc-editor.org/rfc/rfc6886.html), [Proton manual setup](https://protonvpn.com/support/port-forwarding-manual-setup), and the [bundled runtime source](https://github.com/QZGao/aria2-next/tree/c8cfa3b6afcecd8e417ae82077045a1e69f53eeb). The RFC recommends renewal halfway through the granted lifetime. Proton documents its provider-specific workflow separately.

## PR #118: findings and repair plan

The PR adds five README lines and changes no app code. Both repository links exist. They are maintained by a community contributor, not in the Harbor repository.

The Chrome README says that automatic forwarding cancels a browser download only after Harbor accepts it. Its `host.py` reports success when macOS `/usr/bin/open` returns zero. Harbor then presents an Add Download sheet; the user can dismiss it. `background.js` cancels and erases the Chrome download after that helper response. Thus, helper success does not prove that Harbor accepted the download.

The helper also sends `referrer` in the URL, but Harbor's current URL parser extracts only `url`. The Chrome claim of effective referrer forwarding is not supported by Harbor's receiving path. Its manifest also refers to `icons/icon48.png`, which is absent from the reviewed repository tree. The Firefox repository does not expose the extension or helper source in its default branch. The v1.1.3 helper ZIP was inspected without running it: its helper also reports success when `open` returns zero. The published Firefox add-on itself remains unverified. Neither installer was run.

### Required revision

Use a heading such as **Community Browser Extensions**. Name the maintainer. State that each extension requires a local helper. Do not describe either extension as bundled, official, or verified.

Add one practical limit: automatic forwarding can cancel the browser transfer before the user confirms the download in Harbor. Keep it disabled until an acknowledgement from Harbor exists. Do not repeat the upstream claim that `open` confirms acceptance.

Proposed README text:

> Community extensions by head-less-ghost: Chrome and Firefox. Each requires a local helper. Use manual forwarding; automatic forwarding can cancel the browser download before you confirm it in Harbor.

Keep the repository links in that text. Check the published Firefox add-on and exercise both installations before calling either integration tested. A README-only change needs link and diff checks, not an app build.

## Local implementation and verification

#117 is implemented locally. The storage index saves both new download locations and the exact old recovery directories. A later staging-setting change does not move an existing download. The index imports old records only once, so a new queued download does not become an old internal-storage download after a restart.

The code routes direct partials, browser partials, media work files, and completed-file packages through the saved location. The chosen root is `.harbor-downloads` inside the destination folder, unless the user selects a custom staging folder. The new volume checks reject an absent drive and a different drive at the saved mount path. Existing partial files are not moved. A new download is required to use the new default storage behavior for a previously started legacy transfer.

The existing final-placement journal still keeps an independent payload until the completed record is durable. This safety copy stays on the destination volume for new downloads. On a filesystem without copy-on-write support, final placement can require a second payload-sized allocation on that volume. This change removes the internal-drive dependency; it does not remove that existing safety copy.

| Verification | Result |
| --- | --- |
| Original direct-recovery and completion stores, 20 MB legacy volume, 40 MiB payload | Reproduced Cocoa error 640 / POSIX error 28: no space left |
| Fixed stores, same legacy volume, 96 MB destination volume | Wrote and published all 40 MiB on the destination; device and inode were preserved during completion-package publication |
| Destination detached | Recovery lookup reported unavailable; a new writer was refused |
| Different HFS+ volume mounted at the saved path | Recovery lookup reported unavailable; a new writer was refused |
| Original destination reattached | Recovered the saved five-byte partial through a new process and index load |
| Focused recovery and settings group | 118 passed, zero failed |
| Final affected tests after the migration and cleanup updates | Direct HTTP range continuation, old-record migration, media completion replay, and browser handoff passed: 4 passed |
| Three UI tests | Failed before any download action: automation did not observe Harbor's main window within 15 seconds |
| App build | Compiled and signed; version 1.8.8, build 46 |
| Diff whitespace check | Passed |

The UI attempts first exposed unsigned-runner and local-signing configuration problems. A clean build with the configured certificate resolved those build failures. The final UI run still could not observe the main window; a separate native-app inspection also timed out. Do not treat the direct, browser, or media UI flows as verified. The cause of the window-observation failure is not established.

The broad passing run is saved in `build/TestResults/Storage117.xcresult`. The UI run, with three passing recovery checks and three UI failures, is saved in `build/TestResults/Storage117FinalSigned.xcresult`. The final passing recovery run is saved in `build/TestResults/Storage117FinalCore.xcresult`. Build and result files are local artifacts, not release outputs. No version bump, commit, push, deployment, or GitHub edit was made.

### #113 local implementation

The preparation command now builds and signs two DMGs. Each app contains one processor's Harbor executable, Safari extension, media tools, torrent tools, and VPN tools. The shared yt-dlp executable remains universal to preserve its appended Python payload. It keeps the Developer ID signature and library-loading entitlement used by the old release script.

Both packages keep `Harbor.app`, `co.hapy.harbor`, the signing team, and the update key. No processor suffix is added to settings or data paths. The legacy feed offers both packages. The Apple Silicon entry uses the `arm64` hardware requirement and a higher internal build number. Subsequent checks use a processor-specific feed. An Intel process under Rosetta selects the Apple Silicon feed.

Preparation produces local packages, feeds, signatures, a manifest, and Homebrew URL settings. Publication is a separate explicit command. It requires a clean committed source, unchanged package hashes, completed notarization, completed smoke checks, and an unchanged public feed. The current previews do not meet those publication gates.

| Verification | Result |
| --- | --- |
| Actual v1.8.6 DMG and update signature | Verified with the existing public key; app identity and Sparkle 2.9.0 confirmed |
| Actual v1.8.6 Sparkle framework, new legacy feed | Selected Apple Silicon build 46.2 on native Apple Silicon and through Rosetta; selected Intel build 46.1 with the Intel hardware response simulated |
| New feed selector compiled for both processors | Native Apple Silicon and Rosetta selected the ARM feed; simulated Intel selected the Intel feed |
| Feed generation checks | 2 passed; includes first migration, subsequent releases, exact signature associations, and rejection of wrong processor metadata |
| Focused app and saved-download checks | 4 passed: feed URLs, direct continuation, legacy storage migration, and media completion recovery |
| Both final mounted packages | App and Safari extension match the package processor; all native runtime tools and libraries match; opposite processor runtime directories are absent; strict app signatures verified |
| Shared yt-dlp | The initial 30-second version check timed out; a longer check returned the same version for the source and packaged helper |
| Final packaged tools | All 10 version checks passed: yt-dlp, Deno, ffmpeg, ffprobe, and Aria2 Next for ARM and Intel; Intel checks ran through Rosetta |

The focused Xcode result is `build/TestResults/SplitBuilds113.xcresult`. The 29 October preview packages were about 167 MB for Intel and 118 MB for Apple Silicon, with package builds 46.1 and 46.2. They were removed before the #116 build on 31 October under the one-build rule. Regenerate both packages from the final source before release. Source version remains 1.8.8, build 46.

A real Intel Mac and a complete installed-app upgrade have not been checked. The GUI smoke check, saved-data checks across an actual update, Safari extension check, and engine checks on each processor remain required before publication. No package was notarized, uploaded, or released. No public feed, Homebrew cask, or public download link was changed. See [the release instructions](../RELEASING.md).

## Completion gates

- #117: pass the storage and recovery checks above; record what was tested on real disposable volumes and what remains a manual browser/media check.
- #116: implemented locally; six focused checks passed, including the real HTTP regression. A manual visual check of the list and inspector remains before release.
- #113: local split packages and update routing are implemented. Complete the real Intel and installed-app upgrade checks, smoke checks, and notarization before changing the public feed.
- #114: merged on 31 October as `5a3484e`. Manual/default port changes use the live engine API. The duplicate NAT-PMP client was removed. Seven focused checks passed; both bundled engines passed the TCP/UDP socket check. External VPN/router reachability is not claimed.
- #118: merged on 31 October as `68ad3cf`. Community ownership, local helpers, and the automatic-handoff limitation are documented. The extensions remain unverified at runtime.
- Review each final diff separately. Preserve contributor attribution when integrating their work. Refresh GitHub state before any later merge.

## 31 October merge result

Both open PRs were repaired on their contributor branches, then merged with their commit history intact. GitHub reported no open PRs after the merges. The published release is still `v1.8.6`; no release or update feed was changed.

Local `main` is at `68ad3cf8dd4504ce17caa3f551613f21b99c8946`. The uncommitted #113, #116, and #117 work remains in `/Users/tahseen/Developer/Harbor`. A backup stash named `Backup local issues 113 116 117 before merging reviewed PRs 114 118` was retained. All ten untracked files and fourteen files without overlapping edits matched the backup byte for byte. The three overlapping files were reviewed. The single conflict in shutdown was resolved by cancelling progress updates before waiting for the pending port change.

The isolated review checkout is clean at `/Users/tahseen/.codex/worktrees/harbor-pr114/Harbor`. Codex refused to archive it because it now treats it as the chat's primary checkout. Continue local issue work in `/Users/tahseen/Developer/Harbor`.

Final combined validation passed: eleven tests in `build/TestResults/PRMergeCombined.xcresult` and the real HTTP progress test in `build/TestResults/PRMergeHTTPProgress.xcresult`. These cover incoming ports, seeding/paused states, network binding, VPN startup blocking, direct/media recovery, processor update feeds, and progress display. The single local app is `build/HarborDerivedData/Build/Products/Debug/Harbor.app`, version 1.8.8 (46). No visual settings check or external VPN reachability test was performed during this merge.
