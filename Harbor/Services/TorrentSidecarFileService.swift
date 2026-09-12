import Foundation

nonisolated struct TorrentSidecarContext: Sendable {
    let destinationFolderURL: URL
    let sourceKind: DownloadSourceKind
    let torrentFingerprint: String?
    let fileLocationURL: URL?
    let payloadURLs: [URL]
}

nonisolated struct TorrentSidecarFileService {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func hideExistingSidecars(for context: TorrentSidecarContext) {
        for url in verifiedExistingSidecarURLs(for: context) {
            var values = URLResourceValues()
            values.isHidden = true
            var mutableURL = url
            try? mutableURL.setResourceValues(values)
        }
    }

    func removeExistingSidecars(for context: TorrentSidecarContext) throws {
        for url in verifiedExistingSidecarURLs(for: context) {
            try fileManager.removeItem(at: url)
        }
    }

    func removeExistingControlFiles(for context: TorrentSidecarContext) throws {
        for url in existingControlFileURLs(for: context) {
            try fileManager.removeItem(at: url)
        }
    }

    func magnetMetadataURL(for context: TorrentSidecarContext) -> URL? {
        verifiedMetadataURLs(for: context).first
    }

    func removeMagnetMetadata(for context: TorrentSidecarContext) throws {
        for metadataURL in verifiedMetadataURLs(for: context) {
            try fileManager.removeItem(at: metadataURL)
        }
    }

    private func verifiedExistingSidecarURLs(for context: TorrentSidecarContext) -> [URL] {
        var candidates = Set(existingControlFileURLs(for: context))

        for metadataURL in verifiedMetadataURLs(for: context) {
            candidates.insert(metadataURL)

            let metadataControlURL = URL(fileURLWithPath: metadataURL.path + ".aria2")
                .standardizedFileURL
            if isDescendant(
                metadataControlURL,
                of: context.destinationFolderURL.standardizedFileURL
            ) {
                candidates.insert(metadataControlURL)
            }
        }

        return candidates
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    private func existingControlFileURLs(for context: TorrentSidecarContext) -> [URL] {
        let destinationURL = context.destinationFolderURL.standardizedFileURL
        var candidates = Set<URL>()

        for payloadURL in context.payloadURLs + [context.fileLocationURL].compactMap({ $0 }) {
            let controlURL = URL(fileURLWithPath: payloadURL.path + ".aria2").standardizedFileURL
            if isDescendant(controlURL, of: destinationURL) {
                candidates.insert(controlURL)
            }
        }

        if context.sourceKind == .magnetLink,
           let fingerprint = ManagedTorrentSourceStore.normalizedInfoHash(context.torrentFingerprint) {
            let metadataControlURL = destinationURL
                .appendingPathComponent("\(fingerprint).torrent.aria2", isDirectory: false)
                .standardizedFileURL
            candidates.insert(metadataControlURL)
        }

        return candidates
            .filter { fileManager.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
    }

    private func verifiedMetadataURLs(for context: TorrentSidecarContext) -> [URL] {
        guard let fingerprint = ManagedTorrentSourceStore.normalizedInfoHash(context.torrentFingerprint),
              let entries = try? fileManager.contentsOfDirectory(
                at: context.destinationFolderURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ) else { return [] }

        return entries.filter { url in
            // Only generated hash names are support files; preserve user-named torrents.
            guard url.pathExtension == "torrent",
                  ManagedTorrentSourceStore.normalizedInfoHash(url.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true,
                  let data = try? ManagedTorrentSourceStore.loadTorrentData(at: url, fileManager: fileManager)
            else { return false }
            return ManagedTorrentSourceStore.fingerprint(for: data) == fingerprint
        }.sorted { $0.path < $1.path }
    }

    private func isDescendant(_ candidateURL: URL, of directoryURL: URL) -> Bool {
        let directoryPath = directoryURL.path.hasSuffix("/")
            ? directoryURL.path
            : directoryURL.path + "/"
        return candidateURL.path.hasPrefix(directoryPath)
    }
}
