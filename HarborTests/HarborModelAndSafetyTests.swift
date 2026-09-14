import Foundation
import Observation
import os
import XCTest
@testable import Harbor

@MainActor
final class HarborModelAndSafetyTests: XCTestCase {
    func testSingleDownloadActionsDoNotObserveOtherDownloadsProgress() {
        let center = HarborPreviewFixtures.makeCenter()
        let target = center.downloads[0]
        let other = center.downloads[1]
        let changed = OSAllocatedUnfairLock(initialState: false)

        withObservationTracking {
            XCTAssertTrue(center.canPauseDownloads(ids: [target.id]))
        } onChange: {
            changed.withLock { $0 = true }
        }
        other.updatedAt = .now
        other.progress = 0.75
        XCTAssertFalse(changed.withLock { $0 })

        target.status = .paused
        XCTAssertTrue(changed.withLock { $0 })
    }

    func testSingleDownloadActionsStillRespectSearchAndFilter() {
        let center = HarborPreviewFixtures.makeCenter()
        let target = center.downloads[0]
        XCTAssertTrue(center.canPauseDownloads(ids: [target.id]))
        center.searchText = "no-matching-download"
        XCTAssertFalse(center.canPauseDownloads(ids: [target.id]))
        center.searchText = ""
        center.selectedFilter = .completed
        XCTAssertFalse(center.canPauseDownloads(ids: [target.id]))
    }

    func testSpeedColumnShowsOnlyOverridesThatDifferFromGlobalLimits() {
        let settings = HarborPreviewFixtures.makeSettings()
        let center = DownloadCenter(settings: settings)
        let item = HarborPreviewFixtures.sampleDownloads()[0]
        settings.trafficMode = .unlimited
        XCTAssertNil(center.differingTrafficModeOverride(for: item))

        item.downloadLimitOverride = .unlimited
        item.uploadLimitOverride = .unlimited
        XCTAssertNil(center.differingTrafficModeOverride(for: item))

        item.downloadLimitOverride = .limited(kilobytesPerSecond: 5 * 1_024)
        item.uploadLimitOverride = .limited(kilobytesPerSecond: 1_024)
        XCTAssertEqual(center.differingTrafficModeOverride(for: item), .balanced)
        settings.trafficMode = .balanced
        XCTAssertNil(center.differingTrafficModeOverride(for: item))

        item.uploadLimitOverride = .limited(kilobytesPerSecond: 100)
        XCTAssertEqual(center.differingTrafficModeOverride(for: item), .custom)
        item.downloadLimitOverride = .inherit
        item.uploadLimitOverride = .inherit
        XCTAssertNil(center.differingTrafficModeOverride(for: item))
    }

    func testHarborURLSchemeIsRegistered() throws {
        let urlTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        )
        let schemes = urlTypes
            .compactMap { $0["CFBundleURLSchemes"] as? [String] }
            .flatMap { $0 }

