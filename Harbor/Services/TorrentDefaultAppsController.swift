import AppKit
import Observation
import UniformTypeIdentifiers

enum TorrentAssociation: String, CaseIterable, Identifiable {
    case torrentFiles
    case magnetLinks

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .torrentFiles: "Torrent Files"
        case .magnetLinks: "Magnet Links"
        }
    }
}

struct TorrentDefaultApplication: Equatable {
    let name: String
    let bundleIdentifier: String?
}

@MainActor
protocol TorrentApplicationAssociating {
    func defaultApplication(for association: TorrentAssociation) -> TorrentDefaultApplication?
    func setDefaultApplication(at url: URL, for association: TorrentAssociation) async throws
}

struct SystemTorrentApplicationAssociations: TorrentApplicationAssociating {
    private let torrentType = UTType(importedAs: "org.bittorrent.torrent")

    func defaultApplication(for association: TorrentAssociation) -> TorrentDefaultApplication? {
        let url: URL?
        switch association {
        case .torrentFiles:
            url = NSWorkspace.shared.urlForApplication(toOpen: torrentType)
        case .magnetLinks:
            url = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "magnet:")!)
        }
        guard let url else { return nil }
        return TorrentDefaultApplication(
            name: url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: Bundle(url: url)?.bundleIdentifier
        )
    }

    func setDefaultApplication(at url: URL, for association: TorrentAssociation) async throws {
        switch association {
        case .torrentFiles:
            try await NSWorkspace.shared.setDefaultApplication(at: url, toOpen: torrentType)
        case .magnetLinks:
            try await NSWorkspace.shared.setDefaultApplication(at: url, toOpenURLsWithScheme: "magnet")
        }
    }
}

@Observable
@MainActor
final class TorrentDefaultAppsController {
    private let associations: any TorrentApplicationAssociating
    private(set) var applications: [TorrentAssociation: TorrentDefaultApplication] = [:]
    private(set) var updatingAssociation: TorrentAssociation?
    private(set) var errors: [TorrentAssociation: String] = [:]

    init(associations: (any TorrentApplicationAssociating)? = nil) {
        self.associations = associations ?? SystemTorrentApplicationAssociations()
    }

    func refresh() {
        for association in TorrentAssociation.allCases {
            applications[association] = associations.defaultApplication(for: association)
        }
    }

    func isDefault(for association: TorrentAssociation) -> Bool {
        guard let identifier = applications[association]?.bundleIdentifier else { return false }
        return identifier == Bundle.main.bundleIdentifier
    }

    func makeDefault(for association: TorrentAssociation) async {
        // The system can present consent UI. Keep one request active at a time.
        guard updatingAssociation == nil else { return }
        updatingAssociation = association
        errors[association] = nil
        defer {
            refresh()
            updatingAssociation = nil
        }

        do {
            try await associations.setDefaultApplication(at: Bundle.main.bundleURL, for: association)
        } catch {
            errors[association] = error.localizedDescription
        }
    }
}
