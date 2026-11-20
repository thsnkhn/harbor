import Foundation

struct HTTPDownloadIncompleteResponseError: LocalizedError {
    let actualBytes: Int64
    let expectedBytes: Int64?

    var errorDescription: String? {
        if let expectedBytes {
            return "The download ended after \(actualBytes) of \(expectedBytes) bytes."
        }

        return "The server ended a ranged download without declaring the complete file length."
    }
}

struct HTTPDownloadInvalidRangeResponseError: LocalizedError {
    var errorDescription: String? {
        "The server returned an invalid or contradictory byte-range response."
    }
}

struct HTTPDownloadContentRange: Equatable, Sendable {
    let start: Int64
    let end: Int64
    let total: Int64?
}

struct HTTPDownloadStatusError: LocalizedError {
    let statusCode: Int

    var errorDescription: String? {
        "The server returned HTTP \(statusCode) instead of a downloadable file."
    }
}

enum DownloadHTTPResponseValidator {
    nonisolated static func contentRange(
        from value: String?
    ) -> HTTPDownloadContentRange? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else {
            return nil
        }

        let payload = trimmed.dropFirst("bytes ".count)
        let components = payload.split(separator: "/", maxSplits: 1)
        guard components.count == 2 else {
            return nil
        }

        let rangeComponents = components[0].split(separator: "-", maxSplits: 1)
        guard rangeComponents.count == 2,
              let start = Int64(rangeComponents[0]),
              let end = Int64(rangeComponents[1]),
              start >= 0,
              end >= start else {
            return nil
        }

        let total: Int64?
        if components[1] == "*" {
            total = nil
        } else {
            guard let parsedTotal = Int64(components[1]), parsedTotal > end else {
                return nil
            }
            total = parsedTotal
        }

        return HTTPDownloadContentRange(start: start, end: end, total: total)
    }

    nonisolated static func unsatisfiedContentRangeTotal(
        from value: String?
    ) -> Int64? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes */") else {
            return nil
        }

        guard let total = Int64(trimmed.dropFirst("bytes */".count)), total >= 0 else {
            return nil
        }
        return total
    }

    nonisolated static func validatedBrowserCompletedByteCount(
        response: HTTPURLResponse,
        actualBytes: Int64,
        isResumeAttempt: Bool
    ) throws -> Int64 {
        if response.statusCode == 206 {
            let range = try validatedPartialContentRange(response)
            guard isResumeAttempt,
                  let total = range.total,
                  range.start > 0,
                  range.end == total - 1,
                  total == actualBytes else {
                throw HTTPDownloadIncompleteResponseError(
                    actualBytes: actualBytes,
                    expectedBytes: range.total
                )
            }
            return total
        }
        guard actualBytes >= 0 else {
            throw URLError(.badServerResponse)
        }
        guard usesIdentityEncoding(response) else {
            throw URLError(.cannotDecodeContentData)
        }
        guard (200 ... 299).contains(response.statusCode) else {
            throw HTTPDownloadStatusError(statusCode: response.statusCode)
        }
        guard response.statusCode == 200,
              response.value(forHTTPHeaderField: "Content-Range") == nil else {
            throw URLError(.badServerResponse)
        }
        let expectedBytes = try declaredContentLength(response)
            ?? (response.expectedContentLength >= 0 ? response.expectedContentLength : nil)
        if let expectedBytes, expectedBytes != actualBytes {
            throw HTTPDownloadIncompleteResponseError(
                actualBytes: actualBytes,
                expectedBytes: expectedBytes
            )
        }
        return actualBytes
    }

    nonisolated static func validatedPartialContentRange(
        _ response: HTTPURLResponse
    ) throws -> HTTPDownloadContentRange {
        guard usesIdentityEncoding(response),
              let range = contentRange(
                  from: response.value(forHTTPHeaderField: "Content-Range")
              ),
              range.total != nil else {
            throw HTTPDownloadInvalidRangeResponseError()
        }

        let bodyLength = range.end - range.start + 1
        if let declaredLength = try declaredContentLength(response),
           declaredLength != bodyLength {
            throw HTTPDownloadInvalidRangeResponseError()
        }
        return range
    }

    nonisolated static func declaredContentLength(
        _ response: HTTPURLResponse
    ) throws -> Int64? {
        guard let rawValue = response.value(forHTTPHeaderField: "Content-Length") else {
            return nil
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int64(trimmed), value >= 0 else {
            throw URLError(.badServerResponse)
        }
        return value
    }

    nonisolated static func usesIdentityEncoding(
        _ response: HTTPURLResponse
    ) -> Bool {
        guard let rawValue = response.value(forHTTPHeaderField: "Content-Encoding") else {
            return true
        }
        return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare("identity") == .orderedSame
    }

    nonisolated static func strongEntityTag(_ value: String?) -> String? {
        guard let tag = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              tag.count >= 2,
              tag.first == "\"", tag.last == "\"",
              tag.dropFirst().dropLast().contains("\"") == false else {
            return nil
        }
        return tag
    }

    nonisolated static func responseValidator(
        _ response: HTTPURLResponse,
        matching savedValidator: String
    ) -> Bool {
        let headerName = savedValidator.hasPrefix("\"") ? "ETag" : "Last-Modified"
        guard let value = response.value(forHTTPHeaderField: headerName)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return value == savedValidator
    }

    nonisolated static func isInvalidResumeProtocolResponse(
        _ error: Error
    ) -> Bool {
        if error is HTTPDownloadInvalidRangeResponseError {
            return true
        }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return false
        }
        let code = URLError.Code(rawValue: nsError.code)
        return code == .badServerResponse || code == .cannotDecodeContentData
    }
}

