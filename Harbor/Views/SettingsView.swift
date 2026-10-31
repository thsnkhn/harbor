import SwiftUI

struct SettingsView: View {
    let settings: AppSettingsStore
    @ObservedObject var updater: AppUpdater
    @AppStorage("settings.selectedPane") private var selectedPaneID = SettingsPane.general.rawValue

    private var selectedPane: SettingsPane {
        SettingsPane(rawValue: selectedPaneID) ?? .general
    }

    var body: some View {
        TabView(selection: Binding(
            get: { selectedPane },
            set: { selectedPaneID = $0.rawValue }
        )) {
            ForEach(SettingsPane.allCases) { pane in
                paneContent(for: pane)
                    .tabItem {
                        Label(pane.title, systemImage: pane.symbol)
                            .accessibilityIdentifier("settings.navigation.\(pane.rawValue)")
                    }
                    .tag(pane)
            }
        }
        .frame(width: 600, height: 520)
    }

    @ViewBuilder
    private func paneContent(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            GeneralSettingsTab(settings: settings, updater: updater)
                .accessibilityIdentifier(HarborAccessibility.settingsGeneral)
        case .downloads:
            DownloadsSettingsTab(settings: settings)
                .accessibilityIdentifier(HarborAccessibility.settingsDownloads)
        case .media:
            MediaSettingsTab(settings: settings)
                .accessibilityIdentifier("settings.media")
        case .torrents:
            TorrentsSettingsTab(settings: settings)
                .accessibilityIdentifier(HarborAccessibility.settingsTorrents)
        case .bandwidth:
            BandwidthSettingsTab(settings: settings)
                .accessibilityIdentifier(HarborAccessibility.settingsBandwidth)
        case .network:
            NetworkSettingsTab(settings: settings)
                .accessibilityIdentifier("settings.network")
        case .extensions:
            ExtensionsSettingsTab()
                .accessibilityIdentifier("settings.extensions")
        }
    }
}

private enum SettingsPane: String, CaseIterable, Identifiable {
    case general, downloads, media, torrents, bandwidth, network, extensions

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .downloads: "Downloads"
        case .media: "Media"
        case .torrents: "Torrents"
        case .bandwidth: "Bandwidth"
        case .network: "Network"
        case .extensions: "Extensions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .downloads: "folder"
        case .media: "play.rectangle"
        case .torrents: "arrow.up.arrow.down.circle"
        case .bandwidth: "speedometer"
        case .network: "network"
        case .extensions: "puzzlepiece.extension"
        }
    }
}

