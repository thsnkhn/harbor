import CryptoKit
import Darwin
import Foundation

enum TorrentCheckReadError: LocalizedError {
    case changedDuringCheck
    case invalidSelection

    var errorDescription: String? {
        switch self {
        case .changedDuringCheck: "The files changed during verification. Check them again."
        case .invalidSelection: "The torrent file selection is invalid."
        }
    }
}

enum TorrentCheckService {
    /// Read v1 pieces across file boundaries. Memory use does not depend on
    /// piece size. Missing/short files invalidate pieces; I/O failures throw.
    nonisolated static func check(
        metainfo: Data,
        location: URL,
        selection: TorrentFileSelection?,
        onProgress: @Sendable (Double) async -> Void
    ) async throws -> TorrentCheckResult {
        try Task.checkCancellation()
        let info = try TorrentMetainfoParser.verificationInfo(from: metainfo)
        let layout = try TorrentCheckPathMapping.resolve(preview: info.preview, location: location)
        let files = info.preview.files
        let selected = selection.map { Set($0.selectedIndexes) } ?? Set(files.map(\.index))
        guard !selected.isEmpty, selected.isSubset(of: Set(files.map(\.index))) else {
            throw TorrentCheckReadError.invalidSelection
        }
        let total = files.filter { selected.contains($0.index) }.reduce(Int64(0)) { $0 + $1.byteCount }
        let identities = try layout.payloadURLs.map { try identity(at: $0) }
        var hasher = Insecure.SHA1()
        var pieceBytes: Int64 = 0
        var selectedPieceBytes: Int64 = 0
        var scanned: Int64 = 0
        var verified: Int64 = 0
        var pieceIndex = 0
        var pieceReadable = true
        var selectedComplete = true
        var fullComplete = true
        var lastProgress = ContinuousClock.now
        await onProgress(0)

        for (offset, file) in files.enumerated() {
            try Task.checkCancellation()
            let fd = try openRegularFile(layout.payloadURLs[offset])
            defer { if let fd { close(fd) } }
            guard try fd.map({ try identity(fd: $0) }) == identities[offset] else {
                throw TorrentCheckReadError.changedDuringCheck
            }
            let isSelected = selected.contains(file.index)
            if identities[offset]?.size != file.byteCount {
                fullComplete = false
                if isSelected { selectedComplete = false }
            }
            var fileOffset: Int64 = 0
            while fileOffset < file.byteCount {
                try Task.checkCancellation()
                let count = Int(min(1_048_576, file.byteCount - fileOffset, info.pieceLength - pieceBytes))
                var buffer = Data(count: count)
                var readCount = 0
                if let fd {
                    while readCount < count {
                        let amount = buffer.withUnsafeMutableBytes { bytes in
                            pread(fd, bytes.baseAddress!.advanced(by: readCount), count - readCount, off_t(fileOffset) + off_t(readCount))
                        }
                        if amount < 0 {
                            if errno == EINTR { try Task.checkCancellation(); continue }
                            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        }
                        if amount == 0 { break }
                        readCount += amount
                    }
                }
                if readCount == count { hasher.update(data: buffer) }
                else { pieceReadable = false }
                fileOffset += Int64(count)
                scanned += Int64(count)
                pieceBytes += Int64(count)
                if isSelected { selectedPieceBytes += Int64(count) }
                if pieceBytes == info.pieceLength || scanned == info.preview.totalBytes {
                    let expected = info.hashes[(pieceIndex * 20)..<(pieceIndex * 20 + 20)]
                    let valid = pieceReadable && Data(hasher.finalize()) == expected
                    if valid { verified += selectedPieceBytes }
                    else {
                        fullComplete = false
                        if selectedPieceBytes > 0 { selectedComplete = false }
                    }
                    hasher = Insecure.SHA1()
                    pieceBytes = 0
                    selectedPieceBytes = 0
                    pieceReadable = true
                    pieceIndex += 1
                }
                if lastProgress.duration(to: .now) >= .milliseconds(100) {
                    await onProgress(Double(scanned) / Double(max(1, info.preview.totalBytes)))
                    lastProgress = .now
                }
            }
        }
        // A successful hash pass must not bless files replaced during the scan.
        for (index, url) in layout.payloadURLs.enumerated() {
            try Task.checkCancellation()
            guard try identity(at: url) == identities[index] else {
                throw TorrentCheckReadError.changedDuringCheck
            }
        }
        try Task.checkCancellation()
        await onProgress(1)
        try Task.checkCancellation()
        return TorrentCheckResult(state: selectedComplete ? .complete : .incomplete,
                                  isFullTorrentComplete: fullComplete,
                                  verifiedBytes: verified, totalBytes: total, errorMessage: nil)
    }

    nonisolated private struct FileIdentity: Equatable, Sendable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
    }

    nonisolated private static func identity(at url: URL) throws -> FileIdentity? {
        guard let fd = try openRegularFile(url) else { return nil }
        defer { close(fd) }
        return try identity(fd: fd)
    }

    nonisolated private static func identity(fd: Int32) throws -> FileIdentity {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw TorrentMetainfoError.invalidFile }
        return FileIdentity(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                            modifiedSeconds: info.st_mtimespec.tv_sec, modifiedNanoseconds: info.st_mtimespec.tv_nsec,
                            changedSeconds: info.st_ctimespec.tv_sec, changedNanoseconds: info.st_ctimespec.tv_nsec)
    }

    /// Walk with openat so replacing any validated ancestor with a symlink
    /// cannot redirect the subsequent read outside the chosen location.
    nonisolated private static func openRegularFile(_ url: URL) throws -> Int32? {
        var parent = open("/", O_RDONLY | O_DIRECTORY)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(parent) }
        let components = url.pathComponents.dropFirst()
        for (index, component) in components.enumerated() {
            let final = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | (final ? 0 : O_DIRECTORY)
            let child = openat(parent, component, flags)
            guard child >= 0 else {
                if errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if final {
                do { _ = try identity(fd: child) }
                catch { close(child); throw error }
                return child
            }
            close(parent)
            parent = child
        }
        throw TorrentMetainfoError.invalidFile
    }
}

extension Aria2TorrentService {
    nonisolated func checkExistingData(
        metainfo: Data,
        location: URL,
        selection: TorrentFileSelection? = nil,
        onProgress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> TorrentCheckResult {
        let worker = Task.detached(priority: .utility) {
            try await TorrentCheckService.check(metainfo: metainfo, location: location,
                                                selection: selection, onProgress: onProgress)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
