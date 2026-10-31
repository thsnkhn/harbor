import SafariServices
import SwiftUI

struct ExtensionsSettingsTab: View {
    // TODO: Remove the notice when extension setup and automatic handoffs are stable.
    @Environment(\.scenePhase) private var scenePhase
    @State private var extensionEnabled: Bool?
    @State private var errorMessage: String?

    private let extensionIdentifier = "co.hapy.harbor.SafariExtension"

    var body: some View {
        Form {
            Section {
                Label("Extensions are experimental. More features are coming.", systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Safari Extension") {
                LabeledContent("Status") {
                    Text(extensionStatus)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.extensions.safari.status")
                }

                Button(extensionEnabled == true
                       ? String(localized: "Manage in Safari…")
                       : String(localized: "Enable in Safari…")) {
                    SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionIdentifier) { error in
                        Task { @MainActor in
                            errorMessage = error.map(extensionErrorMessage)
                        }
                    }
                }
                .accessibilityIdentifier("settings.extensions.safari.manage")

                Text("Turn on Harbor in Safari Settings → Extensions, then allow access to the websites you want to use.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section("Third-party Extensions") {
                Link("Get Chrome Extension…", destination: URL(string: "https://github.com/head-less-ghost/harbor-chrome-extension")!)
                Link("Get Firefox Extension…", destination: URL(string: "https://github.com/head-less-ghost/harbor-firefox-extension")!)
                Text("Requires a local helper. Use manual forwarding; automatic forwarding can cancel the browser download before you confirm it in Harbor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
        .harborSurface()
        .onAppear(perform: refreshExtensionState)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshExtensionState() }
        }
    }

    private var extensionStatus: LocalizedStringResource {
        if let extensionEnabled {
            return extensionEnabled ? "Enabled" : "Disabled"
        }
        return errorMessage == nil ? "Checking…" : "Unavailable"
    }

    private func refreshExtensionState() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: extensionIdentifier) { state, error in
            extensionEnabled = state?.isEnabled
            errorMessage = error.map(extensionErrorMessage)
        }
    }

    private func extensionErrorMessage(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == SFErrorDomain, error.code == SFErrorCode.noExtensionFound.rawValue {
            return String(localized: "Safari cannot detect the Harbor extension. Reopen Harbor and try again.")
        }
        return String(localized: "Safari could not access the Harbor extension. Try again.")
    }
}
