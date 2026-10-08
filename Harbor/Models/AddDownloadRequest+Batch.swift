import Foundation

extension AddDownloadRequest {
    /// Builds one request per supported URL, all sharing the same destination
    /// folder and start behavior. Skip unsupported URLs and media that has not
    /// passed metadata validation.
    ///
    /// Used by `AddDownloadSheet` when the source field contains more than one
    /// link, so a pasted list can be queued in a single step.
    static func batch(
        from urls: [URL],
        destinationFolder: URL,
        shouldStartImmediately: Bool,
        requestHeaders: [RequestHeader] = [],
        tags: [String] = [],
        mediaMetadata: [URL: MediaDownloadMetadata] = [:],
        mediaDefaults: MediaDownloadDefaults = .init()
    ) -> [AddDownloadRequest] {
        urls.compactMap { url in
            guard let sourceKind = DownloadSourceKind.detect(from: url) else {
                return nil
            }

            let metadata = mediaMetadata[url]
            if AddDownloadMediaResolver.isKnownMediaHost(url), metadata == nil { return nil }
            if metadata != nil, !requestHeaders.isEmpty { return nil }

            // TODO: Reuse the single-link format picker when batch rows support format overrides.
            let preference: MediaDownloadFormatPreference?
            if let metadata {
                guard let resolved = try? mediaDefaults.preference(for: metadata) else { return nil }
                preference = resolved
            } else {
                preference = nil
            }

            return AddDownloadRequest(
                sourceKind: metadata == nil ? sourceKind : .mediaURL,
                sourceURL: url,
                customFilename: nil,
                destinationFolder: destinationFolder,
                shouldStartImmediately: shouldStartImmediately,
                requestHeaders: requestHeaders,
                mediaMetadata: metadata,
                mediaFormatPreference: preference,
                tags: tags
            )
        }
    }
}
