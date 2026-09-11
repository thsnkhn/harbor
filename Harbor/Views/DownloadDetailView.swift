import SwiftUI

struct DownloadDetailView: View {
    let center: DownloadCenter

    var body: some View {
        if center.selectedDownloadIDs.count > 1 {
            DownloadBulkInspector(center: center)
                .accessibilityIdentifier(HarborAccessibility.inspector)
        } else if let item = center.selectedDownload {
            DownloadInspectorContent(item: item, center: center)
                .accessibilityIdentifier(HarborAccessibility.inspector)
        }
    }
}

private struct DownloadInspectorContent: View {
    let item: DownloadItem
    let center: DownloadCenter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                DownloadHeader(item: item)

                DownloadActionRow(
                    item: item,
                    continueInBrowser: continueInBrowser,
                    togglePauseResume: togglePauseResume,
                    retry: retry,
                    startSeeding: startSeeding,
                    stopSeeding: stopSeeding,
                    openFile: openFile,
                    quickLook: quickLook,
                    canQuickLook: center.canQuickLookDownloads(ids: [item.id]),
                    revealInFinder: revealInFinder,
                    copySourceURL: copySourceURL
                )

                if shouldShowMediaFormatRecovery {
                    MediaFormatRecoverySection(item: item, center: center)
                }

                DownloadTransferSection(item: item, center: center)
                if item.backend == .aria2 {
                    Button("Check Files…", systemImage: "checkmark.shield") {
                        center.checkTorrentFiles(id: item.id)
                    }
                    .accessibilityIdentifier("download.checkTorrentFiles")
                }
                DownloadStorageSection(item: item)
                DownloadActivitySection(item: item)

                if item.status == .browserSessionRequired {
                    DownloadCallout(
                        title: "Browser Session Required",
                        message: item.lastError ?? String(
                            localized: "error.direct.browserSessionRequired",
                            defaultValue: "This site requires a browser session before Harbor can download the file.",
                            comment: "Download validation error shown when a site requires browser authentication before downloading."
                        ),
                        systemImage: "globe",
                        tint: .mint
                    )
                }

                if item.backend == .aria2,
                   item.status == .completed,
                   let seedingError = item.displayLastError {
                    DownloadCallout(
                        title: "Seeding Unavailable",
                        message: seedingError,
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }

            }
            .padding(24)
        }
        .navigationTitle(item.displayName)
    }

    private var shouldShowMediaFormatRecovery: Bool {
        guard item.backend == .ytDlp,
              item.status == .failed,
              let metadata = item.mediaMetadata else {
            return false
        }

        if metadata.capabilities.supportsMediaFormatSelection {
            return true
        }

        if case .specific? = item.mediaFormatPreference {
            return true
        }

        return item.lastError
            == MediaDownloadErrorClassifier.selectedFormatUnavailableMessage
    }

    private func continueInBrowser() {
        center.continueInBrowser(id: item.id)
    }

    private func togglePauseResume() {
        center.togglePauseResume(id: item.id)
    }

    private func retry() {
        center.retryDownload(id: item.id)
    }

    private func startSeeding() {
        center.startSeeding(id: item.id)
    }

    private func stopSeeding() {
        center.stopSeeding(id: item.id)
    }

    private func openFile() {
        center.openDownload(id: item.id)
    }

    private func quickLook() {
        center.quickLookDownload(id: item.id)
    }

    private func revealInFinder() {
        center.revealInFinder(id: item.id)
    }

    private func copySourceURL() {
        center.copySourceURL(id: item.id)
    }
}

private struct MediaFormatRecoverySection: View {
    let item: DownloadItem
    let center: DownloadCenter

