import SwiftUI

struct GeneralSettingsTab: View {
    let settings: AppSettingsStore
    @ObservedObject var updater: AppUpdater

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
                Toggle("Send download notifications", isOn: $settings.notificationsEnabled)
                Toggle(
                    "Start at Login",
                    isOn: Binding(
                        get: { settings.startAtLogin },
                        set: { settings.setStartAtLogin($0) }
                    )
                )

                if let startAtLoginErrorMessage = settings.startAtLoginErrorMessage {
                    Text(startAtLoginErrorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            CommandLineSettingsSection(settings: settings)

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
        .onAppear {
            settings.refreshStartAtLoginStatus()
        }
    }
}
