import Foundation
import XCTest
@testable import Harbor

private final class FakeNetworkBindingCatalog: NetworkBindingCataloging, @unchecked Sendable {
    nonisolated(unsafe) var resolvedBinding: ResolvedNetworkBinding?

    private let targets: [NetworkBindingTarget]
    private let eventLog: EventLog?

    init(
        targets: [NetworkBindingTarget],
        resolvedBinding: ResolvedNetworkBinding? = nil,
        eventLog: EventLog? = nil
    ) {
        self.targets = targets
        self.resolvedBinding = resolvedBinding
        self.eventLog = eventLog
    }

    func availableTargets() -> [NetworkBindingTarget] {
        [.any] + targets
    }

    func resolve(_ selection: NetworkBindingSelection) -> ResolvedNetworkBinding? {
        guard selection != .any else {
            return nil
        }
        eventLog?.record("resolvedBinding")
        return resolvedBinding
    }
}

private nonisolated final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ event: String) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

private let vpnSelection = NetworkBindingSelection.service(id: "vpn-service-id")

private func makeVPNCatalog(
    resolvedBinding: ResolvedNetworkBinding? = nil,
    eventLog: EventLog? = nil
) -> FakeNetworkBindingCatalog {
    FakeNetworkBindingCatalog(
        targets: [
            NetworkBindingTarget(
                selection: vpnSelection,
                displayName: "ProtonVPN",
                kind: .service
            ),
            NetworkBindingTarget(
                selection: .interface(name: "en0"),
                displayName: "en0",
                kind: .interface
            )
        ],
        resolvedBinding: resolvedBinding,
        eventLog: eventLog
    )
}

private func makeInterfaceTarget(
    name: String,
    medium: NetworkBindingMedium
) -> NetworkBindingTarget {
    NetworkBindingTarget(
        selection: .interface(name: name),
        displayName: name,
        kind: .interface,
        medium: medium
    )
}

@MainActor
final class NetworkBindingTests: XCTestCase {
    func testSelectionRoundTripsThroughStorageValue() {
        for selection in [
            NetworkBindingSelection.any,
            .service(id: "2EB5D77A-7174-4D95-A2C7-7512BEE9BD57"),
            .interface(name: "utun6")
        ] {
            XCTAssertEqual(
                NetworkBindingSelection(storageValue: selection.storageValue),
                selection
            )
        }
    }

    func testUnreadableStoredSelectionFallsBackToAny() {
        XCTAssertEqual(NetworkBindingSelection(storageValue: ""), .any)
        XCTAssertEqual(NetworkBindingSelection(storageValue: "nonsense"), .any)
        XCTAssertEqual(NetworkBindingSelection(storageValue: "service:"), .any)
        XCTAssertEqual(NetworkBindingSelection(storageValue: "interface:"), .any)
    }

    func testNetworkBindingSelectionDefaultsToAnyAndPersists() throws {
        let suiteName = "HarborTests.NetworkBindingSelection.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(
            userDefaults: userDefaults,
            networkBindingCatalog: makeVPNCatalog()
        )
        XCTAssertEqual(settings.networkBindingSelection, .any)

        var observedSelection: NetworkBindingSelection?
        settings.networkBindingDidChange = { observedSelection = $0 }
        settings.networkBindingSelection = vpnSelection

        XCTAssertEqual(observedSelection, vpnSelection)
        XCTAssertEqual(settings.networkBindingDisplayName, "ProtonVPN")

