import Foundation

nonisolated struct Aria2NextMagnetStatus: Decodable, Sendable {
    nonisolated struct File: Decodable, Sendable {
        let index: String
        let path: String
        let length: String
    }

    nonisolated struct BitTorrent: Decodable, Sendable {
        nonisolated struct Info: Decodable, Sendable {
            let name: String
        }

        let info: Info?
        let infoHashV1: String?
        let infoHashV2: String?
    }

    let status: String
    let errorMessage: String?
    let infoHash: String?
    let files: [File]
    let bittorrent: BitTorrent?

    func preview(relativeTo directoryURL: URL) throws -> TorrentContentsPreview? {
        guard let name = bittorrent?.info?.name,
              name.isEmpty == false,
              let resolvedInfoHash = bittorrent?.infoHashV1 ?? bittorrent?.infoHashV2 ?? infoHash,
              files.isEmpty == false else {
            return nil
        }

        var totalBytes: Int64 = 0
        let descriptors = try files.map { file in
            guard let index = Int(file.index), index > 0,
                  let byteCount = Int64(file.length), byteCount >= 0 else {
                throw TorrentMetainfoError.invalidFile
            }
            let (sum, overflow) = totalBytes.addingReportingOverflow(byteCount)
            guard overflow == false else {
                throw TorrentMetainfoError.invalidFile
            }
            totalBytes = sum

            return TorrentFileDescriptor(
                index: index,
                path: displayPath(for: file.path, torrentName: name, directoryURL: directoryURL),
                byteCount: byteCount
            )
        }

        return TorrentContentsPreview(
            name: name,
            files: descriptors,
            totalBytes: totalBytes,
            metainfoData: nil,
            infoHash: resolvedInfoHash.lowercased()
        )
    }

    private func displayPath(
        for path: String,
        torrentName: String,
        directoryURL: URL
    ) -> String {
        let rootPath = directoryURL.standardizedFileURL.path + "/"
        let filePath = URL(fileURLWithPath: path).standardizedFileURL.path
        let relativePath = filePath.hasPrefix(rootPath)
            ? String(filePath.dropFirst(rootPath.count))
            : URL(fileURLWithPath: path).lastPathComponent
        let components = relativePath.split(separator: "/").map(String.init)
        if components.count > 1, components.first == torrentName {
            return components.dropFirst().joined(separator: "/")
        }
        return components.joined(separator: "/")
    }
}
