import Foundation
import XCTest
@testable import Harbor

@MainActor
final class AppSettingsAndTorrentWatchTests: XCTestCase {
    func testTorrentBlocklistSettingsPersistAndAcceptedStatusUpdates() {
        let suiteName = "HarborTests.Blocklist.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertFalse(settings.torrentBlocklistEnabled)

        var didChange = false
        settings.torrentBlocklistSettingsDidChange = { didChange = true }
        settings.torrentBlocklistURL = "https://example.com/blocklist.txt"
        settings.torrentBlocklistEnabled = true
        XCTAssertTrue(didChange)

        let updatedAt = Date(timeIntervalSince1970: 1_789_300_000)
        settings.updateTorrentBlocklistStatus(
            TorrentBlocklistStatus(ruleCount: 42, lastUpdated: updatedAt)
        )

        let restored = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertTrue(restored.torrentBlocklistEnabled)
        XCTAssertEqual(restored.torrentBlocklistURL, "https://example.com/blocklist.txt")
        XCTAssertEqual(settings.torrentBlocklistRuleCount, 42)
        XCTAssertEqual(settings.torrentBlocklistLastUpdated, updatedAt)
    }

    func testProxySettingsDefaultToSystemAndPersistManualConfiguration() {
        let suiteName = "HarborTests.Proxy.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertEqual(settings.proxySettings, .system)

        var observedSettings: NetworkProxySettings?
        settings.proxySettingsDidChange = { observedSettings = $0 }
        settings.proxyMode = .manual
        settings.proxyScheme = .socks5
        settings.proxyHost = "proxy.example"
        settings.proxyPort = 1_080

        let expected = NetworkProxySettings(
            mode: .manual,
            scheme: .socks5,
            host: "proxy.example",
            port: 1_080
        )
        XCTAssertEqual(observedSettings, expected)
        XCTAssertEqual(AppSettingsStore(userDefaults: userDefaults).proxySettings, expected)
    }

    func testPreventSleepDefaultsOffAndPersists() {
        let suiteName = "HarborTests.PreventSleep.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertFalse(settings.preventSleepWhileDownloading)

        settings.preventSleepWhileDownloading = true

        let restoredSettings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertTrue(restoredSettings.preventSleepWhileDownloading)
    }

    func testSeedingRatioLimitDefaultsOffAndPersists() {
        let suiteName = "HarborTests.SeedingRatio.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertFalse(settings.stopSeedingAtRatioEnabled)
        XCTAssertEqual(settings.stopSeedingRatio, 2)
        XCTAssertNil(settings.seedingRatioLimit)

        settings.stopSeedingRatio = 1.5
        settings.stopSeedingAtRatioEnabled = true

        let restoredSettings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertTrue(restoredSettings.stopSeedingAtRatioEnabled)
        XCTAssertEqual(restoredSettings.seedingRatioLimit, 1.5)
    }

    func testTrafficModesOverlayAndPreserveCustomLimits() {
        let suiteName = "HarborTests.TrafficModes.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertEqual(settings.trafficMode, .unlimited)
        XCTAssertEqual(settings.transferSettings, .default)

        settings.globalSpeedLimitKilobytesPerSecond = 9_000
        settings.perDownloadSpeedLimitKilobytesPerSecond = 3_000
        settings.globalUploadSpeedLimitKilobytesPerSecond = 1_500
        settings.perDownloadUploadSpeedLimitKilobytesPerSecond = 500
        settings.globalSpeedLimitEnabled = true
        settings.perDownloadSpeedLimitEnabled = true
        settings.globalUploadSpeedLimitEnabled = true
        settings.perDownloadUploadSpeedLimitEnabled = true
        XCTAssertEqual(settings.trafficMode, .custom)

        var observedSettings: DownloadTransferSettings?
        settings.transferSettingsDidChange = { observedSettings = $0 }
        settings.trafficMode = .balanced

        XCTAssertEqual(observedSettings?.globalSpeedLimitBytesPerSecond, 25 * 1_024 * 1_024)
        XCTAssertEqual(settings.transferSettings.perDownloadSpeedLimitBytesPerSecond, 5 * 1_024 * 1_024)
        XCTAssertEqual(settings.transferSettings.globalUploadSpeedLimitBytesPerSecond, 5 * 1_024 * 1_024)
        XCTAssertEqual(settings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond, 1_024 * 1_024)

        settings.trafficMode = .quiet
        XCTAssertEqual(settings.transferSettings.globalSpeedLimitBytesPerSecond, 5 * 1_024 * 1_024)
        XCTAssertEqual(settings.transferSettings.perDownloadSpeedLimitBytesPerSecond, 1_024 * 1_024)
        XCTAssertEqual(settings.transferSettings.globalUploadSpeedLimitBytesPerSecond, 512 * 1_024)
        XCTAssertEqual(settings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond, 256 * 1_024)

        settings.trafficMode = .unlimited
        XCTAssertNil(settings.transferSettings.globalSpeedLimitBytesPerSecond)
        XCTAssertNil(settings.transferSettings.perDownloadSpeedLimitBytesPerSecond)
        XCTAssertNil(settings.transferSettings.globalUploadSpeedLimitBytesPerSecond)
        XCTAssertNil(settings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond)

        settings.trafficMode = .custom
        XCTAssertEqual(settings.transferSettings.globalSpeedLimitBytesPerSecond, 9_000 * 1_024)
        XCTAssertEqual(settings.transferSettings.perDownloadSpeedLimitBytesPerSecond, 3_000 * 1_024)
        XCTAssertEqual(settings.transferSettings.globalUploadSpeedLimitBytesPerSecond, 1_500 * 1_024)
        XCTAssertEqual(settings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond, 500 * 1_024)

        let restoredSettings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertEqual(restoredSettings.trafficMode, .custom)
        XCTAssertEqual(restoredSettings.globalSpeedLimitKilobytesPerSecond, 9_000)
        XCTAssertEqual(restoredSettings.perDownloadUploadSpeedLimitKilobytesPerSecond, 500)
    }

