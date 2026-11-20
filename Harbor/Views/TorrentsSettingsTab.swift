import SwiftUI

struct TorrentsSettingsTab: View {
    let settings: AppSettingsStore

    @State private var editingTrackerList: TorrentTrackerListKind?

    var body: some View {
        @Bindable var settings = settings

        Form {
            TorrentDefaultAppsSection()

            Section("Watch Folder") {
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
                Toggle("Allow torrent uploads", isOn: $settings.seedTorrents)
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

            Section("Trackers") {
                ForEach(TorrentTrackerListKind.allCases) { kind in
                    LabeledContent {
                        HStack(spacing: 8) {
                            Text(trackerCountText(settings.torrentTrackers(kind).count))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()

                            Button("Edit…") {
                                editingTrackerList = kind
                            }
                            .popover(
                                isPresented: Binding(
                                    get: { editingTrackerList == kind },
                                    set: { if !$0 { editingTrackerList = nil } }
                                ),
                                arrowEdge: .trailing
                            ) {
                                TorrentTrackerListEditor(kind: kind, settings: settings)
                            }
                        }
                    } label: {
                        Text(kind.title)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .harborSurface()
        .onChange(of: settings.stopSeedingRatio) { _, value in
            let clampedValue = AppSettingsStore.clampedSeedingRatio(value)
            if clampedValue != value {
                settings.stopSeedingRatio = clampedValue
            }
        }
    }

    private func trackerCountText(_ count: Int) -> String {
        if count == 1 {
            return String(localized: "1 tracker")
        }
        return String(format: String(localized: "%d trackers"), count)
    }
}
