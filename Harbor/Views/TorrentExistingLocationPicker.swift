import AppKit
import SwiftUI

struct TorrentExistingLocationPicker: View {
    let preview: TorrentContentsPreview
    @Binding var location: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if isDirectory {
                    Text("Select the torrent’s root folder.")
                } else {
                    Text("Select the existing file.")
                }
            }
            .foregroundStyle(.secondary)
            HStack {
                if let location {
                    Text(location.path)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(location.path)
                        .accessibilityLabel("Existing files location")
                        .accessibilityValue(location.path)
                } else {
                    Text("No location selected")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Choose Location…") {
                    if let chosen = Self.choose(preview: preview, startingAt: location?.deletingLastPathComponent()) {
                        location = chosen
                    }
                }
                .accessibilityIdentifier("torrent.chooseExistingLocation")
            }
        }
    }

    private var isDirectory: Bool { Self.isDirectory(preview) }

    private static func isDirectory(_ preview: TorrentContentsPreview) -> Bool {
        preview.isMultiFile
    }

    @MainActor
    static func choose(preview: TorrentContentsPreview, startingAt url: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = isDirectory(preview)
        panel.canChooseFiles = !isDirectory(preview)
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = url
        panel.prompt = String(localized: "Choose")
        panel.message = isDirectory(preview)
            ? String(localized: "Choose the folder that contains this torrent’s files.")
            : String(localized: "Choose the existing file to check against this torrent.")
        return panel.runModal() == .OK ? panel.url : nil
    }
}