    var body: some View {
        DownloadDetailSection(title: "Media Format") {
            VStack(alignment: .leading, spacing: 12) {
                if capabilities.isSelectionUnavailable(in: item.mediaFormatPreference) {
                    DownloadCallout(
                        title: "Format No Longer Available",
                        message: "Choose another format, then retry the download.",
                        systemImage: "exclamationmark.triangle",
                        tint: .orange
                    )
                }

                Picker("Format", selection: primaryFormatSelection) {
                    if let primaryFormatID = capabilities.unavailablePrimaryFormatID(
                        in: item.mediaFormatPreference
                    ),
                       let selection = item.mediaFormatPreference?.selection {
                        Text(selection.displaySummary ?? "Unavailable Format")
                            .tag(Optional(primaryFormatID))
                            .disabled(true)
                    }

                    Text("Best available")
                        .tag(String?.none)

                    ForEach(formatOptions) { format in
                        Text(format.compactFormatTitle)
                            .tag(Optional(format.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320, alignment: .leading)

                if let selectedFormat {
                    if selectedFormat.isVideoOnly {
                        if audioFormatOptions.isEmpty,
                           unavailableAudioFormatID == nil {
                            LabeledContent("Audio") {
                                Text("No audio available")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Picker("Audio", selection: audioFormatSelection) {
                                if let unavailableAudioFormatID {
                                    Text("Unavailable Audio")
                                        .tag(Optional(unavailableAudioFormatID))
                                        .disabled(true)
                                }

                                Text("No audio")
                                    .tag(String?.none)

                                ForEach(audioFormatOptions) { audioFormat in
                                    Text(audioFormat.audioFormatTitle)
                                        .tag(Optional(audioFormat.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 320, alignment: .leading)
                        }
                    } else if selectedFormat.hasVideo, selectedFormat.hasAudio {
                        LabeledContent("Audio") {
                            Text("Included in selected format")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let mergeOutputFormat = item.mediaFormatPreference?
                        .selection?.mergeOutputFormat {
                        LabeledContent("Output") {
                            Text(mergeOutputFormat.uppercased())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .task {
            if shouldRefreshFormats {
                await center.refreshMediaFormats(for: item.id)
            }
        }
    }

    private var formatOptions: [MediaDownloadFormatOption] {
        capabilities.formatOptions
    }

    private var audioFormatOptions: [MediaDownloadFormatOption] {
        capabilities.audioFormatOptions
    }

    private var capabilities: MediaDownloadCapabilities {
        item.mediaMetadata?.capabilities ?? .unavailable
    }

    private var selectedFormat: MediaDownloadFormatOption? {
        capabilities.selectedFormat(in: item.mediaFormatPreference)
    }

    private var primaryFormatSelection: Binding<String?> {
        Binding(
            get: {
                item.mediaFormatPreference?.selection?.primaryFormatID
            },
            set: { formatID in
                guard let preference = capabilities.preference(
                    selectingPrimaryFormatID: formatID
                ) else {
                    return
                }
                center.setMediaFormatPreference(
                    preference,
                    for: item.id
                )
            }
        )
    }

    private var audioFormatSelection: Binding<String?> {
        Binding(
            get: {
                item.mediaFormatPreference?.selection?.audioFormatID
            },
            set: { audioFormatID in
                guard let preference = capabilities.preference(
                    item.mediaFormatPreference,
                    selectingAudioFormatID: audioFormatID
                ) else {
                    return
                }
                center.setMediaFormatPreference(
                    preference,
                    for: item.id
                )
            }
        )
    }

    private var unavailableAudioFormatID: String? {
        capabilities.unavailableAudioFormatID(in: item.mediaFormatPreference)
    }

    private var shouldRefreshFormats: Bool {
        formatOptions.isEmpty
    }

}

private struct DownloadHeader: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(item.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(3)

                sourceLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            progressBlock
        }
    }

    private var sourceLine: some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Label(item.sourceBadgeTitle, systemImage: item.sourceBadgeImage)

                    if let sourceSummary {
                        Text(sourceSummary)
                            .foregroundStyle(.tertiary)
                    }
                }

                Label(item.sourceBadgeTitle, systemImage: item.sourceBadgeImage)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)

            if let sourceDetail {
                Text(sourceDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
    }

    private var progressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(item.status.title, systemImage: item.status.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(progressTint)

                Spacer()

                Text(progressLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            if let progressValue = item.progressValue {
                ProgressView(value: progressValue, total: 1)
                    .tint(progressTint)
            } else if item.status == .preparing || item.status == .downloading {
                ProgressView()
                    .controlSize(.small)
            } else {
                ProgressView(value: item.progress, total: 1)
                    .tint(progressTint)
            }
        }
    }

    private var progressLabel: LocalizedStringResource {
        if let progressValue = item.progressValue {
            return LocalizedStringResource(stringLiteral: progressValue.formatted(.percent.precision(.fractionLength(0))))
        }

        return item.status == .preparing ? "Starting..." : item.status.title
    }

    private var progressTint: Color {
        switch item.status {
        case .downloading:
            .blue
        case .seeding:
            .purple
        case .browserSessionRequired:
            .mint
        case .paused:
            .yellow
        case .completed:
            .green
        case .failed:
            .red
        case .cancelled:
            .secondary
        case .queued, .preparing, .waitingToRetry:
            .orange
        }
    }

    private var sourceSummary: String? {
        switch item.sourceKind {
        case .directURL:
            item.sourceURL.host
        case .magnetLink:
            String(
                localized: "source.summary.bitTorrent",
                defaultValue: "BitTorrent",
                comment: "Short source summary for magnet and torrent downloads."
            )
        case .torrentFile:
            nil
        case .mediaURL:
            item.mediaMetadata?.platform ?? item.sourceURL.host
        }
    }

    private var sourceDetail: String? {
        switch item.sourceKind {
        case .directURL:
            item.sourceURL.absoluteString
        case .magnetLink:
            nil
        case .torrentFile:
            item.sourceURL.lastPathComponent
        case .mediaURL:
            item.sourceURL.absoluteString
        }
    }
}

private struct DownloadActionRow: View {
    let item: DownloadItem
    let continueInBrowser: () -> Void
    let togglePauseResume: () -> Void
    let retry: () -> Void
    let startSeeding: () -> Void
    let stopSeeding: () -> Void
    let openFile: () -> Void
    let quickLook: () -> Void
    let canQuickLook: Bool
    let revealInFinder: () -> Void
    let copySourceURL: () -> Void

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 10) {
                actionLayout
            }
        } else {
            actionLayout
        }
    }

    private var actionLayout: some View {
        ViewThatFits {
            HStack(spacing: 10) {
                primaryAction
                secondaryAction
                overflowMenu
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                primaryAction
                HStack(spacing: 10) {
                    secondaryAction
                    overflowMenu
                }
            }
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        if item.status == .browserSessionRequired {
            Button(action: continueInBrowser) {
                Label("Continue", systemImage: "globe")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: true))
            .accessibilityIdentifier(HarborAccessibility.inspectorPrimaryAction)
        } else if item.status == .failed || item.status == .cancelled {
            Button(action: retry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: true))
            .accessibilityIdentifier(HarborAccessibility.inspectorPrimaryAction)
        } else if item.canPause || item.canResume {
            let isPause = item.canPause
            let isSeedingTransfer = item.status == .seeding
                || (item.status == .paused && item.finishedAt != nil && item.shouldSeedAfterDownload)
            let actionTitle: LocalizedStringResource = if isSeedingTransfer {
                isPause ? "Pause Seeding" : "Resume Seeding"
            } else {
                isPause ? "Pause" : "Resume"
            }

            Button(action: togglePauseResume) {
                Label(
                    actionTitle,
                    systemImage: isPause ? "pause.fill" : "play.fill"
                )
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: true))
            .accessibilityIdentifier(HarborAccessibility.inspectorPrimaryAction)
        } else if item.fileLocationURL != nil {
            Button(action: openFile) {
                Label("Open", systemImage: "doc.fill")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: true))
            .accessibilityIdentifier(HarborAccessibility.inspectorPrimaryAction)
        }
    }

    @ViewBuilder
    private var secondaryAction: some View {
        if item.status == .completed {
            Button(action: quickLook) {
                Label("Quick Look", systemImage: "eye")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: false))
            .accessibilityIdentifier(HarborAccessibility.inspectorSecondaryAction)
            .disabled(canQuickLook == false)
        } else if item.fileLocationURL != nil,
           item.status != .completed {
            Button(action: openFile) {
                Label("Open", systemImage: "doc.fill")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: false))
            .accessibilityIdentifier(HarborAccessibility.inspectorSecondaryAction)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("Reveal in Finder", systemImage: "folder", action: revealInFinder)

            if item.fileLocationURL != nil,
               item.status == .failed || item.status == .cancelled {
                Button("Open File", systemImage: "doc", action: openFile)
            }

            Button("Copy Source URL", systemImage: "link", action: copySourceURL)

            if item.backend == .aria2, item.status == .completed {
                Button("Start Seeding", systemImage: "arrow.up.circle", action: startSeeding)
            }

            if item.backend == .aria2,
               item.status == .seeding || (item.status == .paused && item.finishedAt != nil && item.shouldSeedAfterDownload) {
                Button("Stop Seeding", systemImage: "stop.fill", role: .destructive, action: stopSeeding)
            }
        } label: {
            Image(systemName: "ellipsis")
                .accessibilityLabel("More actions")
        }
        .buttonStyle(LiquidPillButtonStyle(prominent: false))
        .accessibilityIdentifier(HarborAccessibility.inspectorMoreActions)
        .help("More actions")
    }
}

private struct DownloadTransferSection: View {
    let item: DownloadItem
    let center: DownloadCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfer")
                Spacer()
                DownloadProfileMenu(item: item, center: center)
            }
            .font(.headline)

            VStack(spacing: 0) {
                DownloadedTransferRow(item: item)

                if item.backend == .aria2 {
                    Divider()
                    TorrentSharingRow(item: item)
                }

                if item.status == .downloading {
                    Divider()
                    DownloadValueRow(title: "ETA", value: item.etaText ?? "—")
                }

            }
        }
    }
}

