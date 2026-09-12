import Foundation
import Darwin

struct DownloadPayloadPathResolution: Equatable, Sendable {
    let safeURLs: [URL]
    let rejectedPaths: [String]
}

struct DownloadDataRemovalFailure: Equatable, Identifiable, Sendable {
    let path: String
    let message: String

    var id: String { path }
}

struct DownloadDataRemovalResult: Equatable, Sendable {
    let trashedPaths: [String]
    let missingPaths: [String]
    let failures: [DownloadDataRemovalFailure]

    var remainingPayloadPaths: [String] {
        failures.map(\.path)
    }
}

struct DownloadPayloadInspection: Equatable, Sendable {
    let existingPaths: [String]
    let missingPaths: [String]
    let failures: [DownloadDataRemovalFailure]
}

struct DownloadDataRemovalService {
    nonisolated(unsafe) private let fileManager: FileManager

    nonisolated init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    nonisolated func resolvePayloadURLs(
        destinationFolderPath: String,
        payloadPaths: [String]
    ) -> DownloadPayloadPathResolution {
        let destinationURL = URL(
            fileURLWithPath: destinationFolderPath,
            isDirectory: true
        ).standardizedFileURL
        let destinationComponents = destinationURL.pathComponents
        let canonicalDestinationURL = canonicalFileURL(destinationURL)
        let canonicalDestinationComponents = canonicalDestinationURL.pathComponents
        var safeURLs: [URL] = []
        var rejectedPaths: [String] = []
        var seenSafePaths = Set<String>()
        var seenRejectedPaths = Set<String>()

        for payloadPath in payloadPaths {
            let candidateURL: URL
            if NSString(string: payloadPath).isAbsolutePath {
                candidateURL = URL(fileURLWithPath: payloadPath)
            } else {
                candidateURL = destinationURL.appendingPathComponent(payloadPath)
            }

            let standardizedCandidateURL = candidateURL.standardizedFileURL
            let candidateComponents = standardizedCandidateURL.pathComponents
            guard candidateComponents.count > destinationComponents.count,
                  candidateComponents.starts(with: destinationComponents) else {
                if seenRejectedPaths.insert(payloadPath).inserted {
                    rejectedPaths.append(payloadPath)
                }
                continue
            }

            let canonicalCandidateURL = canonicalFileURL(standardizedCandidateURL)
            let canonicalCandidateComponents = canonicalCandidateURL.pathComponents
            guard canonicalCandidateComponents.count > canonicalDestinationComponents.count,
                  canonicalCandidateComponents.starts(with: canonicalDestinationComponents),
                  standardizedCandidateURL != destinationURL else {
                if seenRejectedPaths.insert(payloadPath).inserted {
                    rejectedPaths.append(payloadPath)
                }
                continue
            }

            if seenSafePaths.insert(standardizedCandidateURL.path).inserted {
                safeURLs.append(standardizedCandidateURL)
            }
        }

        return DownloadPayloadPathResolution(
            safeURLs: safeURLs,
            rejectedPaths: rejectedPaths
        )
    }

    nonisolated func movePayloadDataToTrash(
        destinationFolderPath: String,
        payloadPaths: [String],
        removeEmptyParents: Bool = false
    ) -> DownloadDataRemovalResult {
        let resolution = resolvePayloadURLs(
            destinationFolderPath: destinationFolderPath,
            payloadPaths: payloadPaths
        )
        var trashedPaths: [String] = []
        var missingPaths: [String] = []
        var failures = resolution.rejectedPaths.map {
            DownloadDataRemovalFailure(
                path: $0,
                message: String(
                    localized: "download.removeData.unsafePath",
                    defaultValue: "The path is not safely contained within the download destination.",
                    comment: "Error shown when Harbor refuses to move a path outside the download destination to Trash."
                )
            )
        }

        for url in resolution.safeURLs {
            do {
                guard try DurableFileSystem.pathEntryExists(at: url) else {
                    missingPaths.append(url.path)
                    continue
                }
            } catch {
                failures.append(
                    DownloadDataRemovalFailure(
                        path: url.path,
                        message: error.localizedDescription
                    )
                )
                continue
            }

            do {
                try fileManager.trashItem(at: url, resultingItemURL: nil)
                trashedPaths.append(url.path)
            } catch {
                failures.append(
                    DownloadDataRemovalFailure(
                        path: url.path,
                        message: error.localizedDescription
                    )
                )
            }
        }

        if removeEmptyParents {
            let destination = URL(fileURLWithPath: destinationFolderPath).standardizedFileURL
            var parents = Set<URL>()
            for url in resolution.safeURLs {
                var parent = url.deletingLastPathComponent()
                while parent.pathComponents.count > destination.pathComponents.count {
                    parents.insert(parent)
                    parent.deleteLastPathComponent()
                }
            }
            for parent in parents.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
                let safe = resolvePayloadURLs(destinationFolderPath: destinationFolderPath, payloadPaths: [parent.path])
                guard !safe.safeURLs.isEmpty else { continue }
                // rmdir removes only empty directories, even if new files arrive during cleanup.
                if rmdir(parent.path) != 0, errno != ENOTEMPTY, errno != EEXIST, errno != ENOENT {
                    failures.append(DownloadDataRemovalFailure(path: parent.path, message: String(cString: strerror(errno))))
                }
            }
        }

        return DownloadDataRemovalResult(
            trashedPaths: trashedPaths,
            missingPaths: missingPaths,
            failures: failures
        )
    }

    /// Inspects a previously-started deletion without mutating the filesystem.
    /// Any pathname that exists is treated as ambiguous: after a crash Harbor
    /// cannot prove it is still the payload named by the old journal.
    nonisolated func inspectPayloadData(
        destinationFolderPath: String,
        payloadPaths: [String]
    ) -> DownloadPayloadInspection {
        let resolution = resolvePayloadURLs(
            destinationFolderPath: destinationFolderPath,
            payloadPaths: payloadPaths
        )
        var existingPaths: [String] = []
        var missingPaths: [String] = []
        var failures = resolution.rejectedPaths.map {
            DownloadDataRemovalFailure(
                path: $0,
                message: String(
                    localized: "download.removeData.unsafePath",
                    defaultValue: "The path is not safely contained within the download destination.",
                    comment: "Error shown when Harbor refuses to inspect a path outside the download destination."
                )
            )
        }
        for url in resolution.safeURLs {
            do {
                if try DurableFileSystem.pathEntryExists(at: url) {
                    existingPaths.append(url.path)
                } else {
                    missingPaths.append(url.path)
                }
            } catch {
                failures.append(
                    DownloadDataRemovalFailure(
                        path: url.path,
                        message: error.localizedDescription
                    )
                )
            }
        }
        return DownloadPayloadInspection(
            existingPaths: existingPaths,
            missingPaths: missingPaths,
            failures: failures
        )
    }

    private nonisolated func canonicalFileURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

}
