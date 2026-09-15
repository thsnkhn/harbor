import AppKit
import Foundation
import Observation

enum TrafficMode: String, CaseIterable, Identifiable, Sendable {
    case unlimited
    case balanced
    case quiet
    case custom

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .unlimited: "infinity"
        case .balanced: "dial.medium"
        case .quiet: "leaf"
        case .custom: "slider.horizontal.3"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .unlimited:
            "Unlimited"
        case .balanced:
            "Balanced"
        case .quiet:
            "Quiet"
        case .custom:
            "Custom"
        }
    }

    nonisolated func applying(to customSettings: DownloadTransferSettings) -> DownloadTransferSettings {
        let limits: (download: Int64?, perDownload: Int64?, upload: Int64?, perUpload: Int64?)

        switch self {
        case .unlimited:
            limits = (nil, nil, nil, nil)
        case .balanced:
            limits = (25 * 1_024 * 1_024, 5 * 1_024 * 1_024, 5 * 1_024 * 1_024, 1_024 * 1_024)
        case .quiet:
            limits = (5 * 1_024 * 1_024, 1_024 * 1_024, 512 * 1_024, 256 * 1_024)
        case .custom:
            return customSettings
        }

        return DownloadTransferSettings(
            maxConcurrentDownloads: customSettings.maxConcurrentDownloads,
            globalSpeedLimitBytesPerSecond: limits.download,
            perDownloadSpeedLimitBytesPerSecond: limits.perDownload,
            globalUploadSpeedLimitBytesPerSecond: limits.upload,
            perDownloadUploadSpeedLimitBytesPerSecond: limits.perUpload,
            perDownloadConnectionCount: customSettings.perDownloadConnectionCount
        )
    }
}

struct DownloadTransferSettings: Equatable, Sendable {
    nonisolated static var `default`: DownloadTransferSettings {
        DownloadTransferSettings(
            maxConcurrentDownloads: 3,
            globalSpeedLimitBytesPerSecond: nil,
            perDownloadSpeedLimitBytesPerSecond: nil,
            globalUploadSpeedLimitBytesPerSecond: nil,
            perDownloadUploadSpeedLimitBytesPerSecond: nil,
            perDownloadConnectionCount: 4
        )
    }

    let maxConcurrentDownloads: Int
    let globalSpeedLimitBytesPerSecond: Int64?
    let perDownloadSpeedLimitBytesPerSecond: Int64?
    let globalUploadSpeedLimitBytesPerSecond: Int64?
    let perDownloadUploadSpeedLimitBytesPerSecond: Int64?
    let perDownloadConnectionCount: Int
}

@Observable
@MainActor
final class AppSettingsStore {
    private enum Keys {
        static let defaultDestinationPath = "defaultDestinationPath"
        static let torrentDestinationPath = "torrentDestinationPath"
        static let torrentWatchFolderPath = "torrentWatchFolderPath"
        static let torrentWatchFolderEnabled = "torrentWatchFolderEnabled"
        static let seedNewTorrents = "seedNewTorrents"
        static let stopSeedingAtRatioEnabled = "stopSeedingAtRatioEnabled"
        static let stopSeedingRatio = "stopSeedingRatio"
        static let maxConcurrentDownloads = "maxConcurrentDownloads"
        static let startDownloadsAutomatically = "startDownloadsAutomatically"
        static let notificationsEnabled = "notificationsEnabled"
        static let preventSleepWhileDownloading = "preventSleepWhileDownloading"
        static let trafficMode = "trafficMode"
        static let globalSpeedLimitEnabled = "globalSpeedLimitEnabled"
        static let globalSpeedLimitKilobytesPerSecond = "globalSpeedLimitKilobytesPerSecond"
        static let perDownloadSpeedLimitEnabled = "perDownloadSpeedLimitEnabled"
        static let perDownloadSpeedLimitKilobytesPerSecond = "perDownloadSpeedLimitKilobytesPerSecond"
        static let globalUploadSpeedLimitEnabled = "globalUploadSpeedLimitEnabled"
        static let globalUploadSpeedLimitKilobytesPerSecond = "globalUploadSpeedLimitKilobytesPerSecond"
        static let perDownloadUploadSpeedLimitEnabled = "perDownloadUploadSpeedLimitEnabled"
        static let perDownloadUploadSpeedLimitKilobytesPerSecond = "perDownloadUploadSpeedLimitKilobytesPerSecond"
        static let perDownloadConnectionCount = "perDownloadConnectionCount"
        static let networkBindingSelection = "torrentNetworkBindingSelection"
        static let networkBindingDisplayName = "torrentNetworkBindingDisplayName"
        static let proxyMode = "networkProxyMode"
        static let proxyScheme = "networkProxyScheme"
        static let proxyHost = "networkProxyHost"
        static let proxyPort = "networkProxyPort"
        static let torrentBlocklistEnabled = "torrentBlocklistEnabled"
        static let torrentBlocklistURL = "torrentBlocklistURL"
    }

