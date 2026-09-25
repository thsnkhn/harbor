import SwiftUI

struct TorrentTrackersSection: View {
    let item: DownloadItem
    let center: DownloadCenter

    @State private var trackers: [TorrentTracker] = []
    @State private var trackerURL = ""
    @State private var errorMessage: String?
    @State private var isWorking = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                controls

                if isWorking, trackers.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                } else if trackers.isEmpty {
                    Text("No trackers reported.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(trackers.enumerated()), id: \.element.id) { index, tracker in
                            if index > 0 {
                                Divider()
                            }
                            TrackerRow(tracker: tracker) {
                                Task {
                                    await perform {
                                        try await center.removeTorrentTracker(tracker, for: item.id)
                                    }
                                }
                            }
                        }
                    }
                    .disabled(isWorking)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(.top, 8)
            .task(id: item.backendIdentifier) {
                await loadTrackers()
            }
        } label: {
            Text("Trackers")
                .font(.headline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Tracker URL", text: $trackerURL)
                    .textFieldStyle(.roundedBorder)

                Button("Add") {
                    Task {
                        await perform {
                            try await center.addTorrentTracker(trackerURL, for: item.id)
                            trackerURL = ""
                        }
                    }
                }
                .disabled(trackerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isWorking)
            }

            HStack(spacing: 12) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task {
                        await loadTrackers()
                    }
                }

                Button("Reannounce", systemImage: "megaphone") {
                    Task {
                        await perform {
                            try await center.reannounceTorrentTrackers(for: item.id)
                        }
                    }
                }
            }
            .controlSize(.small)
            .disabled(isWorking)
        }
    }

    @MainActor
    private func loadTrackers() async {
        isWorking = true
        defer { isWorking = false }
        do {
            trackers = try await center.torrentTrackers(for: item.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func perform(_ operation: () async throws -> Void) async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await operation()
            trackers = try await center.torrentTrackers(for: item.id)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TrackerRow: View {
    let tracker: TorrentTracker
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tracker.url)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)

                Text(
                    [tracker.tierText, tracker.statusText, tracker.peerCountText]
                        .compactMap { $0 }
                        .joined(separator: " • ")
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                let activity = [tracker.failureCountText, tracker.nextAnnounceText]
                    .compactMap { $0 }
                if activity.isEmpty == false {
                    Text(activity.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = tracker.message, message.isEmpty == false {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 8)

            if tracker.isRemovable {
                Button("Remove Tracker", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 8)
    }
}
