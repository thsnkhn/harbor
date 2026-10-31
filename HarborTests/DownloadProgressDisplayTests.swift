import Foundation
import XCTest
@testable import Harbor

final class DownloadProgressDisplayTests: XCTestCase {
    func testTimeAverageSmoothsBurstsAndExpiresStalledRates() {
        var statistics = DownloadTransferStatistics(rate: 10_000_000, at: 0)
        XCTAssertEqual(statistics.displaySpeed(at: 0.25), 0)
        XCTAssertEqual(statistics.displaySpeed(at: 1), 10_000_000, accuracy: 1)
        statistics.record(rate: 2_000_000, at: 1)
        XCTAssertEqual(statistics.displaySpeed(at: 2), 6_000_000, accuracy: 1)
        for second in 3...12 {
            statistics.record(rate: 2_000_000, at: Double(second - 1))
            _ = statistics.displaySpeed(at: Double(second))
        }
        XCTAssertEqual(statistics.displaySpeed(at: 13), 2_000_000, accuracy: 1)
        // No more events: idle time must lower speed and eventually remove ETA.
        XCTAssertLessThan(statistics.displaySpeed(at: 18), 2_000_000)
        XCTAssertEqual(statistics.displaySpeed(at: 24), 0)
        XCTAssertNil(DownloadFormatting.etaString(bytesRemaining: 1_000, speedBytesPerSecond: 0))
    }

    func testReportsDoNotGainWeightFromCallbackFrequency() {
        var sparse = DownloadTransferStatistics(rate: 1_000, at: 0)
        var frequent = sparse
        for second in 1...12 {
            let rate = second.isMultiple(of: 2) ? 2_000.0 : 10_000.0
            sparse.record(rate: rate, at: Double(second))
            for tick in 1...100 {
                frequent.record(rate: rate, at: Double(second - 1) + Double(tick) / 100)
            }
            XCTAssertEqual(sparse.displaySpeed(at: Double(second)), frequent.displaySpeed(at: Double(second)), accuracy: 0.001)
        }
    }
}

extension HarborModelAndSafetyTests {
    func testDirectProgressDisplayIsBoundedAndCompletionKeepsEveryByte() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarborProgress-\(UUID())")
        let destination = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = root.appendingPathComponent("ready.json")
        let server = Process()
        server.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scripts/harbor-fixture-server.py")
        server.arguments = [script.path, "--ready-file", ready.path, "--log-file", root.appendingPathComponent("server.jsonl").path,
                            "--work-directory", root.appendingPathComponent("Server").path]
        try server.run()
        defer { server.terminate(); server.waitUntilExit() }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: ready.path) {
            try await Task.sleep(for: .milliseconds(30))
        }
        let configuration = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as! [String: Any]
        let baseURL = try XCTUnwrap(configuration["baseURL"] as? String)
        let payload = Data((0..<(4 * 1024 * 1024)).map { UInt8($0 % 256) })
        let suite = "HarborProgress.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: defaults),
            persistence: DownloadPersistence(directoryURL: root.appendingPathComponent("Records")),
            directRecoveryDirectoryURL: root.appendingPathComponent("Recovery"),
            completedHandoffDirectoryURL: root.appendingPathComponent("Handoffs"),
            remoteByteCountOperation: { _, _ in 4 * 1024 * 1024 }
        )
        await center.initializeIfNeeded()
        let item = DownloadItem(sourceURL: URL(string: baseURL + "/direct/slow.bin")!,
                                sourceKind: .directURL, backend: .urlSession, preferredFilename: nil,
                                destinationFolderPath: destination.path, status: .paused)
        center.downloads = [item]
        center.resumeDownloads(ids: [item.id])
        var changes = 0
        var previousBytes: Int64 = 0
        let clock = ContinuousClock()
        let start = clock.now
        while item.status != .completed && start.duration(to: clock.now) < .seconds(15) {
            if item.bytesWritten != previousBytes {
                changes += 1
                previousBytes = item.bytesWritten
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(item.status, .completed, item.lastError ?? "Download did not complete")
        XCTAssertGreaterThan(changes, 0)
        let elapsed = start.duration(to: clock.now).components
        XCTAssertLessThanOrEqual(changes, Int(elapsed.seconds) + 2, "Network callbacks must produce at most one display change per second, plus completion")
        XCTAssertEqual(item.bytesWritten, 4 * 1024 * 1024)
        let file = try XCTUnwrap(item.fileLocationPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), payload)
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.speedBytesPerSecond, 0)
        XCTAssertEqual(item.progress, 1)
        await center.shutdownForTermination()
    }
}
