import Foundation
import Observation

enum DownloadStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case preparing
    case downloading
    case browserSessionRequired
    case paused
    case completed
    case failed
    case cancelled

    var title: LocalizedStringResource {
        switch self {
        case .queued:
            LocalizedStringResource("status.queued", defaultValue: "Queued")
        case .preparing:
            LocalizedStringResource("status.preparing", defaultValue: "Preparing")
        case .downloading:
            LocalizedStringResource("status.downloading", defaultValue: "Downloading")
        case .browserSessionRequired:
            LocalizedStringResource("status.needsBrowser", defaultValue: "Browser Session Required")
        case .paused:
            LocalizedStringResource("status.paused", defaultValue: "Paused")
        case .completed:
            LocalizedStringResource("status.completed", defaultValue: "Completed")
        case .failed:
            LocalizedStringResource("status.failed", defaultValue: "Failed")
        case .cancelled:
            LocalizedStringResource("status.cancelled", defaultValue: "Cancelled")
        }
    }

    var systemImage: String {
        switch self {
        case .queued:
            "clock.arrow.circlepath"
        case .preparing:
            "ellipsis.circle"
        case .downloading:
            "arrow.down.circle.fill"
        case .browserSessionRequired:
            "globe"
        case .paused:
            "pause.circle.fill"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .cancelled:
            "xmark.circle.fill"
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            true
        case .queued, .preparing, .downloading, .browserSessionRequired, .paused:
            false
        }
    }

    var isRunning: Bool {
        self == .preparing || self == .downloading
    }
}

enum DownloadActivityKind: String, Codable, Sendable {
    case added
    case queued
    case started
    case resumed
    case paused
    case browserSessionRequired
    case completed
    case failed
    case cancelled
}

struct DownloadActivityEvent: Codable, Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: DownloadActivityKind
    let timestamp: Date

    init(
        id: UUID = UUID(),
        kind: DownloadActivityKind,
        timestamp: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }
}

struct TorrentTracker: Codable, Identifiable, Hashable, Sendable {
    let url: String
    let status: String?
    let errorMessage: String?

    var id: String { url }

    nonisolated init(
        url: String,
        status: String? = nil,
        errorMessage: String? = nil
    ) {
        self.url = url
        self.status = status
        self.errorMessage = errorMessage
    }
}

struct DownloadRecord: Codable, Sendable {
    let id: UUID
    let sourceURL: URL
    let sourceKind: DownloadSourceKind
    let backend: DownloadBackend
    let preferredFilename: String?
    let destinationFolderPath: String
    let fileLocationPath: String?
    let status: DownloadStatus
    let progress: Double
    let bytesWritten: Int64
    let expectedBytes: Int64
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let updatedAt: Date
    let lastError: String?
    let resumeData: Data?
    let backendIdentifier: String?
    let metadataName: String?
    let torrentTrackers: [TorrentTracker]
    let manualTrackerURLs: [String]
    let activityEvents: [DownloadActivityEvent]

    private enum CodingKeys: String, CodingKey {
        case id
        case sourceURL
        case sourceKind
        case backend
        case preferredFilename
        case destinationFolderPath
        case fileLocationPath
        case status
        case progress
        case bytesWritten
        case expectedBytes
        case createdAt
        case startedAt
        case finishedAt
        case updatedAt
        case lastError
        case resumeData
        case backendIdentifier
        case metadataName
        case torrentTrackers
        case manualTrackerURLs
        case activityEvents
    }