    static let maxConcurrentDownloadsRange = 1 ... 16
    static let perDownloadConnectionCountRange = 1 ... 16
    static let speedLimitKilobytesRange = 1 ... 1_048_576
    static let seedingRatioRange = 0.1 ... 100.0

    private let userDefaults: UserDefaults
    @ObservationIgnored private let loginItemController: any LoginItemControlling
    @ObservationIgnored private let networkBindingCatalog: any NetworkBindingCataloging
    @ObservationIgnored var transferSettingsDidChange: ((DownloadTransferSettings) -> Void)?
    @ObservationIgnored var torrentAutomationSettingsDidChange: (() -> Void)?
    @ObservationIgnored var networkBindingDidChange: ((NetworkBindingSelection) -> Void)?
    @ObservationIgnored var proxySettingsDidChange: ((NetworkProxySettings) -> Void)?
    @ObservationIgnored var torrentBlocklistSettingsDidChange: (() -> Void)?
    @ObservationIgnored var torrentBlocklistRefreshRequested: (() -> Void)?

    var defaultDestinationPath: String {
        didSet {
            userDefaults.set(defaultDestinationPath, forKey: Keys.defaultDestinationPath)
        }
    }

    var torrentDestinationPath: String {
        didSet {
            userDefaults.set(torrentDestinationPath, forKey: Keys.torrentDestinationPath)
            notifyTorrentAutomationSettingsChanged()
        }
    }

    var torrentWatchFolderPath: String {
        didSet {
            userDefaults.set(torrentWatchFolderPath, forKey: Keys.torrentWatchFolderPath)
            notifyTorrentAutomationSettingsChanged()
        }
    }

    var torrentWatchFolderEnabled: Bool {
        didSet {
            userDefaults.set(torrentWatchFolderEnabled, forKey: Keys.torrentWatchFolderEnabled)
            notifyTorrentAutomationSettingsChanged()
        }
    }

    var seedNewTorrents: Bool {
        didSet {
            userDefaults.set(seedNewTorrents, forKey: Keys.seedNewTorrents)
            notifyTorrentAutomationSettingsChanged()
        }
    }

    var stopSeedingAtRatioEnabled: Bool {
        didSet {
            userDefaults.set(stopSeedingAtRatioEnabled, forKey: Keys.stopSeedingAtRatioEnabled)
            notifyTransferSettingsChanged()
        }
    }

    var stopSeedingRatio: Double {
        didSet {
            userDefaults.set(stopSeedingRatio, forKey: Keys.stopSeedingRatio)
            notifyTransferSettingsChanged()
        }
    }

    private(set) var torrentWatchFolderStatus: TorrentWatchFolderStatus = .stopped

    var networkBindingSelection: NetworkBindingSelection {
        didSet {
            userDefaults.set(
                networkBindingSelection.storageValue,
                forKey: Keys.networkBindingSelection
            )
            rememberNetworkBindingDisplayName()
            networkBindingDidChange?(networkBindingSelection)
        }
    }

    private(set) var availableNetworkBindingTargets: [NetworkBindingTarget] = [.any]
    private(set) var networkBindingStatus: NetworkBindingStatus = .unrestricted

    private var storedNetworkBindingDisplayName: String {
        didSet {
            userDefaults.set(
                storedNetworkBindingDisplayName,
                forKey: Keys.networkBindingDisplayName
            )
        }
    }

