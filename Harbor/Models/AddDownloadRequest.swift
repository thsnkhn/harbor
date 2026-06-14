import Foundation

struct AddDownloadRequest: Sendable {
    let sourceKind: DownloadSourceKind
    let sourceURL: URL
    let customFilename: String?
    let tags: [String]
    let destinationFolder: URL
    let shouldStartImmediately: Bool
}
