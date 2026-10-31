import Foundation

struct DirectDownloadRecoveryMetadata: Codable, Equatable, Sendable {
    let sourceURL: URL
    let entityTag: String?
    let lastModified: String?
    let expectedBytes: Int64
    let suggestedFilename: String?
    let mimeType: String?

    nonisolated var ifRangeValidator: String? {
        let trimmedEntityTag = entityTag?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedEntityTag.isEmpty == false,
           trimmedEntityTag.uppercased().hasPrefix("W/") == false,
           trimmedEntityTag.first == "\"",
           trimmedEntityTag.last == "\"" {
            return trimmedEntityTag
        }

        let trimmedLastModified = lastModified?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedLastModified.isEmpty ? nil : trimmedLastModified
    }
}

struct DirectDownloadRecoverySnapshot: Equatable, Sendable {
    let bytesWritten: Int64
    let metadata: DirectDownloadRecoveryMetadata
}

enum DirectDownloadRecoveryLookup: Sendable {
    case available(DirectDownloadRecoverySnapshot)
    case absent
    case unavailable(String)
}

enum DirectDownloadRecoveryResetReason: Equatable, Sendable {
    case missingValidator
    case sourceChanged
    case invalidLength
    case serverRejectedRange
}

struct DirectDownloadRecoveryPreparation: Sendable {
    let snapshot: DirectDownloadRecoverySnapshot?
    let resetReason: DirectDownloadRecoveryResetReason?
}

final class DirectDownloadRecoveryStore: @unchecked Sendable {
    private enum IntegrityError: Error {
        case invalidMetadata
        case invalidPartial

        var resetReason: DirectDownloadRecoveryResetReason {
            switch self {
            case .invalidMetadata:
                .missingValidator
            case .invalidPartial:
                .invalidLength
            }
        }
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let storageLocations: DownloadStorageLocations?
    private let lock = NSLock()

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        storageLocations: DownloadStorageLocations? = nil
    ) {
        self.fileManager = fileManager
        self.storageLocations = storageLocations
        self.directoryURL = directoryURL
            ?? HarborApplicationSupport.directoryURL(fileManager: fileManager)
                .appendingPathComponent("DirectDownloadRecovery", isDirectory: true)
    }

    func prepareStart(
        id: UUID,
        sourceURL: URL
    ) throws -> DirectDownloadRecoveryPreparation {
        try lock.withLock {
            try storageLocations?.requireAvailable(id: id)
            do {
                let preparation = try recoveryPreparation(id: id, sourceURL: sourceURL)
                if preparation.snapshot == nil {
                    try discardLocked(id: id)
                }
                return preparation
            } catch let error as IntegrityError {
                try discardLocked(id: id)
                return DirectDownloadRecoveryPreparation(
                    snapshot: nil,
                    resetReason: error.resetReason
                )
            }
        }
    }

    func snapshot(
        id: UUID,
        sourceURL: URL
    ) -> DirectDownloadRecoverySnapshot? {
        guard case let .available(snapshot) = lookup(id: id, sourceURL: sourceURL) else {
            return nil
        }
        return snapshot
    }

    func lookup(
        id: UUID,
        sourceURL: URL
    ) -> DirectDownloadRecoveryLookup {
        lock.withLock { () -> DirectDownloadRecoveryLookup in
            do {
                try storageLocations?.requireAvailable(id: id)
                guard let snapshot = try recoveryPreparation(
                    id: id,
                    sourceURL: sourceURL
                ).snapshot else {
                    try discardLocked(id: id)
                    return .absent
                }
                return .available(snapshot)
            } catch is IntegrityError {
                do {
                    try discardLocked(id: id)
                    return .absent
                } catch {
                    return .unavailable(error.localizedDescription)
                }
            } catch {
                // Operational failures (for example, a temporarily
                // inaccessible volume) are not evidence that the recovery
                // data is invalid. Leave both files untouched so a later
                // lookup can recover them.
                return .unavailable(error.localizedDescription)
            }
        }
    }

