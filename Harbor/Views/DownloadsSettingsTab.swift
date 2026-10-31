import SwiftUI

struct DownloadsSettingsTab: View {
    let settings: AppSettingsStore
    @State private var showsAdvanced = false

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

            Section("Downloading") {
                Toggle("Start downloads immediately", isOn: $settings.startDownloadsAutomatically)
                    .accessibilityIdentifier("settings.downloads.startImmediately")
                Stepper(value: $settings.maxConcurrentDownloads, in: AppSettingsStore.maxConcurrentDownloadsRange) {
                    LabeledContent("Maximum active downloads", value: "\(settings.maxConcurrentDownloads)")
                }
                Toggle("Prevent sleep while downloading", isOn: $settings.preventSleepWhileDownloading)
            }

            Section("Download List") {
                Toggle("Remove completed downloads from the list", isOn: $settings.removeCompletedDownloadsAutomatically)
                Text("Downloaded files are kept. Torrents stay listed until seeding stops. Watched .torrent files move to Trash to prevent another import.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Import") {
                Toggle("Import links from a file (Experimental)", isOn: $settings.manifestImportEnabled)
                    .accessibilityIdentifier("settings.downloads.manifest")
                if settings.manifestImportEnabled {
                    Text("One download link per line.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    Toggle(
                        "Use custom temporary-file location",
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
                            title: "Temporary files",
                            path: settings.downloadStagingRootURL.path,
                            choose: settings.chooseDownloadStaging,
                            reveal: settings.revealDownloadStaging
                        )

                        Text("Applies to new downloads.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .harborSurface()
    }
}
