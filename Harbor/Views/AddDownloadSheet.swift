import AppKit
import SwiftUI

struct AddDownloadSheet: View {
    private enum Field: Hashable {
        case sourceURL
        case filename
    }

    let settings: AppSettingsStore
    let mediaPreviewProvider: @MainActor (URL) async throws -> MediaDownloadMetadata?
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
    @State private var mediaPreview: MediaDownloadMetadata?
    @State private var mediaPreviewError: String?
    @State private var mediaFormatPreference: MediaDownloadFormatPreference = .bestMP4
    @State private var hasMediaSavePermission = false
    @State private var isResolvingMedia = false
    @State private var isSubmitting = false
    @State private var mediaPreviewTask: Task<Void, Never>?
    @State private var mediaPreviewGeneration = 0

    init(
        settings: AppSettingsStore,
        draft: AddDownloadSheetDraft,
        mediaPreviewProvider: @escaping @MainActor (URL) async throws -> MediaDownloadMetadata? = { _ in nil },
        onSubmit: @escaping @MainActor (AddDownloadRequest) -> Void
    ) {
        self.settings = settings
        self.mediaPreviewProvider = mediaPreviewProvider
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
                Text("Paste a direct URL, media post URL, magnet link, or choose a `.torrent` file.")
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
                    TextField("https://example.com/file.zip, social link, or magnet:?xt=...", text: $sourceURLText)
                        .focused($focusedField, equals: Field.sourceURL)
                        .onChange(of: sourceURLText) {
                            scheduleMediaPreviewRefresh()
                        }

                    TextField("Optional file name override", text: $customFilename)
                        .focused($focusedField, equals: Field.filename)
                        .disabled(mediaPreview != nil)

                    mediaPreviewRows
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
                        scheduleMediaPreviewRefresh()
                    }
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(isSubmitting ? "Adding…" : "Add Download") {
                    Task {
                        await submit()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(canSubmit == false || isSubmitting)
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
        }
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

        if let mediaPreview {
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
                }
            }

            Picker("Format", selection: $mediaFormatPreference) {
                ForEach(MediaDownloadFormatPreference.allCases) { preference in
                    Text(preference.title).tag(preference)
                }
            }

            Toggle("I own this content or have permission to save it", isOn: $hasMediaSavePermission)
        } else if let mediaPreviewError, shouldShowMediaPreviewError {
            LabeledContent("Media") {
                Label(mediaPreviewError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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

            guard detectedKind == .directURL || detectedKind == .magnetLink || detectedKind == .torrentFile else {
                return false
            }

            if mediaPreview != nil {
                return hasMediaSavePermission
            }

            if isResolvingMedia, shouldWaitForMediaPreview(for: parsedURL) {
                return false
            }

            if mediaPreviewError != nil, isKnownMediaHost(parsedURL) {
                return false
            }

            return true

        case .torrentFile:
            guard let torrentFileURL else {
                return false
            }

            return DownloadSourceKind.detect(from: torrentFileURL) == .torrentFile
        }
    }

    private var shouldShowMediaPreviewError: Bool {
        guard parsedLinkURL != nil else {
            return false
        }

        return parsedLinkURL.map(isKnownMediaHost) == true
    }

    private var parsedLinkURL: URL? {
        let trimmedURL = sourceURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(string: trimmedURL)
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
                } else if shouldWaitForMediaPreview(for: parsedURL) {
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
               let metadata = resolvedMediaPreview {
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
                if mediaPreviewError != nil, isKnownMediaHost(parsedURL) {
                    validationMessage = mediaPreviewError
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
        let trimmedFilename = customFilename.trimmingCharacters(in: .whitespacesAndNewlines)

        onSubmit(
            AddDownloadRequest(
                sourceKind: sourceKind,
                sourceURL: sourceURL,
                customFilename: sourceKind.supportsCustomFilename && trimmedFilename.isEmpty == false ? trimmedFilename : nil,
                destinationFolder: folderURL,
                shouldStartImmediately: shouldStartImmediately,
                mediaMetadata: requestMediaMetadata,
                mediaFormatPreference: requestMediaFormatPreference
            )
        )
        dismiss()
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
                    Image(systemName: metadata.mediaType == .image ? "photo" : "play.rectangle")
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
                Image(systemName: metadata.mediaType == .image ? "photo" : "play.rectangle")
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

    private func scheduleMediaPreviewRefresh() {
        mediaPreviewTask?.cancel()
        mediaPreviewGeneration += 1
        let generation = mediaPreviewGeneration
        resetMediaPreview()

        guard entryMode == .linkOrMagnet,
              let url = parsedLinkURL,
              DownloadSourceKind.detect(from: url) == .directURL else {
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
                showErrors: isKnownMediaHost(url),
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
            guard let metadata = try await mediaPreviewProvider(url),
                  isUsableMediaMetadata(metadata) else {
                return nil
            }

            guard mediaPreviewGeneration == generation,
                  parsedLinkURL == url else {
                return nil
            }

            mediaPreview = metadata
            mediaFormatPreference = metadata.defaultFormatPreference
            hasMediaSavePermission = false
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
        hasMediaSavePermission = false
        mediaFormatPreference = .bestMP4
    }

    private func isUsableMediaMetadata(_ metadata: MediaDownloadMetadata) -> Bool {
        let extractorKey = metadata.extractorKey?.lowercased()
        return metadata.mediaType != .unknown || extractorKey != "generic"
    }

    private func shouldWaitForMediaPreview(for url: URL) -> Bool {
        isKnownMediaHost(url)
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
