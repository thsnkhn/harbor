import Foundation

enum HarborBrowserBridge {
    static let chromeExtensionID = "fochjdokmchcbcbjgfohfpifhagolonm"
    static let firefoxAddonIDs = ["harbor-download-helper@harborapp", "harbor@head-less-ghost"]

    static let chromiumDataDirs = [
        "Google/Chrome", "Google/Chrome Beta", "Chromium",
        "BraveSoftware/Brave-Browser", "Microsoft Edge", "Vivaldi", "Arc/User Data",
    ]

    static func registerIfNeeded() {
        guard let hostURL = Bundle.main.url(forResource: "host", withExtension: "py") else {
            
            return
        }
        let host = hostURL.path
        if !FileManager.default.isExecutableFile(atPath: host) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host)
        }
        guard FileManager.default.isExecutableFile(atPath: host) else {
            
            return
        }

        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")

        for dir in chromiumDataDirs {
            let base = support.appendingPathComponent(dir)
            guard FileManager.default.fileExists(atPath: base.path) else { continue }
            write(name: "com.harbor.chrome",
                  description: "Harbor download bridge for Chromium browsers",
                  host: host,
                  extra: ["allowed_origins": ["chrome-extension://\(chromeExtensionID)/"]],
                  to: base.appendingPathComponent("NativeMessagingHosts/com.harbor.chrome.json"))
        }

        let moz = support.appendingPathComponent("Mozilla")
        if FileManager.default.fileExists(atPath: moz.path) ||
            FileManager.default.fileExists(atPath: support.appendingPathComponent("Firefox").path) {
            write(name: "com.harbor.firefox",
                  description: "Harbor download bridge for Firefox",
                  host: host,
                  extra: ["allowed_extensions": firefoxAddonIDs],
                  to: moz.appendingPathComponent("NativeMessagingHosts/com.harbor.firefox.json"))
        }
    }

    private static func write(name: String, description: String, host: String,
                              extra: [String: Any], to url: URL) {
        var manifest: [String: Any] = [
            "name": name, "description": description, "path": host, "type": "stdio",
        ]
        extra.forEach { manifest[$0.key] = $0.value }
        guard let data = try? JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) else { return }
        if let existing = try? Data(contentsOf: url), existing == data { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
        
    }
}