    init(
        id: UUID,
        sourceURL: URL,
        sourceKind: DownloadSourceKind,
        backend: DownloadBackend,
        preferredFilename: String?,
        destinationFolderPath: String,
        fileLocationPath: String?,
        status: DownloadStatus,
        progress: Double,
        bytesWritten: Int64,
        expectedBytes: Int64,
        createdAt: Date,
        startedAt: Date?,
        finishedAt: Date?,
        updatedAt: Date,
        lastError: String?,
        resumeData: Data?,
        backendIdentifier: String?,
        metadataName: String?,
        torrentTrackers: [TorrentTracker] = [],
        manualTrackerURLs: [String] = [],
        activityEvents: [DownloadActivityEvent] = []
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.backend = backend
        self.preferredFilename = preferredFilename
        self.destinationFolderPath = destinationFolderPath
        self.fileLocationPath = fileLocationPath
        self.status = status
        self.progress = progress
        self.bytesWritten = bytesWritten
        self.expectedBytes = expectedBytes
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
        self.lastError = lastError
        self.resumeData = resumeData
        self.backendIdentifier = backendIdentifier
        self.metadataName = metadataName
        self.torrentTrackers = torrentTrackers
        self.manualTrackerURLs = manualTrackerURLs
        self.activityEvents = activityEvents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        self.sourceKind = try container.decodeIfPresent(DownloadSourceKind.self, forKey: .sourceKind) ?? .directURL
        self.backend = try container.decodeIfPresent(DownloadBackend.self, forKey: .backend) ?? .urlSession
        self.preferredFilename = try container.decodeIfPresent(String.self, forKey: .preferredFilename)
        self.destinationFolderPath = try container.decode(String.self, forKey: .destinationFolderPath)
        self.fileLocationPath = try container.decodeIfPresent(String.self, forKey: .fileLocationPath)
        self.status = try container.decode(DownloadStatus.self, forKey: .status)
        self.progress = try container.decodeIfPresent(Double.self, forKey: .progress) ?? 0
        self.bytesWritten = try container.decodeIfPresent(Int64.self, forKey: .bytesWritten) ?? 0
        self.expectedBytes = try container.decodeIfPresent(Int64.self, forKey: .expectedBytes) ?? 0
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        self.finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self.resumeData = try container.decodeIfPresent(Data.self, forKey: .resumeData)
        self.backendIdentifier = try container.decodeIfPresent(String.self, forKey: .backendIdentifier)
        self.metadataName = try container.decodeIfPresent(String.self, forKey: .metadataName)
        self.torrentTrackers = try container.decodeIfPresent([TorrentTracker].self, forKey: .torrentTrackers) ?? []
        self.manualTrackerURLs = try container.decodeIfPresent([String].self, forKey: .manualTrackerURLs) ?? []
        self.activityEvents = try container.decodeIfPresent([DownloadActivityEvent].self, forKey: .activityEvents) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(sourceURL, forKey: .sourceURL)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(backend, forKey: .backend)
        try container.encode(preferredFilename, forKey: .preferredFilename)
        try container.encode(destinationFolderPath, forKey: .destinationFolderPath)
        try container.encode(fileLocationPath, forKey: .fileLocationPath)
        try container.encode(status, forKey: .status)
        try container.encode(progress, forKey: .progress)
        try container.encode(bytesWritten, forKey: .bytesWritten)
        try container.encode(expectedBytes, forKey: .expectedBytes)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(finishedAt, forKey: .finishedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(lastError, forKey: .lastError)
        try container.encode(resumeData, forKey: .resumeData)
        try container.encode(backendIdentifier, forKey: .backendIdentifier)
        try container.encode(metadataName, forKey: .metadataName)
        try container.encode(torrentTrackers, forKey: .torrentTrackers)
        try container.encode(manualTrackerURLs, forKey: .manualTrackerURLs)
        try container.encode(activityEvents, forKey: .activityEvents)
    }
}

@Observable
@MainActor
final class DownloadItem: Identifiable {
    let id: UUID
    let createdAt: Date
    var sourceURL: URL
    var sourceKind: DownloadSourceKind
    var backend: DownloadBackend
    var preferredFilename: String?
    var destinationFolderPath: String
    var fileLocationPath: String?
    var status: DownloadStatus
    var progress: Double
    var bytesWritten: Int64
    var expectedBytes: Int64
    var speedBytesPerSecond: Double
    var uploadBytesPerSecond: Double
    var startedAt: Date?
    var finishedAt: Date?
    var updatedAt: Date
    var lastError: String?
    var resumeData: Data?
    var taskIdentifier: Int?
    var backendIdentifier: String?
    var metadataName: String?
    var torrentTrackers: [TorrentTracker]
    var manualTrackerURLs: [String]
    var activityEvents: [DownloadActivityEvent]

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        sourceURL: URL,
        sourceKind: DownloadSourceKind,
        backend: DownloadBackend,
        preferredFilename: String?,
        destinationFolderPath: String,
        fileLocationPath: String? = nil,
        status: DownloadStatus,
        progress: Double = 0,
        bytesWritten: Int64 = 0,
        expectedBytes: Int64 = 0,
        speedBytesPerSecond: Double = 0,
        uploadBytesPerSecond: Double = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        updatedAt: Date = .now,
        lastError: String? = nil,
        resumeData: Data? = nil,
        taskIdentifier: Int? = nil,
        backendIdentifier: String? = nil,
        metadataName: String? = nil,
        torrentTrackers: [TorrentTracker] = [],
        manualTrackerURLs: [String] = [],
        activityEvents: [DownloadActivityEvent] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceURL = sourceURL
        self.sourceKind = sourceKind
        self.backend = backend
        self.preferredFilename = preferredFilename
        self.destinationFolderPath = destinationFolderPath
        self.fileLocationPath = fileLocationPath
        self.status = status
        self.progress = progress
        self.bytesWritten = bytesWritten
        self.expectedBytes = expectedBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
        self.lastError = lastError
        self.resumeData = resumeData
        self.taskIdentifier = taskIdentifier
        self.backendIdentifier = backendIdentifier
        self.metadataName = metadataName
        self.torrentTrackers = torrentTrackers
        self.manualTrackerURLs = manualTrackerURLs
        self.activityEvents = activityEvents

