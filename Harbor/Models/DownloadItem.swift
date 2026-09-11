import Foundation
import Observation

enum DownloadStatus: String, Codable, CaseIterable, Sendable {
    case queued
    case preparing
    case downloading
    case seeding
    case browserSessionRequired
    case paused
    case completed
    case failed
    case cancelled
    case waitingToRetry

    var title: LocalizedStringResource {
        switch self {
        case .queued:
            LocalizedStringResource("status.queued", defaultValue: "Queued")
        case .preparing:
            LocalizedStringResource("status.preparing", defaultValue: "Preparing")
        case .waitingToRetry:
            LocalizedStringResource("status.waitingToRetry", defaultValue: "Waiting to Retry")
        case .downloading:
            LocalizedStringResource("status.downloading", defaultValue: "Downloading")
        case .seeding:
            LocalizedStringResource("status.seeding", defaultValue: "Seeding")
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
        case .waitingToRetry:
            "clock.arrow.circlepath"
        case .downloading:
            "arrow.down.circle.fill"
        case .seeding:
            "arrow.up.circle.fill"
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
        case .queued, .preparing, .waitingToRetry, .downloading, .seeding, .browserSessionRequired, .paused:
            false
        }
    }

    var isRunning: Bool {
        self == .preparing || self == .waitingToRetry || self == .downloading
    }

    var consumesDownloadSlot: Bool {
        self == .preparing || self == .downloading
    }
}