private struct DownloadProfileMenu: View {
    let item: DownloadItem
    let center: DownloadCenter
    @State private var showsCustomLimits = false

    private var inheritsGlobal: Bool { item.trafficModeOverride == nil }

    private var currentMode: TrafficMode {
        item.trafficModeOverride ?? center.globalTrafficMode
    }

    var body: some View {
        Menu {
            Button {
                center.setDownloadLimitOverride(.inherit, for: item.id)
                center.setUploadLimitOverride(.inherit, for: item.id)
            } label: {
                if inheritsGlobal {
                    Label("Use Global", systemImage: "checkmark")
                } else {
                    Text("Use Global")
                }
            }
            Divider()
            ForEach(TrafficMode.allCases) { mode in
                Button {
                    if mode == .custom {
                        showsCustomLimits = true
                    } else {
                        let limits = mode.applying(to: .default)
                        center.setDownloadLimitOverride(
                            TransferLimitOverride(bytesPerSecond: limits.perDownloadSpeedLimitBytesPerSecond), for: item.id
                        )
                        center.setUploadLimitOverride(
                            TransferLimitOverride(bytesPerSecond: limits.perDownloadUploadSpeedLimitBytesPerSecond), for: item.id
                        )
                    }
                } label: {
                    if inheritsGlobal == false, currentMode == mode {
                        Label(mode.title, systemImage: "checkmark")
                    } else {
                        Text(mode.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(currentMode.title)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
            }
            .font(.headline)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(item.status == .browserSessionRequired || center.activeBrowserSession?.downloadID == item.id)
        .help("Set this download’s speed profile. Global bandwidth limits still apply.")
        .popover(isPresented: $showsCustomLimits) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Custom Limits").font(.headline)
                TransferLimitControls(item: item, center: center)
            }
            .padding(16)
            .frame(width: 380)
        }
    }


}

private struct TorrentSharingRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            TransferMetric(title: "Uploaded", value: item.uploadedText)
            TransferMetric(title: "Share Ratio", value: item.shareRatioText)
        }
        .padding(.vertical, 9)
    }
}

