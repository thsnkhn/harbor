import SwiftUI

struct TorrentCheckSheet: View {
    let center: DownloadCenter
    let item: DownloadItem

    @Environment(\.dismiss) private var dismiss
    @State private var preview: TorrentContentsPreview?
    @State private var location: URL?
    @State private var errorMessage: String?
    @State private var isStarting = false
    @State private var loadGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Check Torrent Files")
                .font(.title2.weight(.semibold))
            Text(item.displayName)
                .font(.headline)
                .lineLimit(2)

            if item.torrentCheckState == .checking || isStarting {
                TorrentCheckProgressView(progress: item.torrentCheckProgress)
                Text("Harbor is checking the existing files. Downloads stay stopped until you choose an action.")
                    .foregroundStyle(.secondary)
            } else if item.torrentCheckState == .complete {
                if item.torrentFileSelection?.isPartial == true {
                    Label("Selected Files Verified", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("The selected files are complete. You can start seeding or keep the torrent stopped.")
                } else {
                    Label("All Pieces Verified", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("The files are complete. You can start seeding or keep the torrent stopped.")
                }
            } else if item.torrentCheckState == .incomplete {
                Label("Missing or Damaged Pieces", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                Text("Download the missing pieces, check another location, or keep the torrent stopped.")
            } else {
                Text("Choose the existing files, then check them against the torrent metadata.")
                    .foregroundStyle(.secondary)
            }

            if let preview {
                TorrentExistingLocationPicker(preview: preview, location: $location)
                    .disabled(item.torrentCheckState == .checking || isStarting)
            } else if errorMessage == nil {
                ProgressView("Fetching torrent metadata…")
            }

            if let error = errorMessage ?? item.lastError {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                if preview == nil {
                    Button("Try Again") { loadGeneration += 1 }
                }
            }

            HStack {
                Button("Keep Stopped") {
                    center.keepTorrentStopped(id: item.id)
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("torrent.checkKeepStopped")
                Spacer()
                if (item.torrentCheckState == .complete || item.torrentCheckState == .incomplete),
                   locationMatchesCheckedFiles {
                    Button("Check Again", action: beginCheck)
                        .disabled(preview == nil || location == nil || isStarting)
                        .accessibilityIdentifier("torrent.checkAgain")
                }
                if item.torrentCheckState == .complete, locationMatchesCheckedFiles {
                    Button("Start Seeding") {
                        center.startSeeding(id: item.id)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStarting)
                } else if item.torrentCheckState == .incomplete, locationMatchesCheckedFiles {
                    Button("Download Missing Pieces") {
                        center.downloadMissingTorrentPieces(id: item.id)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStarting)
                    .accessibilityIdentifier("torrent.downloadMissingPieces")
                } else if item.torrentCheckState != .checking {
                    Button("Check", action: beginCheck)
                        .keyboardShortcut(.defaultAction)
                        .disabled(preview == nil || location == nil || isStarting)
                        .accessibilityIdentifier("torrent.beginCheck")
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("torrent.checkSheet")
        .interactiveDismissDisabled(item.torrentCheckState == .checking || isStarting)
        .task(id: loadGeneration) {
            errorMessage = nil
            if location == nil, let path = item.torrentExistingDataPath ?? item.fileLocationPath {
                location = URL(fileURLWithPath: path)
            }
            do {
                preview = try await center.loadTorrentCheckPreview(id: item.id)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var locationMatchesCheckedFiles: Bool {
        location?.standardizedFileURL.path == (item.torrentExistingDataPath ?? item.fileLocationPath)
    }

    private func beginCheck() {
        guard let location else { return }
        isStarting = true
        Task {
            await center.beginTorrentCheck(id: item.id, location: location)
            isStarting = false
        }
    }
}

struct TorrentCheckProgressView: View {
    let progress: Double?

    var body: some View {
        Group {
            if let progress {
                ProgressView(value: progress) {
                    Text("Checking Files…")
                } currentValueLabel: {
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                }
            } else {
                ProgressView("Checking Files…")
            }
        }
        .accessibilityIdentifier("torrent.checkProgress")
    }
}