    var proxyMode: NetworkProxyMode {
        didSet {
            userDefaults.set(proxyMode.rawValue, forKey: Keys.proxyMode)
            notifyProxySettingsChanged()
        }
    }

    var proxyScheme: NetworkProxyScheme {
        didSet {
            userDefaults.set(proxyScheme.rawValue, forKey: Keys.proxyScheme)
            notifyProxySettingsChanged()
        }
    }

    var proxyHost: String {
        didSet {
            userDefaults.set(proxyHost, forKey: Keys.proxyHost)
            notifyProxySettingsChanged()
        }
    }

    var proxyPort: Int {
        didSet {
            userDefaults.set(proxyPort, forKey: Keys.proxyPort)
            notifyProxySettingsChanged()
        }
    }

    var torrentBlocklistEnabled: Bool {
        didSet {
            userDefaults.set(torrentBlocklistEnabled, forKey: Keys.torrentBlocklistEnabled)
            torrentBlocklistSettingsDidChange?()
        }
    }

    var torrentBlocklistURL: String {
        didSet {
            userDefaults.set(torrentBlocklistURL, forKey: Keys.torrentBlocklistURL)
        }
    }

    private(set) var torrentBlocklistLastUpdated: Date?
    private(set) var torrentBlocklistRuleCount = 0
    private(set) var torrentBlocklistErrorMessage: String?
    private(set) var isRefreshingTorrentBlocklist = false

    var maxConcurrentDownloads: Int {
        didSet {
            userDefaults.set(maxConcurrentDownloads, forKey: Keys.maxConcurrentDownloads)
            notifyTransferSettingsChanged()
        }
    }

    var startDownloadsAutomatically: Bool {
        didSet {
            userDefaults.set(startDownloadsAutomatically, forKey: Keys.startDownloadsAutomatically)
        }
    }