private struct TransferMetric: View {
    let title: LocalizedStringKey
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TransferLimitControls: View {
    private enum LimitMode: String, CaseIterable, Identifiable {
        case inherit
        case unlimited
        case custom

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .inherit:
                "Inherit"
            case .unlimited:
                "Unlimited"
            case .custom:
                "Custom"
            }
        }
    }

    let item: DownloadItem
    let center: DownloadCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                limitRow(
                    title: "Download Limit",
                    limitOverride: item.downloadLimitOverride,
                    fallbackKilobytesPerSecond: 5 * 1_024,
                    update: { center.setDownloadLimitOverride($0, for: item.id) }
                )

                if item.backend == .aria2 {
                    limitRow(
                        title: "Upload Limit",
                        limitOverride: item.uploadLimitOverride,
                        fallbackKilobytesPerSecond: 1 * 1_024,
                        update: { center.setUploadLimitOverride($0, for: item.id) }
                    )
                }
            }
            .disabled(isBrowserAssistedDownload)

            if isBrowserAssistedDownload {
                Text("Speed limits aren’t available for browser-assisted downloads.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if item.backend == .ytDlp, item.isRunning {
                Text("Media limit changes apply when the download is resumed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 9)
    }

    private var isBrowserAssistedDownload: Bool {
        item.status == .browserSessionRequired
            || center.activeBrowserSession?.downloadID == item.id
    }

    private func limitRow(
        title: LocalizedStringResource,
        limitOverride: TransferLimitOverride,
        fallbackKilobytesPerSecond: Int,
        update: @escaping (TransferLimitOverride) -> Void
    ) -> some View {
        let mode = Binding<LimitMode>(
            get: { limitMode(for: limitOverride) },
            set: { newMode in
                switch newMode {
                case .inherit:
                    update(.inherit)
                case .unlimited:
                    update(.unlimited)
                case .custom:
                    update(.limited(kilobytesPerSecond: customValue(for: limitOverride, fallback: fallbackKilobytesPerSecond)))
                }
            }
        )

        let customValueBinding = Binding<Int>(
            get: { customValue(for: limitOverride, fallback: fallbackKilobytesPerSecond) },
            set: { update(.limited(kilobytesPerSecond: AppSettingsStore.clampedSpeedLimitKilobytes($0))) }
        )

        return LabeledContent {
            HStack(spacing: 8) {
                Picker(title, selection: mode) {
                    ForEach(LimitMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 105)

                if mode.wrappedValue == .custom {
                    TextField("Speed", value: customValueBinding, format: .number)
                        .monospacedDigit()
                        .frame(width: 88)
                    Text("KB/s")
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Text(title)
        }
    }

    private func limitMode(for limitOverride: TransferLimitOverride) -> LimitMode {
        switch limitOverride {
        case .inherit:
            .inherit
        case .unlimited:
            .unlimited
        case .limited:
            .custom
        }
    }

    private func customValue(
        for limitOverride: TransferLimitOverride,
        fallback: Int
    ) -> Int {
        if case let .limited(kilobytesPerSecond) = limitOverride {
            return kilobytesPerSecond
        }

        return fallback
    }
}

private struct DownloadedTransferRow: View {
    let item: DownloadItem

    var body: some View {
        // Keep the layout independent of the changing speed text width.
        VStack(alignment: .leading, spacing: 0) {
            TransferMetric(title: "Downloaded", value: item.progressText)
                .padding(.vertical, 9)

            Divider()

            HStack(alignment: .top, spacing: 14) {
                TransferMetric(title: "Download speed", value: item.speedText)

                if item.backend == .aria2 {
                    TransferMetric(
                        title: "Upload speed",
                        value: DownloadFormatting.throughputString(item.uploadBytesPerSecond)
                    )
                }
            }
            .padding(.vertical, 9)
        }
    }
}

private struct DownloadStorageSection: View {
    let item: DownloadItem

    var body: some View {
        VStack(spacing: 0) {
            DownloadValueRow(title: "Destination", value: item.destinationFolderPath)

            if let selectionText = item.partialTorrentSelectionText,
               let selection = item.torrentFileSelection {
                Divider()
                DownloadValueRow(
                    title: "Selected Files",
                    value: "\(selectionText) • \(DownloadFormatting.byteString(selection.selectedBytes))"
                )
            }

            if let fileLocationPath = item.fileLocationPath {
                Divider()
                DownloadValueRow(title: "Saved File", value: fileLocationPath)
            }
        }
    }
}

private struct DownloadValueRow: View {
    let title: LocalizedStringResource
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
    }
}

private struct DownloadCallout: View {
    let title: LocalizedStringResource
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private struct DownloadActivitySection: View {
    let item: DownloadItem

    var body: some View {
        DownloadDetailSection(title: "Activity") {
            VStack(alignment: .leading, spacing: 0) {
                let activityEntries = entries

                ForEach(Array(activityEntries.enumerated()), id: \.element.id) { index, entry in
                    DownloadActivityRow(
                        entry: entry,
                        isFirst: index == 0,
                        isLast: index == activityEntries.count - 1
                    )
                }
            }
        }
    }

    private var entries: [DownloadActivityTimelineEntry] {
        var entries = item.activityEvents.map { event in
            DownloadActivityTimelineEntry(
                event: event,
                message: activityMessage(for: event.kind)
            )
        }

        appendSyntheticEvent(
            kind: .added,
            timestamp: item.createdAt,
            to: &entries
        )

        if let startedAt = item.startedAt,
           entries.contains(where: { $0.kind == .started || $0.kind == .resumed }) == false {
            entries.append(
                DownloadActivityTimelineEntry(
                    id: "synthetic-started-\(item.id.uuidString)",
                    kind: .started,
                    timestamp: startedAt
                )
            )
        }

        appendCurrentStatusFallback(to: &entries)

        return entries.sorted { lhs, rhs in
            if lhs.timestamp == rhs.timestamp {
                return lhs.kind.sortPriority > rhs.kind.sortPriority
            }

            return lhs.timestamp > rhs.timestamp
        }
    }

    private func appendCurrentStatusFallback(
        to entries: inout [DownloadActivityTimelineEntry]
    ) {
        switch item.status {
        case .queued:
            appendSyntheticEvent(kind: .queued, timestamp: item.updatedAt, to: &entries)
        case .preparing, .waitingToRetry, .downloading:
            if entries.contains(where: { $0.kind == .started || $0.kind == .resumed }) == false {
                appendSyntheticEvent(kind: .started, timestamp: item.startedAt ?? item.updatedAt, to: &entries)
            }
        case .seeding:
            appendSyntheticEvent(kind: .seedingStarted, timestamp: item.finishedAt ?? item.updatedAt, to: &entries)
        case .browserSessionRequired:
            appendSyntheticEvent(kind: .browserSessionRequired, timestamp: item.updatedAt, to: &entries)
        case .paused:
            appendSyntheticEvent(kind: .paused, timestamp: item.updatedAt, to: &entries)
        case .completed:
            appendSyntheticEvent(kind: .completed, timestamp: item.finishedAt ?? item.updatedAt, to: &entries)
        case .failed:
            appendSyntheticEvent(
                kind: .failed,
                timestamp: item.updatedAt,
                message: item.displayLastError,
                to: &entries
            )
        case .cancelled:
            appendSyntheticEvent(kind: .cancelled, timestamp: item.updatedAt, to: &entries)
        }
    }

    private func activityMessage(for kind: DownloadActivityKind) -> String? {
        guard kind == .failed else {
            return nil
        }

        return item.displayLastError
    }

    private func appendSyntheticEvent(
        kind: DownloadActivityKind,
        timestamp: Date,
        message: String? = nil,
        to entries: inout [DownloadActivityTimelineEntry]
    ) {
        guard entries.contains(where: { $0.kind == kind }) == false else {
            return
        }

        entries.append(
            DownloadActivityTimelineEntry(
                id: "synthetic-\(kind.rawValue)-\(item.id.uuidString)",
                kind: kind,
                timestamp: timestamp,
                message: message
            )
        )
    }
}

private struct DownloadActivityTimelineEntry: Identifiable {
    let id: String
    let kind: DownloadActivityKind
    let timestamp: Date
    let message: String?

    init(event: DownloadActivityEvent, message: String? = nil) {
        self.id = event.id.uuidString
        self.kind = event.kind
        self.timestamp = event.timestamp
        self.message = message
    }

    init(
        id: String,
        kind: DownloadActivityKind,
        timestamp: Date,
        message: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.message = message
    }
}

private struct DownloadActivityRow: View {
    let entry: DownloadActivityTimelineEntry
    let isFirst: Bool
    let isLast: Bool

    private let markerSize: CGFloat = 22
    private let verticalPadding: CGFloat = 6

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            marker

            content
        }
        .padding(.vertical, verticalPadding)
        .background(alignment: .topLeading) {
            connector
        }
    }

    private var marker: some View {
        ZStack {
            Circle()
                .fill(entry.kind.tint.opacity(0.14))

            Image(systemName: entry.kind.systemImage)
                .font(.caption2.weight(.bold))
                .foregroundStyle(entry.kind.tint)
                .accessibilityHidden(true)
        }
        .frame(width: markerSize, height: markerSize)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.kind.title)
                .font(.callout.weight(.medium))

            Text(DownloadFormatting.dateString(entry.timestamp))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = entry.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 1)
    }

    private var connector: some View {
        GeometryReader { proxy in
            Path { path in
                let markerMidX = markerSize / 2
                let markerTopY = verticalPadding
                let markerBottomY = verticalPadding + markerSize

                if isFirst == false {
                    path.move(to: CGPoint(x: markerMidX, y: 0))
                    path.addLine(to: CGPoint(x: markerMidX, y: markerTopY))
                }

                if isLast == false {
                    path.move(to: CGPoint(x: markerMidX, y: markerBottomY))
                    path.addLine(to: CGPoint(x: markerMidX, y: proxy.size.height))
                }
            }
            .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
        }
        .frame(width: markerSize)
    }
}

