import CryptoKit
import Foundation

struct ManagedTorrentSource: Equatable, Sendable {
    let fingerprint: String
    let sourceFingerprint: String
    let managedURL: URL
    let originalURL: URL
}

enum ManagedTorrentSourceStoreError: LocalizedError {
    case emptyTorrent
    case torrentTooLarge

    var errorDescription: String? {
        switch self {
        case .emptyTorrent:
            String(
                localized: "torrent.import.empty",
                defaultValue: "The torrent file is empty.",
                comment: "Error shown when a selected torrent file has no data."
            )
        case .torrentTooLarge:
            String(
                localized: "torrent.import.tooLarge",
                defaultValue: "The torrent file is too large.",
                comment: "Error shown when a torrent file exceeds Harbor's safe metadata size limit."
            )
        }
    }
}

actor ManagedTorrentSourceStore {
    private let fileManager: FileManager
    private let directoryURL: URL

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL ?? Self.defaultDirectoryURL(fileManager: fileManager)
    }

    func prepareLocalTorrent(
        at sourceURL: URL,
        originalURL: URL? = nil
    ) throws -> ManagedTorrentSource {
        let didAccessSecurityScopedResource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Self.loadTorrentData(at: sourceURL, fileManager: fileManager)
        return try persist(data: data, originalURL: originalURL ?? sourceURL)
    }

    func fetchRemoteTorrent(
        from remoteURL: URL,
        requestHeaders: [RequestHeader],
        proxySettings: NetworkProxySettings = .system
    ) async throws -> ManagedTorrentSource {
        let data = try await TorrentSourceLoader.fetch(
            from: remoteURL,
            requestHeaders: requestHeaders,
            proxySettings: proxySettings
        )
        return try persist(data: data, originalURL: remoteURL)
    }

    func prepareTorrentData(
        _ data: Data,
        originalURL: URL
    ) throws -> ManagedTorrentSource {
        try persist(data: data, originalURL: originalURL)
    }

    func fingerprint(forTorrentAt sourceURL: URL) throws -> String {
        let data = try Self.loadTorrentData(at: sourceURL, fileManager: fileManager)
        guard data.isEmpty == false else {
            throw ManagedTorrentSourceStoreError.emptyTorrent
        }
        return Self.fingerprint(for: data)
    }

    func torrent(at sourceURL: URL, matches fingerprint: String) -> Bool {
        guard let currentFingerprint = try? self.fingerprint(forTorrentAt: sourceURL) else {
            return false
        }

        return currentFingerprint == fingerprint
    }

    func containsManagedTorrent(at sourceURL: URL, matching fingerprint: String) -> Bool {
        let directory = directoryURL.standardizedFileURL
        let candidate = sourceURL.standardizedFileURL
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"

        guard candidate.path.hasPrefix(directoryPath) else {
            return false
        }

        return torrent(at: candidate, matches: fingerprint)
    }

    nonisolated static func fingerprint(for data: Data) -> String {
        if let infoDictionaryRange = TorrentMetainfoParser.infoDictionaryRange(in: data) {
            return Insecure.SHA1.hash(data: data[infoDictionaryRange])
                .map { String(format: "%02x", $0) }
                .joined()
        }

        // Keep deterministic handling for malformed legacy inputs so callers can surface the
        // parser error through aria2 without losing managed-source deduplication.
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func sourceFingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func loadTorrentData(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> Data {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if let size = attributes[.size] as? NSNumber,
           size.int64Value > Int64(TorrentMetainfoParser.maximumMetainfoBytes) {
            throw ManagedTorrentSourceStoreError.torrentTooLarge
        }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= TorrentMetainfoParser.maximumMetainfoBytes else {
            throw ManagedTorrentSourceStoreError.torrentTooLarge
        }
        return data
    }

    nonisolated static func normalizedInfoHash(_ value: String?) -> String? {
        guard let value = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            value.isEmpty == false else {
            return nil
        }

        if value.count == 40, value.allSatisfy(\.isHexDigit) {
            return value
        }

        guard value.count == 32,
              let decoded = decodeBase32(value),
              decoded.count == 20 else {
            return nil
        }

        return decoded.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func decodeBase32(_ value: String) -> [UInt8]? {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        let lookup = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) })
        var accumulator: UInt64 = 0
        var bitCount = 0
        var bytes: [UInt8] = []

        for character in value {
            guard let decoded = lookup[character] else {
                return nil
            }

            accumulator = (accumulator << 5) | UInt64(decoded)
            bitCount += 5

            if bitCount >= 8 {
                bitCount -= 8
                bytes.append(UInt8((accumulator >> UInt64(bitCount)) & 0xff))
                accumulator &= bitCount == 0 ? 0 : (1 << UInt64(bitCount)) - 1
            }
        }

        return bitCount == 0 ? bytes : nil
    }

    private func persist(data: Data, originalURL: URL) throws -> ManagedTorrentSource {
        guard data.isEmpty == false else {
            throw ManagedTorrentSourceStoreError.emptyTorrent
        }
        guard data.count <= TorrentMetainfoParser.maximumMetainfoBytes else {
            throw ManagedTorrentSourceStoreError.torrentTooLarge
        }

        let fingerprint = Self.fingerprint(for: data)
        let managedURL = directoryURL.appendingPathComponent("\(fingerprint).torrent", isDirectory: false)
        if fileManager.fileExists(atPath: managedURL.path) == false {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: managedURL, options: .atomic)
        }

        return ManagedTorrentSource(
            fingerprint: fingerprint,
            sourceFingerprint: Self.sourceFingerprint(for: data),
            managedURL: managedURL,
            originalURL: originalURL
        )
    }

    nonisolated private static func defaultDirectoryURL(fileManager: FileManager) -> URL {
        HarborApplicationSupport.directoryURL(fileManager: fileManager)
            .appendingPathComponent("TorrentSources", isDirectory: true)
    }
}