    /// Attempts to convert a paused direct download from URLSession's former
    /// opaque resume-data representation into Harbor's owned recovery format.
    ///
    /// URLSession publicly treats resume data as an opaque token, but Harbor
    /// releases predating owned partials persisted that token. We have observed
    /// two representations: older flat property-list dictionaries and newer
    /// `NSKeyedArchiver` envelopes. Their keys are implementation details, so
    /// parsing is deliberately best-effort. Rejecting an unknown representation
    /// is safe because the download will restart instead of combining bytes whose
    /// identity or origin Harbor cannot establish.
    ///
    /// Import never replaces valid owned recovery. It also requires a matching
    /// source URL, a positive byte count within any known total, a physical file
    /// of exactly that size, a usable If-Range validator, and a regular,
    /// non-symlink file confined to the process temporary directory. On success,
    /// the partial is moved into the normal recovery store and receives ordinary
    /// recovery metadata; every later operation therefore uses the owned-partial
    /// path. The caller clears the opaque token after this attempt, whether it
    /// succeeds or fails, so this importer does not preserve a second transport.
    func adoptResumeData(
        _ data: Data,
        id: UUID,
        sourceURL: URL,
        expectedBytes: Int64
    ) {
        guard case .absent = lookup(id: id, sourceURL: sourceURL),
              let info = Self.resumeInfo(from: data),
              let archivedSource = Self.string(
                  ["NSURLSessionDownloadURL"],
                  in: info
              ),
              URL(string: archivedSource) == sourceURL,
              let bytesWritten = Self.byteCount(in: info),
              bytesWritten > 0,
              expectedBytes <= 0 || bytesWritten <= expectedBytes,
              let location = Self.string(
                  [
                      "NSURLSessionResumeInfoLocalPath",
                      "NSURLSessionResumeInfoTempFileName"
                  ],
                  in: info
              ),
              let source = temporaryPartialURL(for: location) else {
            return
        }

        let metadata = DirectDownloadRecoveryMetadata(
            sourceURL: sourceURL,
            entityTag: Self.string(
                ["NSURLSessionResumeEntityTag", "NSURLSessionResumeInfoEntityTag"],
                in: info
            ),
            lastModified: Self.string(
                ["NSURLSessionResumeLastModified", "NSURLSessionResumeInfoLastModified"],
                in: info
            ),
            expectedBytes: expectedBytes,
            suggestedFilename: nil,
            mimeType: nil
        )
        guard metadata.ifRangeValidator != nil else {
            return
        }

        try? lock.withLock {
            if try recoveryPreparation(id: id, sourceURL: sourceURL).snapshot != nil {
                return
            }
            guard try fileSizeIfPresent(at: source) == bytesWritten else {
                return
            }
            try discardLocked(id: id)
            // Write the metadata while holding the store lock, before moving the
            // partial into place. This ordering makes both interruption points
            // recoverable: if the process exits before the move, the next lookup
            // sees metadata without a partial and discards it; if it exits after
            // the move, the complete recovery pair is already present. If the
            // move itself fails, remove the metadata so a later lookup cannot
            // mistake the failed adoption for valid recovery.
            try saveMetadataLocked(metadata, id: id)
            let destination = partialURL(for: id)
            do {
                try fileManager.moveItem(at: source, to: destination)
            } catch {
                try? removeItemIfPresent(at: metadataURL(for: id))
                return
            }

            guard (try? fileSizeIfPresent(at: destination)) == bytesWritten else {
                try? discardLocked(id: id)
                return
            }
            try? DurableFileSystem.synchronizeFile(at: destination)
            try? DurableFileSystem.synchronizeParentDirectory(of: destination)
        }
    }

    func openFreshFile(id: UUID) throws -> FileHandle {
        try lock.withLock {
            try storageLocations?.requireAvailable(id: id)
            try DurableFileSystem.createDirectoryIfNeeded(
                at: directory(for: id),
                fileManager: fileManager
            )
            let partialURL = partialURL(for: id)
            try removeItemIfPresent(at: partialURL)
            guard fileManager.createFile(atPath: partialURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return try FileHandle(forWritingTo: partialURL)
        }
    }

    func openFileForAppending(
        id: UUID,
        expectedOffset: Int64
    ) throws -> FileHandle {
        try lock.withLock {
            try storageLocations?.requireAvailable(id: id)
            let partialURL = partialURL(for: id)
            let actualOffset = try fileSizeIfPresent(at: partialURL) ?? 0
            guard actualOffset == expectedOffset else {
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [
                        NSLocalizedDescriptionKey: "The partial download changed while Harbor was preparing to resume it."
                    ]
                )
            }

            let handle = try FileHandle(forWritingTo: partialURL)
            try handle.seekToEnd()
            return handle
        }
    }

