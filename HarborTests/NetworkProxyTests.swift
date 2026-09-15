import CFNetwork
import Foundation
import XCTest
@testable import Harbor

final class NetworkProxyTests: XCTestCase {
    func testManualHTTPProxyConfiguresURLSessionAndAria2Next() throws {
        let settings = NetworkProxySettings(
            mode: .manual,
            scheme: .http,
            host: "proxy.example",
            port: 8_080
        )
        let configuration = URLSessionConfiguration.ephemeral

        try settings.apply(to: configuration)

        let proxies = try XCTUnwrap(configuration.connectionProxyDictionary)
        XCTAssertEqual(proxies[kCFNetworkProxiesHTTPEnable as String] as? Bool, true)
        XCTAssertEqual(proxies[kCFNetworkProxiesHTTPProxy as String] as? String, "proxy.example")
        XCTAssertEqual(proxies[kCFNetworkProxiesHTTPPort as String] as? Int, 8_080)
        XCTAssertEqual(try settings.aria2ProxyURI(), "http://proxy.example:8080")
    }

    func testManualSOCKSProxyConfiguresURLSessionAndAria2Next() throws {
        let settings = NetworkProxySettings(
            mode: .manual,
            scheme: .socks5,
            host: "127.0.0.1",
            port: 9_050
        )
        let configuration = URLSessionConfiguration.ephemeral

        try settings.apply(to: configuration)

        let proxies = try XCTUnwrap(configuration.connectionProxyDictionary)
        XCTAssertEqual(proxies[kCFNetworkProxiesSOCKSEnable as String] as? Bool, true)
        XCTAssertEqual(proxies[kCFNetworkProxiesSOCKSProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(proxies[kCFNetworkProxiesSOCKSPort as String] as? Int, 9_050)
        XCTAssertEqual(try settings.aria2ProxyURI(), "socks5://127.0.0.1:9050")
    }

    func testSystemProxyPrefersSOCKSForTorrentTraffic() {
        let systemSettings: [String: Any] = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "http.example",
            kCFNetworkProxiesHTTPPort as String: 8_080,
            kCFNetworkProxiesSOCKSEnable as String: true,
            kCFNetworkProxiesSOCKSProxy as String: "socks.example",
            kCFNetworkProxiesSOCKSPort as String: 1_080
        ]

        XCTAssertEqual(
            NetworkProxySettings.systemProxyURI(from: systemSettings),
            "socks5://socks.example:1080"
        )
    }

    func testInvalidManualProxyStopsDirectDownloadBeforeNetworkUse() {
        let settings = NetworkProxySettings(
            mode: .manual,
            scheme: .http,
            host: "",
            port: 8_080
        )
        let coordinator = DownloadCoordinator(
            eventHandler: { _ in },
            proxySettings: settings
        )

        XCTAssertThrowsError(
            try coordinator.startDownload(
                id: UUID(),
                sourceURL: URL(string: "https://example.com/file")!
            )
        ) { error in
            XCTAssertEqual(error as? NetworkProxyError, .invalidManualConfiguration)
        }
    }

    func testManualProxyAddsContextToNetworkFailure() {
        let settings = NetworkProxySettings(
            mode: .manual,
            scheme: .http,
            host: "proxy.example",
            port: 8_080
        )

        XCTAssertEqual(
            settings.downloadError(from: URLError(.cannotConnectToHost)) as? NetworkProxyError,
            .connectionFailed(URLError(.cannotConnectToHost).localizedDescription)
        )
    }

    func testDaemonArgumentsContainResolvedTorrentProxy() {
        let arguments = Aria2TorrentService.daemonArguments(
            sessionFilePath: "/tmp/aria2-next.session",
            stateDirectoryPath: "/tmp/aria2-next-state",
            rpcPort: 18_000,
            rpcSecret: "secret",
            hostProcessIdentifier: 42,
            transferSettings: .default,
            networkBinding: .unrestricted,
            proxyURI: "socks5://127.0.0.1:9050"
        )

        XCTAssertTrue(arguments.contains("--bt-proxy=socks5://127.0.0.1:9050"))
    }
}
