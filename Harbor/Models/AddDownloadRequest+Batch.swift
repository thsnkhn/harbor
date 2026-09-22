import Foundation

extension AddDownloadRequest {
    /// Builds one request per supported URL, all sharing the same destination
    /// folder and start behavior. Unsupported URLs are dropped.
    ///
    /// Used by `AddDownloadSheet` when the source field contains more than one
    /// link, so a pasted list can be queued in a single step.
    static func batch(
        from urls: [URL],
        destinationFolder: URL,
        shouldStartImmediately: Bool,
        requestHeaders: [RequestHeader] = [],
        tags: [String] = []
    ) -> [AddDownloadRequest] {
        urls.compactMap { url in
            guard let sourceKind = DownloadSourceKind.detect(from: url) else {
                return nil
            }

            return AddDownloadRequest(
                sourceKind: sourceKind,
                sourceURL: url,
                customFilename: nil,
                destinationFolder: destinationFolder,
                shouldStartImmediately: shouldStartImmediately,
                requestHeaders: requestHeaders,
                tags: tags
            )
        }
    }
}