private extension DownloadActivityKind {
    var title: LocalizedStringResource {
        switch self {
        case .added:
            LocalizedStringResource("Added", comment: "Timeline activity status")
        case .queued:
            LocalizedStringResource("Queued", comment: "Timeline activity status")
        case .started:
            LocalizedStringResource("Started", comment: "Timeline activity status")
        case .resumed:
            LocalizedStringResource("Resumed", comment: "Timeline activity status")
        case .paused:
            LocalizedStringResource("Paused", comment: "Timeline activity status")
        case .seedingStarted:
            LocalizedStringResource("Seeding Started", comment: "Timeline activity status")
        case .seedingStopped:
            LocalizedStringResource("Seeding Stopped", comment: "Timeline activity status")
        case .browserSessionRequired:
            LocalizedStringResource("Needs Browser", comment: "Timeline activity status")
        case .completed:
            LocalizedStringResource("Completed", comment: "Timeline activity status")
        case .failed:
            LocalizedStringResource("Failed", comment: "Timeline activity status")
        case .cancelled:
            LocalizedStringResource("Cancelled", comment: "Timeline activity status")
        }
    }

    var systemImage: String {
        switch self {
        case .added:
            "plus"
        case .queued:
            "clock"
        case .started:
            "play.fill"
        case .resumed:
            "forward.fill"
        case .paused:
            "pause.fill"
        case .seedingStarted:
            "arrow.up.circle.fill"
        case .seedingStopped:
            "stop.fill"
        case .browserSessionRequired:
            "globe"
        case .completed:
            "checkmark"
        case .failed:
            "exclamationmark"
        case .cancelled:
            "xmark"
        }
    }

    var tint: Color {
        switch self {
        case .added:
            .blue
        case .queued:
            .orange
        case .started, .resumed:
            .green
        case .paused:
            .yellow
        case .seedingStarted:
            .teal
        case .seedingStopped:
            .secondary
        case .browserSessionRequired:
            .mint
        case .completed:
            .green
        case .failed:
            .red
        case .cancelled:
            .secondary
        }
    }

    var sortPriority: Int {
        switch self {
        case .cancelled, .failed, .completed, .seedingStopped:
            8
        case .paused, .browserSessionRequired, .seedingStarted:
            7
        case .resumed:
            6
        case .started:
            5
        case .queued:
            4
        case .added:
            3
        }
    }
}

private struct DownloadDetailSection<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Download Detail") {
    DownloadDetailView(center: HarborPreviewFixtures.makeCenter())
        .frame(width: 420, height: 760)
}
