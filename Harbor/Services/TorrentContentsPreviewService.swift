import Foundation

struct TorrentContentsPreviewService: Sendable {
    func preview(
        sourceKind: DownloadSourceKind,
        sourceURL: URL,
        requestHeaders: [RequestHeader],
        proxySettings: NetworkProxySettings,
        torrentService: Aria2TorrentService
    ) async throws -> TorrentContentsPreview {
        switch sourceKind {
        case .magnetLink:
            return try await torrentService.previewMagnetContents(at: sourceURL)
        case .torrentFile:
            let data: Data
            if sourceURL.isFileURL {
                data = try readLocalTorrent(at: sourceURL)
            } else {
                data = try await TorrentSourceLoader.fetch(
                    from: sourceURL,
                    requestHeaders: requestHeaders,
                    proxySettings: proxySettings
                )
            }
            return try TorrentMetainfoParser.preview(from: data)
        case .directURL, .mediaURL:
            throw TorrentEngineError.invalidSource
        }
    }

    private func readLocalTorrent(at sourceURL: URL) throws -> Data {
        let didAccessSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }
        return try ManagedTorrentSourceStore.loadTorrentData(at: sourceURL)
    }
}
