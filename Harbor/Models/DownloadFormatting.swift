import Foundation

enum DownloadFormatting {
    private static func byteFormatter() -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }

    private static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private static func durationFormatter() -> DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }

    static func byteString(_ byteCount: Int64) -> String {
        byteFormatter().string(fromByteCount: max(0, byteCount))
    }

    static func speedString(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else {
            return String(localized: "Waiting", comment: "Speed status fallback")
        }

        return "\(byteFormatter().string(fromByteCount: Int64(bytesPerSecond.rounded()))) / s"
    }

    static func throughputString(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else {
            return "0 KB/s"
        }

        return "\(byteFormatter().string(fromByteCount: Int64(bytesPerSecond.rounded())))/s"
    }

    static func progressString(bytesWritten: Int64, expectedBytes: Int64) -> String {
        guard expectedBytes > 0 else {
            return byteString(bytesWritten)
        }
        
        let template = String(localized: "progress.format", defaultValue: "%@ of %@", comment: "Download progress, e.g. '90 KB of 90 KB'")

        return String(format: template, byteString(bytesWritten), byteString(expectedBytes))
    }

    static func dateString(_ date: Date?) -> String {
        guard let date else {
            return String(localized: "Not available", comment: "Date fallback status")
        }

        return dateFormatter().string(from: date)
    }

    static func etaString(bytesRemaining: Int64, speedBytesPerSecond: Double) -> String? {
        guard bytesRemaining > 0, speedBytesPerSecond > 0 else {
            return nil
        }

        let eta = Double(bytesRemaining) / speedBytesPerSecond
        return durationFormatter().string(from: eta)
    }
}
