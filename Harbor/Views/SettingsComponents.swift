import SwiftUI

struct DestinationFolderRow: View {
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

struct TorrentWatchStatusRow: View {
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

struct IncomingPortSettings: View {
    let settings: AppSettingsStore
    @State private var portDraft = 0
    @FocusState private var isPortFieldFocused: Bool

    var body: some View {
        @Bindable var settings = settings

        Group {
            Picker("Incoming Port", selection: $settings.torrentIncomingPortMode) {
                Text("Default (6881)").tag(TorrentIncomingPortMode.off)
                Text("Manual").tag(TorrentIncomingPortMode.manual)
            }
            .accessibilityIdentifier(HarborAccessibility.settingsIncomingPortPicker)
            .disabled(settings.torrentVPNEnabled)

            switch settings.torrentIncomingPortMode {
            case .off:
                EmptyView()
            case .manual:
                // Apply the complete value when editing ends.
                LabeledContent("Port") {
                    TextField("Port", value: $portDraft, format: .number.grouping(.never))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .frame(width: 80)
                        .focused($isPortFieldFocused)
                        .onSubmit(commitPort)
                        .disabled(settings.torrentVPNEnabled)
                }
            }
            if settings.torrentVPNEnabled {
                Text("Private VPN does not support incoming connections.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if settings.torrentIncomingPortMode == .manual {
                Text("Forward this TCP and UDP port on your router or VPN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { portDraft = settings.torrentIncomingPort }
        .onChange(of: isPortFieldFocused) { _, isFocused in
            if isFocused == false {
                commitPort()
            }
        }
    }

    private func commitPort() {
        let port = AppSettingsStore.clampedIncomingPort(portDraft)
        portDraft = port
        if settings.torrentIncomingPort != port {
            settings.torrentIncomingPort = port
        }
    }
}

struct NetworkBindingStatusRow: View {
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

struct SpeedLimitRow: View {
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
                .labelsHidden()
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
