import Foundation

enum TorrentOperationIntent: String, Codable, Sendable {
    case download
    case checkOnly
}

/// Separate from DownloadStatus so older records keep their status encoding.
/// Clear this gate only after the user approves a transfer.
enum TorrentCheckState: String, Codable, Sendable {
    case pending
    case checking
    case complete
    case incomplete
    case error
}

struct TorrentCheckResult: Equatable, Sendable {
    let state: TorrentCheckState
    let isFullTorrentComplete: Bool
    let verifiedBytes: Int64
    let totalBytes: Int64
    let errorMessage: String?
}
