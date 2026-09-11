import Darwin
import Foundation

struct TorrentCheckPathMapping: Sendable {
    let directoryURL: URL
    let payloadURLs: [URL]
    let indexOut: [String]
    let preview: TorrentContentsPreview

    nonisolated static func resolve(metainfo: Data, existingDataPath: String) throws -> Self {
        let preview = try TorrentMetainfoParser.preview(from: metainfo)
        return try resolve(preview: preview, location: URL(fileURLWithPath: existingDataPath))
    }

    nonisolated static func resolve(preview: TorrentContentsPreview, location: URL) throws -> Self {
        try validateRelativePath(preview.name)
        guard !preview.name.contains("/") else { throw TorrentMetainfoError.invalidFile }
        guard location.isFileURL else { throw TorrentMetainfoError.invalidFile }
        let chosen = location.standardizedFileURL
        var chosenInfo = stat()
        let exists = lstat(chosen.path, &chosenInfo) == 0
        guard exists || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let kind = chosenInfo.st_mode & S_IFMT
        let canonical = try canonicalURL(chosen)
        try validateRelativePath(canonical.lastPathComponent)
        if !preview.isMultiFile {
            guard !exists || kind == S_IFREG else { throw TorrentMetainfoError.invalidFile }
            return Self(directoryURL: canonical.deletingLastPathComponent(), payloadURLs: [canonical],
                        indexOut: ["1=\(canonical.lastPathComponent)"], preview: preview)
        }
        guard !exists || kind == S_IFDIR else { throw TorrentMetainfoError.invalidFile }
        var seen = Set<String>()
        let files = try preview.files.map { file in
            try validateRelativePath(file.path)
            let url = canonical.appendingPathComponent(file.path)
            guard url.pathComponents.starts(with: canonical.pathComponents),
                  url.pathComponents.count > canonical.pathComponents.count,
                  seen.insert(url.path).inserted else { throw TorrentMetainfoError.invalidFile }
            // Reject symlinks and nonregular payloads, including symlinked
            // ancestors. Missing files are valid inputs to an incomplete check.
            var componentURL = canonical
            let components = file.path.split(separator: "/")
            for (index, component) in components.enumerated() {
                componentURL.appendPathComponent(String(component))
                var statInfo = stat()
                if lstat(componentURL.path, &statInfo) != 0 {
                    if errno == ENOENT { break }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let kind = statInfo.st_mode & S_IFMT
                guard kind == (index == components.count - 1 ? S_IFREG : S_IFDIR) else {
                    throw TorrentMetainfoError.invalidFile
                }
            }
            return url
        }
        return Self(directoryURL: canonical.deletingLastPathComponent(), payloadURLs: files,
                    indexOut: preview.files.map { "\($0.index)=\(canonical.lastPathComponent)/\($0.path)" }, preview: preview)
    }

    nonisolated private static func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.contains("\\"), !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else {
            throw TorrentMetainfoError.invalidFile
        }
    }

    /// Foundation can shorten /private/var back to the /var symlink even after
    /// resolvingSymlinksInPath. Keep the POSIX path for the no-follow reader.
    /// Resolve the existing ancestor when a previously imported file is gone.
    nonisolated private static func canonicalURL(_ url: URL) throws -> URL {
        var ancestor = url
        var missingComponents: [String] = []
        while true {
            if let resolved = realpath(ancestor.path, nil) {
                defer { free(resolved) }
                var result = URL(fileURLWithPath: String(cString: resolved))
                for component in missingComponents.reversed() {
                    result.appendPathComponent(component)
                }
                return result
            }
            guard errno == ENOENT, ancestor.path != "/" else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
}
