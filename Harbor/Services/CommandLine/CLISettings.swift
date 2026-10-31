import Foundation

/// Typed settings use the store setters, including their engine-change callbacks.
@MainActor
struct CLISettings {
    let settings: AppSettingsStore
    private struct Entry {
        let type: String
        let get: () -> Any
        let set: (String) throws -> Void
    }
    private func boolean(_ key: ReferenceWritableKeyPath<AppSettingsStore, Bool>) -> Entry {
        Entry(type: "boolean", get: { settings[keyPath: key] }, set: { value in
            guard value == "true" || value == "false" else { throw CLIError("invalid_argument", "Expected true or false.") }
            settings[keyPath: key] = value == "true"
        })
    }
    private func number(_ key: ReferenceWritableKeyPath<AppSettingsStore, Int>, _ range: ClosedRange<Int>) -> Entry {
        Entry(type: "integer \(range.lowerBound)...\(range.upperBound)", get: { settings[keyPath: key] }, set: { text in
            guard let value = Int(text), range.contains(value) else { throw CLIError("invalid_argument", "Value is outside the allowed range.") }
            settings[keyPath: key] = value
        })
    }
    private func choice<T: RawRepresentable & CaseIterable>(_ key: ReferenceWritableKeyPath<AppSettingsStore, T>) -> Entry where T.RawValue == String {
        Entry(type: T.allCases.map(\.rawValue).joined(separator: " | "), get: { settings[keyPath: key].rawValue }, set: { value in
            guard let parsed = T(rawValue: value) else { throw CLIError("invalid_argument", "Unknown setting value.") }
            settings[keyPath: key] = parsed
        })
    }
    private func directory(_ key: ReferenceWritableKeyPath<AppSettingsStore, String>) -> Entry {
        Entry(type: "absolute directory path", get: { settings[keyPath: key] }, set: { value in
            var isDirectory: ObjCBool = false
            guard value.hasPrefix("/"), FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory),
                  isDirectory.boolValue, FileManager.default.isWritableFile(atPath: value) else {
                throw CLIError("invalid_argument", "Supply an existing, writable absolute directory path.")
            }
            settings[keyPath: key] = value
        })
    }
    private var entries: [String: Entry] {
        [
            "manifestImportEnabled": boolean(\.manifestImportEnabled),
            "torrentVPNEnabled": boolean(\.torrentVPNEnabled),
            "torrentWatchFolderEnabled": boolean(\.torrentWatchFolderEnabled),
            "removeCompletedDownloadsAutomatically": boolean(\.removeCompletedDownloadsAutomatically),
            "seedTorrents": boolean(\.seedTorrents),
            "seedNewTorrents": boolean(\.seedNewTorrents),
            "stopSeedingAtRatioEnabled": boolean(\.stopSeedingAtRatioEnabled),
            "startDownloadsAutomatically": boolean(\.startDownloadsAutomatically),
            "notificationsEnabled": boolean(\.notificationsEnabled),
            "preventSleepWhileDownloading": boolean(\.preventSleepWhileDownloading),
            "globalSpeedLimitEnabled": boolean(\.globalSpeedLimitEnabled),
            "perDownloadSpeedLimitEnabled": boolean(\.perDownloadSpeedLimitEnabled),
            "globalUploadSpeedLimitEnabled": boolean(\.globalUploadSpeedLimitEnabled),
            "perDownloadUploadSpeedLimitEnabled": boolean(\.perDownloadUploadSpeedLimitEnabled),
            "torrentBlocklistEnabled": boolean(\.torrentBlocklistEnabled),
            "maxConcurrentDownloads": number(\.maxConcurrentDownloads, 1...16),
            "perDownloadConnectionCount": number(\.perDownloadConnectionCount, 1...16),
            "torrentIncomingPort": number(\.torrentIncomingPort, 1024...65535),
            "proxyPort": number(\.proxyPort, 1...65535),
            "globalSpeedLimitKilobytesPerSecond": number(\.globalSpeedLimitKilobytesPerSecond, 1...1_048_576),
            "perDownloadSpeedLimitKilobytesPerSecond": number(\.perDownloadSpeedLimitKilobytesPerSecond, 1...1_048_576),
            "globalUploadSpeedLimitKilobytesPerSecond": number(\.globalUploadSpeedLimitKilobytesPerSecond, 1...1_048_576),
            "perDownloadUploadSpeedLimitKilobytesPerSecond": number(\.perDownloadUploadSpeedLimitKilobytesPerSecond, 1...1_048_576),
            "defaultDestinationPath": directory(\.defaultDestinationPath),
            "torrentDestinationPath": directory(\.torrentDestinationPath),
            "torrentWatchFolderPath": directory(\.torrentWatchFolderPath),
            "appearance": choice(\.appearance),
            "trafficMode": choice(\.trafficMode),
            "mediaPreferredFormat": choice(\.mediaPreferredFormat),
            "torrentIncomingPortMode": choice(\.torrentIncomingPortMode),
            "proxyMode": choice(\.proxyMode),
            "proxyScheme": choice(\.proxyScheme),
            "stopSeedingRatio": Entry(type: "number 0.1...100", get: { settings.stopSeedingRatio }, set: { text in
                guard let value = Double(text), value.isFinite, (0.1...100).contains(value) else { throw CLIError("invalid_argument", "Ratio must be from 0.1 to 100.") }
                settings.stopSeedingRatio = value
            }),
            "mediaMaximumResolution": Entry(type: "0 | 720 | 1080 | 2160", get: { settings.mediaMaximumResolution.rawValue }, set: { text in
                guard let raw = Int(text), let value = MediaMaximumResolution(rawValue: raw) else { throw CLIError("invalid_argument", "Unsupported media resolution.") }
                settings.mediaMaximumResolution = value
            }),
            "proxyHost": Entry(type: "host", get: { settings.proxyHost }, set: { value in
                guard !value.contains(":"), !value.contains("/"), !value.contains("@"), !value.contains(where: \.isWhitespace) else { throw CLIError("invalid_argument", "Supply a hostname without credentials, port, or path.") }
                settings.proxyHost = value
            }),
            "torrentBlocklistURL": Entry(type: "HTTP or HTTPS URL", get: { settings.torrentBlocklistURL }, set: { value in
                guard let url = URL(string: value), ["http", "https"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else { throw CLIError("invalid_argument", "Supply an HTTP or HTTPS URL without credentials.") }
                settings.torrentBlocklistURL = value
            }),
            "networkBindingSelection": Entry(type: "network target ID; empty means Automatic", get: { settings.networkBindingSelection.storageValue }, set: { value in
                settings.refreshNetworkBindingTargets()
                guard settings.networkBindingPickerTargets.contains(where: { $0.id == value }) else { throw CLIError("invalid_argument", "Unknown network target. Use settings get networkTargets.") }
                settings.networkBindingSelection = NetworkBindingSelection(storageValue: value)
            }),
            "downloadStagingPath": Entry(type: "absolute directory path; empty restores default", get: { settings.usesCustomDownloadStaging ? settings.downloadStagingPath : "" }, set: { value in
                if value.isEmpty { settings.useDefaultDownloadStaging(); return }
                try directory(\.downloadStagingPath).set(value)
                settings.enableCustomDownloadStaging()
            })
        ]
    }
    func run(_ args: [String]) throws -> Any {
        if args == ["get", "networkTargets"] {
            settings.refreshNetworkBindingTargets()
            return settings.networkBindingPickerTargets.map { ["id": $0.id, "name": $0.displayName] }
        }
        if args == ["list"] {
            return entries.keys.sorted().map { key in
                ["key": key, "type": entries[key]!.type, "value": entries[key]!.get()] as [String: Any]
            }
        }
        guard args.count == 2 && args[0] == "get" || args.count == 3 && args[0] == "set" else {
            throw CLIError("invalid_argument", "Use settings list, get KEY, or set KEY VALUE.")
        }
        guard let entry = entries[args[1]] else { throw CLIError("invalid_argument", "Unknown setting. Interactive system settings are available through harbor ui.") }
        if args[0] == "set" { try entry.set(args[2]) }
        return ["key": args[1], "value": entry.get()]
    }
}
