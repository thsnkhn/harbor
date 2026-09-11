import Darwin
import Foundation

struct DownloadDestinationResolver: @unchecked Sendable {
    nonisolated(unsafe) private let fileManager: FileManager

    nonisolated init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    nonisolated func resolvedFilename(
        custom: String?,
        responseSuggestedFilename: String?,
        sourceURL: URL
    ) -> String {
        let trimmedCustom = custom?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let trimmedSuggested = responseSuggestedFilename?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        var candidate = trimmedCustom
            ?? trimmedSuggested
            ?? sourceURL.lastPathComponent.nilIfEmpty
            ?? sourceURL.host
            ?? "Download"

        if let trimmedCustom,
           URL(fileURLWithPath: trimmedCustom).pathExtension.isEmpty {
            let extensionSource = URL(fileURLWithPath: trimmedSuggested ?? "").pathExtension.nilIfEmpty
                ?? sourceURL.pathExtension.nilIfEmpty

            if let extensionSource {
                candidate += ".\(extensionSource)"
            }
        }

        return sanitize(candidate)
    }

    nonisolated func uniqueDestinationURL(for filename: String, in directory: URL) throws -> URL {
        let cleanName = sanitize(filename)
        let baseURL = directory.appendingPathComponent(cleanName)

        guard try DurableFileSystem.pathEntryExists(at: baseURL) else {
            return baseURL
        }

        let fileExtension = baseURL.pathExtension
        let baseName = fileExtension.isEmpty
            ? cleanName
            : String(cleanName.dropLast(fileExtension.count + 1))

        var attempt = 2
        while true {
            let candidateName: String
            if fileExtension.isEmpty {
                candidateName = "\(baseName) \(attempt)"
            } else {
                candidateName = "\(baseName) \(attempt).\(fileExtension)"
            }

            let candidateURL = directory.appendingPathComponent(candidateName)
            if try DurableFileSystem.pathEntryExists(at: candidateURL) == false {
                return candidateURL
            }

            attempt += 1
        }
    }

    nonisolated func moveDownloadedFile(
        from temporaryURL: URL,
        customFilename: String?,
        responseSuggestedFilename: String?,
        sourceURL: URL,
        into directory: URL
    ) throws -> URL {
        try DurableFileSystem.createDirectoryIfNeeded(at: directory, fileManager: fileManager)

        let targetName = resolvedFilename(
            custom: customFilename,
            responseSuggestedFilename: responseSuggestedFilename,
            sourceURL: sourceURL
        )
        while true {
            let destinationURL = try uniqueDestinationURL(for: targetName, in: directory)
            do {
                try moveDownloadedFile(from: temporaryURL, to: destinationURL)
                return destinationURL
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Another writer won the name after it was selected. Resolve a
                // new name; never remove a file Harbor does not own.
                continue
            }
        }
    }

    nonisolated func destinationURL(
        customFilename: String?,
        responseSuggestedFilename: String?,
        sourceURL: URL,
        in directory: URL
    ) throws -> URL {
        try DurableFileSystem.createDirectoryIfNeeded(at: directory, fileManager: fileManager)
        let targetName = resolvedFilename(
            custom: customFilename,
            responseSuggestedFilename: responseSuggestedFilename,
            sourceURL: sourceURL
        )
        return try uniqueDestinationURL(for: targetName, in: directory)
    }

    nonisolated func moveDownloadedFile(from sourceURL: URL, to destinationURL: URL) throws {
        try DurableFileSystem.createDirectoryIfNeeded(
            at: destinationURL.deletingLastPathComponent(), fileManager: fileManager
        )
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.renameatx_np(
                    AT_FDCWD,
                    sourcePath,
                    AT_FDCWD,
                    destinationPath,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            if code == EEXIST || code == ENOTEMPTY {
                throw CocoaError(.fileWriteFileExists)
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        try DurableFileSystem.synchronizeParentDirectory(of: destinationURL)
    }

    nonisolated func synchronizePlacedFile(at destinationURL: URL) throws {
        guard try DurableFileSystem.pathEntryExists(at: destinationURL) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try DurableFileSystem.synchronizeFile(at: destinationURL)
        try DurableFileSystem.synchronizeParentDirectory(of: destinationURL)
    }

    nonisolated func copyDownloadedFile(from sourceURL: URL, to stagingURL: URL) throws {
        try DurableFileSystem.createDirectoryIfNeeded(
            at: stagingURL.deletingLastPathComponent(), fileManager: fileManager
        )
        guard try DurableFileSystem.pathEntryExists(at: stagingURL) == false else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fileManager.copyItem(at: sourceURL, to: stagingURL)
        try DurableFileSystem.synchronizeFile(at: stagingURL)
        try DurableFileSystem.synchronizeParentDirectory(of: stagingURL)
    }

    private nonisolated func sanitize(_ filename: String) -> String {
        let replaced = filename
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return replaced.isEmpty ? "Download" : replaced
    }
}

private extension String {
    nonisolated var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
