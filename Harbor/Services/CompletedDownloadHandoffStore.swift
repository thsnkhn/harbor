import CryptoKit
import Darwin
import Foundation

nonisolated enum CompletedDownloadHandoffOwner: String, Codable, Equatable, Sendable {
    case direct
    case browser
}

nonisolated enum CompletedDownloadHandoffPhase: String, Codable, Equatable, Sendable {
    case claiming
    case ready
    case destinationRecorded
}

nonisolated struct CompletedDownloadHandoffManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let downloadID: UUID
    let attemptIdentifier: UUID
    let createdAt: Date
    let owner: CompletedDownloadHandoffOwner
    let sourceURL: URL
    let statusCode: Int?
    let mimeType: String?
    let suggestedFilename: String?
    let actualBytes: Int64
    let expectedBytes: Int64
    let payloadSHA256: String
    private(set) var phase: CompletedDownloadHandoffPhase
    private(set) var destinationPath: String?
    private(set) var placementStagingPath: String?

    init(
        downloadID: UUID,
        attemptIdentifier: UUID,
        owner: CompletedDownloadHandoffOwner,
        sourceURL: URL,
        statusCode: Int?,
        mimeType: String?,
        suggestedFilename: String?,
        actualBytes: Int64,
        expectedBytes: Int64,
        payloadSHA256: String = "",
        createdAt: Date = .now,
        phase: CompletedDownloadHandoffPhase = .ready,
        destinationPath: String? = nil,
        placementStagingPath: String? = nil
    ) {
        self.version = Self.currentVersion
        self.downloadID = downloadID
        self.attemptIdentifier = attemptIdentifier
        self.createdAt = createdAt
        self.owner = owner
        self.sourceURL = sourceURL
        self.statusCode = statusCode
        self.mimeType = mimeType
        self.suggestedFilename = suggestedFilename
        self.actualBytes = actualBytes
        self.expectedBytes = expectedBytes
        self.payloadSHA256 = payloadSHA256
        self.phase = phase
        self.destinationPath = destinationPath
        self.placementStagingPath = placementStagingPath
    }

    func recordingDestination(
        _ destinationURL: URL,
        placementStagingURL: URL
    ) -> Self {
        var copy = self
        copy.phase = .destinationRecorded
        copy.destinationPath = destinationURL.standardizedFileURL.path
        copy.placementStagingPath = placementStagingURL.standardizedFileURL.path
        return copy
    }

    func matchesClaim(_ claim: Self, actualBytes: Int64) -> Bool {
        downloadID == claim.downloadID
            && attemptIdentifier == claim.attemptIdentifier
            && owner == claim.owner
            && sourceURL == claim.sourceURL
            && statusCode == claim.statusCode
            && mimeType == claim.mimeType
            && suggestedFilename == claim.suggestedFilename
            && self.actualBytes == actualBytes
            && expectedBytes == actualBytes
            && (claim.payloadSHA256.isEmpty || payloadSHA256 == claim.payloadSHA256)
    }
}

nonisolated struct CompletedDownloadHandoff: Equatable, Sendable {
    let packageURL: URL
    let payloadURL: URL?
    let destinationURL: URL?
    let placementStagingURL: URL?
    let manifest: CompletedDownloadHandoffManifest

    var availablePayloadURL: URL? {
        payloadURL ?? destinationURL
    }
}

nonisolated struct CompletedDownloadHandoffClaim: Sendable {
    let packageURL: URL
    let manifest: CompletedDownloadHandoffManifest
}

nonisolated enum CompletedDownloadHandoffEntry: Sendable {
    case valid(CompletedDownloadHandoff)
    case invalid(packageURL: URL, downloadID: UUID?)
    case unavailable(packageURL: URL, downloadID: UUID?, errorDescription: String)
}

nonisolated enum CompletedDownloadHandoffError: LocalizedError {
    case invalidManifest
    case invalidPayload
    case unexpectedResponseStatus(Int)
    case payloadLengthMismatch(actual: Int64, expected: Int64)
    case destinationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidManifest:
            "The completed download handoff manifest is missing or invalid."
        case .invalidPayload:
            "The completed download handoff payload is missing or invalid."
        case let .unexpectedResponseStatus(statusCode):
            "The server returned HTTP \(statusCode) instead of a downloadable file."
        case let .payloadLengthMismatch(actual, expected):
            "The completed download contains \(actual) bytes, but \(expected) bytes were expected."
        case .destinationUnavailable:
            "The completed download handoff no longer contains a valid payload or destination."
        }
    }
}

