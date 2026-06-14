import Foundation

actor DownloadPersistence {
    private let fileManager: FileManager
    private let fileURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager

        let applicationSupportURL = Self.applicationSupportOverrideURL()
            ?? (try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            ))
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        let directoryURL = applicationSupportURL.appendingPathComponent("Harbor", isDirectory: true)
        self.fileURL = directoryURL.appendingPathComponent("downloads.json")
    }

    func load() throws -> [DownloadRecord] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([DownloadRecord].self, from: data)
    }

    func save(_ records: [DownloadRecord]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: [.atomic])
    }

    private static func applicationSupportOverrideURL() -> URL? {
        if let path = nonBlankPath(ProcessInfo.processInfo.environment["HARBOR_APPLICATION_SUPPORT_DIR"]) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        guard let index = CommandLine.arguments.firstIndex(of: "--harbor-application-support-directory") else {
            return nil
        }

        let valueIndex = CommandLine.arguments.index(after: index)
        guard CommandLine.arguments.indices.contains(valueIndex),
              let path = nonBlankPath(CommandLine.arguments[valueIndex]) else {
            return nil
        }

        // TODO: Keep this CLI hook for release smoke tests until Harbor has a formal UI test target.
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func nonBlankPath(_ path: String?) -> String? {
        let trimmed = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
