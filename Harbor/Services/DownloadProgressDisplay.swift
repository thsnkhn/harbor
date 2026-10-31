import Foundation

// Keep only the latest progress before scheduling any main-thread work.
// Lifecycle events bypass this buffer and retain their existing attempt checks.
nonisolated final class PendingDownloadProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var direct: [UUID: DownloadEvent] = [:]
    private var media: [UUID: (UUID, MediaDownloadEvent)] = [:]

    func store(_ event: DownloadEvent, attempt: UUID) {
        lock.withLock { direct[attempt] = event }
    }

    func store(_ event: MediaDownloadEvent, attempt: UUID) {
        lock.withLock { media[attempt] = (attempt, event) }
    }

    func drain() -> ([DownloadEvent], [(UUID, MediaDownloadEvent)]) {
        lock.withLock {
            let result = (Array(direct.values), Array(media.values))
            direct.removeAll(keepingCapacity: true)
            media.removeAll(keepingCapacity: true)
            return result
        }
    }
}

// A time-weighted moving average of the engines' rate estimates. Sampling at
// display cadence prevents a chatty engine from receiving more weight.
nonisolated struct DownloadTransferStatistics {
    private struct Interval {
        let start: TimeInterval
        let end: TimeInterval
        let rate: Double
    }

    private var intervals: [Interval] = []
    private var lastDisplay: TimeInterval
    private var lastReport: TimeInterval
    private var latestRate: Double

    init(rate: Double, at time: TimeInterval) {
        latestRate = max(rate, 0)
        lastReport = time
        lastDisplay = time
    }

    mutating func record(rate: Double, at time: TimeInterval) {
        latestRate = max(rate, 0)
        lastReport = time
    }

    mutating func displaySpeed(at time: TimeInterval) -> Double {
        guard time > lastDisplay else { return 0 }
        // Torrent status is polled once a second. A missing poll must not keep
        // an old speed alive indefinitely; idle time contributes zero bytes.
        let reportEnd = min(time, lastReport + 2)
        if reportEnd > lastDisplay {
            intervals.append(Interval(start: lastDisplay, end: reportEnd, rate: latestRate))
        }
        if time > max(lastDisplay, reportEnd) {
            intervals.append(Interval(start: max(lastDisplay, reportEnd), end: time, rate: 0))
        }
        lastDisplay = time
        // TODO: Check this window against recordings from very slow links.
        let cutoff = time - 10
        intervals.removeAll { $0.end <= cutoff }
        let duration = intervals.reduce(0) { $0 + $1.end - max($1.start, cutoff) }
        let bytes = intervals.reduce(0) { $0 + $1.rate * ($1.end - max($1.start, cutoff)) }
        return duration >= 1 ? bytes / duration : 0
    }
}
