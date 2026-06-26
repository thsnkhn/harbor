import Foundation

struct AddDownloadRequest: Sendable {
    let sourceKind: DownloadSourceKind
    let sourceURL: URL
    let customFilename: String?
    let destinationFolder: URL
    let shouldStartImmediately: Bool
    let mediaMetadata: MediaDownloadMetadata?
    let mediaFormatPreference: MediaDownloadFormatPreference?

    init(
        sourceKind: DownloadSourceKind,
        sourceURL: URL,
        customFilename: String?,
        destinationFolder: URL,
        shouldStartImmediately: Bool,
        mediaMetadata: MediaDownloadMetadata? = nil,
        mediaFormatPreference: MediaDownloadFormatPreference? = nil
    ) {
        self.sourceKind = sourceKind
        self.sourceURL = sourceURL
        self.customFilename = customFilename
        self.destinationFolder = destinationFolder
        self.shouldStartImmediately = shouldStartImmediately
        self.mediaMetadata = mediaMetadata
        self.mediaFormatPreference = mediaFormatPreference
    }
}
