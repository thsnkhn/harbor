import SwiftUI

struct SettingsView: View {
    let settings: AppSettingsStore
    @ObservedObject var updater: AppUpdater

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("General") {
                LabeledContent("Default Destination") {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(settings.defaultDestinationPath)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)

                        HStack(spacing: 8) {
                            Button("Choose…") {
                                settings.chooseDefaultDestination()
                            }

                            Button("Reveal") {
                                settings.revealDefaultDestination()
                            }
                        }
                    }
                }

                Toggle("Start downloads immediately", isOn: $settings.startDownloadsAutomatically)
                Toggle("Send download notifications", isOn: $settings.notificationsEnabled)
            }

            Section("Bandwidth") {
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

                SpeedLimitRow(
                    title: "Global Speed Limit",
                    isEnabled: $settings.globalSpeedLimitEnabled,
                    kilobytesPerSecond: $settings.globalSpeedLimitKilobytesPerSecond
                )

                SpeedLimitRow(
                    title: "Per-Download Speed Limit",
                    isEnabled: $settings.perDownloadSpeedLimitEnabled,
                    kilobytesPerSecond: $settings.perDownloadSpeedLimitKilobytesPerSecond
                )
            }

            Section("Updates") {
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

                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .disabled(updater.canCheckForUpdates == false)
            }
        }
        .formStyle(.grouped)
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

#Preview("Settings") {
    SettingsView(
        settings: HarborPreviewFixtures.makeSettings(),
        updater: AppUpdater.preview()
    )
        .frame(width: 520, height: 520)
        .padding(20)
}