        let restoredSettings = AppSettingsStore(
            userDefaults: userDefaults,
            networkBindingCatalog: makeVPNCatalog()
        )
        XCTAssertEqual(restoredSettings.networkBindingSelection, vpnSelection)
        XCTAssertEqual(restoredSettings.networkBindingDisplayName, "ProtonVPN")
    }

    func testPickerKeepsAStoredSelectionThatNoLongerExists() throws {
        let suiteName = "HarborTests.NetworkBindingMissing.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(
            userDefaults: userDefaults,
            networkBindingCatalog: makeVPNCatalog()
        )
        settings.networkBindingSelection = vpnSelection

        // The VPN configuration is gone on the next launch.
        let restoredSettings = AppSettingsStore(
            userDefaults: userDefaults,
            networkBindingCatalog: FakeNetworkBindingCatalog(targets: [])
        )

        XCTAssertEqual(restoredSettings.networkBindingSelection, vpnSelection)
        let pickerTarget = try XCTUnwrap(
            restoredSettings.networkBindingPickerTargets
                .first { $0.selection == vpnSelection }
        )
        XCTAssertEqual(pickerTarget.displayName, "ProtonVPN (unavailable)")
    }

    func testIPv4EntriesResolveToABinding() {
        XCTAssertEqual(
            SystemNetworkBindingCatalog.binding(
                fromIPv4Entry: ["InterfaceName": "utun4", "Addresses": ["10.2.0.2"]]
            ),
            ResolvedNetworkBinding(interfaceName: "utun4", ipv4Address: "10.2.0.2")
        )

        // A service that is configured but not up carries no interface.
        XCTAssertNil(SystemNetworkBindingCatalog.binding(fromIPv4Entry: [:]))
        XCTAssertNil(
            SystemNetworkBindingCatalog.binding(fromIPv4Entry: ["InterfaceName": ""])
        )

        // An interface without an address still binds; aria2 resolves the
        // family itself.
        XCTAssertEqual(
            SystemNetworkBindingCatalog.binding(fromIPv4Entry: ["InterfaceName": "en0"]),
            ResolvedNetworkBinding(interfaceName: "en0", ipv4Address: nil)
        )
    }

    func testVPNServicesAreDistinguishableFromOrdinaryConnections() {
        XCTAssertEqual(SystemNetworkBindingCatalog.medium(forInterfaceType: "VPN"), .vpn)
        XCTAssertEqual(SystemNetworkBindingCatalog.medium(forInterfaceType: "IPSec"), .vpn)
        XCTAssertEqual(
            SystemNetworkBindingCatalog.medium(forInterfaceType: "IEEE80211"),
            .wireless
        )
        XCTAssertEqual(
            SystemNetworkBindingCatalog.medium(forInterfaceType: "Ethernet"),
            .wired
        )
        XCTAssertEqual(SystemNetworkBindingCatalog.medium(forInterfaceType: "Bridge"), .wired)
        // A service macOS cannot classify still gets a usable icon.
        XCTAssertEqual(SystemNetworkBindingCatalog.medium(forInterfaceType: nil), .other)
        XCTAssertEqual(NetworkBindingMedium.other.symbolName, "network")
        XCTAssertEqual(NetworkBindingMedium.vpn.symbolName, "lock.shield")
    }

    /// A tunnel is the point of this setting, so it has to lead the list even
    /// though its name sorts last.
    func testTargetsAreGroupedByMediumBeforeName() {
        let targets = NetworkBindingTarget.sortedByMedium([
            makeInterfaceTarget(name: "en10", medium: .wired),
            makeInterfaceTarget(name: "en2", medium: .wired),
            makeInterfaceTarget(name: "utun4", medium: .vpn),
            makeInterfaceTarget(name: "bridge0", medium: .other),
            makeInterfaceTarget(name: "en0", medium: .wireless),
            makeInterfaceTarget(name: "utun0", medium: .vpn)
        ])

        XCTAssertEqual(
            targets.map(\.displayName),
            ["utun0", "utun4", "en0", "en2", "en10", "bridge0"]
        )
    }

    /// macOS has no SCNetworkInterface for a tunnel that is not up, so the name
    /// carries the classification on its own.
    func testTunnelInterfacesAreClassifiedByName() {
        XCTAssertEqual(SystemNetworkBindingCatalog.medium(forInterfaceName: "utun4"), .vpn)
        XCTAssertEqual(SystemNetworkBindingCatalog.medium(forInterfaceName: "ipsec0"), .vpn)
        XCTAssertEqual(SystemNetworkBindingCatalog.medium(forInterfaceName: "ppp0"), .vpn)
        XCTAssertEqual(SystemNetworkBindingCatalog.medium(forInterfaceName: "en0"), .other)
    }

    func testOnlyUsableInterfacesAreOffered() {
        for name in ["en0", "en5", "utun4", "bridge0", "ppp0"] {
            XCTAssertTrue(
                SystemNetworkBindingCatalog.isOfferableInterfaceName(name),
                "\(name) should be offered"
            )
        }

        for name in ["lo0", "anpi0", "anpi1", "ap1", "awdl0", "llw0", "nan0", "gif0", "stf0"] {
            XCTAssertFalse(
                SystemNetworkBindingCatalog.isOfferableInterfaceName(name),
                "\(name) is an Apple-internal device and must stay out of the picker"
            )
        }
    }

    func testDaemonArgumentsBindTheInterfaceOnlyWhileBound() {
        func arguments(for networkBinding: NetworkBindingStatus) -> [String] {
            Aria2TorrentService.daemonArguments(
                sessionFilePath: "/tmp/aria2.session",
                stateDirectoryPath: "/tmp/aria2-next-state",
                rpcPort: 18_000,
                rpcSecret: "secret",
                hostProcessIdentifier: 42,
                transferSettings: .default,
                networkBinding: networkBinding
            )
        }

        let bound = arguments(
            for: .bound(
                displayName: "ProtonVPN",
                binding: ResolvedNetworkBinding(
                    interfaceName: "utun6",
                    ipv4Address: "10.2.0.2"
                )
            )
        )
        XCTAssertEqual(
            bound.filter { $0.hasPrefix("--bt-interface=") },
            ["--bt-interface=utun6"]
        )
        XCTAssertTrue(bound.contains("--state-dir=/tmp/aria2-next-state"))
        XCTAssertTrue(bound.contains("--rpc-listen-all=false"))

        for networkBinding in [
            NetworkBindingStatus.unrestricted,
            .unavailable(displayName: "ProtonVPN")
        ] {
            XCTAssertFalse(
                arguments(for: networkBinding).contains { $0.hasPrefix("--bt-interface=") }
            )
        }
    }

    func testAnUnavailableInterfaceIsTreatedAsTransientRatherThanFailure() {
        XCTAssertTrue(
            DownloadCenter.isTransientTorrentEngineError(
                TorrentEngineError.networkInterfaceUnavailable("ProtonVPN")
            ),
            "A suspended transfer must keep its status instead of failing"
        )
        XCTAssertFalse(
            DownloadCenter.isTransientTorrentEngineError(
                TorrentEngineError.rpc("Unauthorized")
            )
        )
    }

    func testNetworkSuspensionMarkerRoundTripsWithTheDownloadRecord() throws {
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(
                URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
            ),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .paused,
            wasSuspendedForNetworkBinding: true
        )

        let data = try JSONEncoder().encode(item.makeRecord())
        let restored = try JSONDecoder().decode(DownloadRecord.self, from: data)

        XCTAssertTrue(restored.wasSuspendedForNetworkBinding)
    }

    func testInitialAvailableNetworkStatusDoesNotErasePersistedDownloadsBeforeInitialization() async throws {
        let suiteName = "HarborTests.NetworkBindingInitialStatus.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let persistenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "HarborNetworkInitialStatusTests-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: persistenceRoot) }

        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let torrent = DownloadItem(
            sourceURL: try XCTUnwrap(
                URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
            ),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: persistenceRoot.path,
            status: .paused
        )
        try await persistence.save([torrent.makeRecord()])

        let settings = AppSettingsStore(
            userDefaults: userDefaults,
            networkBindingCatalog: makeVPNCatalog()
        )
        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            networkBindingMonitor: NetworkBindingMonitor(
                catalog: makeVPNCatalog(),
                debounceInterval: 0
            ),
            torrentService: Aria2TorrentService(daemonStartupOperation: { _ in })
        )

        try await Task.sleep(for: .milliseconds(400))

        let persistedDownloadIDs = try await persistence.load().map(\.id)
        XCTAssertEqual(persistedDownloadIDs, [torrent.id])

        await center.initializeIfNeeded()

        XCTAssertEqual(center.downloads.map(\.id), [torrent.id])
        _ = await center.shutdownForTermination()
    }

    func testEngineRefusesToStartWhileTheBoundInterfaceIsUnavailable() async {
        let service = Aria2TorrentService()
        await service.setNetworkBinding(.unavailable(displayName: "ProtonVPN"))

        do {
            _ = try await service.allKnownGIDs()
            XCTFail("The engine started without its bound interface")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.contains("ProtonVPN"),
                "Unexpected message: \(error.localizedDescription)"
            )
        }
    }

    func testStartupBindsTheEngineBeforeItRecoversTorrents() async throws {
        let suiteName = "HarborTests.NetworkBindingStartup.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborNetworkStartupTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        // The VPN is down while Harbor launches.
        let eventLog = EventLog()
        let catalog = makeVPNCatalog(resolvedBinding: nil, eventLog: eventLog)
        let settings = AppSettingsStore(
            userDefaults: userDefaults,
            networkBindingCatalog: catalog
        )
        // Set before the center exists, so no callback resolves the selection
        // ahead of the ordering this test measures.
        settings.networkBindingSelection = vpnSelection

        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            networkBindingMonitor: NetworkBindingMonitor(catalog: catalog, debounceInterval: 0),
            torrentService: Aria2TorrentService(
                daemonStartupOperation: { _ in eventLog.record("startedEngine") }
            )
        )
        await center.initializeIfNeeded()

        // Session recovery inside initializeIfNeeded reaches for the engine.
        // The binding has to be resolved and applied before it does.
        XCTAssertEqual(eventLog.recorded.first, "resolvedBinding")
        XCTAssertTrue(
            eventLog.recorded.contains("startedEngine"),
            "Expected startup to reach the torrent engine at all"
        )
        XCTAssertEqual(
            settings.networkBindingStatus,
            .unavailable(displayName: "ProtonVPN")
        )

        await center.shutdownForTermination()
    }

    func testLaunchWhileBindingIsUnavailablePersistsRestoredTorrentAsSuspended() async throws {
        let suiteName = "HarborTests.NetworkBindingRestore.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let persistenceRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborNetworkRestoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceRoot) }

        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let torrent = DownloadItem(
            sourceURL: try XCTUnwrap(
                URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
            ),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: persistenceRoot.path,
            status: .downloading
        )
        try await persistence.save([torrent.makeRecord()])

        let catalog = makeVPNCatalog(resolvedBinding: nil)
        let settings = AppSettingsStore(
            userDefaults: userDefaults,
            networkBindingCatalog: catalog
        )
        settings.networkBindingSelection = vpnSelection
        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            networkBindingMonitor: NetworkBindingMonitor(catalog: catalog, debounceInterval: 0),
            torrentService: Aria2TorrentService(daemonStartupOperation: { _ in })
        )

        await center.initializeIfNeeded()

        let restoredItem = try XCTUnwrap(center.downloads.first)
        XCTAssertEqual(restoredItem.status, .paused)
        XCTAssertTrue(restoredItem.wasSuspendedForNetworkBinding)
        let persistedRecords = try await persistence.load()
        let persistedRecord = try XCTUnwrap(persistedRecords.first)
        XCTAssertEqual(persistedRecord.status, .paused)
        XCTAssertTrue(persistedRecord.wasSuspendedForNetworkBinding)

        _ = await center.shutdownForTermination()
    }

    func testLosingTheBoundInterfacePausesTorrentsAndRegainingItResumesThem() async throws {
        let suiteName = "HarborTests.NetworkKillSwitch.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborNetworkKillSwitchTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let catalog = makeVPNCatalog(
            resolvedBinding: ResolvedNetworkBinding(
                interfaceName: "utun6",
                ipv4Address: "10.2.0.2"
            )
        )
        let settings = AppSettingsStore(
            userDefaults: userDefaults,
            networkBindingCatalog: catalog
        )
        let monitor = NetworkBindingMonitor(catalog: catalog, debounceInterval: 0)
        let startLog = EventLog()
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            networkBindingMonitor: monitor,
            torrentService: Aria2TorrentService(daemonStartupOperation: { _ in }),
            torrentPauseOperation: { _, _ in },
            torrentStartOperation: { _, _, sourceURL, _, _, _ in
                startLog.record(sourceURL.absoluteString)
                return "resumed-gid"
            }
        )
        await center.initializeIfNeeded()

        let activeTorrent = DownloadItem(
            sourceURL: try XCTUnwrap(
                URL(string: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
            ),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: persistenceRoot.path,
            status: .downloading
        )
        let manuallyPausedTorrent = DownloadItem(
            sourceURL: try XCTUnwrap(
                URL(string: "magnet:?xt=urn:btih:89abcdef0123456789abcdef0123456789abcdef")
            ),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: persistenceRoot.path,
            status: .paused
        )
        let activeSeeder = DownloadItem(
            sourceURL: try XCTUnwrap(
                URL(string: "magnet:?xt=urn:btih:fedcba9876543210fedcba9876543210fedcba98")
            ),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: persistenceRoot.path,
            status: .seeding,
            finishedAt: .now,
            shouldSeedAfterDownload: true
        )
        // Neither item carries an engine identifier, so the periodic torrent
        // status poll stays out of this test.
        center.downloads = [activeTorrent, manuallyPausedTorrent, activeSeeder]

        settings.networkBindingSelection = vpnSelection
        XCTAssertEqual(
            settings.networkBindingStatus,
            .bound(
                displayName: "ProtonVPN",
                binding: ResolvedNetworkBinding(
                    interfaceName: "utun6",
                    ipv4Address: "10.2.0.2"
                )
            )
        )
        XCTAssertEqual(activeTorrent.status, .downloading)

        catalog.resolvedBinding = nil
        monitor.refreshStatus()

        XCTAssertEqual(settings.networkBindingStatus, .unavailable(displayName: "ProtonVPN"))
        XCTAssertEqual(activeTorrent.status, .paused)
        XCTAssertEqual(manuallyPausedTorrent.status, .paused)
        XCTAssertEqual(activeSeeder.status, .paused)
        XCTAssertTrue(activeSeeder.shouldSeedAfterDownload)
        XCTAssertTrue(activeSeeder.wasSuspendedForNetworkBinding)

        let queuedDuringOutage = DownloadItem(
            sourceURL: try XCTUnwrap(
                URL(string: "magnet:?xt=urn:btih:00112233445566778899aabbccddeeff00112233")
            ),
            sourceKind: .magnetLink,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: persistenceRoot.path,
            status: .queued
        )
        center.downloads.append(queuedDuringOutage)
        center.resumeDownloads(ids: [queuedDuringOutage.id])
        XCTAssertEqual(queuedDuringOutage.status, .paused)
        XCTAssertTrue(queuedDuringOutage.wasSuspendedForNetworkBinding)

        // The VPN reconnects on a different interface, which is exactly why the
        // engine has to be rebound rather than merely restarted.
        catalog.resolvedBinding = ResolvedNetworkBinding(
            interfaceName: "utun7",
            ipv4Address: "10.2.0.3"
        )
        monitor.refreshStatus()

        for _ in 0 ..< 200 where startLog.recorded.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(
            Set(startLog.recorded),
            Set([
                activeTorrent.sourceURL.absoluteString,
                activeSeeder.sourceURL.absoluteString,
                queuedDuringOutage.sourceURL.absoluteString
            ]),
            "Only the torrents Harbor suspended may be restarted"
        )
        XCTAssertEqual(
            manuallyPausedTorrent.status,
            .paused,
            "A manually paused torrent must not be resumed by the network coming back"
        )
        XCTAssertTrue(
            activeSeeder.shouldSeedAfterDownload,
            "Network suspension must not turn the user’s seeding preference off"
        )

        await center.shutdownForTermination()
    }
}
