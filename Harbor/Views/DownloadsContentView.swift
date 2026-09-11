import SwiftUI

struct DownloadsContentView: View {
    let center: DownloadCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("downloads.table.columnCustomization")
    private var columnCustomization = TableColumnCustomization<DownloadItem>()
    @State private var pendingDataRemovalIDs: Set<UUID> = []

    var body: some View {
        @Bindable var center = center
        let downloads = center.filteredDownloads

        VStack(spacing: 0) {
            if downloads.isEmpty {
                emptyState
            } else {
                // Keep column widths stable as the inspector changes the visible table area.
                Table(
                    of: DownloadItem.self,
                    selection: downloadSelection,
                    sortOrder: $center.sortOrder,
                    columnCustomization: $columnCustomization
                ) {
                    TableColumn("Name", value: \.displayName) { item in
                        DownloadNameCell(item: item)
                            .accessibilityIdentifier(HarborAccessibility.downloadRow(item.id))
                    }
                    .width(300)
                    .customizationID("name")
                    .defaultVisibility(.visible)
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("Status", value: \.status.rawValue) { item in
                        if item.torrentCheckState == .checking {
                            Label("Checking Files…", systemImage: "checkmark.shield")
                                .font(.caption)
                                .accessibilityIdentifier("download.checkingStatus")
                        } else {
                            DownloadStatusBadge(status: item.status, downloadID: item.id)
                        }
                    }
                    .width(135)
                    .customizationID("status")
                    .defaultVisibility(.visible)

                    TableColumn("Transfer", value: \.progress) { item in
                        if item.torrentCheckState == .checking {
                            TorrentCheckProgressView(progress: item.torrentCheckProgress)
                        } else {
                            DownloadTransferCell(item: item)
                        }
                    }
                    .width(190)
                    .customizationID("transfer")
                    .defaultVisibility(.visible)

                    TableColumn("Source", value: \.sourceDisplayText) { item in
                        DownloadSourceCell(item: item)
                    }
                    .width(120)
                    .customizationID("source")
                    .defaultVisibility(.visible)

                    TableColumn("Speed", value: \.displayedSpeedBytesPerSecond) { item in
                        HStack(spacing: 6) {
                            if let mode = center.differingTrafficModeOverride(for: item) {
                                Image(systemName: mode.systemImage)
                                    .symbolVariant(.fill)
                                    .foregroundStyle(.secondary)
                                    .help(Text(mode.title))
                                    .accessibilityLabel(Text(mode.title))
                            }
                            Text(
                                item.status == .seeding
                                    ? DownloadFormatting.throughputString(item.uploadBytesPerSecond)
                                    : item.speedText
                            )
                            .monospacedDigit()
                        }
                    }
                    .width(140)
                    .customizationID("speed")
                    .defaultVisibility(.visible)

                    TableColumn("Created", value: \.createdAt) { item in
                        Text(DownloadFormatting.dateString(item.createdAt))
                            .font(.caption)
                    }
                    .width(170)
                    .customizationID("created")
                    .defaultVisibility(.visible)
                } rows: {
                    ForEach(downloads) { item in
                        TableRow(item)
                            .contextMenu {
                                rowContextMenu(for: item)
                            }
                    }
                }
                .accessibilityIdentifier(HarborAccessibility.downloadsTable)
            }
        }
        .navigationTitle(center.selectedFilter.title)
        .modifier(DownloadDataRemovalConfirmation(center: center, ids: $pendingDataRemovalIDs))
    }

    private var downloadSelection: Binding<Set<UUID>> {
        Binding(
            get: { center.selectedDownloadIDs },
            set: { ids in
                let changesInspectorVisibility = center.selectedDownloadIDs.isEmpty != ids.isEmpty
                // Animate the original selection update, not a later onChange callback.
                withAnimation(changesInspectorVisibility && reduceMotion == false ? .default : nil) {
                    center.selectedDownloadIDs = ids
                }
            }
        )
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyImage)
        } description: {
            Text(emptyDescription)
        } actions: {
            Button {
                center.presentAddSheet()
            } label: {
                Label("Add Download", systemImage: "plus")
            }
            .buttonStyle(LiquidPillButtonStyle(prominent: true))
            .accessibilityIdentifier(HarborAccessibility.newDownload)
            .disabled(center.canAddDownloads == false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: LocalizedStringResource {
        switch center.selectedFilter {
        case .all:
            "No Downloads Yet"
        case .active:
            "Nothing Running"
        case .paused:
            "No Paused Downloads"
        case .completed:
            "Nothing Completed"
        case .failed:
            "No Failures"
        case .cancelled:
            "No Cancelled Downloads"
        }
    }

    private var emptyImage: String {
        center.selectedFilter.systemImage
    }

    private var emptyDescription: LocalizedStringResource {
        switch center.selectedFilter {
        case .all:
            "Paste an HTTP or HTTPS URL to start building your queue."
        case .active:
            "Queued and running transfers appear here."
        case .paused:
            "Paused transfers and browser-required downloads stay here until you continue them."
        case .completed:
            "Finished files will stay listed until you clear them."
        case .failed:
            "Network or filesystem errors surface here with retry support."
        case .cancelled:
            "Cancelled items stay in history until you remove them."
        }
    }

    private func rowContextMenu(for item: DownloadItem) -> some View {
        DownloadSelectionActions(
            center: center,
            ids: center.contextMenuDownloadIDs(for: item.id),
            singleItem: item
        ) { pendingDataRemovalIDs = $0 }
    }

}

private struct DownloadNameCell: View {
    let item: DownloadItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.sourceBadgeImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)

                Text(item.partialTorrentSelectionText ?? item.sourceDisplayText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct DownloadTransferCell: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            progressView

            Text(transferSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private var transferSummary: String {
        guard item.status == .seeding else {
            return item.progressText
        }

        return "↑ \(item.uploadedText) • \(item.shareRatioText) ratio"
    }

    @ViewBuilder
    private var progressView: some View {
        if let progressValue = item.progressValue {
            ProgressView(value: progressValue, total: 1)
                .progressViewStyle(.linear)
        } else if item.status == .downloading || item.status == .preparing {
            ProgressView()
                .controlSize(.small)
        } else {
            ProgressView(value: item.progress, total: 1)
                .progressViewStyle(.linear)
        }
    }
}

private struct DownloadSourceCell: View {
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.sourceBadgeTitle)
                .lineLimit(1)

            Text(item.sourceHost)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

#Preview("Downloads List") {
    DownloadsContentView(center: HarborPreviewFixtures.makeCenter())
        .frame(width: 760, height: 520)
}
