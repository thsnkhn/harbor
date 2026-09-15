import Foundation

@MainActor
final class TorrentBlocklistController {
    nonisolated private static let automaticRefreshInterval: TimeInterval = 24 * 60 * 60

    private let settings: AppSettingsStore
    private let service: TorrentBlocklistService
    private let refreshInterval: TimeInterval
    private var updateTask: Task<Void, Never>?
    private var automaticRefreshTask: Task<Void, Never>?
    private var lastFailedRefresh: Date?

    init(
        settings: AppSettingsStore,
        service: TorrentBlocklistService,
        refreshInterval: TimeInterval = automaticRefreshInterval
    ) {
        self.settings = settings
        self.service = service
        self.refreshInterval = refreshInterval

        settings.torrentBlocklistSettingsDidChange = { [weak self] in
            self?.scheduleUpdate(forceRefresh: false)
        }
        settings.torrentBlocklistRefreshRequested = { [weak self] in
            guard self?.settings.torrentBlocklistEnabled == true else {
                return
            }
            self?.scheduleUpdate(forceRefresh: true)
        }
    }

    deinit {
        updateTask?.cancel()
        automaticRefreshTask?.cancel()
    }

    func activate() async {
        await update(forceRefresh: false)
        scheduleAutomaticRefresh()
    }

    private func scheduleUpdate(forceRefresh: Bool) {
        automaticRefreshTask?.cancel()
        let previousTask = updateTask
        previousTask?.cancel()
        updateTask = Task { @MainActor [weak self] in
            await previousTask?.value
            guard Task.isCancelled == false else {
                return
            }
            guard let self else {
                return
            }
            await self.update(forceRefresh: forceRefresh)
            if Task.isCancelled == false {
                self.updateTask = nil
                self.scheduleAutomaticRefresh()
            }
        }
    }

    private func scheduleAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        guard settings.torrentBlocklistEnabled else {
            automaticRefreshTask = nil
            return
        }

        let referenceDate = [settings.torrentBlocklistLastUpdated, lastFailedRefresh]
            .compactMap { $0 }
            .max()
        let elapsed = referenceDate.map { Date.now.timeIntervalSince($0) } ?? 0
        let delay = max(0, refreshInterval - elapsed)
        automaticRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard Task.isCancelled == false else {
                return
            }
            self?.scheduleUpdate(forceRefresh: true)
        }
    }

    private func update(forceRefresh: Bool) async {
        settings.setTorrentBlocklistRefreshing(true)
        defer { settings.setTorrentBlocklistRefreshing(false) }

        do {
            guard settings.torrentBlocklistEnabled else {
                try await service.disable()
                settings.markTorrentBlocklistDisabled()
                return
            }

            let status = if forceRefresh {
                try await service.refresh(
                    source: settings.torrentBlocklistURL,
                    proxySettings: settings.proxySettings
                )
            } else {
                try await service.activate(
                    source: settings.torrentBlocklistURL,
                    proxySettings: settings.proxySettings
                )
            }
            guard Task.isCancelled == false else {
                return
            }
            lastFailedRefresh = nil
            settings.updateTorrentBlocklistStatus(status)
        } catch {
            guard Task.isCancelled == false else {
                return
            }
            lastFailedRefresh = .now
            settings.updateTorrentBlocklistError(error)
        }
    }
}
