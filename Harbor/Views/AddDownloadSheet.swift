import AppKit
import SwiftUI

struct AddDownloadSheet: View {
    private struct TorrentPreviewSource: Identifiable {
        let sourceKind: DownloadSourceKind
        let sourceURL: URL
        var useExistingFiles = false
        var resolvedPreview: TorrentContentsPreview? = nil

        var id: String { "\(sourceKind.rawValue):\(sourceURL.absoluteString)" }
    }

    private enum PendingSensitiveTorrentAction {
        case preview(TorrentPreviewSource)
        case submit([AddDownloadRequest])
    }

    private enum Layout {
        static let groupedFormHorizontalExpansion: CGFloat = 20
    }

    private enum Field: Hashable {
        case sourceURL
    }

    let settings: AppSettingsStore
    let mediaPreviewProvider: @MainActor (URL) async throws -> MediaDownloadMetadata?
    let torrentPreviewProvider: @MainActor (DownloadSourceKind, URL, [RequestHeader]) async throws -> TorrentContentsPreview
    let onSubmit: @MainActor ([AddDownloadRequest]) -> Void
    let onCheckTorrent: (@MainActor (AddDownloadRequest, URL) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusedField: Field?

    @State private var entryMode: AddDownloadEntryMode
    @State private var sourceURLText: String
    @State private var torrentFileURL: URL?
    @State private var destinationPath: String
    @State private var hasCustomizedDestination = false
    @State private var shouldStartImmediately: Bool
    @State private var requestHeaders: [RequestHeader] = []
    @State private var isRequestHeadersEditorPresented = false
    @State private var validationMessage: String?
    @State private var mediaPreview: MediaDownloadMetadata?
    @State private var mediaPreviewError: String?
    @State private var mediaFormatPreference: MediaDownloadFormatPreference = .bestAvailable
    @State private var hasMediaSavePermission = true
    @State private var isResolvingMedia = false
    @State private var isSubmitting = false
    @State private var isResolvingTorrent = false
    @State private var torrentSubmissionTask: Task<Void, Never>?
    @State private var mediaPreviewTask: Task<Void, Never>?
    @State private var mediaPreviewGeneration = 0
    @State private var torrentPreviewSource: TorrentPreviewSource?
    @State private var hasApprovedSensitiveTorrentHeaders = false
    @State private var pendingSensitiveTorrentAction: PendingSensitiveTorrentAction?

    init(
        settings: AppSettingsStore,
        draft: AddDownloadSheetDraft,
        mediaPreviewProvider: @escaping @MainActor (URL) async throws -> MediaDownloadMetadata? = { _ in nil },
        torrentPreviewProvider: @escaping @MainActor (DownloadSourceKind, URL, [RequestHeader]) async throws -> TorrentContentsPreview = { _, _, _ in
            throw TorrentEngineError.invalidSource
        },
        onCheckTorrent: (@MainActor (AddDownloadRequest, URL) -> Void)? = nil,
        onSubmit: @escaping @MainActor ([AddDownloadRequest]) -> Void
    ) {
        self.settings = settings
        self.mediaPreviewProvider = mediaPreviewProvider
        self.torrentPreviewProvider = torrentPreviewProvider
        self.onSubmit = onSubmit
        self.onCheckTorrent = onCheckTorrent
        _entryMode = State(initialValue: draft.entryMode)
        _sourceURLText = State(initialValue: draft.sourceURLText)
        _torrentFileURL = State(initialValue: draft.torrentFileURL)
        _destinationPath = State(initialValue: draft.destinationFolderURL.path)
        _shouldStartImmediately = State(initialValue: draft.shouldStartImmediately)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Download")
                    .font(.title2.weight(.semibold))
                    .accessibilityIdentifier(HarborAccessibility.addSheet)
                Text("Paste one or more links, a media post URL, a magnet link, or choose a `.torrent` file. Add several at once by putting one link per line.")
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker("Source", selection: $entryMode) {
                    ForEach(AddDownloadEntryMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(HarborAccessibility.addSourceMode)

                if entryMode == .linkOrMagnet {
                    TextField(
                        "Source",
                        text: $sourceURLText,
                        prompt: Text("https://example.com/file.zip, social link, or magnet:?xt=..."),
                        axis: .vertical
                    )
                    .labelsHidden()
                    .lineLimit(1...8)
                    .accessibilityIdentifier(HarborAccessibility.addSource)
                    .focused($focusedField, equals: Field.sourceURL)
                    .onChange(of: sourceURLText) {
                        scheduleMediaPreviewRefresh()
                        updateDestinationForDetectedSourceIfNeeded()
                    }

                    if isBatchEntry {
                        batchSummaryRow
                    } else {
                        mediaPreviewRows
                    }
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
                            .accessibilityIdentifier(HarborAccessibility.addChooseTorrent)
                        }
                    }
                }

                destinationPicker

                Toggle("Start immediately", isOn: $shouldStartImmediately)
                    .accessibilityIdentifier(HarborAccessibility.addStartImmediately)

                advancedSettingsSection
            }
            .formStyle(.grouped)
            .disabled(isResolvingTorrent)
            .padding(.horizontal, -Layout.groupedFormHorizontalExpansion)

            if let validationMessage {
                Text(validationMessage)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .accessibilityIdentifier(HarborAccessibility.addCancel)
                .keyboardShortcut(.cancelAction)

                if let torrentPreviewCandidate, isResolvingTorrent == false {
                    if onCheckTorrent != nil {
                        Button("Use Existing Files…") {
                            var source = torrentPreviewCandidate
                            source.useExistingFiles = true
                            presentTorrentPreview(source)
                        }
                        .accessibilityIdentifier("add.useExistingTorrentFiles")
                    }
                    Button("Preview") {
                        presentTorrentPreview(torrentPreviewCandidate)
                    }
                    .accessibilityIdentifier(HarborAccessibility.addPreview)
                }

                Button(addButtonTitle) {
                    Task {
                        await submit()
                    }
                }
                .accessibilityIdentifier(HarborAccessibility.addSubmit)
                .keyboardShortcut(.defaultAction)
                .disabled(canSubmit == false || isSubmitting || isResolvingTorrent)
            }
        }
        .padding(24)
        .frame(minWidth: 540, idealWidth: 620, maxWidth: 720)
        .onAppear {
            if entryMode == .linkOrMagnet {
                focusedField = .sourceURL
                scheduleMediaPreviewRefresh()
            }
        }
        .onDisappear {
            mediaPreviewTask?.cancel()
            torrentSubmissionTask?.cancel()
            mediaPreviewGeneration += 1
        }
        .onChange(of: entryMode) { _, newMode in
            validationMessage = nil
            mediaPreviewGeneration += 1
            resetMediaPreview()
            if newMode == .linkOrMagnet {
                focusedField = .sourceURL
                scheduleMediaPreviewRefresh()
            } else {
                focusedField = nil
            }
            updateDestinationForDetectedSourceIfNeeded()
        }
        .sheet(item: $torrentPreviewSource) { source in
            torrentContentsSheet(for: source)
        }
        .sheet(isPresented: $isRequestHeadersEditorPresented) {
            RequestHeadersEditor(
                requestHeaders: requestHeaders
            ) { updatedHeaders in
                requestHeaders = updatedHeaders
                hasApprovedSensitiveTorrentHeaders = false
                validationMessage = nil
            }
        }
        .alert(
            "Sensitive headers may be shared",
            isPresented: Binding(
                get: { pendingSensitiveTorrentAction != nil },
                set: { isPresented in
                    if isPresented == false {
                        pendingSensitiveTorrentAction = nil
                    }
                }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingSensitiveTorrentAction = nil
            }

            Button("Continue") {
                continuePendingSensitiveTorrentAction()
            }
        } message: {
            Text(
                "The supplied headers contain Cookie or Authorization information. aria2 may send these headers to every HTTP/HTTPS tracker and web seed used by this torrent. Proceed?"
            )
        }
    }

    private func torrentContentsSheet(for source: TorrentPreviewSource) -> TorrentContentsSelectionSheet {
        let checkAction: (@MainActor (TorrentContentsPreview, TorrentFileSelection?, URL) -> Void)?
        if let onCheckTorrent {
            checkAction = { preview, selection, location in
                let request = AddDownloadRequest(
                    sourceKind: source.sourceKind,
                    sourceURL: source.sourceURL,
                    customFilename: nil,
                    destinationFolder: URL(fileURLWithPath: destinationPath, isDirectory: true),
                    shouldStartImmediately: false,
                    requestHeaders: requestHeaders,
                    torrentFileSelection: selection,
                    preparedTorrentMetainfo: preview.metainfoData,
                    torrentMetadataName: preview.name
                )
                onCheckTorrent(request, location)
                dismiss()
            }
        } else {
            checkAction = nil
        }

        return TorrentContentsSelectionSheet(
            loadPreview: {
                if let preview = source.resolvedPreview { return preview }
                return try await torrentPreviewProvider(
                    source.sourceKind,
                    source.sourceURL,
                    requestHeaders
                )
            },
            destinationFolder: URL(fileURLWithPath: destinationPath, isDirectory: true),
            useExistingFiles: source.useExistingFiles,
            onCheck: checkAction,
            onAdd: { preview, selection in
                submitTorrentPreview(source: source, preview: preview, selection: selection)
            }
        )
    }

    private var torrentPreviewCandidate: TorrentPreviewSource? {
        switch entryMode {
        case .torrentFile:
            guard let torrentFileURL,
                  DownloadSourceKind.detect(from: torrentFileURL) == .torrentFile else {
                return nil
            }
            return TorrentPreviewSource(sourceKind: .torrentFile, sourceURL: torrentFileURL)
        case .linkOrMagnet:
            guard isBatchEntry == false,
                  let parsedLinkURL,
                  let sourceKind = DownloadSourceKind.detect(from: parsedLinkURL),
                  sourceKind == .torrentFile || sourceKind == .magnetLink else {
                return nil
            }
            return TorrentPreviewSource(sourceKind: sourceKind, sourceURL: parsedLinkURL)
        }
    }

    private func presentTorrentPreview(_ source: TorrentPreviewSource) {
        if requestHeaders.triggersSensitiveTorrentWarning,
           hasApprovedSensitiveTorrentHeaders == false {
            pendingSensitiveTorrentAction = .preview(source)
            return
        }

        torrentPreviewSource = source
    }

    @MainActor
    private func submitTorrentPreview(
        source: TorrentPreviewSource,
        preview: TorrentContentsPreview,
        selection: TorrentFileSelection?
    ) {
        let request = AddDownloadRequest(
            sourceKind: source.sourceKind,
            sourceURL: source.sourceURL,
            customFilename: nil,
            destinationFolder: URL(fileURLWithPath: destinationPath, isDirectory: true),
            shouldStartImmediately: shouldStartImmediately,
            requestHeaders: requestHeaders,
            torrentFileSelection: selection,
            preparedTorrentMetainfo: preview.metainfoData,
            torrentMetadataName: preview.name
        )
        submitRequests([request])
    }

    @ViewBuilder
    private var mediaPreviewRows: some View {
        if isResolvingMedia {
            LabeledContent("Media") {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking link…")
                        .foregroundStyle(.secondary)
                }
            }
        }

        else if let mediaPreview {
            LabeledContent("Media") {
                HStack(spacing: 12) {
                    mediaThumbnail(for: mediaPreview)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(mediaPreview.title)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)

                        Text(mediaSummary(for: mediaPreview))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(HarborAccessibility.addMediaMetadata)
                    .accessibilityValue(
                        "extractor=\(mediaPreview.extractorKey ?? "");type=\(mediaPreview.mediaType.rawValue)"
                    )
                }
            }

            if mediaPreview.capabilities.supportsMediaFormatSelection {
                LabeledContent("Format") {
                    ScrollView {
                        Picker("", selection: primaryFormatSelection) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Best available")
                                Text("Let yt-dlp choose the best available streams")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .tag(String?.none)

                            ForEach(mediaPreview.capabilities.formatOptions) { format in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(format.formatTitle)
                                    Text(format.formatDetails)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .tag(Optional(format.id))
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(
                        minHeight: min(
                            CGFloat(mediaPreview.capabilities.formatOptions.count + 1) * 40,
                            220
                        ),
                        maxHeight: 220
                    )
                }

                if let selectedFormat {
                    if selectedFormat.isVideoOnly {
                        LabeledContent("Audio") {
                            if mediaPreview.capabilities.audioFormatOptions.isEmpty {
                                Text("No audio available")
                                    .foregroundStyle(.secondary)
                            } else {
                                Picker("", selection: audioFormatSelection) {
                                    Text("No audio")
                                        .tag(String?.none)

                                    ForEach(mediaPreview.capabilities.audioFormatOptions) { audioFormat in
                                        Text(audioFormat.audioFormatTitle)
                                            .tag(Optional(audioFormat.id))
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                .frame(maxWidth: 360, alignment: .trailing)
                            }
                        }
                    } else if selectedFormat.hasVideo, selectedFormat.hasAudio {
                        LabeledContent("Audio") {
                            Text("Included in selected format")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let mergeOutputFormat = mediaFormatPreference.selection?.mergeOutputFormat {
                        LabeledContent("Output") {
                            Text(mergeOutputFormat.uppercased())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Toggle("I own this content or have permission to save it", isOn: $hasMediaSavePermission)
                .accessibilityIdentifier(HarborAccessibility.addMediaPermission)
        } else if let mediaPreviewError {
            LabeledContent("Media") {
                VStack(alignment: .trailing, spacing: 8) {
                    Label(mediaPreviewError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)

                    if canTryAsMedia {
                        Button("Try as Media") {
                            tryAsMedia()
                        }
                        .accessibilityIdentifier(HarborAccessibility.addTryAsMedia)
                    }
                }
            }
        } else if parsedLinkURL.map(isKnownMediaHost) == true {
            LabeledContent("Media") {
                Text("Harbor will check this link with yt-dlp.")
                    .foregroundStyle(.secondary)
            }
        } else if canTryAsMedia {
            LabeledContent("Media") {
                Button("Try as Media") {
                    tryAsMedia()
                }
                .accessibilityIdentifier(HarborAccessibility.addTryAsMedia)
            }
        }
    }

    private var selectedFormat: MediaDownloadFormatOption? {
        mediaPreview?.capabilities.selectedFormat(in: mediaFormatPreference)
    }

    private var primaryFormatSelection: Binding<String?> {
        Binding(
            get: {
                mediaFormatPreference.selection?.formatID
            },
            set: { formatID in
                guard let mediaPreview,
                      let preference = mediaPreview.capabilities.preference(
                          selectingPrimaryFormatID: formatID
                      ) else {
                    return
                }
                mediaFormatPreference = preference
            }
        )
    }

    private var audioFormatSelection: Binding<String?> {
        Binding(
            get: {
                mediaFormatPreference.selection?.audioFormatID
            },
            set: { audioFormatID in
                guard let mediaPreview,
                      let preference = mediaPreview.capabilities.preference(
                          mediaFormatPreference,
                          selectingAudioFormatID: audioFormatID
                      ) else {
                    return
                }
                mediaFormatPreference = preference
            }
        )
    }

    private var destinationPicker: some View {
        HStack(spacing: 16) {
            Text("Destination")
                .fixedSize()
            HStack(spacing: 8) {
                Text(destinationPath)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
                    .help(destinationPath)
                    .textSelection(.enabled)

                Button("Choose…") {
                    guard let folder = FolderSelectionService.chooseFolder(
                        startingAt: URL(fileURLWithPath: destinationPath, isDirectory: true)
                    ) else {
                        return
                    }

                    destinationPath = folder.path
                    hasCustomizedDestination = true
                }
                .fixedSize()

                Button("Use Default") {
                    destinationPath = sourceAwareDefaultDestinationPath
                    hasCustomizedDestination = false
                }
                .fixedSize()
                .disabled(destinationPath == sourceAwareDefaultDestinationPath)
            }
        }
    }

    private var advancedSettingsSection: some View {
        DisclosureGroup("Advanced Settings") {
            LabeledContent("Request Headers") {
                Button("Configure…") {
                    isRequestHeadersEditorPresented = true
                }
            }
            .padding(.top, 10)
            .padding(.leading, 24)
        }
        .disclosureGroupStyle(AdvancedSettingsDisclosureStyle())
    }

    private var sourceAwareDefaultDestinationPath: String {
        switch entryMode {
        case .torrentFile:
            return settings.torrentDestinationPath
        case .linkOrMagnet:
            let sourceURL = isBatchEntry ? parsedBatchURLs.first : parsedLinkURL
            guard let sourceURL,
                  let sourceKind = DownloadSourceKind.detect(from: sourceURL) else {
                return settings.defaultDestinationPath
            }

            switch sourceKind {
            case .magnetLink, .torrentFile:
                return settings.torrentDestinationPath
            case .directURL, .mediaURL:
                return settings.defaultDestinationPath
            }
        }
    }

    private func updateDestinationForDetectedSourceIfNeeded() {
        guard hasCustomizedDestination == false else {
            return
        }

        destinationPath = sourceAwareDefaultDestinationPath
    }

    private var canSubmit: Bool {
        switch entryMode {
        case .linkOrMagnet:
            if isBatchEntry {
                return parsedBatchURLs.isEmpty == false
            }

            let trimmedURL = sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedURL = URL(string: trimmedURL),
                  let detectedKind = DownloadSourceKind.detect(from: parsedURL) else {
                return false
            }

            guard detectedKind == .directURL || detectedKind == .magnetLink || detectedKind == .torrentFile else {
                return false
            }

            if let mediaPreview {
                return mediaPreview.supportsMediaDownload
                    && hasMediaSavePermission
            }

            if isResolvingMedia {
                return false
            }

            return isKnownMediaHost(parsedURL) == false

        case .torrentFile:
            guard let torrentFileURL else {
                return false
            }

            return DownloadSourceKind.detect(from: torrentFileURL) == .torrentFile
        }
    }

    private var parsedLinkURL: URL? {
        let trimmedURL = sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmedURL)
    }

    private var batchEntries: [DownloadSourceImportService.TextEntry] {
        DownloadSourceImportService.textEntries(from: sourceURLText)
    }

    // Multiple entered lines switch the sheet to batch mode even when some
    // lines are invalid or duplicates. This keeps those lines from being
    // percent-encoded into one bogus URL by Foundation's lenient parser.
    private var parsedBatchURLs: [URL] {
        batchEntries.compactMap(\.url)
    }

    private var isBatchEntry: Bool {
        entryMode == .linkOrMagnet && batchEntries.count > 1
    }

    private var skippedBatchLineCount: Int {
        batchEntries.filter { $0.status != .ready }.count
    }

    @ViewBuilder
    private var batchSummaryRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Label(batchReadyDescription, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                if skippedBatchLineCount > 0 {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Label(batchSkippedDescription, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(batchEntries) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: batchEntrySystemImage(for: entry.status))
                                .foregroundStyle(batchEntryColor(for: entry.status))
                            Text(entry.text)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(batchEntryStatusTitle(for: entry.status))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .frame(maxHeight: 140)
        }
    }

    private func batchEntrySystemImage(for status: DownloadSourceImportService.TextEntry.Status) -> String {
        switch status {
        case .ready:
            "checkmark.circle.fill"
        case .duplicate:
            "doc.on.doc.fill"
        case .unsupported:
            "exclamationmark.triangle.fill"
        }
    }

    private func batchEntryColor(for status: DownloadSourceImportService.TextEntry.Status) -> Color {
        switch status {
        case .ready:
            .green
        case .duplicate, .unsupported:
            .orange
        }
    }

    private func batchEntryStatusTitle(for status: DownloadSourceImportService.TextEntry.Status) -> LocalizedStringKey {
        switch status {
        case .ready:
            "Ready"
        case .duplicate:
            "Duplicate"
        case .unsupported:
            "Skipped"
        }
    }

    private var batchReadyDescription: String {
        let template = String(
            localized: "add.batch.ready",
            defaultValue: "%d links ready to add",
            comment: "Add Download summary showing how many valid links were detected when adding several at once. Parameter is the count."
        )
        return String(format: template, parsedBatchURLs.count)
    }

    private var batchSkippedDescription: String {
        let template = String(
            localized: "add.batch.skipped",
            defaultValue: "%d lines skipped",
            comment: "Add Download summary showing how many pasted lines could not be read as links. Parameter is the count."
        )
        return String(format: template, skippedBatchLineCount)
    }

    private var addButtonTitle: String {
        if isSubmitting || isResolvingTorrent {
            return String(
                localized: "add.button.submitting",
                defaultValue: "Adding…",
                comment: "Add Download button title while the download is being queued."
            )
        }

        if isBatchEntry {
            let template = String(
                localized: "add.button.batch",
                defaultValue: "Add %d Downloads",
                comment: "Add Download button title when adding several links at once. Parameter is the count."
            )
            return String(format: template, parsedBatchURLs.count)
        }

        return String(
            localized: "add.button.single",
            defaultValue: "Add Download",
            comment: "Add Download button title when adding a single download."
        )
    }

    private var canTryAsMedia: Bool {
        guard entryMode == .linkOrMagnet,
              isBatchEntry == false,
              let url = parsedLinkURL,
              DownloadSourceKind.detect(from: url) == .directURL,
              isKnownMediaHost(url) == false,
              mediaPreview == nil,
              isResolvingMedia == false else {
            return false
        }

        return true
    }

    @MainActor
    private func submit() async {
        guard isSubmitting == false else {
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        validationMessage = nil
        mediaPreviewTask?.cancel()
        mediaPreviewGeneration += 1
        let generation = mediaPreviewGeneration

        if entryMode == .linkOrMagnet, isBatchEntry {
            let folderURL = URL(fileURLWithPath: destinationPath, isDirectory: true)
            let requests = AddDownloadRequest.batch(
                from: parsedBatchURLs,
                destinationFolder: folderURL,
                shouldStartImmediately: shouldStartImmediately,
                requestHeaders: requestHeaders
            )

            guard requests.isEmpty == false else {
                return
            }

            submitRequests(requests)
            return
        }

        let sourceURL: URL
        let sourceKind: DownloadSourceKind
        var requestMediaMetadata: MediaDownloadMetadata?
        var requestMediaFormatPreference: MediaDownloadFormatPreference?

        switch entryMode {
        case .linkOrMagnet:
            let trimmedURL = sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parsedURL = URL(string: trimmedURL),
                  let detectedKind = DownloadSourceKind.detect(from: parsedURL),
                  detectedKind == .directURL || detectedKind == .magnetLink || detectedKind == .torrentFile else {
                validationMessage = String(
                    localized: "add.validation.linkOrMagnet",
                    defaultValue: "Enter a valid HTTP/HTTPS URL or magnet link.",
                    comment: "Validation message shown when the entered source is not an HTTP, HTTPS, or magnet URL."
                )
                focusedField = .sourceURL
                return
            }

            sourceURL = parsedURL

            let resolvedMediaPreview: MediaDownloadMetadata?
            if detectedKind == .directURL {
                if let mediaPreview {
                    resolvedMediaPreview = mediaPreview
                } else if isKnownMediaHost(parsedURL) {
                    resolvedMediaPreview = await resolveMediaPreview(
                        for: parsedURL,
                        showErrors: true,
                        generation: generation
                    )
                } else {
                    resolvedMediaPreview = nil
                }
            } else {
                resolvedMediaPreview = nil
            }

            if detectedKind == .directURL,
               let metadata = resolvedMediaPreview,
               metadata.supportsMediaDownload {
                guard hasMediaSavePermission else {
                    validationMessage = String(
                        localized: "add.validation.mediaPermission",
                        defaultValue: "Confirm that you own this content or have permission to save it.",
                        comment: "Validation message shown when a media URL is detected but permission has not been confirmed."
                    )
                    return
                }

                sourceKind = .mediaURL
                requestMediaMetadata = metadata
                requestMediaFormatPreference = mediaFormatPreference
            } else {
                if isKnownMediaHost(parsedURL) {
                    validationMessage = mediaPreviewError ?? String(
                        localized: "add.validation.mediaUnavailable",
                        defaultValue: "yt-dlp couldn’t verify downloadable media for this link.",
                        comment: "Validation message shown when a known media site does not provide verified downloadable media."
                    )
                    focusedField = .sourceURL
                    return
                }

                sourceKind = detectedKind
            }

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

        guard sourceKind != .mediaURL || requestHeaders.isEmpty else {
            validationMessage = String(
                localized: "add.validation.mediaHeadersUnsupported",
                defaultValue: "Request headers aren’t supported for media downloads.",
                comment: "Validation message shown when request headers are supplied for a yt-dlp media download."
            )
            return
        }

        let request = AddDownloadRequest(
            sourceKind: sourceKind,
            sourceURL: sourceURL,
            customFilename: nil,
            destinationFolder: folderURL,
            shouldStartImmediately: shouldStartImmediately,
            requestHeaders: requestHeaders,
            mediaMetadata: requestMediaMetadata,
            mediaFormatPreference: requestMediaFormatPreference
        )

        submitRequests([request])
    }

    @MainActor
    private func submitRequests(_ requests: [AddDownloadRequest]) {
        if requests.contains(where: {
            $0.sourceKind.usesAria2 && $0.requestHeaders.triggersSensitiveTorrentWarning
        }),
           hasApprovedSensitiveTorrentHeaders == false {
            pendingSensitiveTorrentAction = .submit(requests)
            return
        }

        performSubmission(requests)
    }

    @MainActor
    private func performSubmission(_ requests: [AddDownloadRequest]) {
        if isBatchEntry == false, requests.count == 1, let request = requests.first,
           request.shouldStartImmediately,
           request.sourceKind.usesAria2,
           request.preparedTorrentMetainfo == nil,
           onCheckTorrent != nil {
            isResolvingTorrent = true
            torrentSubmissionTask = Task {
                defer { isResolvingTorrent = false }
                do {
                    let preview = try await torrentPreviewProvider(request.sourceKind, request.sourceURL, request.requestHeaders)
                    try Task.checkCancellation()
                    let location = request.destinationFolder.appendingPathComponent(preview.name)
                    if FileManager.default.fileExists(atPath: location.path) {
                        torrentPreviewSource = TorrentPreviewSource(
                            sourceKind: request.sourceKind,
                            sourceURL: request.sourceURL,
                            useExistingFiles: true,
                            resolvedPreview: preview
                        )
                    } else {
                        submitTorrentPreview(
                            source: TorrentPreviewSource(sourceKind: request.sourceKind, sourceURL: request.sourceURL),
                            preview: preview,
                            selection: nil
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    validationMessage = error.localizedDescription
                }
            }
            return
        }
        onSubmit(requests)
        dismiss()
    }

    private func continuePendingSensitiveTorrentAction() {
        guard let action = pendingSensitiveTorrentAction else {
            return
        }

        pendingSensitiveTorrentAction = nil
        hasApprovedSensitiveTorrentHeaders = true

        switch action {
        case let .preview(source):
            torrentPreviewSource = source
        case let .submit(requests):
            guard isSubmitting == false else {
                return
            }
            isSubmitting = true
            defer { isSubmitting = false }
            performSubmission(requests)
        }
    }

    @ViewBuilder
    private func mediaThumbnail(for metadata: MediaDownloadMetadata) -> some View {
        if let thumbnailURL = metadata.thumbnailURL {
            AsyncImage(url: thumbnailURL) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                case .empty:
                    ProgressView()
                        .controlSize(.small)
                case .failure:
                    Image(systemName: mediaIconName(for: metadata))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                @unknown default:
                    EmptyView()
                }
            }
            .frame(width: 86, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.quaternary)
            }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                Image(systemName: mediaIconName(for: metadata))
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 86, height: 54)
        }
    }

    private func mediaSummary(for metadata: MediaDownloadMetadata) -> String {
        let type = mediaTypeTitle(for: metadata)
        let size: String? = metadata.expectedBytes > 0 ? DownloadFormatting.byteString(metadata.expectedBytes) : String(
            localized: "media.preview.sizeUnknown",
            defaultValue: "Size unknown",
            comment: "Media preview fallback shown when yt-dlp cannot estimate the final file size before downloading."
        )
        return [
            metadata.platform,
            type,
            size
        ]
            .compactMap { $0 }
            .joined(separator: " • ")
    }

    private func mediaTypeTitle(for metadata: MediaDownloadMetadata) -> String {
        if metadata.isCollection {
            let template = String(
                localized: "media.preview.collection",
                defaultValue: "%d items",
                comment: "Media preview summary for a collection. Parameter is the number of items."
            )
            return String(format: template, metadata.entryCount)
        }

        switch metadata.mediaType {
        case .video:
            return String(
                localized: "media.preview.video",
                defaultValue: "Video",
                comment: "Media preview type for video content."
            )
        case .audio:
            return String(
                localized: "media.preview.audio",
                defaultValue: "Audio",
                comment: "Media preview type for audio content."
            )
        case .image:
            return String(
                localized: "media.preview.image",
                defaultValue: "Image",
                comment: "Media preview type for image content."
            )
        case .collection:
            return String(
                localized: "media.preview.collectionFallback",
                defaultValue: "Collection",
                comment: "Media preview type for collection content."
            )
        case .unknown:
            return String(
                localized: "media.preview.media",
                defaultValue: "Media",
                comment: "Media preview type fallback."
            )
        }
    }

    private func mediaIconName(for metadata: MediaDownloadMetadata) -> String {
        switch metadata.mediaType {
        case .image:
            return "photo"
        case .audio:
            return "waveform"
        case .video, .collection, .unknown:
            return "play.rectangle"
        }
    }

    private func scheduleMediaPreviewRefresh() {
        mediaPreviewTask?.cancel()
        mediaPreviewGeneration += 1
        let generation = mediaPreviewGeneration
        resetMediaPreview()

        guard entryMode == .linkOrMagnet,
              isBatchEntry == false,
              let url = parsedLinkURL,
              DownloadSourceKind.detect(from: url) == .directURL,
              isKnownMediaHost(url) else {
            return
        }

        mediaPreviewTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(550))
            guard Task.isCancelled == false,
                  mediaPreviewGeneration == generation,
                  parsedLinkURL == url else {
                return
            }

            _ = await resolveMediaPreview(
                for: url,
                showErrors: true,
                generation: generation
            )
        }
    }

    @MainActor
    private func tryAsMedia() {
        guard let url = parsedLinkURL,
              DownloadSourceKind.detect(from: url) == .directURL,
              isKnownMediaHost(url) == false else {
            return
        }

        validationMessage = nil
        mediaPreviewTask?.cancel()
        mediaPreviewGeneration += 1
        let generation = mediaPreviewGeneration

        mediaPreviewTask = Task { @MainActor in
            _ = await resolveMediaPreview(
                for: url,
                showErrors: true,
                generation: generation
            )
        }
    }

    @discardableResult
    @MainActor
    private func resolveMediaPreview(
        for url: URL,
        showErrors: Bool,
        generation: Int
    ) async -> MediaDownloadMetadata? {
        isResolvingMedia = true
        mediaPreviewError = nil
        defer {
            if mediaPreviewGeneration == generation {
                isResolvingMedia = false
            }
        }

        do {
            guard let metadata = try await mediaPreviewProvider(url) else {
                return nil
            }

            guard isUsableMediaMetadata(metadata) else {
                if showErrors, mediaPreviewGeneration == generation {
                    mediaPreviewError = String(
                        localized: "add.validation.mediaUnavailable",
                        defaultValue: "yt-dlp couldn’t verify downloadable media for this link.",
                        comment: "Validation message shown when a known media site does not provide verified downloadable media."
                    )
                }
                return nil
            }

            guard mediaPreviewGeneration == generation,
                  parsedLinkURL == url else {
                return nil
            }

            mediaPreview = metadata
            mediaFormatPreference = .bestAvailable
            return metadata
        } catch {
            if showErrors, mediaPreviewGeneration == generation {
                mediaPreviewError = DownloadItem.displayErrorMessage(from: error.localizedDescription)
            }
            return nil
        }
    }

    private func resetMediaPreview() {
        mediaPreview = nil
        mediaPreviewError = nil
        isResolvingMedia = false
        hasMediaSavePermission = true
        mediaFormatPreference = .bestAvailable
    }

    private func isUsableMediaMetadata(_ metadata: MediaDownloadMetadata) -> Bool {
        metadata.supportsMediaDownload
    }

    private func isKnownMediaHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else {
            return false
        }

        let exactHosts: Set<String> = [
            "fb.watch",
            "pin.it",
            "youtu.be"
        ]

        if exactHosts.contains(host) {
            return true
        }

        let suffixes = [
            "youtube.com",
            "instagram.com",
            "tiktok.com",
            "twitter.com",
            "x.com",
            "facebook.com",
            "pinterest.com",
            "vimeo.com",
            "dailymotion.com",
            "reddit.com",
            "threads.net",
            "soundcloud.com",
            "twitch.tv"
        ]

        return suffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
            || host.contains("pinterest.")
    }
}

private struct AdvancedSettingsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? Text("Expanded") : Text("Collapsed"))

            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}
