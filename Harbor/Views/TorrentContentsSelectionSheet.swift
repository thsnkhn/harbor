import SwiftUI

struct TorrentContentsSelectionSheet: View {
    let loadPreview: @MainActor () async throws -> TorrentContentsPreview
    var destinationFolder: URL? = nil
    var useExistingFiles = false
    var onCheck: (@MainActor (TorrentContentsPreview, TorrentFileSelection?, URL) -> Void)? = nil
    let onAdd: @MainActor (TorrentContentsPreview, TorrentFileSelection?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview: TorrentContentsPreview?
    @State private var selectedIndexes: Set<Int> = []
    @State private var errorMessage: String?
    @State private var loadGeneration = 0
    @State private var existingLocation: URL?
    @State private var isUsingExistingFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Group {
                if let preview {
                    contentsTable(preview)
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t Preview Torrent", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") {
                            loadGeneration += 1
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Fetching torrent metadata…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 320)

            if let preview, onCheck != nil {
                if isUsingExistingFiles {
                    Text("Check existing files before downloading. You can choose what to do after the check.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TorrentExistingLocationPicker(preview: preview, location: $existingLocation)
                } else {
                    Button("Use Existing Files…") {
                        isUsingExistingFiles = true
                        existingLocation = TorrentExistingLocationPicker.choose(preview: preview, startingAt: destinationFolder)
                    }
                }
            }

            footer
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 460, idealHeight: 560)
        .accessibilityIdentifier(HarborAccessibility.torrentSheet)
        .task(id: loadGeneration) {
            await load()
        }
    }

    @ViewBuilder
    private var header: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.name)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Text("\(preview.files.count) files • \(DownloadFormatting.byteString(preview.totalBytes))")
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Torrent Contents")
                .font(.title2.weight(.semibold))
        }
    }

    private func contentsTable(_ preview: TorrentContentsPreview) -> some View {
        // TODO: Add native folder-level tri-state selection if Harbor later exposes a tree view.
        Table(preview.files) {
            TableColumn("") { file in
                Toggle("Select \(file.path)", isOn: selectionBinding(for: file.index))
                    .labelsHidden()
            }
            .width(28)

            TableColumn("File") { file in
                Text(file.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.path)
            }

            TableColumn("Size") { file in
                Text(DownloadFormatting.byteString(file.byteCount))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 90, ideal: 110, max: 140)
        }
        .accessibilityIdentifier(HarborAccessibility.torrentTable)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let preview {
                Button("Select All") {
                    selectedIndexes = Set(preview.files.map(\.index))
                }
                .accessibilityIdentifier(HarborAccessibility.torrentSelectAll)
                .disabled(selectedIndexes.count == preview.files.count)

                Button("Select None") {
                    selectedIndexes.removeAll()
                }
                .accessibilityIdentifier(HarborAccessibility.torrentSelectNone)
                .disabled(selectedIndexes.isEmpty)

                Text(selectionSummary(in: preview))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .accessibilityIdentifier(HarborAccessibility.torrentCancel)
            .keyboardShortcut(.cancelAction)

            if isUsingExistingFiles == false {
                Button("Add Download") {
                    guard let preview else {
                        return
                    }
                    onAdd(
                        preview,
                        TorrentFileSelection.partial(
                            selectedIndexes: selectedIndexes,
                            in: preview
                        )
                    )
                    dismiss()
                }
                .accessibilityIdentifier(HarborAccessibility.torrentAdd)
                .keyboardShortcut(.defaultAction)
                .disabled(preview == nil || selectedIndexes.isEmpty)
            }

            if isUsingExistingFiles {
                Button("Check") {
                    guard let preview, let existingLocation else { return }
                    onCheck?(preview, TorrentFileSelection.partial(selectedIndexes: selectedIndexes, in: preview), existingLocation)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(existingLocation == nil || selectedIndexes.isEmpty)
                .accessibilityIdentifier("torrent.checkExistingFiles")
            }
        }
    }

    private func selectionBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedIndexes.contains(index) },
            set: { isSelected in
                if isSelected {
                    selectedIndexes.insert(index)
                } else {
                    selectedIndexes.remove(index)
                }
            }
        )
    }

    private func selectionSummary(in preview: TorrentContentsPreview) -> String {
        let selectedBytes = preview.files
            .filter { selectedIndexes.contains($0.index) }
            .reduce(0) { $0 + $1.byteCount }
        return "\(selectedIndexes.count) of \(preview.files.count) selected • \(DownloadFormatting.byteString(selectedBytes))"
    }

    @MainActor
    private func load() async {
        preview = nil
        errorMessage = nil
        do {
            let loadedPreview = try await loadPreview()
            try Task.checkCancellation()
            preview = loadedPreview
            selectedIndexes = Set(loadedPreview.files.map(\.index))
            isUsingExistingFiles = useExistingFiles
            if onCheck != nil, let destinationFolder {
                let expected = destinationFolder.appendingPathComponent(loadedPreview.name)
                if FileManager.default.fileExists(atPath: expected.path) {
                    existingLocation = expected
                    isUsingExistingFiles = true
                }
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
