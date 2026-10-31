import Foundation

/// Saves the volume used by each download before an engine can write bytes.
nonisolated final class DownloadStorageLocations: @unchecked Sendable {
    private struct Location: Codable {
        // A nil root keeps downloads from older releases in their existing stores.
        let root: URL?
        let volume: URL?
        let volumeUUID: String?
    }

    private struct SavedLocations: Codable {
        let locations: [String: Location]
        let importedLegacyRecords: Bool
        let legacyDirectories: [String: URL]
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var locations: [String: Location] = [:]
    private var loadError: Error?
    private var importedLegacyRecords = false
    private var legacyDirectories: [String: URL] = [:]

    init(directoryURL: URL = HarborApplicationSupport.directoryURL()) {
        fileURL = directoryURL.appendingPathComponent("download-storage.json")
        do {
            if try DurableFileSystem.itemExists(at: fileURL) {
                let saved = try JSONDecoder().decode(SavedLocations.self, from: Data(contentsOf: fileURL))
                locations = saved.locations
                importedLegacyRecords = saved.importedLegacyRecords
                legacyDirectories = saved.legacyDirectories
            }
        } catch {
            loadError = error
        }
    }

    func checkReadable() throws {
        try lock.withLock {
            if let loadError { throw loadError }
        }
    }

    func preserveLegacyLocations(for ids: [UUID], directories: [String: URL] = [:]) throws {
        try lock.withLock {
            if let loadError { throw loadError }
            guard importedLegacyRecords == false else { return }
            var updated = locations
            for id in ids where updated[id.uuidString] == nil {
                updated[id.uuidString] = Location(root: nil, volume: nil, volumeUUID: nil)
            }
            try save(updated, finishingLegacyMigration: true, legacyDirectories: directories)
        }
    }

    func prepare(id: UUID, destination: URL, customRoot: URL? = nil) throws {
        try lock.withLock {
            if let loadError { throw loadError }
            if locations[id.uuidString] == nil {
                let root = (customRoot ?? destination.appendingPathComponent(".harbor-downloads", isDirectory: true))
                    .standardizedFileURL.resolvingSymlinksInPath()
                // The save folder must exist. Do not recreate an absent external mount on the startup disk.
                let destinationValues = try destination.resourceValues(forKeys: [.isDirectoryKey])
                guard destinationValues.isDirectory == true else { throw Self.unavailable }
                let values = try existingAncestor(of: root).resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey])
                guard let volume = values.volume else { throw Self.unavailable }
                let location = Location(root: root, volume: volume, volumeUUID: values.volumeUUIDString)
                try validate(location)
                var updated = locations
                updated[id.uuidString] = location
                try save(updated)
            }
            if let location = locations[id.uuidString] {
                try validate(location)
                if let root = location.root {
                    try DurableFileSystem.createDirectoryIfNeeded(at: root, fileManager: .default)
                }
            }
        }
    }

    func requireAvailable(id: UUID) throws {
        try lock.withLock {
            if let loadError { throw loadError }
            if let location = locations[id.uuidString] { try validate(location) }
        }
    }

    func directory(for id: UUID, name: String, legacy: URL) -> URL {
        lock.withLock {
            guard let location = locations[id.uuidString] else { return legacy }
            return location.root?.appendingPathComponent(name, isDirectory: true) ?? legacyDirectories[name] ?? legacy
        }
    }

    func directories(name: String, legacy: URL) -> [URL] {
        lock.withLock {
            Array(Set([legacy] + [legacyDirectories[name]].compactMap { $0 }
                + locations.values.compactMap { $0.root?.appendingPathComponent(name, isDirectory: true) }))
        }
    }

    private func validate(_ location: Location) throws {
        guard let root = location.root, let volume = location.volume else { return }
        do {
            let values = try volume.resourceValues(forKeys: [.isVolumeKey, .volumeUUIDStringKey])
            let ancestor = try existingAncestor(of: root).resourceValues(forKeys: [.volumeURLKey])
            guard values.isVolume == true,
                  values.volumeUUIDString == location.volumeUUID,
                  ancestor.volume?.standardizedFileURL == volume.standardizedFileURL else {
                throw Self.unavailable
            }
        } catch {
            throw Self.unavailable
        }
    }

    private func existingAncestor(of url: URL) throws -> URL {
        var candidate = url
        while try DurableFileSystem.itemExists(at: candidate) == false {
            let parent = candidate.deletingLastPathComponent()
            guard parent != candidate else { throw Self.unavailable }
            candidate = parent
        }
        return candidate.resolvingSymlinksInPath()
    }

    private func save(
        _ updated: [String: Location],
        finishingLegacyMigration: Bool = false,
        legacyDirectories: [String: URL]? = nil
    ) throws {
        try DurableFileSystem.createDirectoryIfNeeded(at: fileURL.deletingLastPathComponent(), fileManager: .default)
        let saved = SavedLocations(
            locations: updated,
            importedLegacyRecords: importedLegacyRecords || finishingLegacyMigration,
            legacyDirectories: legacyDirectories ?? self.legacyDirectories
        )
        try JSONEncoder().encode(saved).write(to: fileURL, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: fileURL)
        try DurableFileSystem.synchronizeParentDirectory(of: fileURL)
        locations = updated
        importedLegacyRecords = saved.importedLegacyRecords
        self.legacyDirectories = saved.legacyDirectories
    }

    private static var unavailable: CocoaError {
        CocoaError(.fileWriteVolumeReadOnly, userInfo: [NSLocalizedDescriptionKey:
            "The download drive is not available. Reconnect the drive and resume the download."])
    }

    // TODO: Retire unused locations after their recovery files and completion journals are removed.
}
