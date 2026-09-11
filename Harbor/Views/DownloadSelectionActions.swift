import SwiftUI

/// Shared by the row menu and the multi-selection inspector.
struct DownloadSelectionActions: View {
    let center: DownloadCenter
    let ids: Set<UUID>
    var singleItem: DownloadItem? = nil
    var usesGrid = false
    let requestDataRemoval: (Set<UUID>) -> Void

    var body: some View {
        if let item = singleItem, center.canContinueInBrowser(ids: ids) {
            action("Continue in Harbor", icon: "globe") { center.continueInBrowser(id: item.id) }
        }
        if center.canPauseDownloads(ids: ids) {
            action("Pause", icon: "pause.fill") { center.pauseDownloads(ids: ids) }
        }
        if center.canResumeDownloads(ids: ids) {
            action("Resume", icon: "play.fill") { center.resumeDownloads(ids: ids) }
        }
        if center.canRetryDownloads(ids: ids) {
            action("Retry", icon: "arrow.clockwise") { center.retryDownloads(ids: ids) }
        }
        if center.canOpenDownloads(ids: ids) {
            action("Open File", icon: "doc") { center.openDownloads(ids: ids) }
        }
        if center.canQuickLookDownloads(ids: ids) {
            action("Quick Look", icon: "eye") { center.quickLookDownloads(ids: ids) }
        }
        if ids.count == 1, let item = singleItem, item.backend == .aria2 {
            action("Check Files…", icon: "checkmark.shield") { center.checkTorrentFiles(id: item.id) }
            if item.status == .completed {
                action("Start Seeding", icon: "arrow.up.circle") { center.startSeeding(id: item.id) }
            }
            if item.status == .seeding || (item.status == .paused && item.finishedAt != nil && item.shouldSeedAfterDownload) {
                action("Stop Seeding", icon: "stop.circle") { center.stopSeeding(id: item.id) }
            }
        }
        action("Cancel Download", icon: "xmark.circle") { center.cancelDownloads(ids: ids) }
            .disabled(center.canCancelDownloads(ids: ids) == false)

        if usesGrid == false { Divider() }
        action("Reveal in Finder", icon: "folder") { center.revealInFinder(ids: ids) }
        action("Copy Source URL", icon: "link") { center.copySourceURLs(ids: ids) }
        action("Remove from List", icon: "list.bullet", role: .destructive) { center.removeDownloads(ids: ids) }
        if center.canRemoveDownloadedData(ids: ids) {
            action("Remove and Move Data to Trash…", icon: "trash", role: .destructive) { requestDataRemoval(ids) }
        }
    }

    @ViewBuilder
    private func action(
        _ title: LocalizedStringKey,
        icon: String,
        role: ButtonRole? = nil,
        perform: @escaping () -> Void
    ) -> some View {
        if usesGrid {
            if #available(macOS 26, *) {
                gridButton(title, icon: icon, role: role, perform: perform)
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
            } else {
                gridButton(title, icon: icon, role: role, perform: perform)
                    .buttonStyle(.bordered)
            }
        } else {
            Button(title, role: role, action: perform)
        }
    }

    private func gridButton(
        _ title: LocalizedStringKey,
        icon: String,
        role: ButtonRole?,
        perform: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: perform) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        }
        .buttonBorderShape(.roundedRectangle(radius: 10))
    }
}

struct DownloadDataRemovalConfirmation: ViewModifier {
    let center: DownloadCenter
    @Binding var ids: Set<UUID>

    func body(content: Content) -> some View {
        content
        .confirmationDialog(
            "Move Download Data to Trash?",
            isPresented: Binding(
                get: { ids.isEmpty == false },
                set: { isPresented in
                    if isPresented == false {
                        ids = []
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                let targetIDs = ids
                ids = []
                center.removeDownloadsAndData(ids: targetIDs)
            }

            Button("Cancel", role: .cancel) {
                ids = []
            }
        } message: {
            Text(center.dataRemovalConfirmationMessage(ids: ids))
        }
    }
}
