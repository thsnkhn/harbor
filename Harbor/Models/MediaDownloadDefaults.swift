import Foundation

enum MediaPreferredFormat: String, CaseIterable, Identifiable, Sendable {
    case bestAvailable
    case mp4Compatible

    var id: String { rawValue }
    var title: LocalizedStringResource {
        switch self {
        case .bestAvailable: "Best available"
        case .mp4Compatible: "MP4 compatibility"
        }
    }
}

enum MediaMaximumResolution: Int, CaseIterable, Identifiable, Sendable {
    case bestAvailable = 0
    case ultraHD = 2160
    case fullHD = 1080
    case hd = 720

    var id: Int { rawValue }
    var title: String {
        self == .bestAvailable ? String(localized: "Best available") : "\(rawValue)p"
    }
}

/// Resolve defaults against the source catalog, then retain the normal per-download selection.
struct MediaDownloadDefaults: Equatable, Sendable {
    var format: MediaPreferredFormat = .bestAvailable
    var maximumResolution: MediaMaximumResolution = .bestAvailable

    nonisolated func preference(for metadata: MediaDownloadMetadata) throws -> MediaDownloadFormatPreference {
        guard format != .bestAvailable || maximumResolution != .bestAvailable else {
            return .bestAvailable
        }
        // Video preferences do not change audio-only or image downloads.
        if metadata.mediaType == .audio || metadata.mediaType == .image { return .bestAvailable }

        let capabilities = metadata.capabilities
        let audioFormats = capabilities.audioFormatOptions.filter {
            ["m4a", "mp4"].contains($0.container) && Self.isAAC($0.audioCodec)
        }
        let hasAudio = capabilities.formatOptions.contains(where: \.hasAudio)
        // Catalog order already ranks video resolution, frame rate, and bitrate.
        let video = capabilities.formatOptions.first { option in
            guard option.hasVideo else { return false }
            if maximumResolution != .bestAvailable {
                guard let height = option.height, height <= maximumResolution.rawValue else { return false }
            }
            if format == .mp4Compatible {
                guard ["mp4", "m4v"].contains(option.container),
                      let codec = option.videoCodec?.lowercased(),
                      codec.hasPrefix("avc1") || codec.hasPrefix("h264") else { return false }
                if option.hasAudio { return Self.isAAC(option.audioCodec) }
                return !hasAudio || !audioFormats.isEmpty
            }
            return true
        }
        guard let video else {
            throw MediaDownloadError.unsupported(String(localized:
                "No video matches your media defaults. Choose a format for this download or change Settings → Media."
            ))
        }
        let selectionCapabilities = format == .mp4Compatible
            ? MediaDownloadCapabilities(formatOptions: [video] + audioFormats)
            : capabilities
        return .specific(selectionCapabilities.defaultSelection(for: video))
    }

    private nonisolated static func isAAC(_ codec: String?) -> Bool {
        guard let codec = codec?.lowercased() else { return false }
        return codec.hasPrefix("mp4a") || codec.hasPrefix("aac")
    }
}
