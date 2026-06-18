import SwiftUI

struct DownloadStatusBadge: View {
    let status: DownloadStatus
    let checksumState: DownloadChecksumVerificationState?

    private var tint: Color {
        switch checksumState {
        case .verified:
            return .green
        case .failed:
            return .red
        case nil:
            break
        }

        switch status {
        case .queued:
            return .secondary
        case .preparing:
            return .orange
        case .downloading:
            return .blue
        case .browserSessionRequired:
            return .mint
        case .paused:
            return .yellow
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .secondary
        }
    }

    private var title: LocalizedStringResource {
        switch checksumState {
        case .verified:
            LocalizedStringResource("checksum.verified", defaultValue: "Verified")
        case .failed:
            LocalizedStringResource("checksum.failed", defaultValue: "Checksum failed")
        case nil:
            status.title
        }
    }

    private var systemImage: String {
        switch checksumState {
        case .verified:
            "checkmark.shield.fill"
        case .failed:
            "xmark.shield.fill"
        case nil:
            status.systemImage
        }
    }

    init(
        status: DownloadStatus,
        checksumState: DownloadChecksumVerificationState? = nil
    ) {
        self.status = status
        self.checksumState = checksumState
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.14), in: Capsule(style: .continuous))
    }
}
