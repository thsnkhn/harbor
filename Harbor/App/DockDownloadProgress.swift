import AppKit

@MainActor
final class DockDownloadProgress {
    private var updateTask: Task<Void, Never>?

    func start(center: DownloadCenter) {
        guard updateTask == nil else { return }

        NSApp.dockTile.contentView = nil

        // Refresh aggregate progress without coupling Dock updates to each transfer callback.
        updateTask = Task { @MainActor [weak self, weak center] in
            while !Task.isCancelled {
                guard let self, let center else { return }
                self.update(downloads: center.downloads)
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    private func update(downloads: [DownloadItem]) {
        let tile = NSApp.dockTile
        let active = downloads.filter { $0.status == .downloading || $0.status == .preparing }
        guard !active.isEmpty else {
            if tile.badgeLabel != nil {
                tile.badgeLabel = nil
                tile.display()
            }
            return
        }

        let label: String
        if active.contains(where: { $0.expectedBytes <= 0 }) {
            label = "…"
        } else {
            let total = active.reduce(0.0) { $0 + Double($1.expectedBytes) }
            let received = active.reduce(0.0) {
                $0 + Double(min(max($1.bytesWritten, 0), $1.expectedBytes))
            }
            label = "\(Int((received / total * 100).rounded()))%"
        }

        if tile.badgeLabel != label {
            tile.badgeLabel = label
            tile.display()
        }
    }
}
