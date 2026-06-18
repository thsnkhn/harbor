import Foundation
import SwiftUI

@MainActor
enum HarborPreviewFixtures {
    static func makeSettings() -> AppSettingsStore {
        let suiteName = "HarborPreviewDefaults"
        let userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
        userDefaults.removePersistentDomain(forName: suiteName)

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.defaultDestinationPath = "/Users/example/Downloads"
        settings.maxConcurrentDownloads = 3
        settings.startDownloadsAutomatically = true
        return settings
    }

    static func makeCenter(
        selectedSidebarSelection: DownloadSidebarSelection = .filter(.all),
        selectedDownloadIndex: Int = 1
    ) -> DownloadCenter {
        let settings = makeSettings()
        let center = DownloadCenter(settings: settings)
        center.downloads = sampleDownloads()
        center.selectedSidebarSelection = selectedSidebarSelection
        center.selectedDownloadID = center.downloads[safe: selectedDownloadIndex]?.id
        return center
    }

    static func sampleDownloads() -> [DownloadItem] {
        let now = Date()

        let torrent = DownloadItem(
            createdAt: now.addingTimeInterval(-3_600),
            sourceURL: URL(fileURLWithPath: "/Users/example/Downloads/cold-storage.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/Users/example/Downloads",
            status: .paused,
            progress: 0.14,
            bytesWritten: 246 * 1_024 * 1_024,
            expectedBytes: Int64(1.78 * 1_024 * 1_024 * 1_024),
            speedBytesPerSecond: 0,
            uploadBytesPerSecond: 0,
            startedAt: now.addingTimeInterval(-3_420),
            updatedAt: now.addingTimeInterval(-120),
            backendIdentifier: "preview-torrent",
            metadataName: "Cold Storage (2026) [1080p] [WEBRip] [x265]",
            tags: ["Movies", "Archive"]
        )

        let direct = DownloadItem(
            createdAt: now.addingTimeInterval(-7_200),
            sourceURL: URL(string: "https://example.com/releases/harbor.dmg")!,
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "Harbor.dmg",
            destinationFolderPath: "/Users/example/Downloads",
            fileLocationPath: "/Users/example/Downloads/Harbor.dmg",
            status: .completed,
            progress: 1,
            bytesWritten: 82 * 1_024 * 1_024,
            expectedBytes: 82 * 1_024 * 1_024,
            speedBytesPerSecond: 0,
            startedAt: now.addingTimeInterval(-7_100),
            finishedAt: now.addingTimeInterval(-6_900),
            updatedAt: now.addingTimeInterval(-6_900),
            tags: ["Apps"]
        )

        let magnet = DownloadItem(
            createdAt: now.addingTimeInterval(-900),
            sourceURL: URL(string: "magnet:?xt=urn:btih:1234567890ABCDEF&dn=Ubuntu+ISO")!,
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/Users/example/Downloads",
            status: .downloading,
            progress: 0.52,
            bytesWritten: 812 * 1_024 * 1_024,
            expectedBytes: Int64(1.5 * 1_024 * 1_024 * 1_024),
            speedBytesPerSecond: 7.8 * 1_024 * 1_024,
            uploadBytesPerSecond: 420 * 1_024,
            startedAt: now.addingTimeInterval(-840),
            updatedAt: now.addingTimeInterval(-8),
            backendIdentifier: "preview-magnet",
            metadataName: "Ubuntu ISO",
            tags: ["Linux", "ISO"]
        )

        let failed = DownloadItem(
            createdAt: now.addingTimeInterval(-1_800),
            sourceURL: URL(string: "https://example.com/archive.zip")!,
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: "archive.zip",
            destinationFolderPath: "/Users/example/Downloads",
            status: .failed,
            progress: 0.33,
            bytesWritten: 128 * 1_024 * 1_024,
            expectedBytes: 390 * 1_024 * 1_024,
            speedBytesPerSecond: 0,
            startedAt: now.addingTimeInterval(-1_760),
            updatedAt: now.addingTimeInterval(-300),
            lastError: "The network connection was lost.",
            tags: ["Archive"]
        )

        return [magnet, torrent, direct, failed]
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
