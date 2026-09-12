import AppKit

@MainActor
final class DockDownloadProgress {
    private var updateTask: Task<Void, Never>?
    private let progressView = DockProgressView(icon: NSApp.applicationIconImage)

    func start(center: DownloadCenter) {
        guard updateTask == nil else { return }

        let tile = NSApp.dockTile
        progressView.frame = NSRect(origin: .zero, size: tile.size)
        progressView.autoresizingMask = [.width, .height]

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
                tile.contentView = nil
                tile.display()
            }
            return
        }

        let indeterminate = active.contains { $0.expectedBytes <= 0 }
        if indeterminate {
            progressView.progress = nil
        } else {
            let total = active.reduce(0.0) { $0 + Double($1.expectedBytes) }
            let received = active.reduce(0.0) {
                $0 + Double(min(max($1.bytesWritten, 0), $1.expectedBytes))
            }
            progressView.progress = received / total
        }
        progressView.animationPhase += 0.12
        progressView.needsDisplay = true
        tile.contentView = progressView
        tile.display()
    }
}

private final class DockProgressView: NSView {
    let icon: NSImage
    var progress: Double?
    var animationPhase = 0.0

    init(icon: NSImage) {
        self.icon = icon
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        icon.draw(in: bounds)

        let track = NSRect(
            x: bounds.width * 0.18,
            y: bounds.height * 0.18,
            width: bounds.width * 0.64,
            height: max(bounds.height * 0.12, 11)
        )
        let radius = track.height / 2
        let trackPath = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
        NSColor.black.withAlphaComponent(0.48).setFill()
        trackPath.fill()
        NSColor.white.withAlphaComponent(0.28).setStroke()
        trackPath.lineWidth = 1
        trackPath.stroke()

        let fill: NSRect
        if let progress {
            fill = NSRect(
                x: track.minX,
                y: track.minY,
                width: track.width * min(max(progress, 0), 1),
                height: track.height
            )
        } else {
            let segmentWidth = track.width * 0.3
            fill = NSRect(
                x: track.minX + (track.width - segmentWidth) * animationPhase.truncatingRemainder(dividingBy: 1),
                y: track.minY,
                width: segmentWidth,
                height: track.height
            )
        }

        guard fill.width > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()
        NSColor.systemOrange.setFill()
        fill.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
