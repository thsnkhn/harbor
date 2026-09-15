import Foundation

nonisolated enum TorrentSourceLoader {
    static func fetch(
        from remoteURL: URL,
        requestHeaders: [RequestHeader],
        proxySettings: NetworkProxySettings = .system
    ) async throws -> Data {
        var request = URLRequest(url: remoteURL)
        requestHeaders.apply(to: &request)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        try proxySettings.apply(to: configuration)

        let redirectDelegate = TorrentSourceRedirectDelegate(
            sourceURL: remoteURL,
            requestHeaders: requestHeaders
        )
        let session = URLSession(
            configuration: configuration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
        defer {
            session.finishTasksAndInvalidate()
        }

        let temporaryURL: URL
        let response: URLResponse
        do {
            (temporaryURL, response) = try await session.download(for: request)
        } catch {
            throw proxySettings.downloadError(from: error)
        }
        if let response = response as? HTTPURLResponse,
           (200 ... 299).contains(response.statusCode) == false {
            throw TorrentSourceLoadingError.httpStatus(response.statusCode)
        }

        let data = try ManagedTorrentSourceStore.loadTorrentData(at: temporaryURL)

        guard data.isEmpty == false else {
            throw TorrentSourceLoadingError.emptyResponse
        }

        return data
    }
}

/// Handles redirects while Harbor fetches a remote `.torrent` file before passing its data to aria2.
///
/// `TorrentSourceLoader` uses a separate ephemeral URLSession, so it cannot share the redirect handling
/// in `DownloadCoordinator`. This delegate is scoped to that one source-loading session; it does not
/// control the later tracker or web-seed requests made by aria2.
private nonisolated final class TorrentSourceRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let sourceURL: URL
    private let requestHeaders: [RequestHeader]

    init(
        sourceURL: URL,
        requestHeaders: [RequestHeader]
    ) {
        self.sourceURL = sourceURL
        self.requestHeaders = requestHeaders
    }

    /// Reapplies the supplied headers when the torrent source redirects within its original HTTP origin.
    /// URLSession may omit headers such as `Authorization` from its proposed redirect request. Passing
    /// the adjusted request to the completion handler allows the source fetch to continue without
    /// deliberately reapplying those headers after an origin change.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirectedRequest = request
        requestHeaders.apply(
            toSameOriginRedirect: &redirectedRequest,
            originatingAt: sourceURL
        )
        completionHandler(redirectedRequest)
    }
}

nonisolated enum TorrentSourceLoadingError: LocalizedError, Sendable {
    case httpStatus(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case let .httpStatus(statusCode):
            return String(
                format: String(
                    localized: "error.torrent.sourceHTTPStatus",
                    defaultValue: "The torrent file server returned HTTP %d.",
                    comment: "Error shown when a remote torrent file request returns a non-success HTTP status. Parameter is the HTTP status code."
                ),
                statusCode
            )
        case .emptyResponse:
            return String(
                localized: "error.torrent.sourceEmpty",
                defaultValue: "The torrent file server returned an empty response.",
                comment: "Error shown when a remote torrent file request succeeds without returning torrent data."
            )
        }
    }
}
