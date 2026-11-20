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
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let limit = TorrentTrackerListParser.maximumBytes
        var data = Data()
        while data.count <= limit,
              let chunk = try file.read(upToCount: limit + 1 - data.count),
              chunk.isEmpty == false {
            data.append(chunk)
        }
        return try TorrentTrackerListParser.trackers(from: data)
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
        defer { session.invalidateAndCancel() }

        var data = Data()
        do {
            let (bytes, response) = try await session.bytes(from: url)
            if let response = response as? HTTPURLResponse,
               (200 ... 299).contains(response.statusCode) == false {
                throw TorrentTrackerListError.httpStatus(response.statusCode)
            }
            for try await byte in bytes {
                data.append(byte)
                if data.count > TorrentTrackerListParser.maximumBytes {
                    break
                }
            }
        } catch let error as URLError {
            throw proxySettings.downloadError(from: error)
        }
        return try TorrentTrackerListParser.trackers(from: data)
    }
}
