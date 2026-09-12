import AppKit

@MainActor
final class DockDownloadProgress {
    private var updateTask: Task<Void, Never>?
    private let iconView = NSImageView()
    private let indicator = NSProgressIndicator()

    func start(center: DownloadCenter) {
        guard updateTask == nil else { return }

        let tile = NSApp.dockTile
        iconView.frame = NSRect(origin: .zero, size: tile.size)
        iconView.autoresizingMask = [.width, .height]
        iconView.image = NSApp.applicationIconImage
        indicator.style = .bar
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.frame = NSRect(
            x: tile.size.width * 0.12, y: tile.size.height * 0.12,
            width: tile.size.width * 0.76, height: 12
        )
        indicator.autoresizingMask = [.width, .minYMargin]
        iconView.addSubview(indicator)

        // Dock tiles require explicit redraws, including for indeterminate progress.
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
            if tile.contentView != nil {
                indicator.stopAnimation(nil)
                tile.contentView = nil
                tile.display()
            }
            return
        }

        let indeterminate = active.contains { $0.expectedBytes <= 0 }
        if indicator.isIndeterminate != indeterminate || tile.contentView == nil {
            indicator.stopAnimation(nil)
            indicator.isIndeterminate = indeterminate
            if indeterminate { indicator.startAnimation(nil) }
        }
        if !indeterminate {
            let total = active.reduce(0.0) { $0 + Double($1.expectedBytes) }
            let received = active.reduce(0.0) {
                $0 + Double(min(max($1.bytesWritten, 0), $1.expectedBytes))
            }
            indicator.doubleValue = received / total
        }
        tile.contentView = iconView
        tile.display()
    }
}
