import Foundation
import XCTest
@testable import Harbor

final class SegmentedDirectDownloadTests: XCTestCase {
    private struct Harness {
        let coordinator: DownloadCoordinator
        let events: DirectDownloadTestEventState
        let partialURL: URL
        let recoveryDirectory: URL
        let id: UUID
        let sourceURL: URL
        let completion: XCTestExpectation
        let failure: XCTestExpectation
    }

    private var testRoot: URL!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborSegmentedTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: testRoot)
    }

    func testSegmentBoundariesSplitRemainingBytes() {
        XCTAssertEqual(
            DownloadCoordinator.segmentBoundaries(from: 0, to: 64, connectionCount: 4, minimumSegmentBytes: 8),
            [0, 16, 32, 48, 64]
        )
        XCTAssertEqual(
            DownloadCoordinator.segmentBoundaries(from: 10, to: 100, connectionCount: 16, minimumSegmentBytes: 30),
            [10, 40, 70, 100]
        )
        XCTAssertEqual(
            DownloadCoordinator.segmentBoundaries(from: 0, to: 10, connectionCount: 3, minimumSegmentBytes: 1),
            [0, 3, 6, 10]
        )
        XCTAssertEqual(
            DownloadCoordinator.segmentBoundaries(from: 0, to: 15, connectionCount: 4, minimumSegmentBytes: 8),
            []
        )
        XCTAssertEqual(
            DownloadCoordinator.segmentBoundaries(from: 0, to: 64, connectionCount: 1, minimumSegmentBytes: 8),
            []
        )
    }

    func testRangedServerDownloadUsesOneConnectionPerSegment() async throws {
        SegmentedRangeURLProtocol.reset()
        let harness = try makeHarness()

        try harness.coordinator.startDownload(id: harness.id, sourceURL: harness.sourceURL)
        await fulfillment(of: [harness.completion], timeout: 5)

        let completedURL = try XCTUnwrap(harness.events.completedURL)
        defer { try? FileManager.default.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), SegmentedRangeURLProtocol.payload)
        XCTAssertTrue(harness.events.failures.isEmpty)

        let requests = SegmentedRangeURLProtocol.capturedHeaders
        XCTAssertNil(requests.first?.range)
        XCTAssertEqual(
            Set(requests.dropFirst().map(\.range)),
            ["bytes=16-31", "bytes=32-47", "bytes=48-63"]
        )
        XCTAssertTrue(requests.dropFirst().allSatisfy { $0.ifRange == "\"segment-etag\"" })
        XCTAssertEqual(try segmentFiles(in: harness.recoveryDirectory), [])
    }

    func testServerWithoutRangeSupportKeepsOneConnection() async throws {
        SegmentedRangeURLProtocol.reset(advertiseRanges: false)
        let harness = try makeHarness()

        try harness.coordinator.startDownload(id: harness.id, sourceURL: harness.sourceURL)
        await fulfillment(of: [harness.completion], timeout: 5)

        let completedURL = try XCTUnwrap(harness.events.completedURL)
        defer { try? FileManager.default.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), SegmentedRangeURLProtocol.payload)
        XCTAssertEqual(SegmentedRangeURLProtocol.capturedHeaders.count, 1)
    }

    func testSplittingIsOffUnlessEnabled() async throws {
        SegmentedRangeURLProtocol.reset()
        let harness = try makeHarness(splitsDirectDownloads: false)

        try harness.coordinator.startDownload(id: harness.id, sourceURL: harness.sourceURL)
        await fulfillment(of: [harness.completion], timeout: 5)

        let completedURL = try XCTUnwrap(harness.events.completedURL)
        defer { try? FileManager.default.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), SegmentedRangeURLProtocol.payload)
        XCTAssertEqual(SegmentedRangeURLProtocol.capturedHeaders.count, 1)
    }

    func testRejectedSegmentFallsBackToPrimaryConnection() async throws {
        SegmentedRangeURLProtocol.reset(segmentStatusCode: 200)
        let harness = try makeHarness()

        try harness.coordinator.startDownload(id: harness.id, sourceURL: harness.sourceURL)
        await fulfillment(of: [harness.completion], timeout: 5)

        let completedURL = try XCTUnwrap(harness.events.completedURL)
        defer { try? FileManager.default.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), SegmentedRangeURLProtocol.payload)
        XCTAssertTrue(harness.events.failures.isEmpty)
        XCTAssertEqual(try segmentFiles(in: harness.recoveryDirectory), [])
    }

    func testSegmentFailureAfterPrimaryStopsKeepsContiguousPrefixAndResumes() async throws {
        SegmentedRangeURLProtocol.reset(failedSegmentRange: "bytes=48-63")
        let harness = try makeHarness()

        try harness.coordinator.startDownload(id: harness.id, sourceURL: harness.sourceURL)
        await fulfillment(of: [harness.failure], timeout: 5)

        let failure = try XCTUnwrap(harness.events.firstFailure)
        XCTAssertTrue(failure.isRetryable)
        XCTAssertFalse(failure.requiresFreshStart)
        XCTAssertEqual(failure.recoverableBytes, 48)
        XCTAssertEqual(
            try Data(contentsOf: harness.partialURL),
            SegmentedRangeURLProtocol.payload.prefix(48)
        )
        XCTAssertEqual(try segmentFiles(in: harness.recoveryDirectory), [])

        try harness.coordinator.startDownload(id: harness.id, sourceURL: harness.sourceURL)
        await fulfillment(of: [harness.completion], timeout: 5)

        let completedURL = try XCTUnwrap(harness.events.completedURL)
        defer { try? FileManager.default.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), SegmentedRangeURLProtocol.payload)
        // The retry uses one connection from the preserved offset.
        XCTAssertEqual(SegmentedRangeURLProtocol.capturedHeaders.last?.range, "bytes=48-")
    }

    func testPauseDiscardsSegmentsAndKeepsContiguousPrefix() async throws {
        SegmentedRangeURLProtocol.reset(segmentDelay: 2)
        let harness = try makeHarness()

        try harness.coordinator.startDownload(id: harness.id, sourceURL: harness.sourceURL)
        try await Task.sleep(for: .milliseconds(300))
        let pause = await harness.coordinator.pauseDownloadAndWait(id: harness.id)

        XCTAssertEqual(pause.ownedRecovery?.bytesWritten, 16)
        XCTAssertEqual(
            try Data(contentsOf: harness.partialURL),
            SegmentedRangeURLProtocol.payload.prefix(16)
        )
        XCTAssertEqual(try segmentFiles(in: harness.recoveryDirectory), [])
    }

    private func makeHarness(splitsDirectDownloads: Bool = true) throws -> Harness {
        let fileManager = FileManager.default
        let destination = testRoot.appendingPathComponent("Destination", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let storage = DownloadStorageLocations(directoryURL: testRoot)
        try storage.preserveLegacyLocations(for: [])
        let id = UUID()
        try storage.prepare(id: id, destination: destination)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SegmentedRangeURLProtocol.self]

        let events = DirectDownloadTestEventState()
        let completion = XCTestExpectation(description: "The download completes")
        let failure = XCTestExpectation(description: "The download fails")
        failure.assertForOverFulfill = false
        let coordinator = DownloadCoordinator(
            transferSettings: DownloadTransferSettings(
                maxConcurrentDownloads: 3,
                globalSpeedLimitBytesPerSecond: nil,
                perDownloadSpeedLimitBytesPerSecond: nil,
                globalUploadSpeedLimitBytesPerSecond: nil,
                perDownloadUploadSpeedLimitBytesPerSecond: nil,
                perDownloadConnectionCount: 4,
                splitsDirectDownloads: splitsDirectDownloads
            ),
            minimumSegmentBytes: 8,
            eventHandler: { event in
                switch event {
                case let .failed(_, _, directFailure):
                    _ = events.recordFailure(directFailure)
                    failure.fulfill()
                case let .progress(_, _, bytesWritten, expectedBytes, _):
                    events.recordProgress(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
                case let .finished(_, _, handoff):
                    events.recordCompletion(handoff)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: testRoot.appendingPathComponent("Recovery", isDirectory: true),
            completedHandoffStore: CompletedDownloadHandoffStore(
                directoryURL: testRoot.appendingPathComponent("LegacyHandoffs"),
                storageLocations: storage
            ),
            storageLocations: storage,
            sessionConfiguration: configuration
        )

        let recoveryDirectory = destination
            .appendingPathComponent(".harbor-downloads/DirectDownloadRecovery", isDirectory: true)
        return Harness(
            coordinator: coordinator,
            events: events,
            partialURL: recoveryDirectory.appendingPathComponent("\(id.uuidString).part"),
            recoveryDirectory: recoveryDirectory,
            id: id,
            sourceURL: try XCTUnwrap(URL(string: "https://segments.example.test/file.bin")),
            completion: completion,
            failure: failure
        )
    }

    private func segmentFiles(in directory: URL) throws -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.filter { $0.contains(".segment-") }
    }
}

/// Serves a 64-byte file. Full and open-ended range responses trickle out in
/// 8-byte chunks, like a host that throttles each connection, while closed
/// ranges answer at once so extra connections finish first.
nonisolated final class SegmentedRangeURLProtocol: URLProtocol, @unchecked Sendable {
    struct CapturedHeaders: Sendable {
        let range: String?
        let ifRange: String?
    }

    static let payload = Data((0 ..< 64).map { UInt8($0) })

    private static let stateLock = NSLock()
    private static var headers: [CapturedHeaders] = []
    private static var advertisesRanges = true
    private static var segmentStatus = 206
    private static var failingSegmentRange: String?
    private static var segmentResponseDelay: TimeInterval = 0

    private let loadingLock = NSLock()
    private var isStopped = false

    static var capturedHeaders: [CapturedHeaders] {
        stateLock.withLock { headers }
    }

    static func reset(
        advertiseRanges: Bool = true,
        segmentStatusCode: Int = 206,
        failedSegmentRange: String? = nil,
        segmentDelay: TimeInterval = 0
    ) {
        stateLock.withLock {
            headers = []
            advertisesRanges = advertiseRanges
            segmentStatus = segmentStatusCode
            failingSegmentRange = failedSegmentRange
            segmentResponseDelay = segmentDelay
        }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "segments.example.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let range = request.value(forHTTPHeaderField: "Range")
        let settings = Self.stateLock.withLock { () -> (Bool, Int, String?, TimeInterval) in
            Self.headers.append(
                CapturedHeaders(range: range, ifRange: request.value(forHTTPHeaderField: "If-Range"))
            )
            return (Self.advertisesRanges, Self.segmentStatus, Self.failingSegmentRange, Self.segmentResponseDelay)
        }
        let (advertisesRanges, segmentStatus, failingSegmentRange, segmentDelay) = settings
        let payload = Self.payload
        let total = Int64(payload.count)

        guard let range, let bounds = Self.parse(range) else {
            var headerFields = [
                "Content-Length": "\(total)",
                "Content-Type": "application/octet-stream",
                "ETag": "\"segment-etag\""
            ]
            if advertisesRanges {
                headerFields["Accept-Ranges"] = "bytes"
            }
            respond(status: 200, headers: headerFields, body: payload, trickle: true)
            return
        }

        let isSegment = bounds.end != nil
        let start = bounds.start
        let end = bounds.end ?? total - 1
        let body = payload.subdata(in: Int(start) ..< Int(end + 1))

        if isSegment, range == failingSegmentRange {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
            return
        }
        if isSegment, segmentStatus == 200 {
            respond(
                status: 200,
                headers: ["Content-Length": "\(total)", "ETag": "\"segment-etag\""],
                body: payload,
                trickle: false
            )
            return
        }

        let headerFields = [
            "Content-Length": "\(body.count)",
            "Content-Range": "bytes \(start)-\(end)/\(total)",
            "Content-Type": "application/octet-stream",
            "ETag": "\"segment-etag\"",
            "Accept-Ranges": "bytes"
        ]
        if isSegment, segmentDelay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + segmentDelay) { [self] in
                respond(status: 206, headers: headerFields, body: body, trickle: false)
            }
            return
        }
        respond(status: 206, headers: headerFields, body: body, trickle: isSegment == false)
    }

    override func stopLoading() {
        loadingLock.withLock { isStopped = true }
    }

    private func respond(status: Int, headers: [String: String], body: Data, trickle: Bool) {
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: "HTTP/1.1",
                  headerFields: headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard trickle else {
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        deliver(body, offset: 0)
    }

    private func deliver(_ body: Data, offset: Int) {
        guard loadingLock.withLock({ isStopped }) == false else {
            return
        }
        guard offset < body.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let chunkEnd = min(offset + 8, body.count)
        client?.urlProtocol(self, didLoad: body.subdata(in: offset ..< chunkEnd))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [self] in
            deliver(body, offset: chunkEnd)
        }
    }

    private static func parse(_ range: String) -> (start: Int64, end: Int64?)? {
        guard range.hasPrefix("bytes=") else {
            return nil
        }
        let parts = range.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]) else {
            return nil
        }
        return (start, parts[1].isEmpty ? nil : Int64(parts[1]))
    }
}
