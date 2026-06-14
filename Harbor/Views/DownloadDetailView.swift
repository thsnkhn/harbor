import SwiftUI

struct DownloadDetailView: View {
    let center: DownloadCenter

    var body: some View {
        Group {
            if let item = center.selectedDownload {
                DownloadInspectorContent(item: item, center: center)
            } else {
                EmptyDownloadDetailView(addDownload: center.presentAddSheet)
            }
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
                    openFile: openFile,
                    revealInFinder: revealInFinder,
                    copySourceURL: copySourceURL
                )

                DownloadTransferSection(item: item)
                DownloadStorageSection(item: item)
                if item.backend == .aria2 {
                    DownloadTrackersSection(item: item, center: center)
                }
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

                if let message = item.displayLastError, item.status == .failed {
                    DownloadCallout(
                        title: "Last Error",
                        message: message,
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .red
                    )
                }
            }
            .padding(24)
        }
        .navigationTitle(item.displayName)
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

    private func openFile() {
        center.openDownload(id: item.id)
    }

    private func revealInFinder() {
        center.revealInFinder(id: item.id)
    }

    private func copySourceURL() {
        center.copySourceURL(id: item.id)
    }
}

private struct EmptyDownloadDetailView: View {
    let addDownload: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Select a Download", systemImage: "sidebar.right")
        } description: {
            Text("Choose any row to inspect progress, speed, file location, and recovery actions.")
        } actions: {
            Button(action: addDownload) {
                Label("Add Download", systemImage: "plus")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: true))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DownloadHeader: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.sourceBadgeImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.displayName)
                        .font(.title2.weight(.semibold))
                        .lineLimit(3)

                    sourceLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                DownloadStatusBadge(status: item.status)
            }

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
                Text("Progress")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)

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
        case .queued, .preparing:
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
        }
    }
}

private struct DownloadActionRow: View {
    let item: DownloadItem
    let continueInBrowser: () -> Void
    let togglePauseResume: () -> Void
    let retry: () -> Void
    let openFile: () -> Void
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
        } else {
            let isPause = item.canPause

            Button(action: togglePauseResume) {
                Label(isPause ? "Pause" : "Resume", systemImage: isPause ? "pause.fill" : "play.fill")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: true))
        }
    }

    @ViewBuilder
    private var secondaryAction: some View {
        if item.status == .failed || item.status == .cancelled {
            Button(action: retry) {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: false))
        } else if item.fileLocationURL != nil {
            Button(action: openFile) {
                Label("Open", systemImage: "doc.fill")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: false))
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
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .buttonStyle(LiquidPillButtonStyle(prominent: false))
    }
}

private struct DownloadTransferSection: View {
    let item: DownloadItem

    var body: some View {
        DownloadDetailSection(title: "Transfer") {
            VStack(spacing: 0) {
                DownloadedTransferRow(item: item)

                if let eta = item.etaText {
                    Divider()
                    DownloadValueRow(title: "ETA", value: eta)
                }
            }
        }
    }
}

private struct DownloadedTransferRow: View {
    let item: DownloadItem

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 14) {
                downloadedValue
                Spacer(minLength: 12)
                speedValues
            }
            .padding(.vertical, 9)

            VStack(alignment: .leading, spacing: 8) {
                downloadedValue
                speedValues
            }
            .padding(.vertical, 9)
        }
    }

    private var downloadedValue: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Downloaded")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            Text(item.progressText)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private var speedValues: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Speed")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                SpeedValue(
                    systemImage: "arrow.down",
                    value: item.speedText,
                    accessibilityLabel: "Download speed"
                )

                if item.backend == .aria2 {
                    SpeedValue(
                        systemImage: "arrow.up",
                        value: DownloadFormatting.throughputString(item.uploadBytesPerSecond),
                        accessibilityLabel: "Upload speed"
                    )
                }
            }
        }
    }
}

private struct SpeedValue: View {
    let systemImage: String
    let value: String
    let accessibilityLabel: String

    var body: some View {
        Label {
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .monospacedDigit()
                .textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .accessibilityHidden(true)
        }
        .accessibilityLabel("\(accessibilityLabel): \(value)")
    }
}

private struct DownloadStorageSection: View {
    let item: DownloadItem

    var body: some View {
        DownloadDetailSection(title: "Storage") {
            VStack(spacing: 0) {
                DownloadValueRow(title: "Destination", value: item.destinationFolderPath)

                if let fileLocationPath = item.fileLocationPath {
                    Divider()
                    DownloadValueRow(title: "Saved File", value: fileLocationPath)
                }
            }
        }
    }
}

private struct DownloadTrackersSection: View {
    let item: DownloadItem
    let center: DownloadCenter

    @State private var trackerURL = ""

