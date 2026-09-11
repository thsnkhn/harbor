import Foundation

struct DownloadPersistenceRevision: Equatable, Sendable {
    let writerIdentifier: UUID
    let value: UInt64
}

actor DownloadPersistence {
    private let fileManager: FileManager
    private let fileURL: URL
    private var latestRevisionByWriter: [UUID: UInt64] = [:]

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        let resolvedDirectoryURL = directoryURL
            ?? HarborApplicationSupport.directoryURL(fileManager: fileManager)
        self.fileURL = resolvedDirectoryURL.appendingPathComponent("downloads.json")
    }

    func load() throws -> [DownloadRecord] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch let error as POSIXError where error.code == .ENOENT {
            return []
        }
        return try JSONDecoder().decode([DownloadRecord].self, from: data)
    }

    func save(_ records: [DownloadRecord]) throws {
        try write(records)
    }

    func save(
        _ records: [DownloadRecord],
        revision: DownloadPersistenceRevision
    ) throws {
        guard revision.value > (latestRevisionByWriter[revision.writerIdentifier] ?? 0) else {
            return
        }

        try write(records)
        latestRevisionByWriter[revision.writerIdentifier] = revision.value
    }

    private func write(_ records: [DownloadRecord]) throws {
        let directoryURL = fileURL.deletingLastPathComponent()
        try DurableFileSystem.createDirectoryIfNeeded(at: directoryURL, fileManager: fileManager)
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: [.atomic])
        try DurableFileSystem.synchronizeFile(at: fileURL)
        try DurableFileSystem.synchronizeDirectory(at: directoryURL)
    }

}
