import CFNetwork
import Foundation

nonisolated enum NetworkProxyMode: String, CaseIterable, Identifiable, Sendable {
    case none
    case system
    case manual

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .none: "No Proxy"
        case .system: "Use System Proxy"
        case .manual: "Manual Proxy"
        }
    }
}

nonisolated enum NetworkProxyScheme: String, CaseIterable, Identifiable, Sendable {
    case http
    case socks5

    var id: String { rawValue }

    var title: String {
        switch self {
        case .http: "HTTP"
        case .socks5: "SOCKS5"
        }
    }
}

nonisolated enum NetworkProxyError: LocalizedError, Equatable, Sendable {
    case invalidManualConfiguration
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidManualConfiguration:
            "Enter a proxy host and a port between 1 and 65535."
        case let .connectionFailed(detail):
            "The download failed while using the configured proxy. \(detail)"
        }
    }
}

nonisolated struct NetworkProxySettings: Equatable, Sendable {
    static let system = NetworkProxySettings(
        mode: .system,
        scheme: .http,
        host: "",
        port: 8_080
    )

    let mode: NetworkProxyMode
    let scheme: NetworkProxyScheme
    let host: String
    let port: Int

    var validationError: NetworkProxyError? {
        guard mode == .manual else {
            return nil
        }
        return Self.proxyURI(scheme: scheme, host: host, port: port) == nil
            ? .invalidManualConfiguration
            : nil
    }

    func apply(to configuration: URLSessionConfiguration) throws {
        switch mode {
        case .system:
            configuration.connectionProxyDictionary = nil
        case .none:
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: false,
                kCFNetworkProxiesHTTPSEnable as String: false,
                kCFNetworkProxiesSOCKSEnable as String: false
            ]
        case .manual:
            guard validationError == nil else {
                throw NetworkProxyError.invalidManualConfiguration
            }
            let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
            switch scheme {
            case .http:
                configuration.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: true,
                    kCFNetworkProxiesHTTPProxy as String: host,
                    kCFNetworkProxiesHTTPPort as String: port,
                    kCFNetworkProxiesHTTPSEnable as String: true,
                    kCFNetworkProxiesHTTPSProxy as String: host,
                    kCFNetworkProxiesHTTPSPort as String: port
                ]
            case .socks5:
                configuration.connectionProxyDictionary = [
                    kCFNetworkProxiesSOCKSEnable as String: true,
                    kCFNetworkProxiesSOCKSProxy as String: host,
                    kCFNetworkProxiesSOCKSPort as String: port
                ]
            }
        }
    }

    func aria2ProxyURI() throws -> String? {
        switch mode {
        case .none:
            return nil
        case .system:
            guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue()
                as? [String: Any] else {
                return nil
            }
            return Self.systemProxyURI(from: settings)
        case .manual:
            guard let uri = Self.proxyURI(scheme: scheme, host: host, port: port) else {
                throw NetworkProxyError.invalidManualConfiguration
            }
            return uri
        }
    }

    func downloadError(from error: Error) -> Error {
        guard mode == .manual else {
            return error
        }
        return NetworkProxyError.connectionFailed(error.localizedDescription)
    }

    static func systemProxyURI(from settings: [String: Any]) -> String? {
        if isEnabled(kCFNetworkProxiesSOCKSEnable, in: settings),
           let endpoint = endpoint(
               hostKey: kCFNetworkProxiesSOCKSProxy,
               portKey: kCFNetworkProxiesSOCKSPort,
               in: settings
           ) {
            return proxyURI(scheme: .socks5, host: endpoint.host, port: endpoint.port)
        }

        for (enabledKey, hostKey, portKey) in [
            (kCFNetworkProxiesHTTPSEnable, kCFNetworkProxiesHTTPSProxy, kCFNetworkProxiesHTTPSPort),
            (kCFNetworkProxiesHTTPEnable, kCFNetworkProxiesHTTPProxy, kCFNetworkProxiesHTTPPort)
        ] where isEnabled(enabledKey, in: settings) {
            if let endpoint = endpoint(hostKey: hostKey, portKey: portKey, in: settings) {
                return proxyURI(scheme: .http, host: endpoint.host, port: endpoint.port)
            }
        }

        return nil
    }

    private static func isEnabled(_ key: CFString, in settings: [String: Any]) -> Bool {
        (settings[key as String] as? NSNumber)?.boolValue == true
            || settings[key as String] as? Bool == true
    }

    private static func endpoint(
        hostKey: CFString,
        portKey: CFString,
        in settings: [String: Any]
    ) -> (host: String, port: Int)? {
        guard let host = settings[hostKey as String] as? String else {
            return nil
        }
        let port = (settings[portKey as String] as? NSNumber)?.intValue
            ?? settings[portKey as String] as? Int
            ?? 0
        guard proxyURI(scheme: .http, host: host, port: port) != nil else {
            return nil
        }
        return (host, port)
    }

    private static func proxyURI(
        scheme: NetworkProxyScheme,
        host: String,
        port: Int
    ) -> String? {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty == false,
              host.contains(where: \.isWhitespace) == false,
              (1 ... 65_535).contains(port) else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme.rawValue
        components.host = host
        components.port = port
        return components.url?.absoluteString
    }
}
