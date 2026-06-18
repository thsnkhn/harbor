import Foundation

struct AddDownloadRequest: Sendable {
    let sourceKind: DownloadSourceKind
    let sourceURL: URL
    let customFilename: String?
    let expectedSHA256: String?
    let destinationFolder: URL
    let shouldStartImmediately: Bool
}
