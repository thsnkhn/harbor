import Foundation

struct AddDownloadRequest: Sendable {
    let sourceKind: DownloadSourceKind
    let sourceURL: URL
    let customFilename: String?
    let destinationFolder: URL
    let shouldStartImmediately: Bool
    let requestHeaders: [RequestHeader]
    let mediaMetadata: MediaDownloadMetadata?
    let mediaFormatPreference: MediaDownloadFormatPreference?
    let torrentFileSelection: TorrentFileSelection?
    let preparedTorrentMetainfo: Data?
    let torrentMetadataName: String?
    let torrentOperation: TorrentOperationIntent
    let torrentExistingDataPath: String?

    init(
        sourceKind: DownloadSourceKind,
        sourceURL: URL,
        customFilename: String?,
        destinationFolder: URL,
        shouldStartImmediately: Bool,
        requestHeaders: [RequestHeader] = [],
        mediaMetadata: MediaDownloadMetadata? = nil,
        mediaFormatPreference: MediaDownloadFormatPreference? = nil,
        torrentFileSelection: TorrentFileSelection? = nil,
        preparedTorrentMetainfo: Data? = nil,
        torrentMetadataName: String? = nil,
        torrentOperation: TorrentOperationIntent = .download,
        torrentExistingDataPath: String? = nil
    ) {
        self.sourceKind = sourceKind
        self.sourceURL = sourceURL
        self.customFilename = customFilename
        self.destinationFolder = destinationFolder
        self.shouldStartImmediately = shouldStartImmediately
        self.requestHeaders = requestHeaders
        self.mediaMetadata = mediaMetadata
        self.mediaFormatPreference = mediaFormatPreference
        self.torrentFileSelection = torrentFileSelection
        self.preparedTorrentMetainfo = preparedTorrentMetainfo
        self.torrentMetadataName = torrentMetadataName
        self.torrentOperation = torrentOperation
        self.torrentExistingDataPath = torrentExistingDataPath
    }
}
