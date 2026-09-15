import Darwin
import Foundation

nonisolated struct TorrentBlocklistApplication: Decodable, Equatable, Sendable {
    let ruleCount: Int
    let revision: Int
}

nonisolated struct TorrentBlocklistStatus: Equatable, Sendable {
    let ruleCount: Int
    let lastUpdated: Date
}

nonisolated enum TorrentBlocklistError: LocalizedError, Equatable, Sendable {
    case invalidURL
    case httpStatus(Int)
    case invalidEncoding
    case invalidRule(line: Int)
    case empty
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter an HTTP or HTTPS blocklist URL."
        case let .httpStatus(statusCode):
            "The blocklist server returned HTTP \(statusCode)."
        case .invalidEncoding:
            "The blocklist is not valid UTF-8 text."
        case let .invalidRule(line):
            "The blocklist contains an unsupported rule on line \(line)."
        case .empty:
            "The blocklist does not contain any IP or CIDR rules."
        case .tooLarge:
            "The blocklist is larger than 32 MB."
        }
    }
}

nonisolated enum TorrentBlocklistParser {
    static let maximumBytes = 32 * 1_024 * 1_024

    static func rules(from data: Data) throws -> [String] {
        guard data.count <= maximumBytes else {
            throw TorrentBlocklistError.tooLarge
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw TorrentBlocklistError.invalidEncoding
        }

        var seen = Set<String>()
        var rules: [String] = []
        for (offset, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let rule = rawLine
                .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard rule.isEmpty || isValid(rule) else {
                throw TorrentBlocklistError.invalidRule(line: offset + 1)
            }
            if rule.isEmpty == false, seen.insert(rule).inserted {
                rules.append(rule)
            }
        }

        guard rules.isEmpty == false else {
            throw TorrentBlocklistError.empty
        }
        return rules
    }

    private static func isValid(_ rule: String) -> Bool {
        let components = rule.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 2 else {
            return false
        }

        let address = String(components[0])
        let maximumPrefix: Int
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        if inet_pton(AF_INET, address, &ipv4) == 1 {
            maximumPrefix = 32
        } else if inet_pton(AF_INET6, address, &ipv6) == 1 {
            maximumPrefix = 128
        } else {
            return false
        }

        guard components.count == 2 else {
            return true
        }
        guard let prefix = Int(components[1]),
              (0 ... maximumPrefix).contains(prefix) else {
            return false
        }
        return true
    }
}