    func saveMetadata(
        _ metadata: DirectDownloadRecoveryMetadata,
        id: UUID
    ) throws {
        try lock.withLock {
            try saveMetadataLocked(metadata, id: id)
        }
    }

    func recoveredByteCount(id: UUID) -> Int64? {
        lock.withLock {
            try? fileSizeIfPresent(at: partialURL(for: id))
        } ?? nil
    }

    func publishCompletedPayload<T>(
        id: UUID,
        expectedBytes: Int64,
        _ publish: (URL) throws -> T
    ) throws -> T {
        try lock.withLock {
            let url = partialURL(for: id)
            let actualBytes = try fileSizeIfPresent(at: url)
            guard let actualBytes,
                  actualBytes >= 0,
                  expectedBytes <= 0 || actualBytes == expectedBytes else {
                throw CocoaError(.fileReadCorruptFile)
            }

            // Keep the recovery lease while the immutable completion store
            // claims the file. Otherwise cancellation or a same-ID restart can
            // replace/delete the path after validation but before publication.
            let result = try publish(url)
            try? discardLocked(id: id)
            return result
        }
    }

    func discard(id: UUID) {
        try? discardThrowing(id: id)
    }

    func discardThrowing(id: UUID) throws {
        try lock.withLock {
            try discardLocked(id: id)
        }
    }

    func discardOrphans(retaining retainedIDs: Set<UUID>) {
        lock.withLock {
            for directoryURL in directories {
                guard let contents = try? fileManager.contentsOfDirectory(
                    at: directoryURL,
                    includingPropertiesForKeys: nil
                ) else {
                    continue
                }

                let ids = Set(contents.compactMap { url -> UUID? in
                    UUID(uuidString: url.deletingPathExtension().lastPathComponent)
                })
                for id in ids.subtracting(retainedIDs) {
                    try? discardLocked(id: id)
                }
            }
        }
    }

    private var directories: [URL] {
        storageLocations?.directories(name: "DirectDownloadRecovery", legacy: directoryURL) ?? [directoryURL]
    }

    private func directory(for id: UUID) -> URL {
        storageLocations?.directory(for: id, name: "DirectDownloadRecovery", legacy: directoryURL) ?? directoryURL
    }

    private func partialURL(for id: UUID) -> URL {
        directory(for: id)
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("part")
    }

    private func metadataURL(for id: UUID) -> URL {
        directory(for: id)
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
    }

    private static func resumeInfo(from data: Data) -> [String: Any]? {
        guard let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let dictionary = object as? [String: Any] else {
            return nil
        }
        // PropertyListSerialization exposes the actual resume dictionary for
        // older tokens. A modern token is itself a property list describing a
        // keyed archive, so its outer dictionary contains archive machinery
        // rather than the resume fields. Recognize that envelope and securely
        // decode its restricted root object before reading any values.
        if byteCount(in: dictionary) != nil {
            return dictionary
        }
        guard dictionary["$archiver"] as? String == "NSKeyedArchiver",
              let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else {
            return nil
        }
        defer { unarchiver.finishDecoding() }
        unarchiver.requiresSecureCoding = true
        return unarchiver.decodeObject(
            of: [NSDictionary.self, NSString.self, NSNumber.self, NSData.self],
            forKey: "NSKeyedArchiveRootObjectKey"
        ) as? [String: Any]
    }

    private static func byteCount(in info: [String: Any]) -> Int64? {
        for key in ["NSURLSessionResumeBytesReceived", "NSURLSessionResumeInfoBytesReceived"] {
            if let number = info[key] as? NSNumber {
                return number.int64Value
            }
            if let text = info[key] as? String, let value = Int64(text) {
                return value
            }
        }
        return nil
    }

