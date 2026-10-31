import SwiftUI

struct BandwidthSettingsTab: View {
    let settings: AppSettingsStore

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Speed Limits") {
                Picker("Preset", selection: $settings.trafficMode) {
                    ForEach(TrafficMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                if settings.trafficMode != .custom {
                    LabeledContent("Download", value: speedLabel(settings.transferSettings.globalSpeedLimitBytesPerSecond))
                    LabeledContent("Upload", value: speedLabel(settings.transferSettings.globalUploadSpeedLimitBytesPerSecond))
                }
            }

            if settings.trafficMode == .custom {
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
            }

            Section("Connections") {
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
    private func speedLabel(_ bytesPerSecond: Int64?) -> String {
        guard let bytesPerSecond else { return String(localized: "Unlimited") }
        return ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .binary) + "/s"
    }
}