    var body: some View {
        DownloadDetailSection(title: "Trackers") {
            VStack(alignment: .leading, spacing: 10) {
                trackerInput

                if item.displayedTrackers.isEmpty {
                    Text("No trackers reported yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 9)
                } else {
                    VStack(spacing: 0) {
                        let trackers = item.displayedTrackers

                        ForEach(Array(trackers.enumerated()), id: \.element.id) { index, tracker in
                            TorrentTrackerRow(
                                tracker: tracker,
                                isManual: item.manualTrackerURLs.contains(tracker.url),
                                remove: {
                                    center.removeManualTracker(tracker.url, from: item.id)
                                }
                            )

                            if index < trackers.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
            }
        }
    }

    private var trackerInput: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                trackerTextField
                addButton
                refreshButton
            }

            VStack(alignment: .leading, spacing: 8) {
                trackerTextField
                HStack(spacing: 8) {
                    addButton
                    refreshButton
                }
            }
        }
    }

    private var trackerTextField: some View {
        TextField("Tracker URL", text: $trackerURL)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220)
            .onSubmit(addTracker)
    }

    private var addButton: some View {
        Button(action: addTracker) {
            Label("Add", systemImage: "plus")
        }
        .buttonStyle(LiquidPillButtonStyle(prominent: false))
        .disabled(trackerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var refreshButton: some View {
        Button {
            center.refreshTorrentTrackers(id: item.id)
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(LiquidPillButtonStyle(prominent: false))
        .help("Refresh tracker list")
    }

    private func addTracker() {
        if center.addTracker(trackerURL, to: item.id) {
            trackerURL = ""
        }
    }
}

private struct TorrentTrackerRow: View {
    let tracker: TorrentTracker
    let isManual: Bool
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tracker.url)
                    .font(.callout)
                    .lineLimit(2)
                    .textSelection(.enabled)

                trackerMetadata
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isManual {
                Button(action: remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove tracker")
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var trackerMetadata: some View {
        if let errorMessage = tracker.errorMessage, errorMessage.isEmpty == false {
            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
                .textSelection(.enabled)
        } else if let status = tracker.status, status.isEmpty == false {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if isManual {
            Text("Manual")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
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
                        isLast: index == activityEntries.count - 1
                    )
                }
            }
        }
    }

    private var entries: [DownloadActivityTimelineEntry] {
        var entries = item.activityEvents.map { event in
            DownloadActivityTimelineEntry(event: event)
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
        case .preparing, .downloading:
            if entries.contains(where: { $0.kind == .started || $0.kind == .resumed }) == false {
                appendSyntheticEvent(kind: .started, timestamp: item.startedAt ?? item.updatedAt, to: &entries)
            }
        case .browserSessionRequired:
            appendSyntheticEvent(kind: .browserSessionRequired, timestamp: item.updatedAt, to: &entries)
        case .paused:
            appendSyntheticEvent(kind: .paused, timestamp: item.updatedAt, to: &entries)
        case .completed:
            appendSyntheticEvent(kind: .completed, timestamp: item.finishedAt ?? item.updatedAt, to: &entries)
        case .failed:
            appendSyntheticEvent(kind: .failed, timestamp: item.updatedAt, to: &entries)
        case .cancelled:
            appendSyntheticEvent(kind: .cancelled, timestamp: item.updatedAt, to: &entries)
        }
    }

    private func appendSyntheticEvent(
        kind: DownloadActivityKind,
        timestamp: Date,
        to entries: inout [DownloadActivityTimelineEntry]
    ) {
        guard entries.contains(where: { $0.kind == kind }) == false else {
            return
        }

        entries.append(
            DownloadActivityTimelineEntry(
                id: "synthetic-\(kind.rawValue)-\(item.id.uuidString)",
                kind: kind,
                timestamp: timestamp
            )
        )
    }
}

private struct DownloadActivityTimelineEntry: Identifiable {
    let id: String
    let kind: DownloadActivityKind
    let timestamp: Date

    init(event: DownloadActivityEvent) {
        self.id = event.id.uuidString
        self.kind = event.kind
        self.timestamp = event.timestamp
    }

    init(
        id: String,
        kind: DownloadActivityKind,
        timestamp: Date
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
    }
}

private struct DownloadActivityRow: View {
    let entry: DownloadActivityTimelineEntry
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                ZStack {
                    Circle()
                        .fill(entry.kind.tint.opacity(0.14))

                    Image(systemName: entry.kind.systemImage)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(entry.kind.tint)
                        .accessibilityHidden(true)
                }
                .frame(width: 22, height: 22)

                if isLast == false {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.22))
                        .frame(width: 1, height: 18)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.kind.title)
                    .font(.callout.weight(.medium))

                Text(DownloadFormatting.dateString(entry.timestamp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 1)
        }
        .padding(.vertical, 6)
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
        case .cancelled, .failed, .completed:
            8
        case .paused, .browserSessionRequired:
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

private struct LiquidPillButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(minHeight: 32)
            .foregroundStyle(prominent ? Color.white : Color.secondary)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)

        if #available(macOS 26, *) {
            label
                .glassEffect(
                    prominent ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                    in: .rect(cornerRadius: 16)
                )
        } else {
            label
                .background(
                    prominent ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            prominent ? Color.accentColor.opacity(0.24) : Color.secondary.opacity(0.16)
                        )
                }
        }
    }
}

#Preview("Download Detail") {
    DownloadDetailView(center: HarborPreviewFixtures.makeCenter())
        .frame(width: 420, height: 760)
}
