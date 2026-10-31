import SwiftUI

struct NetworkSettingsTab: View {
    let settings: AppSettingsStore
    @State private var showsVPN = false
    @State private var showsBlocklist = false

    var body: some View {
        @Bindable var settings = settings
        Form {
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

            Section("Torrent Connections") {
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
                .disabled(settings.torrentVPNEnabled)

                if !settings.torrentVPNEnabled, settings.networkBindingSelection != .any {
                    NetworkBindingStatusRow(status: settings.networkBindingStatus)
                }

                if settings.torrentVPNEnabled {
                    Text("Private VPN controls the torrent connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if settings.networkBindingSelection != .any {
                    Text("Torrents pause if this interface disconnects and resume when it returns.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                IncomingPortSettings(settings: settings)

                DisclosureGroup("Private VPN (Experimental)", isExpanded: $showsVPN) {
                    Toggle("Use Private VPN", isOn: $settings.torrentVPNEnabled)
                        .accessibilityIdentifier("settings.network.vpn")
                    Text("When enabled, torrents wait for this VPN. Other downloads and apps use their normal connection.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if settings.torrentVPNEnabled {
                        TorrentVPNSettingsContent(controller: settings.torrentVPN)
                    }
                }

                DisclosureGroup("Peer Blocklist", isExpanded: $showsBlocklist) {
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

                    if settings.torrentBlocklistEnabled {
                        Text("Use one IP address or network range per line. If a refresh fails, the last valid list stays active.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("Applies only to torrent connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .harborSurface()
        .onAppear {
            settings.refreshNetworkBindingTargets()
            showsVPN = settings.torrentVPNEnabled
            showsBlocklist = settings.torrentBlocklistEnabled
        }
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

    private var serviceTargets: [NetworkBindingTarget] {
        settings.networkBindingPickerTargets.filter { $0.kind == .service }
    }

    private var interfaceTargets: [NetworkBindingTarget] {
        settings.networkBindingPickerTargets.filter { $0.kind == .interface }
    }
}
