import SwiftUI

struct TorrentContentsSelectionSheet: View {
    let loadPreview: @MainActor () async throws -> TorrentContentsPreview
    var isExistingDownload = false
    let onAdd: @MainActor (TorrentContentsPreview, TorrentFileSelection?) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview: TorrentContentsPreview?
    @State private var selectedIndexes: Set<Int> = []
    @State private var errorMessage: String?
    @State private var loadGeneration = 0
    @State private var isSaving = false
    @State private var saveError: String?

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

            if let saveError {
                Text(saveError).foregroundStyle(.red)
            }
            footer
        }
        .padding(20)
        .frame(minWidth: 640, idealWidth: 720, minHeight: 460, idealHeight: 560)
        .accessibilityIdentifier(HarborAccessibility.torrentSheet)
        .interactiveDismissDisabled(isSaving)
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
                    .disabled(preview.completedIndexes.contains(file.index) || isSaving)
            }
            .width(28)

            TableColumn("File") { file in
                HStack {
                    Text(file.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(file.path)
                    if preview.completedIndexes.contains(file.index) {
                        Text("Downloaded").foregroundStyle(.secondary)
                    }
                }
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
                .disabled(isSaving || selectedIndexes.count == preview.files.count)

                Button("Select None") {
                    selectedIndexes = preview.completedIndexes
                }
                .accessibilityIdentifier(HarborAccessibility.torrentSelectNone)
                .disabled(isSaving || selectedIndexes == preview.completedIndexes)

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
            .disabled(isSaving)

            Button(isExistingDownload ? "Save Selection" : "Add Download") {
                guard let preview else { return }
                isSaving = true
                saveError = nil
                Task { @MainActor in
                    defer { isSaving = false }
                    do {
                        try await onAdd(
                            preview,
                            TorrentFileSelection.partial(selectedIndexes: selectedIndexes, in: preview)
                        )
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
            }
            .accessibilityIdentifier(HarborAccessibility.torrentAdd)
            .keyboardShortcut(.defaultAction)
            .disabled(preview == nil || selectedIndexes.isEmpty || isSaving
                      || (isExistingDownload && selectedIndexes == preview?.selectedIndexes))

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
            selectedIndexes = (loadedPreview.selectedIndexes ?? Set(loadedPreview.files.map(\.index)))
                .union(loadedPreview.completedIndexes)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
