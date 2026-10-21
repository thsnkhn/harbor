import SwiftUI

struct GeneralSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .accessibilityIdentifier("settings.appearance")
            }
            Section("Behavior") {
                Toggle("Start downloads immediately", isOn: $settings.startDownloadsAutomatically)
                Toggle("Send download notifications", isOn: $settings.notificationsEnabled)
                Toggle(
                    "Start at Login",
                    isOn: Binding(
                        get: { settings.startAtLogin },
                        set: { settings.setStartAtLogin($0) }
                    )
                )
                Toggle("Prevent sleep while downloading", isOn: $settings.preventSleepWhileDownloading)

                if let startAtLoginErrorMessage = settings.startAtLoginErrorMessage {
                    Text(startAtLoginErrorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .harborSurface()
        .onAppear {
            settings.refreshStartAtLoginStatus()
        }
    }
}

struct DownloadsSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Save Locations") {
                DestinationFolderRow(
                    title: "Regular Downloads",
                    path: settings.defaultDestinationPath,
                    choose: settings.chooseDefaultDestination,
                    reveal: settings.revealDefaultDestination
                )

                DestinationFolderRow(
                    title: "Torrent Downloads",
                    path: settings.torrentDestinationPath,
                    choose: settings.chooseTorrentDestination,
                    reveal: settings.revealTorrentDestination
                )
            }

            Section("Download List") {
                Toggle("Remove completed downloads from the list", isOn: $settings.removeCompletedDownloadsAutomatically)
                Text("Removes entries when downloads finish. Files stay in their save folder. Torrents stay listed until seeding stops. Source .torrent files in the watch folder move to Trash to prevent another import.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Staging") {
                Toggle(
                    "Use custom staging folder",
                    isOn: Binding(
                        get: { settings.usesCustomDownloadStaging },
                        set: { enabled in
                            if enabled {
                                settings.enableCustomDownloadStaging()
                            } else {
                                settings.useDefaultDownloadStaging()
                            }
                        }
                    )
                )

                if settings.usesCustomDownloadStaging {
                    DestinationFolderRow(
                        title: "In-Progress Files",
                        path: settings.downloadStagingRootURL.path,
                        choose: settings.chooseDownloadStaging,
                        reveal: settings.revealDownloadStaging
                    )

                    Text("A folder on the save volume avoids copying finished downloads between volumes. Restart Harbor to apply changes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Proxy") {
                Picker("Mode", selection: $settings.proxyMode) {
                    ForEach(NetworkProxyMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if settings.proxyMode == .manual {
                    Picker("Protocol", selection: $settings.proxyScheme) {
                        ForEach(NetworkProxyScheme.allCases) { scheme in
                            Text(scheme.title).tag(scheme)
                        }
                    }

                    TextField("Host", text: $settings.proxyHost)
                        .textFieldStyle(.roundedBorder)

                    TextField("Port", value: $settings.proxyPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()

                    if let error = settings.proxySettings.validationError {
                        Text(error.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Text(proxyExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .harborSurface()
    }

    private var proxyExplanation: LocalizedStringResource {
        switch settings.proxyMode {
        case .none:
            "Harbor connects directly for regular and torrent downloads."
        case .system:
            "Regular downloads use the macOS proxy configuration. Torrents use its static HTTP or SOCKS proxy when one is configured."
        case .manual:
            "The manual proxy applies to new regular and torrent connections. Proxy authentication is not supported yet."
        }
    }
}

struct TorrentsSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            TorrentDefaultAppsSection()

            Section("Automation") {
                Toggle("Watch a folder for torrent files", isOn: $settings.torrentWatchFolderEnabled)

                if settings.torrentWatchFolderEnabled {
                    DestinationFolderRow(
                        title: "Watch Folder",
                        path: settings.torrentWatchFolderPath,
                        choose: settings.chooseTorrentWatchFolder,
                        reveal: settings.revealTorrentWatchFolder
                    )

                    TorrentWatchStatusRow(status: settings.torrentWatchFolderStatus)
                }
            }

            Section("Seeding") {
                Toggle("Seed torrents", isOn: $settings.seedTorrents)
                Text("When off, torrents do not upload file data, including while downloading. Network messages are still required.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if settings.seedTorrents {
                    Toggle("Continue seeding after download", isOn: $settings.seedNewTorrents)
                    Text("Applies to new torrents.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if settings.seedNewTorrents {
                        LabeledContent("Stop at Share Ratio") {
                            HStack(spacing: 8) {
                                Toggle("Stop at Share Ratio", isOn: $settings.stopSeedingAtRatioEnabled)
                                    .labelsHidden()

                                TextField(
                                    "Ratio",
                                    value: $settings.stopSeedingRatio,
                                    format: .number.precision(.fractionLength(1...2))
                                )
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                                .frame(width: 72)
                                .disabled(!settings.stopSeedingAtRatioEnabled)

                                Text("ratio")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Text("Stops seeding after Harbor uploads the selected multiple of the torrent size.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Network") {
                Picker("Network Interface", selection: $settings.networkBindingSelection) {
                    Label(
                        NetworkBindingTarget.any.displayName,
                        systemImage: NetworkBindingTarget.any.symbolName
                    )
                    .tag(NetworkBindingSelection.any)

                    if serviceTargets.isEmpty == false {
                        Section("Services") {
                            ForEach(serviceTargets) { target in
                                Label(target.displayName, systemImage: target.symbolName)
                                    .tag(target.selection)
                            }
                        }
                    }

                    if interfaceTargets.isEmpty == false {
                        Section("Interfaces") {
                            ForEach(interfaceTargets) { target in
                                Label(target.displayName, systemImage: target.symbolName)
                                    .tag(target.selection)
                            }
                        }
                    }
                }
                .accessibilityIdentifier(HarborAccessibility.settingsNetworkInterfacePicker)

                if settings.networkBindingSelection != .any {
                    NetworkBindingStatusRow(status: settings.networkBindingStatus)
                }

                Text("Torrent traffic uses only the selected interface. While that interface is unavailable, Harbor pauses every torrent and resumes it once the interface returns. Regular and media downloads are not affected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            IncomingPortSection(settings: settings)

            Section("Peer Blocklist") {
                Toggle("Enable IP blocklist", isOn: $settings.torrentBlocklistEnabled)

                if settings.torrentBlocklistEnabled {
                    TextField("Blocklist URL", text: $settings.torrentBlocklistURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            settings.requestTorrentBlocklistRefresh()
                        }

                    LabeledContent("Status") {
                        if settings.isRefreshingTorrentBlocklist {
                            ProgressView()
                                .controlSize(.small)
                        } else if let lastUpdated = settings.torrentBlocklistLastUpdated {
                            Text(
                                "\(settings.torrentBlocklistRuleCount) rules • \(lastUpdated.formatted(date: .abbreviated, time: .shortened))"
                            )
                            .foregroundStyle(.secondary)
                        } else {
                            Text("No valid blocklist cached")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Button("Refresh Blocklist", systemImage: "arrow.clockwise") {
                        settings.requestTorrentBlocklistRefresh()
                    }
                    .disabled(
                        settings.torrentBlocklistURL
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                            || settings.isRefreshingTorrentBlocklist
                    )

                    if let errorMessage = settings.torrentBlocklistErrorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Text("Aria2 Next accepts one IPv4 address, IPv6 address, or CIDR range per line. The last valid cached list remains active when a refresh fails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .harborSurface()
        .onAppear {
            settings.refreshNetworkBindingTargets()
        }
        .onChange(of: settings.stopSeedingRatio) { _, value in
            let clampedValue = AppSettingsStore.clampedSeedingRatio(value)
            if clampedValue != value {
                settings.stopSeedingRatio = clampedValue
            }
        }
    }

    private var serviceTargets: [NetworkBindingTarget] {
        settings.networkBindingPickerTargets.filter { $0.kind == .service }
    }

    private var interfaceTargets: [NetworkBindingTarget] {
        settings.networkBindingPickerTargets.filter { $0.kind == .interface }
    }
}

struct BandwidthSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Traffic Mode") {
                Picker("Mode", selection: $settings.trafficMode) {
                    ForEach(TrafficMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Text("Unlimited has no limits. Balanced uses 25 MB/s down and 5 MB/s up. Quiet uses 5 MB/s down and 512 KB/s up. Custom uses the limits below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom Limits") {
                SpeedLimitRow(
                    title: "Global Download Limit",
                    isEnabled: $settings.globalSpeedLimitEnabled,
                    kilobytesPerSecond: $settings.globalSpeedLimitKilobytesPerSecond
                )

                if HarborFeatureFlags.perDownloadTransferLimits {
                    SpeedLimitRow(
                        title: "Default Download Limit",
                        isEnabled: $settings.perDownloadSpeedLimitEnabled,
                        kilobytesPerSecond: $settings.perDownloadSpeedLimitKilobytesPerSecond
                    )
                }

                SpeedLimitRow(
                    title: "Global Upload Limit",
                    isEnabled: $settings.globalUploadSpeedLimitEnabled,
                    kilobytesPerSecond: $settings.globalUploadSpeedLimitKilobytesPerSecond
                )

                if HarborFeatureFlags.perDownloadTransferLimits {
                    SpeedLimitRow(
                        title: "Default Torrent Upload Limit",
                        isEnabled: $settings.perDownloadUploadSpeedLimitEnabled,
                        kilobytesPerSecond: $settings.perDownloadUploadSpeedLimitKilobytesPerSecond
                    )
                }
            }

            Section("Connections") {
                Stepper(
                    value: $settings.maxConcurrentDownloads,
                    in: AppSettingsStore.maxConcurrentDownloadsRange
                ) {
                    LabeledContent("Max Active Downloads", value: "\(settings.maxConcurrentDownloads)")
                }

                Stepper(
                    value: $settings.perDownloadConnectionCount,
                    in: AppSettingsStore.perDownloadConnectionCountRange
                ) {
                    LabeledContent("Connections per Download", value: "\(settings.perDownloadConnectionCount)")
                }
            }
        }
        .formStyle(.grouped)
        .harborSurface()
    }
}

struct UpdatesSettingsTab: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Form {
            Section("Software Update") {
                LabeledContent("Current Version") {
                    Text(updater.currentVersionLabel)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    "Automatically check for updates",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.setAutomaticallyChecksForUpdates($0) }
                    )
                )

                LabeledContent {
                    Button("Check for Updates…") {
                        updater.checkForUpdates()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.canCheckForUpdates == false)
                } label: {
                    Text("Updates")
                }
            }
        }
        .formStyle(.grouped)
        .harborSurface()
    }
}

private struct DestinationFolderRow: View {
    let title: LocalizedStringResource
    let path: String
    let choose: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Text(title)
                .fixedSize()

            HStack(spacing: 8) {
                Text(path)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                    .textSelection(.enabled)
                    .help(path)

                Button("Choose…", action: choose)
                    .fixedSize()
                Button("Reveal", action: reveal)
                    .fixedSize()
            }
        }
    }
}

private struct TorrentWatchStatusRow: View {
    let status: TorrentWatchFolderStatus

    var body: some View {
        LabeledContent("Status") {
            Label(message, systemImage: symbolName)
                .foregroundStyle(foregroundStyle)
        }
    }

    private var message: LocalizedStringResource {
        switch status {
        case .stopped:
            "Waiting for the watcher to start"
        case .watching:
            "Watching for new torrent files"
        case .unavailable:
            "Folder unavailable; Harbor will retry"
        }
    }

    private var symbolName: String {
        switch status {
        case .stopped:
            "clock"
        case .watching:
            "eye"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }

    private var foregroundStyle: Color {
        switch status {
        case .stopped:
            .secondary
        case .watching:
            .green
        case .unavailable:
            .orange
        }
    }
}

private struct IncomingPortSection: View {
    let settings: AppSettingsStore
    @State private var portDraft = 0
    @FocusState private var isPortFieldFocused: Bool

    var body: some View {
        @Bindable var settings = settings

        Section("Incoming Port") {
            Picker("Incoming Port", selection: $settings.torrentIncomingPortMode) {
                Text("Default").tag(TorrentIncomingPortMode.off)
                Text("Manual").tag(TorrentIncomingPortMode.manual)
                Text("Automatic (NAT-PMP)").tag(TorrentIncomingPortMode.automatic)
            }
            .accessibilityIdentifier(HarborAccessibility.settingsIncomingPortPicker)

            switch settings.torrentIncomingPortMode {
            case .off:
                Text("aria2 picks a port between 6881 and 6999.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .manual:
                // Commits only when editing ends: every committed port
                // restarts the torrent engine.
                LabeledContent("Port") {
                    TextField("Port", value: $portDraft, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 80)
                        .focused($isPortFieldFocused)
                        .onSubmit(commitPort)
                }
                Text("Forward this port for TCP and UDP on your router. Changing it restarts the torrent engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .automatic:
                if settings.networkBindingSelection == .any {
                    Label("Select your VPN as the network interface above.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    IncomingPortStatusRow(status: settings.incomingPortStatus)
                }
                Text("Requests the forwarded port from your VPN and renews it while Harbor runs. For ProtonVPN, connect to a P2P server with port forwarding turned on. A new port restarts the torrent engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { portDraft = settings.torrentIncomingPort }
        .onChange(of: isPortFieldFocused) { _, isFocused in
            if isFocused == false {
                commitPort()
            }
        }
    }

    private func commitPort() {
        let port = AppSettingsStore.clampedIncomingPort(portDraft)
        portDraft = port
        if settings.torrentIncomingPort != port {
            settings.torrentIncomingPort = port
        }
    }
}

private struct IncomingPortStatusRow: View {
    let status: IncomingPortStatus

    var body: some View {
        LabeledContent("Status") {
            switch status {
            case .waiting:
                Label("Waiting for the VPN", systemImage: "circle")
                    .foregroundStyle(.secondary)
            case let .mapped(port):
                Label(
                    String(format: String(localized: "Forwarded port %@"), String(port)),
                    systemImage: "checkmark.shield"
                )
                .foregroundStyle(.green)
            case .failed:
                Label("The VPN did not assign a port", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }
}

private struct NetworkBindingStatusRow: View {
    let status: NetworkBindingStatus

    var body: some View {
        LabeledContent("Status") {
            Label(message, systemImage: symbolName)
                .foregroundStyle(foregroundStyle)
        }
    }

    private var message: String {
        switch status {
        case .unrestricted:
            String(localized: "No interface restriction")
        case let .bound(_, binding):
            if let ipv4Address = binding.ipv4Address {
                String(
                    format: String(localized: "Bound to %1$@ (%2$@)"),
                    binding.interfaceName,
                    ipv4Address
                )
            } else {
                String(format: String(localized: "Bound to %@"), binding.interfaceName)
            }
        case let .unavailable(displayName):
            String(
                format: String(localized: "%@ is unavailable; torrents are paused"),
                displayName
            )
        }
    }

    private var symbolName: String {
        switch status {
        case .unrestricted:
            "circle"
        case .bound:
            "checkmark.shield"
        case .unavailable:
            "exclamationmark.triangle"
        }
    }

    private var foregroundStyle: Color {
        switch status {
        case .unrestricted:
            .secondary
        case .bound:
            .green
        case .unavailable:
            .orange
        }
    }
}

private struct SpeedLimitRow: View {
    let title: LocalizedStringResource
    @Binding var isEnabled: Bool
    @Binding var kilobytesPerSecond: Int

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                Toggle("Limit", isOn: $isEnabled)
                    .labelsHidden()

                TextField(
                    "Speed",
                    value: $kilobytesPerSecond,
                    format: .number
                )
                .monospacedDigit()
                .frame(width: 110)
                .disabled(isEnabled == false)

                Text("KB/s")
                    .foregroundStyle(.secondary)
            }
        } label: {
            Text(title)
                .lineLimit(1)
        }
        .onChange(of: kilobytesPerSecond) { _, newValue in
            let clampedValue = AppSettingsStore.clampedSpeedLimitKilobytes(newValue)
            if clampedValue != newValue {
                kilobytesPerSecond = clampedValue
            }
        }
    }
}
