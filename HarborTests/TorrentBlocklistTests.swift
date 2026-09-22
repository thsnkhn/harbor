import Foundation
import XCTest
@testable import Harbor

final class TorrentBlocklistTests: XCTestCase {
    @MainActor
    func testEnabledBlocklistRefreshesOnSchedule() async throws {
        let suiteName = "HarborTests.BlocklistSchedule.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborBlocklistSchedule-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.torrentBlocklistURL = "https://example.com/blocklist.txt"
        settings.torrentBlocklistEnabled = true
        let secondDownload = expectation(description: "Scheduled blocklist refresh")
        let downloadRecorder = BlocklistDownloadRecorder()
        let service = TorrentBlocklistService(
            directoryURL: directoryURL,
            downloader: { _, _ in
                if await downloadRecorder.recordDownload() == 2 {
                    secondDownload.fulfill()
                }
                return Data("192.0.2.1\n".utf8)
            },
            apply: { rules in
                TorrentBlocklistApplication(ruleCount: rules.count, revision: 1)
            }
        )
        let controller = TorrentBlocklistController(
            settings: settings,
            service: service,
            refreshInterval: 0.02
        )

        await controller.activate()
        await fulfillment(of: [secondDownload], timeout: 1)
        _ = controller
    }

    @MainActor
    func testDisablingWaitsForCancelledRefreshBeforeClearingFilter() async throws {
        let suiteName = "HarborTests.BlocklistCancellation.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborBlocklistCancellation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        let downloadStarted = expectation(description: "Blocklist download started")
        let rulesApplied = expectation(description: "Downloaded rules applied")
        let rulesCleared = expectation(description: "Blocklist cleared")
        let recorder = BlocklistApplicationRecorder()
        let service = TorrentBlocklistService(
            directoryURL: directoryURL,
            downloader: { _, _ in
                downloadStarted.fulfill()
                try? await Task.sleep(for: .milliseconds(100))
                return Data("192.0.2.1\n".utf8)
            },
            apply: { rules in
                if rules.isEmpty {
                    rulesCleared.fulfill()
                } else {
                    rulesApplied.fulfill()
                }
                return await recorder.apply(rules)
            }
        )
        let controller = TorrentBlocklistController(settings: settings, service: service)
        settings.torrentBlocklistURL = "https://example.com/blocklist.txt"
        settings.torrentBlocklistEnabled = true
        await fulfillment(of: [downloadStarted], timeout: 1)

        settings.torrentBlocklistEnabled = false
        await fulfillment(of: [rulesApplied, rulesCleared], timeout: 1)

        let applications = await recorder.allRules()
        XCTAssertEqual(applications.last, [])
        _ = controller
    }

    func testParserAcceptsIPAndCIDRRulesAndRemovesCommentsAndDuplicates() throws {
        let data = Data(
            """
            # comment
            192.0.2.1
            198.51.100.0/24 # inline comment
            2001:db8::/32
            192.0.2.1

            """.utf8
        )

        XCTAssertEqual(
            try TorrentBlocklistParser.rules(from: data),
            ["192.0.2.1", "198.51.100.0/24", "2001:db8::/32"]
        )
    }

    func testParserRejectsUnsupportedRangeFormat() {
        XCTAssertThrowsError(
            try TorrentBlocklistParser.rules(from: Data("bad:1.2.3.4-1.2.3.9".utf8))
        ) { error in
            XCTAssertEqual(error as? TorrentBlocklistError, .invalidRule(line: 1))
        }
    }

    func testServiceKeepsAcceptedCacheWhenRefreshFails() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborBlocklistTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let recorder = BlocklistApplicationRecorder()
        let validData = Data("192.0.2.1\n198.51.100.0/24\n".utf8)

        let initialService = TorrentBlocklistService(
            directoryURL: directoryURL,
            downloader: { _, _ in validData },
            apply: { rules in await recorder.apply(rules) }
        )
        let initialStatus = try await initialService.refresh(
            source: "https://example.com/blocklist.txt",
            proxySettings: .system
        )
        XCTAssertEqual(initialStatus.ruleCount, 2)

        let failingService = TorrentBlocklistService(
            directoryURL: directoryURL,
            downloader: { _, _ in throw BlocklistProbeError.downloadFailed },
            apply: { rules in await recorder.apply(rules) }
        )
        do {
            _ = try await failingService.refresh(
                source: "https://example.com/blocklist.txt",
                proxySettings: .system
            )
            XCTFail("The failed refresh unexpectedly succeeded")
        } catch {
            XCTAssertEqual(error as? BlocklistProbeError, .downloadFailed)
        }
        let rulesAfterFailure = await recorder.lastRules()
        XCTAssertEqual(rulesAfterFailure, ["192.0.2.1", "198.51.100.0/24"])

        let restoredStatus = try await failingService.activate(
            source: "https://example.com/blocklist.txt",
            proxySettings: .system
        )
        XCTAssertEqual(restoredStatus, initialStatus)
        let lastRules = await recorder.lastRules()
        XCTAssertEqual(lastRules, ["192.0.2.1", "198.51.100.0/24"])

        try await failingService.disable()
        let disabledRules = await recorder.lastRules()
        XCTAssertEqual(disabledRules, [])
    }
}

private enum BlocklistProbeError: Error, Equatable {
    case downloadFailed
}

private actor BlocklistDownloadRecorder {
    private var count = 0

    func recordDownload() -> Int {
        count += 1
        return count
    }
}

private actor BlocklistApplicationRecorder {
    private var applications: [[String]] = []

    func apply(_ rules: [String]) -> TorrentBlocklistApplication {
        applications.append(rules)
        return TorrentBlocklistApplication(
            ruleCount: rules.count,
            revision: applications.count
        )
    }

    func lastRules() -> [String]? {
        applications.last
    }

    func allRules() -> [[String]] {
        applications
    }
}