        XCTAssertTrue(schemes.contains("harbor"))
    }

    func testExternalHTTPSourcePrefillsAddSheetWithDefaultDestination() async throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborExternalSourceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let settings = HarborPreviewFixtures.makeSettings()
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(
                directoryURL: testRoot.appendingPathComponent("Persistence", isDirectory: true)
            ),
            directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery", isDirectory: true),
            completedHandoffDirectoryURL: testRoot.appendingPathComponent("Handoffs", isDirectory: true),
            browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery", isDirectory: true),
            managedTorrentSourceStore: ManagedTorrentSourceStore(
                fileManager: fileManager,
                directoryURL: testRoot.appendingPathComponent("ManagedTorrents", isDirectory: true)
            ),
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
            )
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/file.zip"))

        center.receiveExternalAddSources([sourceURL])
        await center.initializeIfNeeded()

        let draft = try XCTUnwrap(center.addSheetDraft)
        XCTAssertEqual(draft.entryMode, .linkOrMagnet)
        XCTAssertEqual(draft.sourceURLText, sourceURL.absoluteString)
        XCTAssertEqual(draft.destinationFolderURL, settings.defaultDestinationURL)
        await center.shutdownForTermination()
    }

    func testDownloadedPayloadClassifierDetectsTorrentResponses() {
        let extensionlessURL = URL(string: "https://example.com/download?id=42")!

        XCTAssertTrue(
            DownloadedPayloadClassifier.isTorrent(
                sourceURL: extensionlessURL,
                suggestedFilename: nil,
                responseMimeType: "application/x-bittorrent"
            )
        )
        XCTAssertTrue(
            DownloadedPayloadClassifier.isTorrent(
                sourceURL: extensionlessURL,
                suggestedFilename: "Linux.torrent",
                responseMimeType: "application/octet-stream"
            )
        )
        XCTAssertTrue(
            DownloadedPayloadClassifier.isTorrent(
                sourceURL: URL(string: "https://example.com/linux.torrent")!,
                suggestedFilename: nil,
                responseMimeType: nil
            )
        )
        XCTAssertFalse(
            DownloadedPayloadClassifier.isTorrent(
                sourceURL: extensionlessURL,
                suggestedFilename: "archive.zip",
                responseMimeType: "application/octet-stream"
            )
        )
        XCTAssertFalse(
            DownloadedPayloadClassifier.isTorrent(
                sourceURL: extensionlessURL,
                suggestedFilename: "error.torrent",
                responseMimeType: "application/x-bittorrent",
                statusCode: 404
            )
        )
    }

    func testTorrentShareRatioPersistsWithUploadedBytes() throws {
        let item = DownloadItem(
            sourceURL: URL(fileURLWithPath: "/tmp/example.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .seeding,
            progress: 1,
            bytesWritten: 1_000,
            expectedBytes: 1_000,
            uploadedBytes: 1_500
        )

        XCTAssertEqual(item.shareRatio, 1.5)

        let restoredItem = DownloadItem(record: item.makeRecord())
        XCTAssertEqual(restoredItem.uploadedBytes, 1_500)
        XCTAssertEqual(restoredItem.shareRatio, 1.5)
    }

    func testDownloadedTorrentHandoffReusesTheDirectDownloadRow() {
        let sourceURL = URL(string: "https://example.com/download?id=42")!
        let item = DownloadItem(
            sourceURL: sourceURL,
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "metadata.torrent",
            destinationFolderPath: "/tmp",
            fileLocationPath: "/tmp/metadata.torrent",
            status: .downloading,
            progress: 1,
            bytesWritten: 512,
            expectedBytes: 512,
            finishedAt: .now,
            resumeData: Data([0x01]),
            taskIdentifier: 7,
            backendIdentifier: "old-backend",
            completionNotificationDelivered: true,
            activityEvents: [
                DownloadActivityEvent(kind: .added),
                DownloadActivityEvent(kind: .started)
            ]
        )
        let originalID = item.id
        let originalActivity = item.activityEvents
        item.requestHeaders = [
            RequestHeader(name: "Authorization", value: "Bearer source-secret"),
            RequestHeader(name: "X-API-Key", value: "source-key")
        ]

        DownloadCenter.configureDownloadedTorrentHandoff(
            item,
            shouldSeedAfterDownload: true
        )

        XCTAssertEqual(item.id, originalID)
        XCTAssertEqual(item.sourceURL, sourceURL)
        XCTAssertEqual(item.sourceKind, .torrentFile)
        XCTAssertEqual(item.backend, .aria2)
        XCTAssertTrue(item.requestHeaders.isEmpty)
        XCTAssertEqual(item.status, .preparing)
        XCTAssertEqual(item.activityEvents, originalActivity)
        XCTAssertNil(item.preferredFilename)
        XCTAssertNil(item.fileLocationPath)
        XCTAssertNil(item.resumeData)
        XCTAssertNil(item.taskIdentifier)
        XCTAssertNil(item.backendIdentifier)
        XCTAssertEqual(item.progress, 0)
        XCTAssertEqual(item.bytesWritten, 0)
        XCTAssertEqual(item.expectedBytes, 0)
        XCTAssertNil(item.finishedAt)
        XCTAssertTrue(item.shouldSeedAfterDownload)
        XCTAssertFalse(item.completionNotificationDelivered)
    }

    func testTransferLimitOverrideResolution() {
        XCTAssertEqual(
            TransferLimitOverride.inherit.resolvedBytesPerSecond(inheriting: 4_096),
            4_096
        )
        XCTAssertNil(
            TransferLimitOverride.unlimited.resolvedBytesPerSecond(inheriting: 4_096)
        )
        XCTAssertEqual(
            TransferLimitOverride.limited(kilobytesPerSecond: 500)
                .resolvedBytesPerSecond(inheriting: nil),
            512_000
        )
        XCTAssertEqual(
            TransferLimitOverride.limited(kilobytesPerSecond: 0)
                .resolvedBytesPerSecond(inheriting: nil),
            1_024
        )
    }

    func testDirectDownloadLimitPrecedenceKeepsGlobalCapForUnlimitedItem() {
        let settings = DownloadTransferSettings(
            maxConcurrentDownloads: 3,
            globalSpeedLimitBytesPerSecond: 900_000,
            perDownloadSpeedLimitBytesPerSecond: 500_000,
            globalUploadSpeedLimitBytesPerSecond: nil,
            perDownloadUploadSpeedLimitBytesPerSecond: nil,
            perDownloadConnectionCount: 4
        )

        XCTAssertEqual(
            DownloadCoordinator.effectiveSpeedLimit(
                activeTransferCount: 3,
                transferSettings: settings,
                speedLimitOverride: .unlimited
            ),
            300_000
        )
        XCTAssertEqual(
            DownloadCoordinator.effectiveSpeedLimit(
                activeTransferCount: 1,
                transferSettings: settings,
                speedLimitOverride: .limited(kilobytesPerSecond: 200)
            ),
            200 * 1_024
        )
    }

    func testDirectDownloadThrottlePreservesLowRateByteDebt() throws {
        let settings = DownloadTransferSettings(
            maxConcurrentDownloads: 1,
            globalSpeedLimitBytesPerSecond: nil,
            perDownloadSpeedLimitBytesPerSecond: 1_024,
            globalUploadSpeedLimitBytesPerSecond: nil,
            perDownloadUploadSpeedLimitBytesPerSecond: nil,
            perDownloadConnectionCount: 1
        )

        let delay = try XCTUnwrap(DownloadCoordinator.throttleDelay(
            deltaBytes: 64 * 1_024,
            elapsed: 1,
            activeTransferCount: 1,
            transferSettings: settings,
            speedLimitOverride: .inherit
        ))

        XCTAssertEqual(delay, 63, accuracy: 0.001)
    }

    func testAriaPerTorrentOptionsUseAuthoritativeItemLimits() {
        let settings = DownloadTransferSettings(
            maxConcurrentDownloads: 3,
            globalSpeedLimitBytesPerSecond: 900_000,
            perDownloadSpeedLimitBytesPerSecond: 500_000,
            globalUploadSpeedLimitBytesPerSecond: 300_000,
            perDownloadUploadSpeedLimitBytesPerSecond: 200_000,
            perDownloadConnectionCount: 6
        )
        let options = Aria2TorrentService.perDownloadOptions(
            settings,
            transferOptions: TorrentTransferOptions(
                downloadLimitBytesPerSecond: nil,
                uploadLimitBytesPerSecond: 75_000,
                shouldSeed: true
            )
        )

        XCTAssertEqual(options["max-download-limit"], "0")
        XCTAssertEqual(options["max-upload-limit"], "75000")
        XCTAssertEqual(options["max-connection-per-server"], "6")
        XCTAssertEqual(options["seed-ratio"], "0.0")
        XCTAssertNil(options["seed-time"])

        let ratioLimitedOptions = Aria2TorrentService.perDownloadOptions(
            settings,
            transferOptions: TorrentTransferOptions(
                downloadLimitBytesPerSecond: nil,
                uploadLimitBytesPerSecond: nil,
                shouldSeed: true,
                seedRatioLimit: 2
            )
        )
        XCTAssertEqual(ratioLimitedOptions["seed-ratio"], "2.0")
    }

    func testMediaDownloadArgumentsKeepAutomaticAndExactFormatPathsSeparate() throws {
        let runtime = MediaRuntimeResolution(
            ytDlpURL: URL(fileURLWithPath: "/tmp/yt-dlp"),
            denoURL: URL(fileURLWithPath: "/tmp/deno"),
            ffmpegURL: URL(fileURLWithPath: "/tmp/ffmpeg"),
            ffprobeURL: URL(fileURLWithPath: "/tmp/ffprobe")
        )
        let formatFixture = makeMediaFormatTestFixture()
        let sourceURL = formatFixture.sourceURL
        let destinationURL = URL(fileURLWithPath: "/tmp/downloads", isDirectory: true)
        let temporaryURL = URL(fileURLWithPath: "/tmp/media", isDirectory: true)
        let completionReceiptURL = URL(
            fileURLWithPath: "/tmp/media%owned/final-paths.jsonl"
        )

        let customArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: nil,
            formatPreference: .bestAvailable,
            customFilename: " My/video: 100% %(title)s ",
            completionReceiptURL: completionReceiptURL,
            speedLimitBytesPerSecond: nil
        )
        let customOutputIndex = try XCTUnwrap(customArguments.firstIndex(of: "--output"))
        XCTAssertEqual(customArguments[customOutputIndex + 1], "My-video- 100%% %%(title)s.%(ext)s")
        XCTAssertTrue(DownloadSourceKind.mediaURL.supportsCustomFilename)
        XCTAssertFalse(DownloadSourceKind.torrentFile.supportsCustomFilename)
        XCTAssertFalse(DownloadSourceKind.magnetLink.supportsCustomFilename)

        let limitedArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: nil,
            formatPreference: .bestAvailable,
            completionReceiptURL: completionReceiptURL,
            speedLimitBytesPerSecond: 345_678
        )
        let unlimitedArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: nil,
            formatPreference: .bestAvailable,
            completionReceiptURL: completionReceiptURL,
            speedLimitBytesPerSecond: nil
        )
        let outputConflictIdentifier = UUID()
        let collisionSafeArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: nil,
            formatPreference: .bestAvailable,
            outputConflictIdentifier: outputConflictIdentifier,
            completionReceiptURL: completionReceiptURL,
            speedLimitBytesPerSecond: nil
        )

        let limitIndex = try XCTUnwrap(limitedArguments.firstIndex(of: "--limit-rate"))
        XCTAssertEqual(limitedArguments[limitedArguments.index(after: limitIndex)], "345678")
        XCTAssertTrue(limitedArguments.contains("--progress"))
        XCTAssertTrue(unlimitedArguments.contains("--progress"))
        XCTAssertFalse(unlimitedArguments.contains("--limit-rate"))
        XCTAssertFalse(limitedArguments.contains("--format"))
        XCTAssertFalse(unlimitedArguments.contains("--format"))
        let collisionOutputIndex = try XCTUnwrap(
            collisionSafeArguments.firstIndex(of: "--output")
        )
        XCTAssertEqual(
            collisionSafeArguments[collisionSafeArguments.index(after: collisionOutputIndex)],
            "%(title).180B [%(id)s] [Harbor \(outputConflictIdentifier.uuidString)].%(ext)s"
        )
        let concurrentDownloadID = UUID()
        XCTAssertNil(
            MediaDownloadService.outputIdentifier(
                requested: nil,
                downloadID: concurrentDownloadID,
                hasCompetingDestination: false
            )
        )
        XCTAssertEqual(
            MediaDownloadService.outputIdentifier(
                requested: nil,
                downloadID: concurrentDownloadID,
                hasCompetingDestination: true
            ),
            concurrentDownloadID
        )
        XCTAssertEqual(
            MediaDownloadService.outputIdentifier(
                requested: outputConflictIdentifier,
                downloadID: concurrentDownloadID,
                hasCompetingDestination: true
            ),
            outputConflictIdentifier
        )

        let retryValues = zip(limitedArguments, limitedArguments.dropFirst())
            .filter { $0.0 == "--retry-sleep" }
            .map(\.1)
        XCTAssertEqual(
            retryValues,
            [
                "http:exp=2:60",
                "fragment:exp=2:60",
                "file_access:exp=2:60",
                "extractor:exp=2:60"
            ]
        )
        func value(after option: String) -> String? {
            guard let optionIndex = limitedArguments.firstIndex(of: option) else {
                return nil
            }

            let valueIndex = limitedArguments.index(after: optionIndex)
            return limitedArguments.indices.contains(valueIndex)
                ? limitedArguments[valueIndex]
                : nil
        }
        XCTAssertEqual(value(after: "--retries"), "10")
        XCTAssertEqual(value(after: "--fragment-retries"), "10")
        XCTAssertEqual(value(after: "--file-access-retries"), "3")
        XCTAssertEqual(value(after: "--extractor-retries"), "3")
        XCTAssertEqual(value(after: "--js-runtimes"), "deno:/tmp/deno")
        let printToFileIndex = try XCTUnwrap(
            limitedArguments.firstIndex(of: "--print-to-file")
        )
        XCTAssertFalse(limitedArguments.contains("--print"))
        XCTAssertEqual(
            limitedArguments[limitedArguments.index(after: printToFileIndex)],
            "after_move:harbor-file:%(filepath)j"
        )
        let receiptPathIndex = limitedArguments.index(
            printToFileIndex,
            offsetBy: 2
        )
        XCTAssertEqual(
            limitedArguments[receiptPathIndex],
            "/tmp/media%%owned/final-paths.jsonl"
        )

        let selectedArguments = try MediaDownloadService.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationURL,
            temporaryFolder: temporaryURL,
            metadata: formatFixture.metadata.persistenceSnapshot,
            formatPreference: .specific(formatFixture.selection),
            completionReceiptURL: temporaryURL.appendingPathComponent("final-paths.jsonl"),
            speedLimitBytesPerSecond: 345_678
        )

        let formatIndex = try XCTUnwrap(selectedArguments.firstIndex(of: "--format"))
        XCTAssertEqual(selectedArguments[selectedArguments.index(after: formatIndex)], "137+140")
        let mergeIndex = try XCTUnwrap(selectedArguments.firstIndex(of: "--merge-output-format"))
        XCTAssertEqual(selectedArguments[selectedArguments.index(after: mergeIndex)], "mp4")
        let selectedLimitIndex = try XCTUnwrap(selectedArguments.firstIndex(of: "--limit-rate"))
        XCTAssertEqual(
            selectedArguments[selectedArguments.index(after: selectedLimitIndex)],
            "345678"
        )

        XCTAssertEqual(
            formatFixture.selection.displaySummary,
            "1080p • MP4 • AVC1 + English (Original)"
        )
        let capabilities = formatFixture.metadata.capabilities
        let preference = MediaDownloadFormatPreference.specific(formatFixture.selection)
        XCTAssertEqual(
            capabilities.preference(selectingPrimaryFormatID: "137")?.selection,
            formatFixture.selection
        )
        XCTAssertEqual(capabilities.preference(selectingPrimaryFormatID: nil), .bestAvailable)
        let unavailable = MediaDownloadFormatPreference.specific(
            MediaDownloadFormatSelection(legacySelector: "missing")
        )
        XCTAssertEqual(
            [preference, unavailable].map { capabilities.isSelectionUnavailable(in: $0) },
            [false, true]
        )
        XCTAssertEqual(capabilities.unavailablePrimaryFormatID(in: unavailable), "missing")
        XCTAssertEqual(
            MediaDownloadFormatPreference.specific(formatFixture.selection)
                .initialExpectedBytes(metadataEstimate: 243_768_398),
            formatFixture.selection.estimatedBytes
        )
        XCTAssertEqual(
            MediaDownloadFormatPreference.bestAvailable
                .initialExpectedBytes(metadataEstimate: 243_768_398),
            243_768_398
        )
    }

    func testMediaRecordPersistsSelectionWithoutFormatCatalog() throws {
        let fixture = makeMediaFormatTestFixture()
        let item = DownloadItem(
            sourceURL: fixture.sourceURL,
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: "/tmp/downloads",
            status: .paused,
            mediaMetadata: fixture.metadata,
            mediaFormatPreference: .specific(fixture.selection)
        )

        let record = item.makeRecord()

        XCTAssertEqual(record.mediaMetadata?.capabilities, .unavailable)
        XCTAssertEqual(record.mediaFormatPreference, .specific(fixture.selection))
        XCTAssertEqual(
            item.mediaMetadata?.capabilities.formatOptions,
            [fixture.videoFormat, fixture.audioFormat]
        )

        let encodedRecord = try JSONEncoder().encode(record)
        XCTAssertFalse(String(decoding: encodedRecord, as: UTF8.self).contains("formatOptions"))
    }

    func testUnavailableExactMediaFormatHasDedicatedError() {
        XCTAssertEqual(
            MediaDownloadErrorClassifier.message(
                from: "ERROR: [youtube] Requested format is not available"
            ),
            MediaDownloadErrorClassifier.selectedFormatUnavailableMessage
        )
    }

    func testRequestHeaderValidationAndSensitiveDetection() {
        XCTAssertNil(RequestHeader(name: "User-Agent", value: "Harbor\t1.0").validationIssue)
        XCTAssertEqual(RequestHeader(name: "Bad Header", value: "value").validationIssue, .invalidName)

        for value in ["line\nbreak", "line\rbreak", "nul\u{0}byte", "delete\u{7F}byte"] {
            XCTAssertEqual(
                RequestHeader(name: "X-Test", value: value).validationIssue,
                .invalidValue
            )
        }

        XCTAssertTrue(RequestHeader(name: "cookie", value: "session=secret").triggersSensitiveTorrentWarning)
        XCTAssertTrue(RequestHeader(name: "AUTHORIZATION", value: "Bearer secret").triggersSensitiveTorrentWarning)
        XCTAssertFalse(RequestHeader(name: "Referer", value: "https://example.com").triggersSensitiveTorrentWarning)
    }

    func testRequestHeadersApplyOnlyToSameOriginRedirects() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/source"))
        let headers = [
            RequestHeader(name: "Authorization", value: "Bearer secret"),
            RequestHeader(name: "X-Client", value: "Harbor")
        ]

        var sameOriginRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/redirected"))
        )
        headers.apply(toSameOriginRedirect: &sameOriginRequest, originatingAt: sourceURL)
        XCTAssertEqual(
            sameOriginRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer secret"
        )
        XCTAssertEqual(sameOriginRequest.value(forHTTPHeaderField: "X-Client"), "Harbor")

        var crossOriginRequest = URLRequest(
            url: try XCTUnwrap(URL(string: "https://downloads.example.net/file"))
        )
        headers.apply(toSameOriginRedirect: &crossOriginRequest, originatingAt: sourceURL)
        XCTAssertNil(crossOriginRequest.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(crossOriginRequest.value(forHTTPHeaderField: "X-Client"))
    }

    func testCrossOriginRedirectsRemoveAlreadyPopulatedCustomHeaders() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/source"))
        let headers = [
            RequestHeader(name: "Authorization", value: "Bearer secret"),
            RequestHeader(name: "Cookie", value: "session=secret"),
            RequestHeader(name: "X-API-Key", value: "secret-key"),
            RequestHeader(name: "User-Agent", value: "Harbor")
        ]

        for redirectedURL in [
            "https://downloads.example.net/file",
            "http://example.com/file",
            "https://example.com:8443/file"
        ] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: redirectedURL)))
            for header in headers {
                request.setValue(header.value, forHTTPHeaderField: header.name.lowercased())
            }
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")

            headers.apply(toSameOriginRedirect: &request, originatingAt: sourceURL)

            for header in headers {
                XCTAssertNil(
                    request.value(forHTTPHeaderField: header.name),
                    "\(header.name) was forwarded to \(redirectedURL)"
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
        }
    }

    func testFreshDownloadIgnoresCustomRangeHeaders() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/archive.bin"))
        let request = DirectDownloadResponsePolicy.request(
            sourceURL: sourceURL,
            recovery: nil,
            requestHeaders: [
                RequestHeader(name: "Range", value: "bytes=100-"),
                RequestHeader(name: "If-Range", value: "\"stale-etag\""),
                RequestHeader(name: "X-Client", value: "Harbor")
            ]
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Range"))
        XCTAssertNil(request.value(forHTTPHeaderField: "If-Range"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client"), "Harbor")
    }

    func testDirectDownloadRequestPreservesHeadersAndRecoveryInvariants() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://example.com/archive.bin"))
        let recovery = DirectDownloadRecoverySnapshot(
            bytesWritten: 128,
            metadata: DirectDownloadRecoveryMetadata(
                sourceURL: sourceURL,
                entityTag: "\"current-etag\"",
                lastModified: nil,
                expectedBytes: 1_024,
                suggestedFilename: nil,
                mimeType: nil
            )
        )

        let request = DirectDownloadResponsePolicy.request(
            sourceURL: sourceURL,
            recovery: recovery,
            requestHeaders: [
                RequestHeader(name: "X-Client", value: "Harbor"),
                RequestHeader(name: "Accept-Encoding", value: "gzip"),
                RequestHeader(name: "Range", value: "bytes=0-1"),
                RequestHeader(name: "If-Range", value: "\"stale-etag\"")
            ]
        )

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Client"), "Harbor")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=128-")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Range"), "\"current-etag\"")
    }

    func testDownloadRecordRoundTripPreservesHeadersAndTorrentOptions() throws {
        let headers = [
            RequestHeader(name: "User-Agent", value: "Harbor"),
            RequestHeader(name: "Cookie", value: "session=secret")
        ]
        let item = DownloadItem(
            sourceURL: URL(fileURLWithPath: "/tmp/source.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .paused,
            requestHeaders: headers,
            downloadLimitOverride: .limited(kilobytesPerSecond: 512),
            uploadLimitOverride: .unlimited,
            torrentFingerprint: "fingerprint",
            managedTorrentSourcePath: "/tmp/managed.torrent",
            shouldSeedAfterDownload: true
        )

        let data = try JSONEncoder().encode(item.makeRecord())
        let restored = try JSONDecoder().decode(DownloadRecord.self, from: data)

        XCTAssertEqual(restored.requestHeaders, headers)
        XCTAssertEqual(restored.downloadLimitOverride, .limited(kilobytesPerSecond: 512))
        XCTAssertEqual(restored.uploadLimitOverride, .unlimited)
        XCTAssertEqual(restored.torrentFingerprint, "fingerprint")
        XCTAssertEqual(restored.managedTorrentSourcePath, "/tmp/managed.torrent")
        XCTAssertTrue(restored.shouldSeedAfterDownload)
    }

    func testQuickLookRequiresCompletedExistingLocalFiles() throws {
        let suiteName = "HarborTests.QuickLook.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Harbor-Quick-Look-\(UUID().uuidString).txt")
        try Data("Preview".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let previewService = FakeQuickLookPreviewService()
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            quickLookPreviewService: previewService
        )
        let item = makeTorrentItem(
            sourceURL: URL(fileURLWithPath: "/tmp/preview.torrent"),
            sourceKind: .torrentFile,
            fileLocationPath: fileURL.path
        )
        center.downloads = [item]
        center.selectedDownloadID = item.id

        XCTAssertTrue(center.canQuickLookSelectedDownloads)

        center.quickLookSelectedDownloads()

        XCTAssertEqual(previewService.previewedURLs, [fileURL])
        XCTAssertEqual(item.status, .completed)

        item.status = .paused
        XCTAssertFalse(center.canQuickLookSelectedDownloads)

        item.status = .completed
        try FileManager.default.removeItem(at: fileURL)
        XCTAssertFalse(center.canQuickLookSelectedDownloads)

        center.quickLookSelectedDownloads()
        XCTAssertEqual(center.activeAlert?.title, "Quick Look Unavailable")
    }

    func testLegacyCompletedTorrentDoesNotSeed() throws {
        let record = try legacyTorrentRecord(status: .completed)

        XCTAssertTrue(record.requestHeaders.isEmpty)
        XCTAssertFalse(record.shouldSeedAfterDownload)
        XCTAssertFalse(record.removeOriginalTorrentAfterImport)
        XCTAssertTrue(record.completionNotificationDelivered)
        XCTAssertEqual(record.downloadLimitOverride, .inherit)
        XCTAssertEqual(record.uploadLimitOverride, .inherit)
        XCTAssertTrue(record.torrentPayloadPaths.isEmpty)
    }

    func testLegacyUnfinishedTorrentSeeds() throws {
        let record = try legacyTorrentRecord(status: .downloading)

        XCTAssertTrue(record.shouldSeedAfterDownload)
    }

    func testTorrentDisplayNamePrefersSemanticMetadata() {
        let item = makeTorrentItem(
            sourceURL: URL(fileURLWithPath: "/tmp/ubuntu.torrent"),
            sourceKind: .torrentFile,
            metadataName: "Ubuntu 26.04",
            fileLocationPath: "/tmp/download.html"
        )

        XCTAssertEqual(item.displayName, "Ubuntu 26.04")
    }

    func testTorrentDisplayNameUsesTorrentFilenameBeforePayloadFilename() {
        let item = makeTorrentItem(
            sourceURL: URL(fileURLWithPath: "/tmp/ubuntu-desktop.torrent"),
            sourceKind: .torrentFile,
            fileLocationPath: "/tmp/download.html"
        )

        XCTAssertEqual(item.displayName, "ubuntu-desktop")
    }

    func testMagnetDisplayNameWinsOverPayloadFilename() throws {
        let sourceURL = try XCTUnwrap(
            URL(string: "magnet:?xt=urn:btih:ABC123&dn=Ubuntu%2026.04")
        )
        let item = makeTorrentItem(
            sourceURL: sourceURL,
            sourceKind: .magnetLink,
            fileLocationPath: "/tmp/download.html"
        )

        XCTAssertEqual(item.displayName, "Ubuntu 26.04")
    }

    func testSeedingStatusIsActiveButDoesNotConsumeDownloadConcurrency() {
        let item = makeTorrentItem(
            sourceURL: URL(fileURLWithPath: "/tmp/ubuntu.torrent"),
            sourceKind: .torrentFile,
            status: .seeding
        )

        XCTAssertFalse(DownloadStatus.seeding.isTerminal)
        XCTAssertFalse(DownloadStatus.seeding.isRunning)
        XCTAssertTrue(DownloadStatus.allCases.contains(.seeding))
        XCTAssertTrue(DownloadFilter.active.includes(item))
        XCTAssertTrue(item.canPause)
    }

    func testPayloadResolutionRejectsRootAndTraversalAndKeepsExactPayloadPaths() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destinationURL = rootURL.appendingPathComponent("destination", isDirectory: true)
        let outsideURL = rootURL.appendingPathComponent("outside.bin")
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let resolution = DownloadDataRemovalService().resolvePayloadURLs(
            destinationFolderPath: destinationURL.path,
            payloadPaths: [
                "Collection/one.bin",
                "Collection/two.bin",
                destinationURL.appendingPathComponent("single.iso").path,
                destinationURL.path,
                "../outside.bin",
                outsideURL.path
            ]
        )

        XCTAssertEqual(
            resolution.safeURLs.map(\.path),
            [
                destinationURL.appendingPathComponent("Collection/one.bin").path,
                destinationURL.appendingPathComponent("Collection/two.bin").path,
                destinationURL.appendingPathComponent("single.iso").path
            ]
        )
        XCTAssertEqual(
            Set(resolution.rejectedPaths),
            Set([destinationURL.path, "../outside.bin", outsideURL.path])
        )
    }

    struct ChildMediaAttemptReceipt: Encodable {
        let version: Int
        let downloadID: UUID
        let attemptIdentifier: UUID
        let sourceURL: URL
        let destinationFolderPath: String
        let isCollection: Bool
        let preexistingDestinationFiles: [
            String: MediaDownloadService.RegularFileIdentity
        ]
        let createdAt: Date
    }

    func writeChildOwnedMediaCompletionEvidence(
        recoveryFolder: URL,
        downloadID: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        destinationFolder: URL,
        completedURLs: [URL],
        isCollection: Bool = false,
        includeSuccessMarker: Bool = true,
        preexistingDestinationFiles: [
            String: MediaDownloadService.RegularFileIdentity
        ] = [:]
    ) throws {
        let receipt = ChildMediaAttemptReceipt(
            version: 1,
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            destinationFolderPath: destinationFolder.standardizedFileURL.path,
            isCollection: isCollection,
            preexistingDestinationFiles: preexistingDestinationFiles,
            createdAt: .now
        )
        try JSONEncoder().encode(receipt).write(
            to: recoveryFolder.appendingPathComponent(".harbor-attempt.json"),
            options: .atomic
        )
        let pathLines = try completedURLs.map { url in
            let encodedPath = try XCTUnwrap(
                String(data: JSONEncoder().encode(url.path), encoding: .utf8)
            )
            return "harbor-file:\(encodedPath)"
        }.joined(separator: "\n") + "\n"
        try Data(pathLines.utf8).write(
            to: recoveryFolder.appendingPathComponent(".harbor-final-paths.jsonl"),
            options: .atomic
        )
        if includeSuccessMarker {
            try Data("\(attemptIdentifier.uuidString)\n".utf8).write(
                to: recoveryFolder.appendingPathComponent(".harbor-process-succeeded"),
                options: .atomic
            )
        }
    }

    func makeCompletedHandoff(
        payloadURL: URL,
        handoffDirectoryURL: URL,
        downloadID: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        owner: CompletedDownloadHandoffOwner = .direct,
        suggestedFilename: String? = nil,
        statusCode: Int? = 200,
        mimeType: String? = "application/octet-stream"
    ) throws -> CompletedDownloadHandoff {
        let byteCount = Int64(try Data(contentsOf: payloadURL).count)
        return try CompletedDownloadHandoffStore(directoryURL: handoffDirectoryURL).publish(
            payloadAt: payloadURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: downloadID,
                attemptIdentifier: attemptIdentifier,
                owner: owner,
                sourceURL: sourceURL,
                statusCode: statusCode,
                mimeType: mimeType,
                suggestedFilename: suggestedFilename,
                actualBytes: byteCount,
                expectedBytes: byteCount
            )
        )
    }

    func legacyTorrentRecord(status: DownloadStatus) throws -> DownloadRecord {
        let record = DownloadRecord(
            id: UUID(),
            sourceURL: URL(fileURLWithPath: "/tmp/legacy.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            fileLocationPath: nil,
            status: status,
            progress: 0,
            bytesWritten: 0,
            expectedBytes: 0,
            createdAt: .now,
            startedAt: nil,
            finishedAt: nil,
            updatedAt: .now,
            lastError: nil,
            resumeData: nil,
            backendIdentifier: nil,
            metadataName: nil
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any]
        )
        [
            "requestHeaders",
            "downloadLimitOverride",
            "uploadLimitOverride",
            "requiresMediaRecoveryReset",
            "torrentFingerprint",
            "torrentSourceFingerprint",
            "managedTorrentSourcePath",
            "torrentPayloadPaths",
            "uploadedBytes",
            "shouldSeedAfterDownload",
            "removeOriginalTorrentAfterImport",
            "completionNotificationDelivered"
        ].forEach { object.removeValue(forKey: $0) }

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(DownloadRecord.self, from: legacyData)
    }

    func makeTorrentItem(
        sourceURL: URL,
        sourceKind: DownloadSourceKind,
        status: DownloadStatus = .completed,
        metadataName: String? = nil,
        fileLocationPath: String? = nil
    ) -> DownloadItem {
        DownloadItem(
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            fileLocationPath: fileLocationPath,
            status: status,
            metadataName: metadataName
        )
    }
}
@MainActor
private final class FakeQuickLookPreviewService: QuickLookPreviewing {
    private(set) var previewedURLs: [URL] = []

    func preview(urls: [URL]) {
        previewedURLs = urls
    }
}
