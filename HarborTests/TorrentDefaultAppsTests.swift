import Foundation
import XCTest
@testable import Harbor

@MainActor
final class TorrentDefaultAppsTests: XCTestCase {
    func testRefreshReadsBothSystemAssociationsAndExternalChanges() {
        let system = TestTorrentApplicationAssociations()
        system.applications[.torrentFiles] = harbor
        system.applications[.magnetLinks] = other
        let controller = TorrentDefaultAppsController(associations: system)
        controller.refresh()
        XCTAssertTrue(controller.isDefault(for: .torrentFiles))
        XCTAssertFalse(controller.isDefault(for: .magnetLinks))
        XCTAssertEqual(controller.applications[.magnetLinks]?.name, "Other App")

        system.applications[.torrentFiles] = other
        system.applications[.magnetLinks] = nil
        controller.refresh()
        XCTAssertFalse(controller.isDefault(for: .torrentFiles))
        XCTAssertNil(controller.applications[.magnetLinks])
        XCTAssertTrue(system.requests.isEmpty)
    }

    func testMakeDefaultChangesOnlyTheSelectedAssociationAndReadsBack() async {
        let system = TestTorrentApplicationAssociations()
        system.applications = [.torrentFiles: other, .magnetLinks: other]
        let controller = TorrentDefaultAppsController(associations: system)
        await controller.makeDefault(for: .torrentFiles)

        XCTAssertEqual(system.requests, [.torrentFiles])
        XCTAssertEqual(system.requestedURL, Bundle.main.bundleURL)
        XCTAssertTrue(controller.isDefault(for: .torrentFiles))
        XCTAssertFalse(controller.isDefault(for: .magnetLinks))
        XCTAssertNil(controller.updatingAssociation)
        XCTAssertTrue(controller.errors.isEmpty)
    }

    func testRejectedChangeKeepsCurrentDefaultAndAllowsRetry() async {
        let system = TestTorrentApplicationAssociations()
        system.applications[.magnetLinks] = other
        system.error = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Change declined"])
        let controller = TorrentDefaultAppsController(associations: system)
        await controller.makeDefault(for: .magnetLinks)

        XCTAssertEqual(controller.applications[.magnetLinks], other)
        XCTAssertEqual(controller.errors[.magnetLinks], "Change declined")
        XCTAssertNil(controller.updatingAssociation)

        system.error = nil
        await controller.makeDefault(for: .magnetLinks)
        XCTAssertTrue(controller.isDefault(for: .magnetLinks))
        XCTAssertNil(controller.errors[.magnetLinks])
    }

    func testPendingSystemConfirmationDoesNotStartAnotherRequest() async {
        let system = TestTorrentApplicationAssociations()
        system.waitForConfirmation = true
        let controller = TorrentDefaultAppsController(associations: system)
        let request = Task { await controller.makeDefault(for: .torrentFiles) }
        while system.confirmation == nil { await Task.yield() }
        XCTAssertEqual(controller.updatingAssociation, .torrentFiles)

        await controller.makeDefault(for: .magnetLinks)
        XCTAssertEqual(system.requests, [.torrentFiles])
        system.confirmation?.resume()
        await request.value
        XCTAssertNil(controller.updatingAssociation)
        XCTAssertTrue(controller.isDefault(for: .torrentFiles))
    }

    private var harbor: TorrentDefaultApplication {
        TorrentDefaultApplication(name: "Harbor", bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    private var other: TorrentDefaultApplication {
        TorrentDefaultApplication(name: "Other App", bundleIdentifier: "test.other")
    }
}

// TODO: Cover native consent with a system test that restores both original associations.
@MainActor
private final class TestTorrentApplicationAssociations: TorrentApplicationAssociating {
    var applications: [TorrentAssociation: TorrentDefaultApplication] = [:]
    var requests: [TorrentAssociation] = []
    var requestedURL: URL?
    var error: Error?
    var waitForConfirmation = false
    var confirmation: CheckedContinuation<Void, Never>?

    func defaultApplication(for association: TorrentAssociation) -> TorrentDefaultApplication? {
        applications[association]
    }

    func setDefaultApplication(at url: URL, for association: TorrentAssociation) async throws {
        requests.append(association)
        requestedURL = url
        if waitForConfirmation {
            await withCheckedContinuation { confirmation = $0 }
        }
        if let error { throw error }
        applications[association] = TorrentDefaultApplication(
            name: "Harbor", bundleIdentifier: Bundle(url: url)?.bundleIdentifier
        )
    }
}
