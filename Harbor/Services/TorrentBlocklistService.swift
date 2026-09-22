import Foundation

actor TorrentBlocklistService {
    typealias Downloader = @Sendable (URL, NetworkProxySettings) async throws -> Data
    typealias Apply = @Sendable ([String]) async throws -> TorrentBlocklistApplication

    private struct Cache: Codable {
        let sourceURL: URL
        let rules: [String]
        let lastUpdated: Date
    }

    private let fileManager: FileManager
    private let cacheURL: URL
    private let downloader: Downloader
    private let apply: Apply

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        downloader: Downloader? = nil,
        apply: @escaping Apply
    ) {
        self.fileManager = fileManager
        self.cacheURL = (directoryURL
            ?? HarborApplicationSupport.directoryURL(fileManager: fileManager))
            .appendingPathComponent("torrent-blocklist.json", isDirectory: false)
        self.downloader = downloader ?? Self.download
        self.apply = apply
    }

    func activate(
        source: String,
        proxySettings: NetworkProxySettings
    ) async throws -> TorrentBlocklistStatus {
        let sourceURL = try Self.sourceURL(from: source)
        if let cache = loadCache(), cache.sourceURL == sourceURL {
            let application = try await apply(cache.rules)
            return TorrentBlocklistStatus(
                ruleCount: application.ruleCount,
                lastUpdated: cache.lastUpdated
            )
        }
        return try await refresh(source: source, proxySettings: proxySettings)
    }

    func refresh(
        source: String,
        proxySettings: NetworkProxySettings
    ) async throws -> TorrentBlocklistStatus {
        let sourceURL = try Self.sourceURL(from: source)
        let data = try await downloader(sourceURL, proxySettings)
        let rules = try TorrentBlocklistParser.rules(from: data)
        let application = try await apply(rules)
        let cache = Cache(sourceURL: sourceURL, rules: rules, lastUpdated: .now)
        try persist(cache)
        return TorrentBlocklistStatus(
            ruleCount: application.ruleCount,
            lastUpdated: cache.lastUpdated
        )
    }

    func disable() async throws {
        _ = try await apply([])
    }

    private func loadCache() -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL) else {
            return nil
        }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func persist(_ cache: Cache) throws {
        let directoryURL = cacheURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: cacheURL)
        try DurableFileSystem.synchronizeDirectory(at: directoryURL)
    }

    private nonisolated static func sourceURL(from value: String) throws -> URL {
        guard let components = URLComponents(
            string: value.trimmingCharacters(in: .whitespacesAndNewlines)
        ), let scheme = components.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           components.host?.isEmpty == false,
           let url = components.url else {
            throw TorrentBlocklistError.invalidURL
        }
        return url
    }

    private nonisolated static func download(
        from url: URL,
        proxySettings: NetworkProxySettings
    ) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        try proxySettings.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(from: url)
        } catch {
            throw proxySettings.downloadError(from: error)
        }
        if let response = response as? HTTPURLResponse,
           (200 ... 299).contains(response.statusCode) == false {
            throw TorrentBlocklistError.httpStatus(response.statusCode)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        if let byteCount = attributes[.size] as? NSNumber,
           byteCount.intValue > TorrentBlocklistParser.maximumBytes {
            throw TorrentBlocklistError.tooLarge
        }
        return try Data(contentsOf: temporaryURL)
    }

}
