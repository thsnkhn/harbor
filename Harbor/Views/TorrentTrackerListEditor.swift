import SwiftUI

struct TorrentTrackerListEditor: View {
    let kind: TorrentTrackerListKind
    let settings: AppSettingsStore

    @State private var trackerURL = ""
    @State private var sourceURL = ""
    @State private var isEnteringSourceURL = false
    @State private var selection = Set<String>()
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var fieldHeight: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind.title)
                .font(.headline)

            Text(kind.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Tracker URL", text: $trackerURL)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTrackerURL)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fieldHeight = $0 }

                iconButton("Add Tracker", systemImage: "plus", action: addTrackerURL)
                    .disabled(trackerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            List(settings.torrentTrackers(kind), id: \.self, selection: $selection) { url in
                Text(url)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .listStyle(.bordered)
            .frame(height: 180)
            .onDeleteCommand(perform: removeSelection)

            HStack(spacing: 8) {
                Button("Import from File…", systemImage: "doc", action: importFile)

                Button("Import from URL…", systemImage: "link") {
                    isEnteringSourceURL = true
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                iconButton("Remove", systemImage: "minus", action: removeSelection)
                    .disabled(selection.isEmpty)
            }
            .disabled(isLoading)

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.leading)
        .padding()
        .frame(width: 420)
        .alert("Import from URL", isPresented: $isEnteringSourceURL) {
            Group {
                TextField("Tracker list URL", text: $sourceURL)
                Button("Cancel", role: .cancel) {}
                Button("Import", action: loadSourceURL)
                    .disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .multilineTextAlignment(.leading)
        } message: {
            Text("Enter URL of a tracker list.")
        }
    }

    /// Square button as tall as the tracker URL field, whatever the symbol's size.
    private func iconButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: fieldHeight, height: fieldHeight)
    }

    private func addTrackerURL() {
        do {
            add([try TorrentTrackerError.normalizedURL(trackerURL)])
            trackerURL = ""
        } catch {
            message = nil
            errorMessage = error.localizedDescription
        }
    }

    private func importFile() {
        guard let url = TorrentTrackerListLoader.chooseFile() else {
            return
        }
        do {
            add(try TorrentTrackerListLoader.trackers(fromFileAt: url))
        } catch {
            message = nil
            errorMessage = error.localizedDescription
        }
    }

    private func loadSourceURL() {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                add(try await TorrentTrackerListLoader.trackers(
                    fromSource: sourceURL,
                    proxySettings: settings.proxySettings
                ))
                sourceURL = ""
            } catch {
                message = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func add(_ urls: [String]) {
        let count = settings.addTorrentTrackers(urls, to: kind)
        errorMessage = nil
        message = count == 1
            ? String(localized: "Added 1 tracker.")
            : String(format: String(localized: "Added %d trackers."), count)
    }

    private func removeSelection() {
        settings.removeTorrentTrackers(selection, from: kind)
        selection = []
    }
}

extension TorrentTrackerListKind {
    var title: LocalizedStringResource {
        switch self {
        case .added:
            "Add to Torrents"
        case .excluded:
            "Remove from Torrents"
        }
    }

    var explanation: LocalizedStringResource {
        switch self {
        case .added:
            "Harbor adds these trackers to every torrent you add."
        case .excluded:
            "Harbor removes these trackers from every torrent you add."
        }
    }
}