nonisolated final class CompletedDownloadHandoffStore: @unchecked Sendable {
    typealias PayloadHashOperation = @Sendable (URL) throws -> String

    private struct VerifiedFile {
        let identity: DurableFileSystem.RegularFileIdentity
        let sha256: String
    }

    private static let packageExtension = "handoff"
    private static let stagingExtension = "staging"
    private static let manifestFilename = "manifest.json"
    private static let payloadFilename = "payload"

    private let fileManager: FileManager
    private let directoryURL: URL
    private let payloadHashOperation: PayloadHashOperation
    private let registryLock = NSLock()
    private var downloadLocks: [UUID: NSLock] = [:]

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        payloadHashOperation: @escaping PayloadHashOperation = DurableFileSystem.sha256
    ) {
        self.fileManager = fileManager
        self.directoryURL = directoryURL
            ?? HarborApplicationSupport.directoryURL(fileManager: fileManager)
                .appendingPathComponent("CompletedDownloadHandoffs", isDirectory: true)
        self.payloadHashOperation = payloadHashOperation
    }

    /// Atomically takes ownership of completed bytes without hashing them.
    /// This phase is intentionally short enough for URLSession/WebKit delegate
    /// callbacks; `finalize(_:)` performs the expensive integrity pass later.
    func claim(
        payloadAt sourceURL: URL,
        manifest proposedManifest: CompletedDownloadHandoffManifest
    ) throws -> CompletedDownloadHandoffClaim {
        try withDownloadLock(
            downloadID: proposedManifest.downloadID
        ) {
            try DurableFileSystem.createDirectoryIfNeeded(
                at: directoryURL,
                fileManager: fileManager
            )
            let actualBytes = try regularFileSize(at: sourceURL)
            guard proposedManifest.version == CompletedDownloadHandoffManifest.currentVersion,
                  proposedManifest.actualBytes == actualBytes,
                  proposedManifest.phase == .ready,
                  proposedManifest.destinationPath == nil,
                  proposedManifest.placementStagingPath == nil,
                  proposedManifest.payloadSHA256.isEmpty
                    || proposedManifest.payloadSHA256.count == SHA256.byteCount * 2 else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            if let statusCode = proposedManifest.statusCode,
               (200 ... 299).contains(statusCode) == false {
                throw CompletedDownloadHandoffError.unexpectedResponseStatus(statusCode)
            }
            if proposedManifest.expectedBytes > 0,
               proposedManifest.expectedBytes != actualBytes {
                throw CompletedDownloadHandoffError.payloadLengthMismatch(
                    actual: actualBytes,
                    expected: proposedManifest.expectedBytes
                )
            }
            let claimingManifest = CompletedDownloadHandoffManifest(
                downloadID: proposedManifest.downloadID,
                attemptIdentifier: proposedManifest.attemptIdentifier,
                owner: proposedManifest.owner,
                sourceURL: proposedManifest.sourceURL,
                statusCode: proposedManifest.statusCode,
                mimeType: proposedManifest.mimeType,
                suggestedFilename: proposedManifest.suggestedFilename,
                actualBytes: actualBytes,
                expectedBytes: proposedManifest.expectedBytes > 0
                    ? proposedManifest.expectedBytes
                    : actualBytes,
                payloadSHA256: proposedManifest.payloadSHA256,
                createdAt: proposedManifest.createdAt,
                phase: .claiming
            )
            let readyURL = packageURL(
                downloadID: claimingManifest.downloadID,
                attemptIdentifier: claimingManifest.attemptIdentifier,
                pathExtension: Self.packageExtension
            )
            if try DurableFileSystem.itemExists(at: readyURL) {
                let existingManifest = try manifestMatchingClaim(
                    at: readyURL,
                    claim: claimingManifest,
                    actualBytes: actualBytes
                )
                try? fileManager.removeItem(at: sourceURL)
                return CompletedDownloadHandoffClaim(
                    packageURL: readyURL,
                    manifest: existingManifest
                )
            }
            let stagingURL = packageURL(
                downloadID: claimingManifest.downloadID,
                attemptIdentifier: claimingManifest.attemptIdentifier,
                pathExtension: Self.stagingExtension
            )
            if try DurableFileSystem.itemExists(at: stagingURL) {
                let existingManifest = try manifestMatchingClaim(
                    at: stagingURL,
                    claim: claimingManifest,
                    actualBytes: actualBytes
                )
                try? fileManager.removeItem(at: sourceURL)
                return CompletedDownloadHandoffClaim(
                    packageURL: stagingURL,
                    manifest: existingManifest
                )
            }

            try fileManager.createDirectory(
                at: stagingURL,
                withIntermediateDirectories: false
            )
            try DurableFileSystem.synchronizeDirectory(at: directoryURL)
            try writeManifest(claimingManifest, to: stagingURL)
            try DurableFileSystem.synchronizeDirectory(at: stagingURL)
            let payloadURL = stagingURL.appendingPathComponent(Self.payloadFilename)
            try fileManager.moveItem(at: sourceURL, to: payloadURL)
            let stagedBytes = try regularFileSize(at: payloadURL)
            guard stagedBytes == actualBytes else {
                throw CompletedDownloadHandoffError.payloadLengthMismatch(
                    actual: stagedBytes,
                    expected: actualBytes
                )
            }
            try synchronizeFile(at: payloadURL)
            try DurableFileSystem.synchronizeDirectory(at: stagingURL)
            return CompletedDownloadHandoffClaim(
                packageURL: stagingURL,
                manifest: claimingManifest
            )
        }
    }

    func finalize(
        _ claim: CompletedDownloadHandoffClaim
    ) throws -> CompletedDownloadHandoff {
        let pathExtension = claim.packageURL.pathExtension
        if pathExtension == Self.packageExtension {
            return try withDownloadLock(
                downloadID: claim.manifest.downloadID
            ) {
                try validatedHandoff(at: claim.packageURL)
            }
        }
        guard pathExtension == Self.stagingExtension else {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        let recoveredReadyHandoff: CompletedDownloadHandoff? = try withDownloadLock(
            downloadID: claim.manifest.downloadID
        ) {
            guard let identifiers = identifiers(from: claim.packageURL),
                  claim.manifest.downloadID == identifiers.downloadID,
                  claim.manifest.attemptIdentifier == identifiers.attemptIdentifier else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            // A crash can occur after the ready manifest is made durable
            // but before the staging directory is renamed. A repeated
            // delegate callback may still hold the original claim, so
            // finish that already-validated promotion instead of trying
            // to reinterpret the ready manifest as a claiming manifest.
            guard manifestIfDecodable(at: claim.packageURL)?.phase == .ready else {
                return nil
            }
            let staged = try validatedHandoff(at: claim.packageURL)
            guard staged.manifest.matchesClaim(
                claim.manifest,
                actualBytes: staged.manifest.actualBytes
            ) else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            try promoteStagingPackageLocked(at: claim.packageURL)
            let readyURL = packageURL(
                downloadID: staged.manifest.downloadID,
                attemptIdentifier: staged.manifest.attemptIdentifier,
                pathExtension: Self.packageExtension
            )
            let ready = try validatedHandoff(at: readyURL)
            guard ready.manifest == staged.manifest else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            return ready
        }
        if let recoveredReadyHandoff {
            return recoveredReadyHandoff
        }
        let hashingInput: (
            stagingURL: URL,
            readyURL: URL,
            payloadURL: URL,
            manifest: CompletedDownloadHandoffManifest
        ) = try withDownloadLock(
            downloadID: claim.manifest.downloadID
        ) {
            guard let identifiers = identifiers(from: claim.packageURL),
                  claim.manifest.downloadID == identifiers.downloadID,
                  claim.manifest.attemptIdentifier == identifiers.attemptIdentifier else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            let manifest = try claimingManifest(at: claim.packageURL)
            guard manifest.matchesClaim(
                claim.manifest,
                actualBytes: manifest.actualBytes
            ) else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            let payloadURL = claim.packageURL.appendingPathComponent(Self.payloadFilename)
            try synchronizeFile(at: payloadURL)
            try DurableFileSystem.synchronizeDirectory(at: claim.packageURL)
            return (
                claim.packageURL,
                packageURL(
                    downloadID: manifest.downloadID,
                    attemptIdentifier: manifest.attemptIdentifier,
                    pathExtension: Self.packageExtension
                ),
                payloadURL,
                manifest
            )
        }

        // Hash outside the registry lock. URLSession uses one serial delegate
        // queue, so holding the store-wide lock here would let a large payload
        // block unrelated completion claims and progress callbacks.
        let payloadVerification = try verifiedFile(
            at: hashingInput.payloadURL,
            expectedBytes: hashingInput.manifest.actualBytes
        )
        let payloadSHA256 = payloadVerification.sha256

        return try withDownloadLock(
            downloadID: claim.manifest.downloadID
        ) {
            if try DurableFileSystem.itemExists(at: hashingInput.readyURL) {
                do {
                    let existing = try validatedHandoff(at: hashingInput.readyURL)
                    guard existing.manifest.matchesClaim(
                        hashingInput.manifest,
                        actualBytes: hashingInput.manifest.actualBytes
                    ) else {
                        throw CocoaError(.fileWriteFileExists)
                    }
                    if try DurableFileSystem.itemExists(at: hashingInput.stagingURL) {
                        try fileManager.removeItem(at: hashingInput.stagingURL)
                        try DurableFileSystem.synchronizeDirectory(at: directoryURL)
                    }
                    return existing
                } catch is CompletedDownloadHandoffError {
                    try fileManager.removeItem(at: hashingInput.readyURL)
                }
            }

            let current = try claimingManifest(at: hashingInput.stagingURL)
            guard current == hashingInput.manifest else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            try requireUnchanged(payloadVerification, at: hashingInput.payloadURL)
            if current.payloadSHA256.isEmpty == false,
               current.payloadSHA256 != payloadSHA256 {
                throw CompletedDownloadHandoffError.invalidPayload
            }

            let readyManifest = CompletedDownloadHandoffManifest(
                downloadID: current.downloadID,
                attemptIdentifier: current.attemptIdentifier,
                owner: current.owner,
                sourceURL: current.sourceURL,
                statusCode: current.statusCode,
                mimeType: current.mimeType,
                suggestedFilename: current.suggestedFilename,
                actualBytes: current.actualBytes,
                expectedBytes: current.expectedBytes,
                payloadSHA256: payloadSHA256,
                createdAt: current.createdAt
            )
            try writeManifest(readyManifest, to: hashingInput.stagingURL)
            try DurableFileSystem.synchronizeDirectory(at: hashingInput.stagingURL)
            try fileManager.moveItem(
                at: hashingInput.stagingURL,
                to: hashingInput.readyURL
            )
            try DurableFileSystem.synchronizeDirectory(at: directoryURL)
            return CompletedDownloadHandoff(
                packageURL: hashingInput.readyURL,
                payloadURL: hashingInput.readyURL.appendingPathComponent(Self.payloadFilename),
                destinationURL: nil,
                placementStagingURL: nil,
                manifest: readyManifest
            )
        }
    }

    func publish(
        payloadAt sourceURL: URL,
        manifest: CompletedDownloadHandoffManifest
    ) throws -> CompletedDownloadHandoff {
        try finalize(claim(payloadAt: sourceURL, manifest: manifest))
    }

    func recordDestination(
        _ destinationURL: URL,
        for handoff: CompletedDownloadHandoff
    ) throws -> CompletedDownloadHandoff {
        try withDownloadLock(
            downloadID: handoff.manifest.downloadID
        ) {
            let current = try validatedHandoff(at: handoff.packageURL)
            guard current.manifest.downloadID == handoff.manifest.downloadID,
                  current.manifest.attemptIdentifier == handoff.manifest.attemptIdentifier else {
                throw CompletedDownloadHandoffError.invalidManifest
            }

            try removePlacementStagingLocked(for: current.manifest)
            let stagingURL = try unusedPlacementStagingURL(
                destinationURL: destinationURL,
                manifest: current.manifest
            )
            let updatedManifest = current.manifest.recordingDestination(
                destinationURL,
                placementStagingURL: stagingURL
            )
            try JSONEncoder().encode(updatedManifest).write(
                to: manifestURL(for: current.packageURL),
                options: .atomic
            )
            try synchronizeFile(at: manifestURL(for: current.packageURL))
            try DurableFileSystem.synchronizeDirectory(at: current.packageURL)
            return try validatedHandoff(at: current.packageURL)
        }
    }

    func validatePlacementStaging(for handoff: CompletedDownloadHandoff) throws {
        try withDownloadLock(
            downloadID: handoff.manifest.downloadID
        ) {
            let current = try validatedHandoff(at: handoff.packageURL)
            guard current.manifest == handoff.manifest,
                  let stagingURL = current.placementStagingURL else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            let stagingVerification = try verifiedFile(
                at: stagingURL,
                expectedBytes: current.manifest.actualBytes
            )
            guard stagingVerification.sha256 == current.manifest.payloadSHA256 else {
                throw CompletedDownloadHandoffError.invalidPayload
            }
            try requireUnchanged(stagingVerification, at: stagingURL)
            let afterValidation = try validatedHandoff(at: handoff.packageURL)
            guard afterValidation.manifest == current.manifest else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
        }
    }

    func discardPlacementStaging(for handoff: CompletedDownloadHandoff) {
        withDownloadLock(
            downloadID: handoff.manifest.downloadID
        ) {
            discardPlacementStagingLocked(for: handoff.manifest)
        }
    }

    func releasePayloadAfterPlacement(for handoff: CompletedDownloadHandoff) throws {
        try withDownloadLock(
            downloadID: handoff.manifest.downloadID
        ) {
            let current = try validatedHandoff(at: handoff.packageURL)
            guard current.destinationURL != nil else {
                throw CompletedDownloadHandoffError.destinationUnavailable
            }
            if let payloadURL = current.payloadURL {
                try fileManager.removeItem(at: payloadURL)
                try DurableFileSystem.synchronizeDirectory(at: current.packageURL)
            }
        }
    }

    func handoff(
        downloadID: UUID,
        attemptIdentifier: UUID
    ) -> CompletedDownloadHandoff? {
        withDownloadLock(
            downloadID: downloadID
        ) {
            let readyURL = packageURL(
                downloadID: downloadID,
                attemptIdentifier: attemptIdentifier,
                pathExtension: Self.packageExtension
            )
            if let ready = try? validatedHandoff(at: readyURL) {
                return ready
            }
            let stagingURL = packageURL(
                downloadID: downloadID,
                attemptIdentifier: attemptIdentifier,
                pathExtension: Self.stagingExtension
            )
            guard (try? DurableFileSystem.itemExists(at: stagingURL)) == true else {
                return nil
            }
            try? promoteStagingPackageLocked(at: stagingURL)
            return try? validatedHandoff(at: readyURL)
        }
    }

    func ownsAttempt(downloadID: UUID, attemptIdentifier: UUID) -> Bool {
        withDownloadLock(
            downloadID: downloadID
        ) {
            for pathExtension in [Self.packageExtension, Self.stagingExtension] {
                do {
                    if try DurableFileSystem.itemExists(
                        at: packageURL(
                            downloadID: downloadID,
                            attemptIdentifier: attemptIdentifier,
                            pathExtension: pathExtension
                        )
                    ) {
                        return true
                    }
                } catch {
                    // An operational lookup failure is not proof that the
                    // journal is absent. Fail closed against deletion.
                    return true
                }
            }
            return false
        }
    }

    func entries() throws -> [CompletedDownloadHandoffEntry] {
        let exists = try withRegistryLock {
            try DurableFileSystem.itemExists(at: directoryURL)
        }
        guard exists else {
            return []
        }
        promoteValidStagingPackages()
        let contents = try withRegistryLock {
            try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
        }

        return contents.compactMap { url in
            guard url.pathExtension == Self.packageExtension
                    || url.pathExtension == Self.stagingExtension else {
                return nil
            }
            guard let identifiers = identifiers(from: url) else {
                return .invalid(packageURL: url, downloadID: nil)
            }
            return withDownloadLock(
                downloadID: identifiers.downloadID
            ) {
                if url.pathExtension == Self.stagingExtension {
                    // Promotion already ran above. Any staging entry still
                    // present may own the only completed bytes.
                    return .unavailable(
                        packageURL: url,
                        downloadID: identifiers.downloadID,
                        errorDescription: "The completed download is awaiting durable handoff recovery."
                    )
                }
                do {
                    return .valid(try validatedHandoff(at: url))
                } catch let error as CompletedDownloadHandoffError {
                    if case .destinationUnavailable = error,
                       manifestIfDecodable(at: url)?.phase == .destinationRecorded {
                        return .unavailable(
                            packageURL: url,
                            downloadID: identifiers.downloadID,
                            errorDescription: error.localizedDescription
                        )
                    }
                    return .invalid(
                        packageURL: url,
                        downloadID: identifiers.downloadID
                    )
                } catch {
                    return .unavailable(
                        packageURL: url,
                        downloadID: identifiers.downloadID,
                        errorDescription: error.localizedDescription
                    )
                }
            }
        }
    }

    func acknowledge(_ handoff: CompletedDownloadHandoff) {
        withDownloadLock(
            downloadID: handoff.manifest.downloadID
        ) {
            do {
                if let manifest = manifestIfDecodable(at: handoff.packageURL) {
                    try removePlacementStagingLocked(for: manifest)
                }
                try fileManager.removeItem(at: handoff.packageURL)
                try DurableFileSystem.synchronizeDirectory(at: directoryURL)
            } catch {
                // Retain the package as the cleanup journal. Reconciliation
                // will retry without losing the only reference to staging.
            }
        }
    }

    func discard(downloadID: UUID, attemptIdentifier: UUID? = nil) {
        try? discardThrowing(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier
        )
    }

    /// Removes every completion package owned by one download and reports
    /// operational filesystem failures to callers that must durably retry the
    /// cleanup. Malformed manifests do not make an explicitly requested purge
    /// unsafe: the package remains confined to this store, while readable
    /// manifests are used to remove any separately journaled placement file.
    func discardThrowing(
        downloadID: UUID,
        attemptIdentifier: UUID? = nil
    ) throws {
        try withDownloadLock(
            downloadID: downloadID
        ) {
            guard try DurableFileSystem.itemExists(at: directoryURL) else {
                return
            }
            let contents = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            var removedEntry = false

            for url in contents where url.pathExtension == Self.packageExtension
                || url.pathExtension == Self.stagingExtension {
                guard let identifiers = identifiers(from: url),
                      identifiers.downloadID == downloadID,
                      attemptIdentifier == nil || identifiers.attemptIdentifier == attemptIdentifier else {
                    continue
                }
                if let manifest = try manifestForExplicitDiscard(at: url) {
                    try removePlacementStagingLocked(for: manifest)
                }
                do {
                    try fileManager.removeItem(at: url)
                    removedEntry = true
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    continue
                } catch let error as POSIXError where error.code == .ENOENT {
                    continue
                }
            }
            if removedEntry {
                try DurableFileSystem.synchronizeDirectory(at: directoryURL)
            }
        }
    }

    func discardPackage(at packageURL: URL) {
        guard packageURL.deletingLastPathComponent().standardizedFileURL
                == directoryURL.standardizedFileURL,
              packageURL.pathExtension == Self.packageExtension,
              let identifiers = identifiers(from: packageURL) else {
            return
        }
        withDownloadLock(
            downloadID: identifiers.downloadID
        ) {
            do {
                if let manifest = manifestIfDecodable(at: packageURL) {
                    try removePlacementStagingLocked(for: manifest)
                }
                try fileManager.removeItem(at: packageURL)
                try DurableFileSystem.synchronizeDirectory(at: directoryURL)
            } catch {
                // Keep the package as a retryable cleanup journal.
            }
        }
    }

    func discardOrphans(retaining retainedIDs: Set<UUID>) {
        promoteValidStagingPackages()
        guard let contents = withRegistryLock({
            try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
        }) else {
            return
        }

        for url in contents where url.pathExtension == Self.packageExtension
            || url.pathExtension == Self.stagingExtension {
            guard let identifiers = identifiers(from: url),
                  retainedIDs.contains(identifiers.downloadID) == false else {
                continue
            }
            withDownloadLock(
                downloadID: identifiers.downloadID
            ) {
                guard retainedIDs.contains(identifiers.downloadID) == false else {
                    return
                }
                do {
                    if let manifest = manifestIfDecodable(at: url) {
                        try removePlacementStagingLocked(for: manifest)
                    }
                    try fileManager.removeItem(at: url)
                    try DurableFileSystem.synchronizeDirectory(at: directoryURL)
                } catch {
                    // Operational failures retain the package for a later pass.
                }
            }
        }
    }

    func discardLegacyUnvalidatedFiles(in legacyDirectoryURL: URL) {
        withRegistryLock {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: legacyDirectoryURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) else {
                return
            }

            for url in contents {
                guard url.pathExtension == "download",
                      UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else {
                    continue
                }
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private func validatedHandoff(at packageURL: URL) throws -> CompletedDownloadHandoff {
        guard packageURL.pathExtension == Self.packageExtension
                || packageURL.pathExtension == Self.stagingExtension,
              packageURL.deletingLastPathComponent().standardizedFileURL
                == directoryURL.standardizedFileURL,
              let identifiers = identifiers(from: packageURL) else {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        guard try DurableFileSystem.itemExists(at: packageURL) else {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        let packageValues = try packageURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard
              packageValues.isDirectory == true,
              packageValues.isSymbolicLink != true,
              try DurableFileSystem.itemExists(at: manifestURL(for: packageURL)) else {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        let manifestData = try Data(contentsOf: manifestURL(for: packageURL))
        let manifest: CompletedDownloadHandoffManifest
        do {
            manifest = try JSONDecoder().decode(
                CompletedDownloadHandoffManifest.self,
                from: manifestData
            )
        } catch {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        guard
              manifest.version == CompletedDownloadHandoffManifest.currentVersion,
              manifest.downloadID == identifiers.downloadID,
              manifest.attemptIdentifier == identifiers.attemptIdentifier,
              manifest.actualBytes >= 0,
              manifest.expectedBytes == manifest.actualBytes,
              manifest.payloadSHA256.count == SHA256.byteCount * 2,
              manifest.phase != .claiming else {
            throw CompletedDownloadHandoffError.invalidManifest
        }

        if let statusCode = manifest.statusCode,
           (200 ... 299).contains(statusCode) == false {
            throw CompletedDownloadHandoffError.unexpectedResponseStatus(statusCode)
        }

        let payloadURL = packageURL.appendingPathComponent(Self.payloadFilename)
        let validPayloadURL: URL?
        let payloadVerification: VerifiedFile?
        if try DurableFileSystem.itemExists(at: payloadURL) {
            let verified = try verifiedFile(
                at: payloadURL,
                expectedBytes: manifest.actualBytes
            )
            guard verified.sha256 == manifest.payloadSHA256 else {
                throw CompletedDownloadHandoffError.invalidPayload
            }
            validPayloadURL = payloadURL
            payloadVerification = verified
        } else {
            validPayloadURL = nil
            payloadVerification = nil
        }

        let destinationURL: URL?
        let placementStagingURL: URL?
        let destinationVerification: VerifiedFile?
        if manifest.phase == .destinationRecorded {
            guard let destinationPath = manifest.destinationPath,
                  let ownedStagingURL = ownedPlacementStagingURL(for: manifest) else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            placementStagingURL = ownedStagingURL
            let candidate = URL(fileURLWithPath: destinationPath).standardizedFileURL
            if try DurableFileSystem.itemExists(at: candidate) {
                do {
                    let verified = try verifiedFile(
                        at: candidate,
                        expectedBytes: manifest.actualBytes
                    )
                    if verified.sha256 == manifest.payloadSHA256 {
                        destinationURL = candidate
                        destinationVerification = verified
                    } else if validPayloadURL != nil {
                        // The destination may have appeared after Harbor
                        // selected it. Keep the immutable package usable so
                        // reconciliation can choose another name without ever
                        // deleting the unrelated entry.
                        destinationURL = nil
                        destinationVerification = nil
                    } else {
                        throw CompletedDownloadHandoffError.invalidPayload
                    }
                } catch is CompletedDownloadHandoffError where validPayloadURL != nil {
                    // A non-regular destination entry is an ordinary name
                    // collision, not evidence that the separately validated
                    // package payload is corrupt. Operational read failures do
                    // not enter this branch and remain retryable/unavailable.
                    destinationURL = nil
                    destinationVerification = nil
                }
            } else {
                destinationURL = nil
                destinationVerification = nil
            }
        } else {
            guard manifest.destinationPath == nil,
                  manifest.placementStagingPath == nil else {
                throw CompletedDownloadHandoffError.invalidManifest
            }
            destinationURL = nil
            placementStagingURL = nil
            destinationVerification = nil
        }

        guard validPayloadURL != nil || destinationURL != nil else {
            throw CompletedDownloadHandoffError.destinationUnavailable
        }
        guard try Data(contentsOf: manifestURL(for: packageURL)) == manifestData else {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        if let payloadVerification {
            try requireUnchanged(payloadVerification, at: payloadURL)
        }
        if let destinationVerification, let destinationURL {
            try requireUnchanged(destinationVerification, at: destinationURL)
        }

        return CompletedDownloadHandoff(
            packageURL: packageURL,
            payloadURL: validPayloadURL,
            destinationURL: destinationURL,
            placementStagingURL: placementStagingURL,
            manifest: manifest
        )
    }

    private func unusedPlacementStagingURL(
        destinationURL: URL,
        manifest: CompletedDownloadHandoffManifest
    ) throws -> URL {
        for _ in 0 ..< 100 {
            let candidate = destinationURL.deletingLastPathComponent()
                .appendingPathComponent(
                    ".harbor-placement-\(manifest.downloadID.uuidString)-\(manifest.attemptIdentifier.uuidString)-\(UUID().uuidString)"
                )
            if try DurableFileSystem.itemExists(at: candidate) == false {
                return candidate
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    private func ownedPlacementStagingURL(
        for manifest: CompletedDownloadHandoffManifest
    ) -> URL? {
        guard let destinationPath = manifest.destinationPath,
              let stagingPath = manifest.placementStagingPath else {
            return nil
        }
        let destinationURL = URL(fileURLWithPath: destinationPath).standardizedFileURL
        let stagingURL = URL(fileURLWithPath: stagingPath).standardizedFileURL
        let requiredPrefix = ".harbor-placement-\(manifest.downloadID.uuidString)-\(manifest.attemptIdentifier.uuidString)-"
        guard stagingURL.deletingLastPathComponent() == destinationURL.deletingLastPathComponent(),
              stagingURL.lastPathComponent.hasPrefix(requiredPrefix) else {
            return nil
        }
        return stagingURL
    }

    private func discardPlacementStagingLocked(
        for manifest: CompletedDownloadHandoffManifest
    ) {
        do {
            try removePlacementStagingLocked(for: manifest)
        } catch {
            // Best-effort cleanup is retried whenever the package is
            // reconciled or acknowledged. The manifest never trusts an
            // unreferenced staging file.
        }
    }

    private func removePlacementStagingLocked(
        for manifest: CompletedDownloadHandoffManifest
    ) throws {
        guard let stagingURL = ownedPlacementStagingURL(for: manifest),
              try DurableFileSystem.itemExists(at: stagingURL) else {
            return
        }
        try fileManager.removeItem(at: stagingURL)
        try DurableFileSystem.synchronizeParentDirectory(of: stagingURL)
    }

    private func manifestIfDecodable(
        at packageURL: URL
    ) -> CompletedDownloadHandoffManifest? {
        guard let data = try? Data(contentsOf: manifestURL(for: packageURL)) else {
            return nil
        }
        return try? JSONDecoder().decode(CompletedDownloadHandoffManifest.self, from: data)
    }

    private func manifestMatchingClaim(
        at packageURL: URL,
        claim: CompletedDownloadHandoffManifest,
        actualBytes: Int64
    ) throws -> CompletedDownloadHandoffManifest {
        let values = try packageURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true,
              let manifest = manifestIfDecodable(at: packageURL),
              manifest.phase == .claiming || manifest.phase == .ready,
              manifest.matchesClaim(claim, actualBytes: actualBytes),
              try regularFileSize(
                  at: packageURL.appendingPathComponent(Self.payloadFilename)
              ) == actualBytes else {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        return manifest
    }

    private func manifestForExplicitDiscard(
        at packageURL: URL
    ) throws -> CompletedDownloadHandoffManifest? {
        let url = manifestURL(for: packageURL)
        guard try DurableFileSystem.itemExists(at: url) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try? JSONDecoder().decode(
            CompletedDownloadHandoffManifest.self,
            from: data
        )
    }

    private func writeManifest(
        _ manifest: CompletedDownloadHandoffManifest,
        to packageURL: URL
    ) throws {
        let url = manifestURL(for: packageURL)
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        try synchronizeFile(at: url)
    }

    private func recoverClaimingHandoff(
        at stagingURL: URL
    ) throws -> CompletedDownloadHandoff {
        let payloadURL = stagingURL.appendingPathComponent(Self.payloadFilename)
        guard try DurableFileSystem.itemExists(at: payloadURL) else {
            // A crash can leave the claiming manifest durable before the
            // source payload is moved into its package. That state contains
            // no completed bytes and must not be retained as an operationally
            // unavailable handoff forever.
            throw CompletedDownloadHandoffError.invalidPayload
        }
        let manifest = try claimingManifest(at: stagingURL)
        try synchronizeFile(at: payloadURL)
        try DurableFileSystem.synchronizeDirectory(at: stagingURL)
        let payloadVerification = try verifiedFile(
            at: payloadURL,
            expectedBytes: manifest.actualBytes
        )
        let payloadSHA256 = payloadVerification.sha256
        if manifest.payloadSHA256.isEmpty == false,
           manifest.payloadSHA256 != payloadSHA256 {
            throw CompletedDownloadHandoffError.invalidPayload
        }
        try requireUnchanged(payloadVerification, at: payloadURL)

        let readyManifest = CompletedDownloadHandoffManifest(
            downloadID: manifest.downloadID,
            attemptIdentifier: manifest.attemptIdentifier,
            owner: manifest.owner,
            sourceURL: manifest.sourceURL,
            statusCode: manifest.statusCode,
            mimeType: manifest.mimeType,
            suggestedFilename: manifest.suggestedFilename,
            actualBytes: manifest.actualBytes,
            expectedBytes: manifest.expectedBytes,
            payloadSHA256: payloadSHA256,
            createdAt: manifest.createdAt
        )
        try writeManifest(readyManifest, to: stagingURL)
        try DurableFileSystem.synchronizeDirectory(at: stagingURL)
        return try validatedHandoff(at: stagingURL)
    }

    private func claimingManifest(
        at packageURL: URL
    ) throws -> CompletedDownloadHandoffManifest {
        guard packageURL.pathExtension == Self.stagingExtension,
              packageURL.deletingLastPathComponent().standardizedFileURL
                == directoryURL.standardizedFileURL,
              let identifiers = identifiers(from: packageURL) else {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        let packageValues = try packageURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard packageValues.isDirectory == true,
              packageValues.isSymbolicLink != true else {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        let manifestData = try Data(contentsOf: manifestURL(for: packageURL))
        let manifest: CompletedDownloadHandoffManifest
        do {
            manifest = try JSONDecoder().decode(
                CompletedDownloadHandoffManifest.self,
                from: manifestData
            )
        } catch {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        guard manifest.version == CompletedDownloadHandoffManifest.currentVersion,
              manifest.downloadID == identifiers.downloadID,
              manifest.attemptIdentifier == identifiers.attemptIdentifier,
              manifest.phase == .claiming,
              manifest.destinationPath == nil,
              manifest.placementStagingPath == nil,
              manifest.actualBytes >= 0,
              manifest.expectedBytes == manifest.actualBytes,
              manifest.payloadSHA256.isEmpty
                || manifest.payloadSHA256.count == SHA256.byteCount * 2,
              manifest.statusCode.map({ (200 ... 299).contains($0) }) != false else {
            throw CompletedDownloadHandoffError.invalidManifest
        }
        let payloadBytes = try regularFileSize(
            at: packageURL.appendingPathComponent(Self.payloadFilename)
        )
        guard payloadBytes == manifest.actualBytes else {
            throw CompletedDownloadHandoffError.payloadLengthMismatch(
                actual: payloadBytes,
                expected: manifest.actualBytes
            )
        }
        return manifest
    }

    private func regularFileSize(at url: URL) throws -> Int64 {
        let identity = try regularFileIdentity(at: url)
        guard identity.size >= 0 else {
            throw CompletedDownloadHandoffError.invalidPayload
        }
        return Int64(identity.size)
    }

    private func regularFileIdentity(
        at url: URL
    ) throws -> DurableFileSystem.RegularFileIdentity {
        do {
            return try DurableFileSystem.regularFileIdentity(at: url)
        } catch is CocoaError {
            throw CompletedDownloadHandoffError.invalidPayload
        }
    }

    private func verifiedFile(
        at url: URL,
        expectedBytes: Int64
    ) throws -> VerifiedFile {
        let before = try regularFileIdentity(at: url)
        guard Int64(before.size) == expectedBytes else {
            throw CompletedDownloadHandoffError.payloadLengthMismatch(
                actual: Int64(before.size),
                expected: expectedBytes
            )
        }
        let hash = try payloadHashOperation(url)
        let after = try regularFileIdentity(at: url)
        guard after == before else {
            throw CompletedDownloadHandoffError.invalidPayload
        }
        return VerifiedFile(identity: after, sha256: hash)
    }

    private func requireUnchanged(_ verified: VerifiedFile, at url: URL) throws {
        guard try regularFileIdentity(at: url) == verified.identity else {
            throw CompletedDownloadHandoffError.invalidPayload
        }
    }

    private func synchronizeFile(at url: URL) throws {
        try DurableFileSystem.synchronizeFile(at: url)
    }

    private func packageURL(
        downloadID: UUID,
        attemptIdentifier: UUID,
        pathExtension: String
    ) -> URL {
        directoryURL
            .appendingPathComponent(
                "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)",
                isDirectory: true
            )
            .appendingPathExtension(pathExtension)
    }

    private func manifestURL(for packageURL: URL) -> URL {
        packageURL.appendingPathComponent(Self.manifestFilename)
    }

    private func identifiers(from packageURL: URL) -> (
        downloadID: UUID,
        attemptIdentifier: UUID
    )? {
        let name = packageURL.deletingPathExtension().lastPathComponent
        guard name.count == 73,
              name[name.index(name.startIndex, offsetBy: 36)] == "-" else {
            return nil
        }

        let splitIndex = name.index(name.startIndex, offsetBy: 36)
        let downloadText = String(name[..<splitIndex])
        let attemptStart = name.index(after: splitIndex)
        let attemptText = String(name[attemptStart...])
        guard let downloadID = UUID(uuidString: downloadText),
              let attemptIdentifier = UUID(uuidString: attemptText) else {
            return nil
        }
        return (downloadID, attemptIdentifier)
    }

    private func promoteValidStagingPackages() {
        guard let contents = withRegistryLock({
            try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
        }) else {
            return
        }
        for url in contents where url.pathExtension == Self.stagingExtension {
            guard let identifiers = identifiers(from: url) else {
                continue
            }
            withDownloadLock(
                downloadID: identifiers.downloadID
            ) {
                do {
                    try promoteStagingPackageLocked(at: url)
                } catch is CompletedDownloadHandoffError {
                    // This entry cannot contain a complete payload. Removing
                    // it is safe; operational failures retain it for retry.
                    try? fileManager.removeItem(at: url)
                    try? DurableFileSystem.synchronizeDirectory(at: directoryURL)
                } catch {
                    // An I/O error is not proof that the payload is corrupt.
                }
            }
        }
    }

    private func promoteStagingPackageLocked(at stagingURL: URL) throws {
        let handoff: CompletedDownloadHandoff
        if manifestIfDecodable(at: stagingURL)?.phase == .claiming {
            handoff = try recoverClaimingHandoff(at: stagingURL)
        } else {
            handoff = try validatedHandoff(at: stagingURL)
        }

        let readyURL = packageURL(
            downloadID: handoff.manifest.downloadID,
            attemptIdentifier: handoff.manifest.attemptIdentifier,
            pathExtension: Self.packageExtension
        )
        try synchronizeFile(at: manifestURL(for: stagingURL))
        if let payloadURL = handoff.payloadURL {
            try synchronizeFile(at: payloadURL)
        }
        try DurableFileSystem.synchronizeDirectory(at: stagingURL)

        if try DurableFileSystem.itemExists(at: readyURL) {
            do {
                _ = try validatedHandoff(at: readyURL)
                // A valid ready package already owns this immutable attempt.
                try fileManager.removeItem(at: stagingURL)
            } catch is CompletedDownloadHandoffError {
                // A torn ready entry must not suppress the complete staging
                // package produced by the atomic claim sequence.
                try fileManager.removeItem(at: readyURL)
                try fileManager.moveItem(at: stagingURL, to: readyURL)
            }
        } else {
            try fileManager.moveItem(at: stagingURL, to: readyURL)
        }
        try DurableFileSystem.synchronizeDirectory(at: directoryURL)
    }

    private func withDownloadLock<T>(
        downloadID: UUID,
        _ work: () throws -> T
    ) rethrows -> T {
        let downloadLock = registryLock.withLock {
            if let existing = downloadLocks[downloadID] {
                return existing
            }
            let created = NSLock()
            downloadLocks[downloadID] = created
            return created
        }
        return try downloadLock.withLock(work)
    }

    private func withRegistryLock<T>(_ work: () throws -> T) rethrows -> T {
        registryLock.lock()
        defer { registryLock.unlock() }
        return try work()
    }
}
