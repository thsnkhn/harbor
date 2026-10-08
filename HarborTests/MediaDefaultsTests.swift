import Foundation
import XCTest
@testable import Harbor

@MainActor
final class MediaDefaultsTests: XCTestCase {
    func testDefaultsPersistWithoutChangingExistingBestAvailableBehavior() throws {
        let suite = "HarborTests.MediaDefaults.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(userDefaults: defaults)
        XCTAssertFalse(settings.removeCompletedDownloadsAutomatically)
        XCTAssertEqual(try settings.mediaDefaults.preference(for: makeMediaFormatTestFixture().metadata), .bestAvailable)
        settings.mediaPreferredFormat = .mp4Compatible
        settings.mediaMaximumResolution = .fullHD
        settings.removeCompletedDownloadsAutomatically = true
        let restored = AppSettingsStore(userDefaults: defaults)
        XCTAssertEqual(restored.mediaDefaults, MediaDownloadDefaults(format: .mp4Compatible, maximumResolution: .fullHD))
        XCTAssertTrue(restored.removeCompletedDownloadsAutomatically)
    }

    func testMP4DefaultsSelectH264AndAACInsteadOfAV1OrOpus() throws {
        let fixture = makeMediaFormatTestFixture()
        let av1 = MediaDownloadFormatOption(
            formatID: "av1", container: "mp4", videoCodec: "av01.0.12M.08", audioCodec: nil,
            width: 3840, height: 2160, framesPerSecond: 60, dynamicRange: "SDR",
            bitrateKbps: 8000, estimatedBytes: 0
        )
        let opus = MediaDownloadFormatOption(
            formatID: "opus", container: "webm", videoCodec: nil, audioCodec: "opus",
            width: nil, height: nil, framesPerSecond: nil, dynamicRange: nil,
            bitrateKbps: 256, estimatedBytes: 0, languagePreference: 100
        )
        let metadata = metadata(options: [av1, fixture.videoFormat, opus, fixture.audioFormat])
        let preferences = MediaDownloadDefaults(format: .mp4Compatible, maximumResolution: .ultraHD)
        let selected = try XCTUnwrap(preferences.preference(for: metadata).selection)
        XCTAssertEqual(selected.selector, "137+140")
        XCTAssertEqual(selected.mergeOutputFormat, "mp4")
        XCTAssertThrowsError(try preferences.preference(for: self.metadata(options: [av1, opus])))
        // A compatible video must not silently lose its audio when AAC is absent.
        XCTAssertThrowsError(try preferences.preference(for: self.metadata(options: [fixture.videoFormat, opus])))
    }

    func testResolutionLimitAndBatchDefaultsKeepValidRows() throws {
        let fixture = makeMediaFormatTestFixture()
        let defaults = MediaDownloadDefaults(maximumResolution: .hd)
        XCTAssertThrowsError(try defaults.preference(for: fixture.metadata))
        let low = MediaDownloadFormatOption(
            formatID: "720", container: "mp4", videoCodec: "avc1", audioCodec: "mp4a.40.2",
            width: 1280, height: 720, framesPerSecond: 30, dynamicRange: "SDR",
            bitrateKbps: 2000, estimatedBytes: 0
        )
        let source = URL(string: "https://youtube.com/watch?v=available")!
        let unavailable = URL(string: "https://youtube.com/watch?v=unavailable")!
        let direct = URL(string: "https://example.test/archive.zip")!
        let metadata = metadata(options: [fixture.videoFormat, low, fixture.audioFormat])
        let requests = AddDownloadRequest.batch(
            from: [source, unavailable, direct], destinationFolder: URL(fileURLWithPath: "/tmp"),
            shouldStartImmediately: false,
            mediaMetadata: [source: metadata, unavailable: fixture.metadata], mediaDefaults: defaults
        )
        XCTAssertEqual(requests.map(\.sourceURL), [source, direct])
        XCTAssertEqual(requests.first?.mediaFormatPreference?.selection?.selector, "720")
        XCTAssertNil(requests.last?.mediaFormatPreference)
        XCTAssertEqual(try defaults.preference(for: self.metadata(options: [fixture.audioFormat], type: .audio)), .bestAvailable)
    }

    private func metadata(options: [MediaDownloadFormatOption], type: MediaDownloadType = .video) -> MediaDownloadMetadata {
        MediaDownloadMetadata(
            title: "Test", platform: "Test", extractorKey: "Test", thumbnailURL: nil,
            webpageURL: nil, expectedBytes: 0, mediaType: type, entryCount: 1,
            capabilities: MediaDownloadCapabilities(formatOptions: options)
        )
    }
}