        if self.activityEvents.contains(where: { $0.kind == .added }) == false {
            self.activityEvents.insert(
                DownloadActivityEvent(kind: .added, timestamp: createdAt),
                at: 0
            )
        }
    }

    convenience init(record: DownloadRecord) {
        self.init(
            id: record.id,
            createdAt: record.createdAt,
            sourceURL: record.sourceURL,
            sourceKind: record.sourceKind,
            backend: record.backend,
            preferredFilename: record.preferredFilename,
            destinationFolderPath: record.destinationFolderPath,
            fileLocationPath: record.fileLocationPath,
            status: record.status,
            progress: record.progress,
            bytesWritten: record.bytesWritten,
            expectedBytes: record.expectedBytes,
            speedBytesPerSecond: 0,
            uploadBytesPerSecond: 0,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            updatedAt: record.updatedAt,
            lastError: record.lastError,
            resumeData: record.resumeData,
            taskIdentifier: nil,
            backendIdentifier: record.backendIdentifier,
            metadataName: record.metadataName,
            torrentTrackers: record.torrentTrackers,
            manualTrackerURLs: record.manualTrackerURLs,
            activityEvents: record.activityEvents
        )
    }

    var displayName: String {
        if let fileLocationURL {
            return fileLocationURL.lastPathComponent
        }

        if let metadataName, metadataName.isEmpty == false {
            return metadataName
        }

        if let preferredFilename, preferredFilename.isEmpty == false {
            return preferredFilename
        }

        if sourceKind == .magnetLink {
            let metadata = MagnetLinkMetadata(url: sourceURL)
            if let displayName = metadata.displayName {
                return displayName
            }

            if let infoHash = metadata.infoHash {
                return infoHash
            }

            return String(
                localized: "download.displayName.magnet",
                defaultValue: "Magnet Download",
                comment: "Fallback display name for a magnet download before metadata is available."
            )
        }

        if sourceKind == .torrentFile, sourceURL.isFileURL {
            return sourceURL.deletingPathExtension().lastPathComponent
        }

        if sourceURL.lastPathComponent.isEmpty == false {
            return sourceURL.lastPathComponent
        }

        return sourceURL.host ?? String(
            localized: "download.displayName.generic",
            defaultValue: "Download",
            comment: "Generic fallback display name for a download."
        )
    }

    var sourceHost: String {
        switch sourceKind {
        case .directURL:
            sourceURL.host ?? sourceURL.absoluteString
        case .magnetLink:
            String(
                localized: "source.host.magnetLink",
                defaultValue: "Magnet Link",
                comment: "Source host fallback for magnet link downloads."
            )
        case .torrentFile:
            String(
                localized: "source.host.torrentFile",
                defaultValue: "Torrent File",
                comment: "Source host fallback for local torrent file downloads."
            )
        }
    }

    var sourceDisplayText: String {
        sourceURL.isFileURL ? sourceURL.path : sourceURL.absoluteString
    }

    var sourceBadgeTitle: LocalizedStringResource {
        sourceKind.title
    }

    var sourceBadgeImage: String {
        sourceKind.systemImage
    }

    var destinationFolderURL: URL {
        URL(fileURLWithPath: destinationFolderPath, isDirectory: true)
    }

    var fileLocationURL: URL? {
        guard let fileLocationPath else {
            return nil
        }

        return URL(fileURLWithPath: fileLocationPath)
    }