    private static func string(_ keys: [String], in info: [String: Any]) -> String? {
        keys.lazy.compactMap { info[$0] as? String }.first
    }

    private func temporaryPartialURL(for location: String) -> URL? {
        // Depending on the URLSession representation, the partial is identified
        // by either an absolute local path or only a CFNetwork temporary filename.
        // Resolve both forms, then standardize the path and resolve symlinks before
        // confirming that it remains beneath the process temporary directory.
        // This prevents path traversal or a symlink from turning the importer into
        // a way to inspect or move an unrelated file.
        let temporaryDirectory = fileManager.temporaryDirectory
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let path = location as NSString
        let candidate: URL
        if path.isAbsolutePath {
            candidate = URL(fileURLWithPath: location)
        } else {
            guard location.isEmpty == false, path.lastPathComponent == location else {
                return nil
            }
            candidate = temporaryDirectory.appendingPathComponent(location)
        }
        let standardized = candidate.standardizedFileURL
        let resolvedPath = standardized.resolvingSymlinksInPath().path
        guard resolvedPath.hasPrefix(temporaryDirectory.path + "/") else {
            return nil
        }
        return standardized
    }

    private func saveMetadataLocked(
        _ metadata: DirectDownloadRecoveryMetadata,
        id: UUID
    ) throws {
        try storageLocations?.requireAvailable(id: id)
        try DurableFileSystem.createDirectoryIfNeeded(
            at: directory(for: id),
            fileManager: fileManager
        )
        let data = try JSONEncoder().encode(metadata)
        let destinationURL = metadataURL(for: id)
        try data.write(to: destinationURL, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: destinationURL)
        try DurableFileSystem.synchronizeParentDirectory(of: destinationURL)
    }

    private func loadMetadata(id: UUID) throws -> DirectDownloadRecoveryMetadata? {
        let url = metadataURL(for: id)
        guard try DurableFileSystem.itemExists(at: url) else {
            return nil
        }

        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(
                DirectDownloadRecoveryMetadata.self,
                from: data
            )
        } catch {
            throw IntegrityError.invalidMetadata
        }
    }

    private func recoveryPreparation(
        id: UUID,
        sourceURL: URL
    ) throws -> DirectDownloadRecoveryPreparation {
        let bytesWritten = try fileSizeIfPresent(at: partialURL(for: id)) ?? 0
        guard bytesWritten > 0 else {
            return DirectDownloadRecoveryPreparation(snapshot: nil, resetReason: nil)
        }
        guard let metadata = try loadMetadata(id: id) else {
            return DirectDownloadRecoveryPreparation(
                snapshot: nil,
                resetReason: .missingValidator
            )
        }
        guard metadata.sourceURL == sourceURL else {
            return DirectDownloadRecoveryPreparation(snapshot: nil, resetReason: .sourceChanged)
        }
        guard metadata.ifRangeValidator != nil else {
            return DirectDownloadRecoveryPreparation(snapshot: nil, resetReason: .missingValidator)
        }
        guard metadata.expectedBytes <= 0 || bytesWritten <= metadata.expectedBytes else {
            return DirectDownloadRecoveryPreparation(snapshot: nil, resetReason: .invalidLength)
        }
        return DirectDownloadRecoveryPreparation(
            snapshot: DirectDownloadRecoverySnapshot(
                bytesWritten: bytesWritten,
                metadata: metadata
            ),
            resetReason: nil
        )
    }

    private func fileSizeIfPresent(at url: URL) throws -> Int64? {
        guard try DurableFileSystem.itemExists(at: url) else {
            return nil
        }

        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw IntegrityError.invalidPartial
        }
        return Int64(fileSize)
    }

    private func discardLocked(id: UUID) throws {
        try storageLocations?.requireAvailable(id: id)
        try removeItemIfPresent(at: partialURL(for: id))
        try removeItemIfPresent(at: metadataURL(for: id))
    }

    private func removeItemIfPresent(at url: URL) throws {
        guard try DurableFileSystem.itemExists(at: url) else {
            return
        }
        try fileManager.removeItem(at: url)
        try DurableFileSystem.synchronizeParentDirectory(of: url)
    }

}
