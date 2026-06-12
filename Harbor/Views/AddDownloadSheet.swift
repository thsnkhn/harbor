import AppKit
import SwiftUI

struct AddDownloadSheet: View {
    private enum Field: Hashable {
        case sourceURL
        case filename
    }

    let settings: AppSettingsStore
    let onSubmit: @MainActor (AddDownloadRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    @State private var entryMode: AddDownloadEntryMode
    @State private var sourceURLText: String
    @State private var customFilename: String
    @State private var torrentFileURL: URL?
    @State private var destinationPath: String
    @State private var shouldStartImmediately: Bool
    @State private var validationMessage: String?

    init(
        settings: AppSettingsStore,
        draft: AddDownloadSheetDraft,
        onSubmit: @escaping @MainActor (AddDownloadRequest) -> Void
    ) {
        self.settings = settings
        self.onSubmit = onSubmit
        _entryMode = State(initialValue: draft.entryMode)
        _sourceURLText = State(initialValue: draft.sourceURLText)
        _customFilename = State(initialValue: draft.customFilename)
        _torrentFileURL = State(initialValue: draft.torrentFileURL)
        _destinationPath = State(initialValue: draft.destinationFolderURL.path)
        _shouldStartImmediately = State(initialValue: draft.shouldStartImmediately)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Download")
                    .font(.title2.weight(.semibold))
                Text("Paste a direct URL, add a magnet link, or choose a `.torrent` file. Torrent transfers use a dedicated backend while direct links stay on the native `URLSession` path.")
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker("Source", selection: $entryMode) {
                    ForEach(AddDownloadEntryMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if entryMode == .linkOrMagnet {
                    TextField("https://example.com/file.zip or magnet:?xt=...", text: $sourceURLText)
                        .focused($focusedField, equals: Field.sourceURL)

                    TextField("Optional file name override", text: $customFilename)
                        .focused($focusedField, equals: Field.filename)
                } else {
                    LabeledContent("Torrent File") {
                        HStack(spacing: 8) {
                            Text(torrentFileURL?.path ?? "No file selected")
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)

                            Button("Choose…") {
                                torrentFileURL = TorrentFileSelectionService.chooseTorrentFile(
                                    startingAt: URL(fileURLWithPath: destinationPath, isDirectory: true)
                                )
                            }
                        }
                    }
                }

                destinationPicker

                Toggle("Start immediately", isOn: $shouldStartImmediately)
            }
            .formStyle(.grouped)

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                if entryMode == .linkOrMagnet {
                    Button("Paste Link") {
                        sourceURLText = NSPasteboard.general.string(forType: .string) ?? sourceURLText
                    }
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Add Download") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(canSubmit == false)
            }
        }
        .padding(24)
        .frame(minWidth: 500, idealWidth: 560, maxWidth: 640)
        .onAppear {
            if entryMode == .linkOrMagnet {
                focusedField = .sourceURL
            }
        }
        .onChange(of: entryMode) { _, newMode in
            validationMessage = nil
            if newMode == .linkOrMagnet {
                focusedField = .sourceURL
            } else {
                focusedField = nil
            }
        }
    }

    private var destinationPicker: some View {
        LabeledContent("Destination") {
            HStack(spacing: 8) {
                Text(destinationPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)

                Button("Choose…") {
                    guard let folder = FolderSelectionService.chooseFolder(
                        startingAt: URL(fileURLWithPath: destinationPath, isDirectory: true)
                    ) else {
                        return
                    }

                    destinationPath = folder.path
                }

                Button("Use Default") {
                    destinationPath = settings.defaultDestinationPath
                }
                .disabled(destinationPath == settings.defaultDestinationPath)
            }
        }
    }

    private var canSubmit: Bool {
        switch entryMode {
        case .linkOrMagnet:
            let trimmedURL = sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedURL = URL(string: trimmedURL),
                  let detectedKind = DownloadSourceKind.detect(from: parsedURL) else {
                return false
            }

            return detectedKind == .directURL || detectedKind == .magnetLink

        case .torrentFile:
            guard let torrentFileURL else {
                return false
            }

            return DownloadSourceKind.detect(from: torrentFileURL) == .torrentFile
        }
    }

    private func submit() {
        validationMessage = nil

        let sourceURL: URL
        let sourceKind: DownloadSourceKind

        switch entryMode {
        case .linkOrMagnet:
            let trimmedURL = sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedURL = URL(string: trimmedURL),
                  let detectedKind = DownloadSourceKind.detect(from: parsedURL),
                  detectedKind == .directURL || detectedKind == .magnetLink else {
                validationMessage = String(
                    localized: "add.validation.linkOrMagnet",
                    defaultValue: "Enter a valid HTTP/HTTPS URL or magnet link.",
                    comment: "Validation message shown when the entered source is not an HTTP, HTTPS, or magnet URL."
                )
                focusedField = .sourceURL
                return
            }

            sourceURL = parsedURL
            sourceKind = detectedKind

        case .torrentFile:
            guard let torrentFileURL,
                  DownloadSourceKind.detect(from: torrentFileURL) == .torrentFile else {
                validationMessage = String(
                    localized: "add.validation.torrentFile",
                    defaultValue: "Choose a valid `.torrent` file.",
                    comment: "Validation message shown when the selected torrent file is missing or invalid."
                )
                return
            }

            sourceURL = torrentFileURL
            sourceKind = .torrentFile
        }

        let folderURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
        let trimmedFilename = customFilename.trimmingCharacters(in: .whitespacesAndNewlines)

        onSubmit(
            AddDownloadRequest(
                sourceKind: sourceKind,
                sourceURL: sourceURL,
                customFilename: sourceKind.supportsCustomFilename && trimmedFilename.isEmpty == false ? trimmedFilename : nil,
                destinationFolder: folderURL,
                shouldStartImmediately: shouldStartImmediately
            )
        )
        dismiss()
    }
}