    func testLegacyEnabledLimitsMigrateToCustomTrafficMode() {
        let suiteName = "HarborTests.LegacyTrafficMode.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        userDefaults.set(true, forKey: "globalSpeedLimitEnabled")
        userDefaults.set(7_500, forKey: "globalSpeedLimitKilobytesPerSecond")

        let settings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertEqual(settings.trafficMode, .custom)
        XCTAssertEqual(settings.transferSettings.globalSpeedLimitBytesPerSecond, 7_500 * 1_024)
    }

    func testStartAtLoginReflectsControllerStateAndFailures() {
        let controller = FakeLoginItemController(status: .disabled)
        let settings = AppSettingsStore(loginItemController: controller)

        XCTAssertFalse(settings.startAtLogin)

        settings.setStartAtLogin(true)
        XCTAssertTrue(settings.startAtLogin)
        XCTAssertNil(settings.startAtLoginErrorMessage)

        controller.status = .requiresApproval
        settings.refreshStartAtLoginStatus()
        XCTAssertFalse(settings.startAtLogin)

        settings.setStartAtLogin(true)
        XCTAssertFalse(settings.startAtLogin)
        XCTAssertNotNil(settings.startAtLoginErrorMessage)
    }

    func testSleepPreventionTracksOnlyActiveDownloads() async {
        let settings = HarborTestFixtures.makeSettings()
        let sleepPreventionService = FakeSleepPreventionService()
        let center = DownloadCenter(
            settings: settings,
            sleepPreventionService: sleepPreventionService
        )
        let item = HarborTestFixtures.sampleDownloads()[0]

        settings.preventSleepWhileDownloading = true
        center.downloads = [item]
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(sleepPreventionService.isPreventingSleep)

        item.status = .seeding
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(sleepPreventionService.isPreventingSleep)

        item.status = .downloading
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(sleepPreventionService.isPreventingSleep)

        await center.shutdownForTermination()
        XCTAssertFalse(sleepPreventionService.isPreventingSleep)
        XCTAssertEqual(sleepPreventionService.stopCallCount, 1)
    }

    func testLegacySettingsReceiveTorrentAutomationDefaults() {
        let suiteName = "HarborTests.Settings.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let regularDestinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        userDefaults.set(regularDestinationURL.path, forKey: "defaultDestinationPath")

        let settings = AppSettingsStore(userDefaults: userDefaults)
        let downloadsURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser

        XCTAssertFalse(settings.torrentWatchFolderEnabled)
        XCTAssertEqual(settings.torrentWatchFolderURL.standardizedFileURL, downloadsURL.standardizedFileURL)
        XCTAssertTrue(settings.seedNewTorrents)
        XCTAssertFalse(settings.stopSeedingAtRatioEnabled)
        XCTAssertEqual(settings.stopSeedingRatio, 2)
        XCTAssertNil(settings.seedingRatioLimit)
        XCTAssertEqual(settings.trafficMode, .unlimited)
        XCTAssertEqual(
            settings.torrentDestinationURL.standardizedFileURL,
            regularDestinationURL
                .appendingPathComponent("Torrents", isDirectory: true)
                .standardizedFileURL
        )
        XCTAssertFalse(settings.globalUploadSpeedLimitEnabled)
        XCTAssertFalse(settings.perDownloadUploadSpeedLimitEnabled)
        XCTAssertNil(settings.transferSettings.globalUploadSpeedLimitBytesPerSecond)
        XCTAssertNil(settings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond)
    }

