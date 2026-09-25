import Foundation

enum HarborAccessibility {
    static let root = "harbor.root"
    static let sidebar = "harbor.sidebar"
    static let downloadsTable = "downloads.table"
    static let newDownload = "toolbar.new-download"
    static let pauseResumeAll = "toolbar.pause-resume-all"
    static let inspector = "download.inspector"
    static let inspectorPrimaryAction = "download.inspector.primary-action"
    static let inspectorSecondaryAction = "download.inspector.secondary-action"
    static let inspectorMoreActions = "download.inspector.more-actions"

    static func sidebarFilter(_ filter: DownloadFilter) -> String {
        "sidebar.filter.\(filter.rawValue)"
    }

    static func downloadRow(_ id: UUID) -> String {
        "downloads.row.\(id.uuidString.lowercased())"
    }

    static func downloadStatus(_ status: DownloadStatus) -> String {
        "downloads.status.\(status.rawValue)"
    }

    static func downloadStatus(_ status: DownloadStatus, downloadID: UUID) -> String {
        "downloads.status.\(downloadID.uuidString.lowercased()).\(status.rawValue)"
    }

    static let addSheet = "add-download.sheet"
    static let addSourceMode = "add-download.source-mode"
    static let addSource = "add-download.source"
    static let addChooseTorrent = "add-download.choose-torrent"
    static let addCancel = "add-download.cancel"
    static let addPreview = "add-download.preview"
    static let addSubmit = "add-download.submit"
    static let addTryAsMedia = "add-download.try-as-media"
    static let addMediaPermission = "add-download.media-permission"
    static let addMediaMetadata = "add-download.media-metadata"

    static let torrentSheet = "torrent-contents.sheet"
    static let torrentTable = "torrent-contents.table"
    static let torrentSelectAll = "torrent-contents.select-all"
    static let torrentSelectNone = "torrent-contents.select-none"
    static let torrentCancel = "torrent-contents.cancel"
    static let torrentAdd = "torrent-contents.add"

    static let settingsGeneral = "settings.general"
    static let settingsDownloads = "settings.downloads"
    static let settingsTorrents = "settings.torrents"
    static let settingsNetworkInterfacePicker = "settings.torrents.networkInterface"
    static let settingsBandwidth = "settings.bandwidth"
    static let settingsUpdates = "settings.updates"
    static let settingsAcknowledgments = "settings.acknowledgments"

    static let browserSheet = "browser-download.sheet"
    static let browserWebView = "browser-download.web-view"
    static let browserCancel = "browser-download.cancel"
}