struct DirectDownloadRecoveryRestartError: LocalizedError {
    var errorDescription: String? {
        "The server did not accept the saved partial download."
    }
}

enum DirectDownloadResponsePolicy {
    struct ResumeIdentity {
        let offset: Int64
        let expectedBytes: Int64
        let validator: String?
    }

    enum Plan {
        enum Destination {
            case fresh
            case append
        }

        case finishExisting(expectedBytes: Int64)
        case receiveBody(
            destination: Destination,
            contentRange: HTTPDownloadContentRange?,
            expectedBytes: Int64?,
            resetReason: DirectDownloadRecoveryResetReason?
        )
    }

    nonisolated static func request(
        sourceURL: URL,
        recovery: DirectDownloadRecoverySnapshot?,
        requestHeaders: [RequestHeader] = []
    ) -> URLRequest {
        var request = URLRequest(url: sourceURL)
        requestHeaders.apply(to: &request)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        // Harbor owns byte ranges so custom headers cannot request a partial file.
        request.setValue(nil, forHTTPHeaderField: "Range")
        request.setValue(nil, forHTTPHeaderField: "If-Range")

        if let recovery,
           let validator = recovery.metadata.ifRangeValidator {
            request.setValue(
                "bytes=\(recovery.bytesWritten)-",
                forHTTPHeaderField: "Range"
            )
            request.setValue(validator, forHTTPHeaderField: "If-Range")
        }

        return request
    }

    nonisolated static func plan(
        for response: HTTPURLResponse,
        resume: ResumeIdentity?
    ) throws -> Plan {
        let isResuming = (resume?.offset ?? 0) > 0

        if isResuming, response.statusCode == 416 {
            let total = DownloadHTTPResponseValidator.unsatisfiedContentRangeTotal(
                from: response.value(forHTTPHeaderField: "Content-Range")
            )
            let matchesSavedTotal = (resume?.expectedBytes ?? 0) <= 0
                || total == resume?.expectedBytes
            if let resume,
               total == resume.offset,
               matchesSavedTotal,
               let validator = resume.validator,
               DownloadHTTPResponseValidator.responseValidator(
                   response,
                   matching: validator
               ) {
                return .finishExisting(expectedBytes: total ?? resume.offset)
            }
            throw DirectDownloadRecoveryRestartError()
        }

        guard (200 ... 299).contains(response.statusCode) else {
            throw HTTPDownloadStatusError(statusCode: response.statusCode)
        }

        do {
            guard response.statusCode == 200 || response.statusCode == 206,
                  DownloadHTTPResponseValidator.usesIdentityEncoding(response) else {
                throw URLError(.badServerResponse)
            }

            let contentRange: HTTPDownloadContentRange?
            if response.statusCode == 206 {
                contentRange = try DownloadHTTPResponseValidator
                    .validatedPartialContentRange(response)
            } else {
                guard response.value(forHTTPHeaderField: "Content-Range") == nil else {
                    throw URLError(.badServerResponse)
                }
                contentRange = nil
            }

            if let resume, resume.offset > 0, response.statusCode == 206 {
                let matchesSavedTotal = resume.expectedBytes <= 0
                    || contentRange?.total == resume.expectedBytes
                guard let contentRange,
                      contentRange.start == resume.offset,
                      matchesSavedTotal,
                      let validator = resume.validator,
                      DownloadHTTPResponseValidator.responseValidator(
                          response,
                          matching: validator
                      ) else {
                    throw DirectDownloadRecoveryRestartError()
                }
            } else if isResuming == false,
                      response.statusCode == 206,
                      contentRange?.start != 0 {
                throw URLError(.badServerResponse)
            }

            let expectedBytes: Int64?
            if response.statusCode == 206 {
                expectedBytes = contentRange?.total
            } else {
                expectedBytes = try DownloadHTTPResponseValidator.declaredContentLength(response)
                    ?? (response.expectedContentLength >= 0
                        ? response.expectedContentLength
                        : nil)
            }

            return .receiveBody(
                destination: isResuming && response.statusCode == 206
                    ? .append
                    : .fresh,
                contentRange: contentRange,
                expectedBytes: expectedBytes,
                resetReason: isResuming && response.statusCode == 200
                    ? .serverRejectedRange
                    : nil
            )
        } catch {
            if isResuming,
               DownloadHTTPResponseValidator.isInvalidResumeProtocolResponse(error) {
                throw DirectDownloadRecoveryRestartError()
            }
            throw error
        }
    }
}
