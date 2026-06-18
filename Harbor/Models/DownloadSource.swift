import Foundation

enum DownloadSourceKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case directURL
    case magnetLink
    case torrentFile

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .directURL:
            LocalizedStringResource("source.kind.directURL", defaultValue: "Direct Link")
        case .magnetLink:
            LocalizedStringResource("source.kind.magnetLink", defaultValue: "Magnet Link")
        case .torrentFile:
            LocalizedStringResource("source.kind.torrentFile", defaultValue: "Torrent File")
        }
    }

    var systemImage: String {
        switch self {
        case .directURL:
            "link"
        case .magnetLink:
            "bolt.horizontal.circle"
        case .torrentFile:
            "doc.fill"
        }
    }

    var supportsCustomFilename: Bool {
        self == .directURL
    }

    static func detect(from url: URL) -> DownloadSourceKind? {
        if url.isFileURL {
            return url.pathExtension.lowercased() == "torrent" ? .torrentFile : nil
        }

        switch url.scheme?.lowercased() {
        case "http", "https":
            if url.pathExtension.lowercased() == "torrent" {
                return .torrentFile
            }

            return .directURL
        case "magnet":
            return .magnetLink
        default:
            return nil
        }
    }
}

enum DownloadBackend: String, Codable, Sendable {
    case urlSession
    case aria2
}

struct MagnetLinkMetadata: Sendable {
    let displayName: String?
    let infoHash: String?
    let trackerURLs: [String]

    init(url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        self.displayName = queryItems.first(where: { $0.name == "dn" })?.value?
            .removingPercentEncoding?
            .nilIfBlank

        self.infoHash = queryItems
            .first(where: { $0.name == "xt" })?
            .value?
            .split(separator: ":")
            .last
            .map(String.init)?
            .nilIfBlank

        var seenTrackerURLs = Set<String>()
        self.trackerURLs = queryItems
            .filter { $0.name.lowercased() == "tr" }
            .compactMap { $0.value?.nilIfBlank }
            .filter { seenTrackerURLs.insert($0).inserted }
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
