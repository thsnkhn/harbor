import SwiftUI

struct DownloadsContentView: View {
    let center: DownloadCenter

    @AppStorage("downloads.table.columnCustomization")
    private var columnCustomization = TableColumnCustomization<DownloadItem>()

    var body: some View {
        @Bindable var center = center

        VStack(spacing: 0) {
            if center.filteredDownloads.isEmpty {
                emptyState
            } else {
                Table(
                    of: DownloadItem.self,
                    selection: $center.selectedDownloadID,
                    columnCustomization: $columnCustomization
                ) {
                    TableColumn("Name") { item in
                        DownloadNameCell(item: item)
                    }
                    .customizationID("name")
                    .defaultVisibility(.visible)
                    .disabledCustomizationBehavior(.visibility)

                    TableColumn("Status") { item in
                        DownloadStatusBadge(
                            status: item.status,
                            checksumState: item.checksumVerificationState
                        )
                    }
                    .customizationID("status")
                    .defaultVisibility(.visible)

                    TableColumn("Transfer") { item in
                        DownloadTransferCell(item: item)
                    }
                    .customizationID("transfer")
                    .defaultVisibility(.visible)

                    TableColumn("Source") { item in
                        DownloadSourceCell(item: item)
                    }
                    .customizationID("source")
                    .defaultVisibility(.visible)

                    TableColumn("Speed") { item in
                        Text(item.speedText)
                            .monospacedDigit()
                    }
                    .customizationID("speed")
                    .defaultVisibility(.visible)

                    TableColumn("Updated") { item in
                        Text(DownloadFormatting.dateString(item.updatedAt))
                            .font(.caption)
                    }
                    .customizationID("updated")
                    .defaultVisibility(.visible)
                } rows: {
                    ForEach(center.filteredDownloads) { item in
                        TableRow(item)
                            .contextMenu {
                                rowContextMenu(for: item)
                            }
                    }
                }
            }
        }
        .navigationTitle(center.selectedFilter.title)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: emptyImage)
        } description: {
            Text(emptyDescription)
        } actions: {
            Button("Add Download") {
                center.presentAddSheet()
            }
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

    @ViewBuilder
    private func rowContextMenu(for item: DownloadItem) -> some View {
        if item.status == .browserSessionRequired {
            Button("Continue in Harbor") {
                center.continueInBrowser(id: item.id)
            }
        } else {
            Button(item.canPause ? "Pause" : "Resume") {
                center.togglePauseResume(id: item.id)
            }
        }

        if item.status == .failed || item.status == .cancelled {
            Button("Retry") {
                center.retryDownload(id: item.id)
            }
        }

        if item.fileLocationURL != nil {
            Button("Open File") {
                center.openDownload(id: item.id)
            }
        }

        Button("Cancel Download") {
            center.cancelDownload(id: item.id)
        }
        .disabled(item.status == .completed || item.status == .cancelled)

        Divider()

        Button("Reveal in Finder") {
            center.revealInFinder(id: item.id)
        }

        Button("Copy Source URL") {
            center.copySourceURL(id: item.id)
        }

        Button("Remove from List", role: .destructive) {
            center.removeDownload(id: item.id)
        }
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

                Text(item.sourceDisplayText)
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

            Text(item.progressText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
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
