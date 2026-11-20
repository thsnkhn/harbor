import AppKit
import Foundation
import UniformTypeIdentifiers

enum TorrentTrackerListLoader {
    @MainActor
    static func chooseFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.prompt = String(localized: "Import")
        return panel.runModal() == .OK ? panel.url : nil
    }

    nonisolated static func trackers(fromFileAt url: URL) throws -> [String] {
        try TorrentTrackerListParser.trackers(from: Data(contentsOf: url))
    }

    nonisolated static func trackers(
        fromSource value: String,
        proxySettings: NetworkProxySettings
    ) async throws -> [String] {
        guard let components = URLComponents(
            string: value.trimmingCharacters(in: .whitespacesAndNewlines)
        ), let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           components.host?.isEmpty == false,
           let url = components.url else {
            throw TorrentTrackerListError.invalidURL
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        try proxySettings.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw proxySettings.downloadError(from: error)
        }
        if let response = response as? HTTPURLResponse,
           (200 ... 299).contains(response.statusCode) == false {
            throw TorrentTrackerListError.httpStatus(response.statusCode)
        }
        return try TorrentTrackerListParser.trackers(from: data)
    }
}