    var progressValue: Double? {
        expectedBytes > 0 ? min(max(progress, 0), 1) : nil
    }

    var progressText: String {
        DownloadFormatting.progressString(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
    }

    var speedText: String {
        if speedBytesPerSecond > 0 {
            return DownloadFormatting.speedString(speedBytesPerSecond)
        }

        switch status {
        case .queued, .preparing, .downloading:
            return String(localized: "Waiting", comment: "Speed status fallback")
        case .browserSessionRequired, .paused, .completed, .failed, .cancelled:
            return "-"
        }
    }

    var etaText: String? {
        DownloadFormatting.etaString(
            bytesRemaining: max(expectedBytes - bytesWritten, 0),
            speedBytesPerSecond: speedBytesPerSecond
        )
    }

    var displayLastError: String? {
        lastError.map { Self.displayErrorMessage(from: $0) }
    }

    var displayedTrackers: [TorrentTracker] {
        var trackerURLs = Set<String>()
        var displayedTrackers: [TorrentTracker] = []

        for tracker in torrentTrackers where trackerURLs.insert(tracker.url).inserted {
            displayedTrackers.append(tracker)
        }

        if sourceKind == .magnetLink {
            for trackerURL in MagnetLinkMetadata(url: sourceURL).trackerURLs
                where trackerURLs.insert(trackerURL).inserted {
                displayedTrackers.append(TorrentTracker(url: trackerURL))
            }
        }

        for trackerURL in manualTrackerURLs where trackerURLs.insert(trackerURL).inserted {
            displayedTrackers.append(TorrentTracker(url: trackerURL))
        }

        return displayedTrackers
    }

    var isRunning: Bool {
        status.isRunning
    }

    var canPause: Bool {
        status == .preparing || status == .downloading
    }

    var canResume: Bool {
        status == .paused || status == .failed || status == .queued
    }

    func makeRecord() -> DownloadRecord {
        DownloadRecord(
            id: id,
            sourceURL: sourceURL,
            sourceKind: sourceKind,
            backend: backend,
            preferredFilename: preferredFilename,
            destinationFolderPath: destinationFolderPath,
            fileLocationPath: fileLocationPath,
            status: status,
            progress: progress,
            bytesWritten: bytesWritten,
            expectedBytes: expectedBytes,
            createdAt: createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            updatedAt: updatedAt,
            lastError: lastError,
            resumeData: resumeData,
            backendIdentifier: backendIdentifier,
            metadataName: metadataName,
            torrentTrackers: torrentTrackers,
            manualTrackerURLs: manualTrackerURLs,
            activityEvents: activityEvents
        )
    }

    func recordActivity(
        _ kind: DownloadActivityKind,
        timestamp: Date = .now
    ) {
        activityEvents.append(
            DownloadActivityEvent(kind: kind, timestamp: timestamp)
        )

        while activityEvents.count > 40 {
            if activityEvents.first?.kind == .added,
               activityEvents.count > 1 {
                activityEvents.remove(at: 1)
            } else {
                activityEvents.removeFirst()
            }
        }
    }

    static func displayErrorMessage(from rawMessage: String) -> String {
        if let existingPath = existingTorrentDestinationPath(from: rawMessage) {
            let template = String(
                localized: "error.torrent.duplicateDestination",
                defaultValue: """
                An item with this name already exists in the destination. Harbor stopped the torrent to avoid overwriting or truncating it.

                Existing item:
                %@

                Move, rename, or delete the existing item, then retry the download.
                """,
                comment: "Friendly torrent error shown when the target file already exists. Parameter is the existing file path."
            )

            // TODO: Keep torrent backend errors structured so future localizations do not depend on parsing raw aria2 text.
            return String(format: template, existingPath)
        }

        return rawMessage
    }

    private static func existingTorrentDestinationPath(from rawMessage: String) -> String? {
        let pathStartMarker = "File "
        let pathEndMarker = " exists, but a control file"

        guard let pathStart = rawMessage.range(
            of: pathStartMarker,
            options: .caseInsensitive
        )?.upperBound else {
            return nil
        }

        guard let pathEnd = rawMessage.range(
            of: pathEndMarker,
            options: .caseInsensitive,
            range: pathStart ..< rawMessage.endIndex
        )?.lowerBound else {
            return nil
        }

        let path = rawMessage[pathStart ..< pathEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return path.isEmpty ? nil : path
    }
}
