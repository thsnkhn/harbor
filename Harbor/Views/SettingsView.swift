import SwiftUI

struct SettingsView: View {
    // TODO: Add a Tags settings tab when automatic tagging rules are introduced.
    let settings: AppSettingsStore
    @ObservedObject var updater: AppUpdater

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .accessibilityIdentifier(HarborAccessibility.settingsGeneral)
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            DownloadsSettingsTab(settings: settings)
                .accessibilityIdentifier(HarborAccessibility.settingsDownloads)
                .tabItem {
                    Label("Downloads", systemImage: "folder")
                }

            TorrentsSettingsTab(settings: settings)
                .accessibilityIdentifier(HarborAccessibility.settingsTorrents)
                .tabItem {
                    Label("Torrents", systemImage: "arrow.up.arrow.down.circle")
                }

            BandwidthSettingsTab(settings: settings)
                .accessibilityIdentifier(HarborAccessibility.settingsBandwidth)
                .tabItem {
                    Label("Bandwidth", systemImage: "speedometer")
                }

            UpdatesSettingsTab(updater: updater)
                .accessibilityIdentifier(HarborAccessibility.settingsUpdates)
                .tabItem {
                    Label("Updates", systemImage: "arrow.triangle.2.circlepath")
                }

            AcknowledgmentsSettingsTab()
                .accessibilityIdentifier(HarborAccessibility.settingsAcknowledgments)
                .tabItem {
                    Label("Acknowledgments", systemImage: "info.circle")
                }
        }
        .frame(width: 640, height: 460)
        .scenePadding()
    }
}
