import Foundation

enum MediaDownloadType: String, Codable, Sendable {
    case video
    case image
    case collection
    case unknown
}

enum MediaDownloadFormatPreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case bestMP4
    case original

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .bestMP4:
            "Best MP4"
        case .original:
            "Original"
        }
    }
}

struct MediaDownloadMetadata: Codable, Equatable, Sendable {
    let title: String
    let platform: String
    let extractorKey: String?
    let thumbnailURL: URL?
    let webpageURL: URL?
    let expectedBytes: Int64
    let mediaType: MediaDownloadType
    let entryCount: Int

    nonisolated var isCollection: Bool {
        entryCount > 1 || mediaType == .collection
    }

    nonisolated var defaultFormatPreference: MediaDownloadFormatPreference {
        mediaType == .video ? .bestMP4 : .original
    }
}

enum MediaDownloadMetadataParser {
    nonisolated static func metadata(from data: Data, sourceURL: URL) throws -> MediaDownloadMetadata {
        let payload = try JSONDecoder().decode(YTDLPInfoPayload.self, from: data)
        return metadata(from: payload, sourceURL: sourceURL)
    }

    private nonisolated static func metadata(
        from payload: YTDLPInfoPayload,
        sourceURL: URL
    ) -> MediaDownloadMetadata {
        let entries = payload.entries ?? []
        let entryCount = max(entries.count, 1)
        let mediaType = mediaType(for: payload, entryCount: entryCount)
        let expectedBytes = max(payload.expectedBytes, entries.map(\.expectedBytes).max() ?? 0)
        let title = payload.bestTitle ?? sourceURL.host ?? "Media Download"

        return MediaDownloadMetadata(
            title: title,
            platform: payload.platform ?? sourceURL.host ?? "Media",
            extractorKey: payload.extractorKey,
            thumbnailURL: payload.thumbnailURL,
            webpageURL: payload.webpageURL ?? sourceURL,
            expectedBytes: expectedBytes,
            mediaType: mediaType,
            entryCount: entryCount
        )
    }

    private nonisolated static func mediaType(
        for payload: YTDLPInfoPayload,
        entryCount: Int
    ) -> MediaDownloadType {
        if entryCount > 1 {
            return .collection
        }

        if let ext = payload.ext?.lowercased(),
           imageExtensions.contains(ext) {
            return .image
        }

        if payload.formats?.contains(where: { $0.vcodec != nil && $0.vcodec != "none" }) == true {
            return .video
        }

        if payload.ext != nil {
            return .video
        }

        return .unknown
    }

    private nonisolated static let imageExtensions: Set<String> = [
        "avif",
        "gif",
        "heic",
        "jpeg",
        "jpg",
        "png",
        "webp"
    ]
}

private nonisolated struct YTDLPInfoPayload: Decodable {
    let id: String?
    let title: String?
    let fulltitle: String?
    let extractor: String?
    let extractorKey: String?
    let webpageURL: URL?
    let originalURL: URL?
    let thumbnailURL: URL?
    let ext: String?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let formats: [YTDLPFormatPayload]?
    let entries: [YTDLPInfoEntryPayload]?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case fulltitle
        case extractor
        case extractorKey = "extractor_key"
        case webpageURL = "webpage_url"
        case originalURL = "original_url"
        case thumbnailURL = "thumbnail"
        case ext
        case filesize
        case filesizeApprox = "filesize_approx"
        case formats
        case entries
    }

    nonisolated var bestTitle: String? {
        fulltitle?.nilIfBlank ?? title?.nilIfBlank ?? id?.nilIfBlank
    }

    nonisolated var platform: String? {
        extractorKey?.nilIfBlank ?? extractor?.nilIfBlank
    }

    nonisolated var expectedBytes: Int64 {
        filesize ?? filesizeApprox ?? formats?.compactMap(\.expectedBytes).max() ?? 0
    }
}

private nonisolated struct YTDLPInfoEntryPayload: Decodable {
    let id: String?
    let title: String?
    let filesize: Int64?
    let filesizeApprox: Int64?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case filesize
        case filesizeApprox = "filesize_approx"
    }

    nonisolated var expectedBytes: Int64 {
        filesize ?? filesizeApprox ?? 0
    }
}

private nonisolated struct YTDLPFormatPayload: Decodable {
    let ext: String?
    let vcodec: String?
    let filesize: Int64?
    let filesizeApprox: Int64?

    enum CodingKeys: String, CodingKey {
        case ext
        case vcodec
        case filesize
        case filesizeApprox = "filesize_approx"
    }

    nonisolated var expectedBytes: Int64 {
        filesize ?? filesizeApprox ?? 0
    }
}

private extension String {
    nonisolated var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
