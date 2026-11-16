import Foundation

/// Trackers Harbor adds to, or removes from, every torrent it starts.
nonisolated enum TorrentTrackerListKind: CaseIterable, Identifiable, Sendable {
    case added
    case excluded

    var id: Self { self }
}

nonisolated enum TorrentTrackerListError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case httpStatus(Int)
    case invalidEncoding
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            String(localized: "Enter an HTTP or HTTPS tracker list URL.")
        case let .httpStatus(statusCode):
            String(format: String(localized: "The tracker list server returned HTTP %d."), statusCode)
        case .invalidEncoding:
            String(localized: "The tracker list is not valid UTF-8 text.")
        case .tooLarge:
            String(localized: "The tracker list is larger than 1 MB.")
        }
    }
}

nonisolated enum TorrentTrackerListParser {
    static let maximumBytes = 64 * 1024 * 1024

    /// Reads one tracker URL per line. Blank lines, `#` comments, and invalid
    /// URLs are skipped; duplicates keep their first position.
    static func trackers(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).compactMap { line in
            let value = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            guard let url = try? TorrentTrackerError.normalizedURL(String(value)),
                  seen.insert(url).inserted else {
                return nil
            }
            return url
        }
    }

    static func trackers(from data: Data) throws -> [String] {
        guard data.count <= maximumBytes else {
            throw TorrentTrackerListError.tooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TorrentTrackerListError.invalidEncoding
        }
        return trackers(from: text)
    }
}