    func testDisabledUploadLimitsRetainTheirSavedValues() {
        let suiteName = "HarborTests.UploadLimits.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.globalUploadSpeedLimitKilobytesPerSecond = 900
        settings.perDownloadUploadSpeedLimitKilobytesPerSecond = 300
        settings.globalUploadSpeedLimitEnabled = true
        settings.perDownloadUploadSpeedLimitEnabled = true

        XCTAssertEqual(settings.transferSettings.globalUploadSpeedLimitBytesPerSecond, 900 * 1_024)
        XCTAssertEqual(settings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond, 300 * 1_024)

        settings.globalUploadSpeedLimitEnabled = false
        settings.perDownloadUploadSpeedLimitEnabled = false

        let restoredSettings = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertFalse(restoredSettings.globalUploadSpeedLimitEnabled)
        XCTAssertFalse(restoredSettings.perDownloadUploadSpeedLimitEnabled)
        XCTAssertEqual(restoredSettings.globalUploadSpeedLimitKilobytesPerSecond, 900)
        XCTAssertEqual(restoredSettings.perDownloadUploadSpeedLimitKilobytesPerSecond, 300)
        XCTAssertNil(restoredSettings.transferSettings.globalUploadSpeedLimitBytesPerSecond)
        XCTAssertNil(restoredSettings.transferSettings.perDownloadUploadSpeedLimitBytesPerSecond)
    }

    func testExistingTorrentIsEmittedOnlyAfterTwoStableScans() async throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let torrentURL = directoryURL.appendingPathComponent("existing.torrent")
        try Data("stable torrent".utf8).write(to: torrentURL)

        let debounceInterval: TimeInterval = 0.08
        let service = TorrentWatchFolderService(
            fileManager: fileManager,
            debounceInterval: debounceInterval,
            retryInterval: 0.05
        )
        defer {
            service.stop()
            try? fileManager.removeItem(at: directoryURL)
        }

        let emitted = expectation(description: "Existing stable torrent emitted")
        let startedAt = Date()
        var emittedURLs: [URL] = []
        var elapsedAtEmission: TimeInterval?
        service.start(watching: directoryURL) { candidateURL in
            emittedURLs.append(candidateURL)
            elapsedAtEmission = Date().timeIntervalSince(startedAt)
            emitted.fulfill()
        }

        try await Task.sleep(for: .milliseconds(25))
        XCTAssertTrue(emittedURLs.isEmpty)

        await fulfillment(of: [emitted], timeout: 1)
        XCTAssertEqual(emittedURLs, [torrentURL.standardizedFileURL])
        XCTAssertGreaterThanOrEqual(elapsedAtEmission ?? 0, debounceInterval * 0.75)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(emittedURLs.count, 1)
    }

    func testLiveTorrentIsEmittedWhileSubdirectoryTorrentIsIgnored() async throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborWatcherTests-\(UUID().uuidString)", isDirectory: true)
        let nestedDirectoryURL = directoryURL.appendingPathComponent("Nested", isDirectory: true)
        try fileManager.createDirectory(at: nestedDirectoryURL, withIntermediateDirectories: true)
        let nestedTorrentURL = nestedDirectoryURL.appendingPathComponent("ignored.torrent")
        try Data("nested torrent".utf8).write(to: nestedTorrentURL)

        let service = TorrentWatchFolderService(
            fileManager: fileManager,
            debounceInterval: 0.05,
            retryInterval: 0.05
        )
        defer {
            service.stop()
            try? fileManager.removeItem(at: directoryURL)
        }

        let emitted = expectation(description: "Live torrent emitted")
        var emittedURLs: [URL] = []
        service.start(watching: directoryURL) { candidateURL in
            emittedURLs.append(candidateURL)
            emitted.fulfill()
        }

        try await Task.sleep(for: .milliseconds(140))
        XCTAssertTrue(emittedURLs.isEmpty)

        let liveTorrentURL = directoryURL.appendingPathComponent("live.torrent")
        try Data("live torrent".utf8).write(to: liveTorrentURL)

        await fulfillment(of: [emitted], timeout: 1)
        XCTAssertEqual(emittedURLs, [liveTorrentURL.standardizedFileURL])

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(emittedURLs.count, 1)
    }
}

private final class FakeLoginItemController: LoginItemControlling {
    var status: LoginItemStatus

    init(status: LoginItemStatus) {
        self.status = status
    }

    func setEnabled(_ isEnabled: Bool) throws {
        guard status != .requiresApproval else {
            return
        }

        status = isEnabled ? .enabled : .disabled
    }
}

@MainActor
private final class FakeSleepPreventionService: DownloadSleepPreventing {
    private(set) var isPreventingSleep = false
    private(set) var stopCallCount = 0

    func update(isEnabled: Bool, hasActiveDownloads: Bool) {
        isPreventingSleep = isEnabled && hasActiveDownloads
    }

    func stop() {
        stopCallCount += 1
        isPreventingSleep = false
    }
}
