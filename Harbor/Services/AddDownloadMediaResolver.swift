import Foundation

/// Shared metadata validation for single links and pasted batches.
enum AddDownloadMediaResolver {
    @MainActor
    static func resolve(
        _ url: URL,
        using provider: @MainActor (URL) async throws -> MediaDownloadMetadata?
    ) async throws -> MediaDownloadMetadata {
        guard let metadata = try await provider(url), metadata.supportsMediaDownload else {
            throw ResolutionError.unavailable
        }
        try Task.checkCancellation()
        return metadata
    }

    private enum ResolutionError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            String(localized: "yt-dlp couldn’t verify downloadable media for this link.")
        }
    }

    static func isKnownMediaHost(_ url: URL) -> Bool {
        guard DownloadSourceKind.detect(from: url) == .directURL,
              let host = url.host?.lowercased() else {
            return false
        }

        let exactHosts: Set<String> = [
            "fb.watch",
            "pin.it",
            "youtu.be"
        ]

        if exactHosts.contains(host) {
            return true
        }

        let suffixes = [
            "youtube.com",
            "instagram.com",
            "tiktok.com",
            "twitter.com",
            "x.com",
            "facebook.com",
            "pinterest.com",
            "vimeo.com",
            "dailymotion.com",
            "reddit.com",
            "threads.net",
            "soundcloud.com",
            "twitch.tv"
        ]

        return suffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
            || host.contains("pinterest.")
    }
}