    var notificationsEnabled: Bool {
        didSet {
            userDefaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled)
        }
    }

    var preventSleepWhileDownloading: Bool {
        didSet {
            userDefaults.set(preventSleepWhileDownloading, forKey: Keys.preventSleepWhileDownloading)
        }
    }

    private(set) var startAtLogin = false
    private(set) var startAtLoginErrorMessage: String?

    var trafficMode: TrafficMode {
        didSet {
            userDefaults.set(trafficMode.rawValue, forKey: Keys.trafficMode)
            notifyTransferSettingsChanged()
        }
    }

    var globalSpeedLimitEnabled: Bool {
        didSet {
            userDefaults.set(globalSpeedLimitEnabled, forKey: Keys.globalSpeedLimitEnabled)
            if activateCustomTrafficMode() == false {
                notifyTransferSettingsChanged()
            }
        }
    }

    var globalSpeedLimitKilobytesPerSecond: Int {
        didSet {
            userDefaults.set(globalSpeedLimitKilobytesPerSecond, forKey: Keys.globalSpeedLimitKilobytesPerSecond)
            if activateCustomTrafficMode() == false {
                notifyTransferSettingsChanged()
            }
        }
    }

    var perDownloadSpeedLimitEnabled: Bool {
        didSet {
            userDefaults.set(perDownloadSpeedLimitEnabled, forKey: Keys.perDownloadSpeedLimitEnabled)
            if activateCustomTrafficMode() == false {
                notifyTransferSettingsChanged()
            }
        }
    }

    var perDownloadSpeedLimitKilobytesPerSecond: Int {
        didSet {
            userDefaults.set(perDownloadSpeedLimitKilobytesPerSecond, forKey: Keys.perDownloadSpeedLimitKilobytesPerSecond)
            if activateCustomTrafficMode() == false {
                notifyTransferSettingsChanged()
            }
        }
    }

    var globalUploadSpeedLimitEnabled: Bool {
        didSet {
            userDefaults.set(globalUploadSpeedLimitEnabled, forKey: Keys.globalUploadSpeedLimitEnabled)
            if activateCustomTrafficMode() == false {
                notifyTransferSettingsChanged()
            }
        }
    }

    var globalUploadSpeedLimitKilobytesPerSecond: Int {
        didSet {
            userDefaults.set(
                globalUploadSpeedLimitKilobytesPerSecond,
                forKey: Keys.globalUploadSpeedLimitKilobytesPerSecond
            )
            if activateCustomTrafficMode() == false {
                notifyTransferSettingsChanged()
            }
        }
    }

    var perDownloadUploadSpeedLimitEnabled: Bool {
        didSet {
            userDefaults.set(perDownloadUploadSpeedLimitEnabled, forKey: Keys.perDownloadUploadSpeedLimitEnabled)
            if activateCustomTrafficMode() == false {
                notifyTransferSettingsChanged()
            }
        }
    }

    var perDownloadUploadSpeedLimitKilobytesPerSecond: Int {
        didSet {
            userDefaults.set(
                perDownloadUploadSpeedLimitKilobytesPerSecond,
                forKey: Keys.perDownloadUploadSpeedLimitKilobytesPerSecond
            )
            if activateCustomTrafficMode() == false {
                notifyTransferSettingsChanged()
            }
        }
    }

    var perDownloadConnectionCount: Int {
        didSet {
            userDefaults.set(perDownloadConnectionCount, forKey: Keys.perDownloadConnectionCount)
            notifyTransferSettingsChanged()
        }
    }

    init(
        userDefaults: UserDefaults = .standard,
        loginItemController: (any LoginItemControlling)? = nil,
        networkBindingCatalog: (any NetworkBindingCataloging)? = nil
    ) {
        self.userDefaults = userDefaults
        let resolvedLoginItemController = loginItemController ?? SystemLoginItemController()
        self.loginItemController = resolvedLoginItemController
        self.networkBindingCatalog = networkBindingCatalog ?? SystemNetworkBindingCatalog()

        let defaultDownloadsPath = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first?.path ?? NSHomeDirectory()

        let regularDestinationPath = userDefaults.string(forKey: Keys.defaultDestinationPath) ?? defaultDownloadsPath
        self.defaultDestinationPath = regularDestinationPath
        self.torrentDestinationPath = userDefaults.string(forKey: Keys.torrentDestinationPath)
            ?? URL(fileURLWithPath: regularDestinationPath, isDirectory: true)
                .appendingPathComponent("Torrents", isDirectory: true)
                .path
        self.torrentWatchFolderPath = userDefaults.string(forKey: Keys.torrentWatchFolderPath)
            ?? defaultDownloadsPath
        self.torrentWatchFolderEnabled = userDefaults.bool(forKey: Keys.torrentWatchFolderEnabled)
        if userDefaults.object(forKey: Keys.seedNewTorrents) == nil {
            self.seedNewTorrents = true
        } else {
            self.seedNewTorrents = userDefaults.bool(forKey: Keys.seedNewTorrents)
        }
        self.stopSeedingAtRatioEnabled = userDefaults.bool(forKey: Keys.stopSeedingAtRatioEnabled)
        let storedSeedingRatio = userDefaults.double(forKey: Keys.stopSeedingRatio)
        self.stopSeedingRatio = Self.clampedSeedingRatio(storedSeedingRatio == 0 ? 2.0 : storedSeedingRatio)

        let storedConcurrency = userDefaults.integer(forKey: Keys.maxConcurrentDownloads)
        self.maxConcurrentDownloads = Self.clamped(
            storedConcurrency == 0 ? 3 : storedConcurrency,
            to: Self.maxConcurrentDownloadsRange
        )

        if userDefaults.object(forKey: Keys.startDownloadsAutomatically) == nil {
            self.startDownloadsAutomatically = true
        } else {
            self.startDownloadsAutomatically = userDefaults.bool(forKey: Keys.startDownloadsAutomatically)
        }

        if userDefaults.object(forKey: Keys.notificationsEnabled) == nil {
            self.notificationsEnabled = true
        } else {
            self.notificationsEnabled = userDefaults.bool(forKey: Keys.notificationsEnabled)
        }
        self.preventSleepWhileDownloading = userDefaults.bool(forKey: Keys.preventSleepWhileDownloading)
        self.startAtLogin = resolvedLoginItemController.status == .enabled

        if let storedTrafficMode = userDefaults.string(forKey: Keys.trafficMode)
            .flatMap(TrafficMode.init(rawValue:)) {
            self.trafficMode = storedTrafficMode
        } else {
            let hasLegacyLimits = userDefaults.bool(forKey: Keys.globalSpeedLimitEnabled)
                || userDefaults.bool(forKey: Keys.perDownloadSpeedLimitEnabled)
                || userDefaults.bool(forKey: Keys.globalUploadSpeedLimitEnabled)
                || userDefaults.bool(forKey: Keys.perDownloadUploadSpeedLimitEnabled)
            self.trafficMode = hasLegacyLimits ? .custom : .unlimited
        }

        self.globalSpeedLimitEnabled = userDefaults.bool(forKey: Keys.globalSpeedLimitEnabled)
        self.globalSpeedLimitKilobytesPerSecond = Self.clamped(
            userDefaults.integer(forKey: Keys.globalSpeedLimitKilobytesPerSecond) == 0
                ? 25 * 1_024
                : userDefaults.integer(forKey: Keys.globalSpeedLimitKilobytesPerSecond),
            to: Self.speedLimitKilobytesRange
        )

        self.perDownloadSpeedLimitEnabled = userDefaults.bool(forKey: Keys.perDownloadSpeedLimitEnabled)
        self.perDownloadSpeedLimitKilobytesPerSecond = Self.clamped(
            userDefaults.integer(forKey: Keys.perDownloadSpeedLimitKilobytesPerSecond) == 0
                ? 5 * 1_024
                : userDefaults.integer(forKey: Keys.perDownloadSpeedLimitKilobytesPerSecond),
            to: Self.speedLimitKilobytesRange
        )

        self.globalUploadSpeedLimitEnabled = userDefaults.bool(forKey: Keys.globalUploadSpeedLimitEnabled)
        self.globalUploadSpeedLimitKilobytesPerSecond = Self.clamped(
            userDefaults.integer(forKey: Keys.globalUploadSpeedLimitKilobytesPerSecond) == 0
                ? 5 * 1_024
                : userDefaults.integer(forKey: Keys.globalUploadSpeedLimitKilobytesPerSecond),
            to: Self.speedLimitKilobytesRange
        )

        self.perDownloadUploadSpeedLimitEnabled = userDefaults.bool(
            forKey: Keys.perDownloadUploadSpeedLimitEnabled
        )
        self.perDownloadUploadSpeedLimitKilobytesPerSecond = Self.clamped(
            userDefaults.integer(forKey: Keys.perDownloadUploadSpeedLimitKilobytesPerSecond) == 0
                ? 1_024
                : userDefaults.integer(forKey: Keys.perDownloadUploadSpeedLimitKilobytesPerSecond),
            to: Self.speedLimitKilobytesRange
        )

        let storedConnectionCount = userDefaults.integer(forKey: Keys.perDownloadConnectionCount)
        self.perDownloadConnectionCount = Self.clamped(
            storedConnectionCount == 0 ? 4 : storedConnectionCount,
            to: Self.perDownloadConnectionCountRange
        )

        let storedSelection = NetworkBindingSelection(
            storageValue: userDefaults.string(forKey: Keys.networkBindingSelection) ?? ""
        )
        self.networkBindingSelection = storedSelection
        self.storedNetworkBindingDisplayName = userDefaults
            .string(forKey: Keys.networkBindingDisplayName)
            ?? Self.fallbackDisplayName(for: storedSelection)

        self.proxyMode = userDefaults.string(forKey: Keys.proxyMode)
            .flatMap(NetworkProxyMode.init(rawValue:))
            ?? .system
        self.proxyScheme = userDefaults.string(forKey: Keys.proxyScheme)
            .flatMap(NetworkProxyScheme.init(rawValue:))
            ?? .http
        self.proxyHost = userDefaults.string(forKey: Keys.proxyHost) ?? ""
        let storedProxyPort = userDefaults.integer(forKey: Keys.proxyPort)
        self.proxyPort = storedProxyPort == 0 ? 8_080 : storedProxyPort

        self.torrentBlocklistEnabled = userDefaults.bool(forKey: Keys.torrentBlocklistEnabled)
        self.torrentBlocklistURL = userDefaults.string(forKey: Keys.torrentBlocklistURL) ?? ""
        self.torrentBlocklistLastUpdated = nil
        self.torrentBlocklistErrorMessage = nil

        refreshNetworkBindingTargets()
    }

    func refreshStartAtLoginStatus() {
        startAtLogin = loginItemController.status == .enabled
    }

    func setStartAtLogin(_ isEnabled: Bool) {
        startAtLoginErrorMessage = nil

        do {
            try loginItemController.setEnabled(isEnabled)
            refreshStartAtLoginStatus()

            guard startAtLogin == isEnabled else {
                startAtLoginErrorMessage = loginItemStatusMessage(loginItemController.status)
                return
            }
        } catch {
            refreshStartAtLoginStatus()
            startAtLoginErrorMessage = error.localizedDescription
        }
    }

    var defaultDestinationURL: URL {
        URL(fileURLWithPath: defaultDestinationPath, isDirectory: true)
    }

    var torrentDestinationURL: URL {
        URL(fileURLWithPath: torrentDestinationPath, isDirectory: true)
    }

    var torrentWatchFolderURL: URL {
        URL(fileURLWithPath: torrentWatchFolderPath, isDirectory: true)
    }

    var transferSettings: DownloadTransferSettings {
        let customSettings = DownloadTransferSettings(
            maxConcurrentDownloads: Self.clamped(maxConcurrentDownloads, to: Self.maxConcurrentDownloadsRange),
            globalSpeedLimitBytesPerSecond: speedLimitBytesPerSecond(
                isEnabled: globalSpeedLimitEnabled,
                kilobytesPerSecond: globalSpeedLimitKilobytesPerSecond
            ),
            perDownloadSpeedLimitBytesPerSecond: speedLimitBytesPerSecond(
                isEnabled: perDownloadSpeedLimitEnabled,
                kilobytesPerSecond: perDownloadSpeedLimitKilobytesPerSecond
            ),
            globalUploadSpeedLimitBytesPerSecond: speedLimitBytesPerSecond(
                isEnabled: globalUploadSpeedLimitEnabled,
                kilobytesPerSecond: globalUploadSpeedLimitKilobytesPerSecond
            ),
            perDownloadUploadSpeedLimitBytesPerSecond: speedLimitBytesPerSecond(
                isEnabled: perDownloadUploadSpeedLimitEnabled,
                kilobytesPerSecond: perDownloadUploadSpeedLimitKilobytesPerSecond
            ),
            perDownloadConnectionCount: Self.clamped(
                perDownloadConnectionCount,
                to: Self.perDownloadConnectionCountRange
            )
        )

        return trafficMode.applying(to: customSettings)
    }

    var proxySettings: NetworkProxySettings {
        NetworkProxySettings(
            mode: proxyMode,
            scheme: proxyScheme,
            host: proxyHost,
            port: proxyPort
        )
    }

    static func clampedSpeedLimitKilobytes(_ value: Int) -> Int {
        clamped(value, to: speedLimitKilobytesRange)
    }

    static func clampedSeedingRatio(_ value: Double) -> Double {
        guard value.isFinite else {
            return 2.0
        }

        return min(max(value, seedingRatioRange.lowerBound), seedingRatioRange.upperBound)
    }

    var seedingRatioLimit: Double? {
        stopSeedingAtRatioEnabled ? Self.clampedSeedingRatio(stopSeedingRatio) : nil
    }

    func chooseDefaultDestination() {
        guard let folder = FolderSelectionService.chooseFolder(startingAt: defaultDestinationURL) else {
            return
        }

        defaultDestinationPath = folder.path
    }

    func revealDefaultDestination() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: defaultDestinationPath)
    }

    func chooseTorrentDestination() {
        guard let folder = FolderSelectionService.chooseFolder(startingAt: torrentDestinationURL) else {
            return
        }

        torrentDestinationPath = folder.path
    }

    func revealTorrentDestination() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: torrentDestinationPath)
    }

    func chooseTorrentWatchFolder() {
        guard let folder = FolderSelectionService.chooseFolder(startingAt: torrentWatchFolderURL) else {
            return
        }

        torrentWatchFolderPath = folder.path
    }

    func revealTorrentWatchFolder() {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: torrentWatchFolderPath)
    }

    func updateTorrentWatchFolderStatus(_ status: TorrentWatchFolderStatus) {
        torrentWatchFolderStatus = status
    }

    func updateNetworkBindingStatus(_ status: NetworkBindingStatus) {
        networkBindingStatus = status
    }

    func requestTorrentBlocklistRefresh() {
        torrentBlocklistRefreshRequested?()
    }

    func setTorrentBlocklistRefreshing(_ isRefreshing: Bool) {
        isRefreshingTorrentBlocklist = isRefreshing
    }

    func updateTorrentBlocklistStatus(_ status: TorrentBlocklistStatus) {
        torrentBlocklistRuleCount = status.ruleCount
        torrentBlocklistLastUpdated = status.lastUpdated
        torrentBlocklistErrorMessage = nil
    }

    func updateTorrentBlocklistError(_ error: Error) {
        torrentBlocklistErrorMessage = error.localizedDescription
    }

    func markTorrentBlocklistDisabled() {
        torrentBlocklistErrorMessage = nil
        torrentBlocklistRuleCount = 0
    }

    func refreshNetworkBindingTargets() {
        availableNetworkBindingTargets = networkBindingCatalog.availableTargets()
        rememberNetworkBindingDisplayName()
    }

    /// The name to show for the current selection, falling back to the name it
    /// carried the last time it existed.
    var networkBindingDisplayName: String {
        availableNetworkBindingTargets
            .first { $0.selection == networkBindingSelection }?
            .displayName
            ?? storedNetworkBindingDisplayName
    }

    /// Keeps a selection that has disappeared, such as a removed VPN service,
    /// visible in the picker instead of silently reverting to "Automatic".
    var networkBindingPickerTargets: [NetworkBindingTarget] {
        var targets = availableNetworkBindingTargets
        guard targets.contains(where: { $0.selection == networkBindingSelection }) == false else {
            return targets
        }

        targets.append(
            NetworkBindingTarget(
                selection: networkBindingSelection,
                displayName: String(
                    format: String(
                        localized: "network.binding.missingTarget",
                        defaultValue: "%@ (unavailable)",
                        comment: "Picker label for a stored network selection that no longer exists."
                    ),
                    networkBindingDisplayName
                ),
                kind: .service
            )
        )
        return targets
    }

    private func rememberNetworkBindingDisplayName() {
        guard let displayName = availableNetworkBindingTargets
            .first(where: { $0.selection == networkBindingSelection })?
            .displayName else {
            return
        }

        storedNetworkBindingDisplayName = displayName
    }

    private static func fallbackDisplayName(for selection: NetworkBindingSelection) -> String {
        switch selection {
        case .any:
            NetworkBindingTarget.any.displayName
        case let .interface(name):
            name
        case .service:
            String(
                localized: "network.binding.unknownService",
                defaultValue: "Unknown network",
                comment: "Placeholder for a stored VPN or network service Harbor can no longer find."
            )
        }
    }

    private func notifyTransferSettingsChanged() {
        transferSettingsDidChange?(transferSettings)
    }

    @discardableResult
    private func activateCustomTrafficMode() -> Bool {
        guard trafficMode != .custom else {
            return false
        }

        trafficMode = .custom
        return true
    }

    private func loginItemStatusMessage(_ status: LoginItemStatus) -> String {
        switch status {
        case .requiresApproval:
            String(
                localized: "Allow Harbor in System Settings > General > Login Items, then return here."
            )
        case .unavailable:
            String(localized: "Start at Login is not available for this copy of Harbor.")
        case .disabled, .enabled:
            String(localized: "Harbor could not update the Start at Login setting.")
        }
    }

    private func notifyTorrentAutomationSettingsChanged() {
        torrentAutomationSettingsDidChange?()
    }

    private func notifyProxySettingsChanged() {
        proxySettingsDidChange?(proxySettings)
    }

    private func speedLimitBytesPerSecond(
        isEnabled: Bool,
        kilobytesPerSecond: Int
    ) -> Int64? {
        guard isEnabled else {
            return nil
        }

        return Int64(Self.clampedSpeedLimitKilobytes(kilobytesPerSecond)) * 1_024
    }

    private static func clamped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