enum DownloadActivityKind: String, Codable, Sendable {
    case added
    case queued
    case started
    case resumed
    case paused
    case seedingStarted
    case seedingStopped
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
    let uploadedBytes: Int64
    let createdAt: Date
    let startedAt: Date?
    let finishedAt: Date?
    let updatedAt: Date
    let lastError: String?
    /// Opaque resume data produced by URLSession for direct downloads created
    /// before Harbor owned its partial files. The field remains in the persisted
    /// model only so startup can perform a one-time import. New direct downloads
    /// never populate it; WebKit continuation data uses `browserResumeData`.
    let resumeData: Data?
    let browserResumeData: Data?
    let requestHeaders: [RequestHeader]
    let backendIdentifier: String?
    let metadataName: String?
    let mediaMetadata: MediaDownloadMetadata?
    let mediaFormatPreference: MediaDownloadFormatPreference?
    let requiresMediaRecoveryReset: Bool
    let mediaOutputConflictIdentifier: UUID?
    let downloadLimitOverride: TransferLimitOverride
    let uploadLimitOverride: TransferLimitOverride
    let torrentFingerprint: String?
    let torrentSourceFingerprint: String?
    let managedTorrentSourcePath: String?
    let torrentFileSelection: TorrentFileSelection?
    let torrentPayloadPaths: [String]
    let torrentCheckState: TorrentCheckState?
    let torrentExistingDataPath: String?
    let shouldSeedAfterDownload: Bool
    let wasSuspendedForNetworkBinding: Bool
    let removeOriginalTorrentAfterImport: Bool
    let completionNotificationDelivered: Bool
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
        case uploadedBytes
        case createdAt
        case startedAt
        case finishedAt
        case updatedAt
        case lastError
        case resumeData
        case browserResumeData
        case requestHeaders
        case backendIdentifier
        case metadataName
        case mediaMetadata
        case mediaFormatPreference
        case requiresMediaRecoveryReset
        case mediaOutputConflictIdentifier
        case downloadLimitOverride
        case uploadLimitOverride
        case torrentFingerprint
        case torrentSourceFingerprint
        case managedTorrentSourcePath
        case torrentFileSelection
        case torrentPayloadPaths
        case torrentCheckState
        case torrentExistingDataPath
        case shouldSeedAfterDownload
        case wasSuspendedForNetworkBinding
        case removeOriginalTorrentAfterImport
        case completionNotificationDelivered
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
        uploadedBytes: Int64 = 0,
        createdAt: Date,
        startedAt: Date?,
        finishedAt: Date?,
        updatedAt: Date,
        lastError: String?,
        resumeData: Data?,
        browserResumeData: Data? = nil,
        requestHeaders: [RequestHeader] = [],
        backendIdentifier: String?,
        metadataName: String?,
        mediaMetadata: MediaDownloadMetadata? = nil,
        mediaFormatPreference: MediaDownloadFormatPreference? = nil,
        requiresMediaRecoveryReset: Bool = false,
        mediaOutputConflictIdentifier: UUID? = nil,
        downloadLimitOverride: TransferLimitOverride = .inherit,
        uploadLimitOverride: TransferLimitOverride = .inherit,
        torrentFingerprint: String? = nil,
        torrentSourceFingerprint: String? = nil,
        managedTorrentSourcePath: String? = nil,
        torrentFileSelection: TorrentFileSelection? = nil,
        torrentPayloadPaths: [String] = [],
        torrentCheckState: TorrentCheckState? = nil,
        torrentExistingDataPath: String? = nil,
        shouldSeedAfterDownload: Bool? = nil,
        wasSuspendedForNetworkBinding: Bool = false,
        removeOriginalTorrentAfterImport: Bool = false,
        completionNotificationDelivered: Bool? = nil,
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
        self.uploadedBytes = uploadedBytes
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
        self.lastError = lastError
        self.resumeData = resumeData
        self.browserResumeData = browserResumeData
        self.requestHeaders = requestHeaders
        self.backendIdentifier = backendIdentifier
        self.metadataName = metadataName
        self.mediaMetadata = mediaMetadata
        self.mediaFormatPreference = mediaFormatPreference
        self.requiresMediaRecoveryReset = requiresMediaRecoveryReset
        self.mediaOutputConflictIdentifier = mediaOutputConflictIdentifier
        self.downloadLimitOverride = downloadLimitOverride
        self.uploadLimitOverride = uploadLimitOverride
        self.torrentFingerprint = torrentFingerprint
        self.torrentSourceFingerprint = torrentSourceFingerprint
        self.managedTorrentSourcePath = managedTorrentSourcePath
        self.torrentFileSelection = torrentFileSelection
        self.torrentPayloadPaths = torrentPayloadPaths
        self.torrentCheckState = torrentCheckState
        self.torrentExistingDataPath = torrentExistingDataPath
        self.shouldSeedAfterDownload = shouldSeedAfterDownload
            ?? (backend == .aria2 || sourceKind == .magnetLink || sourceKind == .torrentFile)
        self.wasSuspendedForNetworkBinding = wasSuspendedForNetworkBinding
        self.removeOriginalTorrentAfterImport = removeOriginalTorrentAfterImport
        self.completionNotificationDelivered = completionNotificationDelivered ?? (status == .completed)
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
        self.uploadedBytes = try container.decodeIfPresent(Int64.self, forKey: .uploadedBytes) ?? 0
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? .now
        self.startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        self.finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .now
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self.resumeData = try container.decodeIfPresent(Data.self, forKey: .resumeData)
        self.browserResumeData = try container.decodeIfPresent(Data.self, forKey: .browserResumeData)
        self.requestHeaders = try container.decodeIfPresent([RequestHeader].self, forKey: .requestHeaders) ?? []
        self.backendIdentifier = try container.decodeIfPresent(String.self, forKey: .backendIdentifier)
        self.metadataName = try container.decodeIfPresent(String.self, forKey: .metadataName)
        self.mediaMetadata = try container.decodeIfPresent(MediaDownloadMetadata.self, forKey: .mediaMetadata)
        self.mediaFormatPreference = try container.decodeIfPresent(MediaDownloadFormatPreference.self, forKey: .mediaFormatPreference)
        self.requiresMediaRecoveryReset = try container.decodeIfPresent(
            Bool.self,
            forKey: .requiresMediaRecoveryReset
        ) ?? false
        self.mediaOutputConflictIdentifier = try container.decodeIfPresent(
            UUID.self,
            forKey: .mediaOutputConflictIdentifier
        )
        self.downloadLimitOverride = try container.decodeIfPresent(
            TransferLimitOverride.self,
            forKey: .downloadLimitOverride
        ) ?? .inherit
        self.uploadLimitOverride = try container.decodeIfPresent(
            TransferLimitOverride.self,
            forKey: .uploadLimitOverride
        ) ?? .inherit
        self.torrentFingerprint = try container.decodeIfPresent(String.self, forKey: .torrentFingerprint)
        self.torrentSourceFingerprint = try container.decodeIfPresent(String.self, forKey: .torrentSourceFingerprint)
        self.managedTorrentSourcePath = try container.decodeIfPresent(String.self, forKey: .managedTorrentSourcePath)
        self.torrentFileSelection = try container.decodeIfPresent(TorrentFileSelection.self, forKey: .torrentFileSelection)
        self.torrentPayloadPaths = try container.decodeIfPresent([String].self, forKey: .torrentPayloadPaths) ?? []
        self.torrentCheckState = try container.decodeIfPresent(TorrentCheckState.self, forKey: .torrentCheckState)
        self.torrentExistingDataPath = try container.decodeIfPresent(String.self, forKey: .torrentExistingDataPath)
        self.shouldSeedAfterDownload = try container.decodeIfPresent(
            Bool.self,
            forKey: .shouldSeedAfterDownload
        ) ?? Self.shouldSeedLegacyTorrent(
            backend: backend,
            sourceKind: sourceKind,
            status: status
        )
        self.wasSuspendedForNetworkBinding = try container.decodeIfPresent(
            Bool.self,
            forKey: .wasSuspendedForNetworkBinding
        ) ?? false
        self.removeOriginalTorrentAfterImport = try container.decodeIfPresent(
            Bool.self,
            forKey: .removeOriginalTorrentAfterImport
        ) ?? false
        self.completionNotificationDelivered = try container.decodeIfPresent(
            Bool.self,
            forKey: .completionNotificationDelivered
        ) ?? (status == .completed)
        self.activityEvents = try container.decodeIfPresent([DownloadActivityEvent].self, forKey: .activityEvents) ?? []
    }

    private static func shouldSeedLegacyTorrent(
        backend: DownloadBackend,
        sourceKind: DownloadSourceKind,
        status: DownloadStatus
    ) -> Bool {
        let isTorrent = backend == .aria2 || sourceKind == .magnetLink || sourceKind == .torrentFile
        return isTorrent && status != .completed
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
    var uploadedBytes: Int64
    var speedBytesPerSecond: Double
    var uploadBytesPerSecond: Double
    var startedAt: Date?
    var finishedAt: Date?
    var updatedAt: Date
    var lastError: String?
    /// In-memory copy of the persisted compatibility token. Initialization
    /// clears it after attempting the one-time import, before records are saved.
    var resumeData: Data?
    var browserResumeData: Data?
    var taskIdentifier: Int?
    var backendIdentifier: String?
    var metadataName: String?
    var mediaMetadata: MediaDownloadMetadata?
    var mediaFormatPreference: MediaDownloadFormatPreference?
    var requestHeaders: [RequestHeader]
    var requiresMediaRecoveryReset: Bool
    var mediaOutputConflictIdentifier: UUID?
    var downloadLimitOverride: TransferLimitOverride
    var uploadLimitOverride: TransferLimitOverride
    var torrentFingerprint: String?
    var torrentSourceFingerprint: String?
    var managedTorrentSourcePath: String?
    var torrentFileSelection: TorrentFileSelection?
    var torrentPayloadPaths: [String]
    var torrentCheckState: TorrentCheckState?
    var torrentExistingDataPath: String?
    var torrentCheckProgress: Double?
    var shouldSeedAfterDownload: Bool
    var wasSuspendedForNetworkBinding: Bool
    var removeOriginalTorrentAfterImport: Bool
    var completionNotificationDelivered: Bool
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
        uploadedBytes: Int64 = 0,
        speedBytesPerSecond: Double = 0,
        uploadBytesPerSecond: Double = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        updatedAt: Date = .now,
        lastError: String? = nil,
        resumeData: Data? = nil,
        browserResumeData: Data? = nil,
        taskIdentifier: Int? = nil,
        backendIdentifier: String? = nil,
        metadataName: String? = nil,
        mediaMetadata: MediaDownloadMetadata? = nil,
        mediaFormatPreference: MediaDownloadFormatPreference? = nil,
        requestHeaders: [RequestHeader] = [],
        requiresMediaRecoveryReset: Bool = false,
        mediaOutputConflictIdentifier: UUID? = nil,
        downloadLimitOverride: TransferLimitOverride = .inherit,
        uploadLimitOverride: TransferLimitOverride = .inherit,
        torrentFingerprint: String? = nil,
        torrentSourceFingerprint: String? = nil,
        managedTorrentSourcePath: String? = nil,
        torrentFileSelection: TorrentFileSelection? = nil,
        torrentPayloadPaths: [String] = [],
        torrentCheckState: TorrentCheckState? = nil,
        torrentExistingDataPath: String? = nil,
        shouldSeedAfterDownload: Bool? = nil,
        wasSuspendedForNetworkBinding: Bool = false,
        removeOriginalTorrentAfterImport: Bool = false,
        completionNotificationDelivered: Bool? = nil,
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
        self.uploadedBytes = uploadedBytes
        self.speedBytesPerSecond = speedBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.updatedAt = updatedAt
        self.lastError = lastError
        self.resumeData = resumeData
        self.browserResumeData = browserResumeData
        self.taskIdentifier = taskIdentifier
        self.backendIdentifier = backendIdentifier
        self.metadataName = metadataName
        self.mediaMetadata = mediaMetadata
        self.mediaFormatPreference = mediaFormatPreference
        self.requestHeaders = requestHeaders
        self.requiresMediaRecoveryReset = requiresMediaRecoveryReset
        self.mediaOutputConflictIdentifier = mediaOutputConflictIdentifier
        self.downloadLimitOverride = downloadLimitOverride
        self.uploadLimitOverride = uploadLimitOverride
        self.torrentFingerprint = torrentFingerprint
        self.torrentSourceFingerprint = torrentSourceFingerprint
        self.managedTorrentSourcePath = managedTorrentSourcePath
        self.torrentFileSelection = torrentFileSelection
        self.torrentPayloadPaths = torrentPayloadPaths
        self.torrentCheckState = torrentCheckState
        self.torrentExistingDataPath = torrentExistingDataPath
        self.torrentCheckProgress = nil
        self.shouldSeedAfterDownload = shouldSeedAfterDownload
            ?? (backend == .aria2 || sourceKind == .magnetLink || sourceKind == .torrentFile)
        self.wasSuspendedForNetworkBinding = wasSuspendedForNetworkBinding
        self.removeOriginalTorrentAfterImport = removeOriginalTorrentAfterImport
        self.completionNotificationDelivered = completionNotificationDelivered ?? (status == .completed)
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
            uploadedBytes: record.uploadedBytes,
            speedBytesPerSecond: 0,
            uploadBytesPerSecond: 0,
            startedAt: record.startedAt,
            finishedAt: record.finishedAt,
            updatedAt: record.updatedAt,
            lastError: record.lastError,
            resumeData: record.resumeData,
            browserResumeData: record.browserResumeData,
            taskIdentifier: nil,
            backendIdentifier: record.backendIdentifier,
            metadataName: record.metadataName,
            mediaMetadata: record.mediaMetadata,
            mediaFormatPreference: record.mediaFormatPreference,
            requestHeaders: record.requestHeaders,
            requiresMediaRecoveryReset: record.requiresMediaRecoveryReset,
            mediaOutputConflictIdentifier: record.mediaOutputConflictIdentifier,
            downloadLimitOverride: record.downloadLimitOverride,
            uploadLimitOverride: record.uploadLimitOverride,
            torrentFingerprint: record.torrentFingerprint,
            torrentSourceFingerprint: record.torrentSourceFingerprint,
            managedTorrentSourcePath: record.managedTorrentSourcePath,
            torrentFileSelection: record.torrentFileSelection,
            torrentPayloadPaths: record.torrentPayloadPaths,
            torrentCheckState: record.torrentCheckState,
            torrentExistingDataPath: record.torrentExistingDataPath,
            shouldSeedAfterDownload: record.shouldSeedAfterDownload,
            wasSuspendedForNetworkBinding: record.wasSuspendedForNetworkBinding,
            removeOriginalTorrentAfterImport: record.removeOriginalTorrentAfterImport,
            completionNotificationDelivered: record.completionNotificationDelivered,
            activityEvents: record.activityEvents
        )
    }

    func restorePersistedState(from record: DownloadRecord) {
        precondition(record.id == id && record.createdAt == createdAt)
        sourceURL = record.sourceURL
        sourceKind = record.sourceKind
        backend = record.backend
        preferredFilename = record.preferredFilename
        destinationFolderPath = record.destinationFolderPath
        fileLocationPath = record.fileLocationPath
        status = record.status
        progress = record.progress
        bytesWritten = record.bytesWritten
        expectedBytes = record.expectedBytes
        speedBytesPerSecond = 0
        uploadBytesPerSecond = 0
        startedAt = record.startedAt
        finishedAt = record.finishedAt
        updatedAt = record.updatedAt
        lastError = record.lastError
        resumeData = record.resumeData
        browserResumeData = record.browserResumeData
        taskIdentifier = nil
        backendIdentifier = record.backendIdentifier
        metadataName = record.metadataName
        mediaMetadata = record.mediaMetadata
        mediaFormatPreference = record.mediaFormatPreference
        requestHeaders = record.requestHeaders
        requiresMediaRecoveryReset = record.requiresMediaRecoveryReset
        mediaOutputConflictIdentifier = record.mediaOutputConflictIdentifier
        downloadLimitOverride = record.downloadLimitOverride
        uploadLimitOverride = record.uploadLimitOverride
        torrentFingerprint = record.torrentFingerprint
        managedTorrentSourcePath = record.managedTorrentSourcePath
        torrentFileSelection = record.torrentFileSelection
        torrentPayloadPaths = record.torrentPayloadPaths
        torrentCheckState = record.torrentCheckState
        torrentExistingDataPath = record.torrentExistingDataPath
        torrentCheckProgress = nil
        shouldSeedAfterDownload = record.shouldSeedAfterDownload
        wasSuspendedForNetworkBinding = record.wasSuspendedForNetworkBinding
        removeOriginalTorrentAfterImport = record.removeOriginalTorrentAfterImport
        completionNotificationDelivered = record.completionNotificationDelivered
        activityEvents = record.activityEvents
    }

    var displayName: String {
        if isTorrent {
            if let metadataName, metadataName.isEmpty == false {
                return metadataName
            }

            if sourceKind == .magnetLink {
                let metadata = MagnetLinkMetadata(url: sourceURL)
                if let displayName = metadata.displayName {
                    return displayName
                }

                if let infoHash = metadata.infoHash {
                    return infoHash
                }
            }

            if sourceKind == .torrentFile {
                let torrentName = sourceURL.deletingPathExtension().lastPathComponent
                if torrentName.isEmpty == false {
                    return torrentName
                }
            }
        }

        if let fileLocationURL {
            return fileLocationURL.lastPathComponent
        }

        if let metadataName, metadataName.isEmpty == false {
            return metadataName
        }

        if sourceKind == .mediaURL,
           let title = mediaMetadata?.title,
           title.isEmpty == false {
            return title
        }

        if let preferredFilename, preferredFilename.isEmpty == false {
            return preferredFilename
        }

        if sourceKind == .magnetLink {
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
        case .mediaURL:
            mediaMetadata?.platform ?? sourceURL.host ?? sourceURL.absoluteString
        }
    }

    var sourceDisplayText: String {
        sourceURL.isFileURL ? sourceURL.path : sourceURL.absoluteString
    }

    var partialTorrentSelectionText: String? {
        guard let torrentFileSelection,
              torrentFileSelection.isPartial else {
            return nil
        }
        let template = String(
            localized: "torrent.selection.summary",
            defaultValue: "%d of %d files selected",
            comment: "Summary for a torrent download that includes only some files. Parameters are selected count and total count."
        )
        return String(
            format: template,
            torrentFileSelection.selectedFileCount,
            torrentFileSelection.totalFileCount
        )
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

    var shareRatio: Double? {
        guard isTorrent, expectedBytes > 0 else {
            return nil
        }

        return Double(max(uploadedBytes, 0)) / Double(expectedBytes)
    }

    var shareRatioText: String {
        DownloadFormatting.ratioString(shareRatio)
    }

    var uploadedText: String {
        DownloadFormatting.byteString(uploadedBytes)
    }

    var speedText: String {
        if speedBytesPerSecond > 0 {
            return DownloadFormatting.speedString(speedBytesPerSecond)
        }

        switch status {
        case .queued, .preparing, .waitingToRetry, .downloading:
            return String(localized: "Waiting", comment: "Speed status fallback")
        case .seeding, .browserSessionRequired, .paused, .completed, .failed, .cancelled:
            return "-"
        }
    }

    var displayedSpeedBytesPerSecond: Double {
        status == .seeding ? uploadBytesPerSecond : speedBytesPerSecond
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

    var isRunning: Bool {
        status.isRunning
    }

    var isPausedSeeder: Bool {
        backend == .aria2
            && status == .paused
            && finishedAt != nil
            && shouldSeedAfterDownload
    }

    var canPause: Bool {
        status == .preparing || status == .waitingToRetry || status == .downloading || status == .seeding
    }

    var canResume: Bool {
        torrentCheckState != .checking && (status == .paused || status == .failed || status == .queued)
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
            uploadedBytes: uploadedBytes,
            createdAt: createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            updatedAt: updatedAt,
            lastError: lastError,
            resumeData: resumeData,
            browserResumeData: browserResumeData,
            requestHeaders: requestHeaders,
            backendIdentifier: backendIdentifier,
            metadataName: metadataName,
            mediaMetadata: mediaMetadata?.persistenceSnapshot,
            mediaFormatPreference: mediaFormatPreference,
            requiresMediaRecoveryReset: requiresMediaRecoveryReset,
            mediaOutputConflictIdentifier: mediaOutputConflictIdentifier,
            downloadLimitOverride: downloadLimitOverride,
            uploadLimitOverride: uploadLimitOverride,
            torrentFingerprint: torrentFingerprint,
            torrentSourceFingerprint: torrentSourceFingerprint,
            managedTorrentSourcePath: managedTorrentSourcePath,
            torrentFileSelection: torrentFileSelection,
            torrentPayloadPaths: torrentPayloadPaths,
            torrentCheckState: torrentCheckState,
            torrentExistingDataPath: torrentExistingDataPath,
            shouldSeedAfterDownload: shouldSeedAfterDownload,
            wasSuspendedForNetworkBinding: wasSuspendedForNetworkBinding,
            removeOriginalTorrentAfterImport: removeOriginalTorrentAfterImport,
            completionNotificationDelivered: completionNotificationDelivered,
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

    private var isTorrent: Bool {
        backend == .aria2 || sourceKind == .magnetLink || sourceKind == .torrentFile
    }
}
