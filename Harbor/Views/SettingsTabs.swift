import SwiftUI

struct GeneralSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
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
        .onAppear {
            settings.refreshStartAtLoginStatus()
        }
    }
}

struct DownloadsSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
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

            Section("Staging") {
                DestinationFolderRow(
                    title: "In-Progress Files",
                    path: settings.downloadStagingRootURL.path,
                    choose: settings.chooseDownloadStaging,
                    reveal: settings.revealDownloadStaging
                )

                if settings.usesCustomDownloadStaging {
                    Button("Use Default Location", action: settings.useDefaultDownloadStaging)
                }

                Text("Harbor writes downloads here before moving them to a save location. A folder on the same volume as the save location avoids copying every finished file between volumes. Restart Harbor to apply a change.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct TorrentsSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
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
                Toggle("Seed new torrents after downloading", isOn: $settings.seedNewTorrents)

                LabeledContent("Stop at Share Ratio") {
                    HStack(spacing: 8) {
                        Toggle("Stop at Share Ratio", isOn: $settings.stopSeedingAtRatioEnabled)
                            .labelsHidden()

                        TextField(
                            "Ratio",
                            value: $settings.stopSeedingRatio,
                            format: .number.precision(.fractionLength(1...2))
                        )
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
        }
        .formStyle(.grouped)
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
