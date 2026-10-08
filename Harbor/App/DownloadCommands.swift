import SwiftUI

struct DownloadCommands: Commands {
    let center: DownloadCenter
    let updater: AppUpdater
    @FocusedValue(\.focusDownloadSearch) private var focusDownloadSearch
    @FocusedBinding(\.sidebarVisibility) private var sidebarVisibility

    var body: some Commands {
        CommandGroup(replacing: .sidebar) {
            Button(sidebarVisibility == .detailOnly ? "Show Sidebar" : "Hide Sidebar", systemImage: "sidebar.left") {
                withAnimation {
                    sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
                }
            }
            .keyboardShortcut("b")
            .disabled(sidebarVisibility == nil)
        }

        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommandView(updater: updater)
            Divider()
        }

        CommandMenu("Downloads") {
            Button("New Download...") {
                center.presentAddSheet()
            }
            .keyboardShortcut("n")
            .disabled(center.canAddDownloads == false)

            Button("Add from Clipboard") {
                center.addDownloadSourcesFromPasteboard()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .disabled(center.canAddDownloads == false)

            Button("Find Downloads") {
                focusDownloadSearch?()
            }
            .keyboardShortcut("f")
            .disabled(focusDownloadSearch == nil)

            Divider()

            Button("Pause or Resume Selected") {
                center.togglePauseResumeForSelection()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(center.canToggleSelectedDownload == false)

            Button("Retry Selected") {
                center.retrySelectedDownload()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(center.canRetrySelectedDownload == false)

            Button("Cancel Selected") {
                center.cancelSelectedDownload()
            }
            .disabled(center.canCancelSelectedDownload == false)

            Divider()

            Button("Pause All") {
                center.pauseAll()
            }
            .disabled(center.hasPausableDownloads == false)

            Button("Resume All") {
                center.resumeAll()
            }
            .disabled(center.hasResumableDownloads == false)

            Divider()

            Button("Reveal in Finder") {
                center.revealSelectedInFinder()
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(center.selectedDownload == nil)

            Button("Open Downloaded File") {
                center.openSelectedDownload()
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(center.canOpenSelectedDownload == false)

            Button("Quick Look") {
                center.quickLookSelectedDownloads()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(center.canQuickLookSelectedDownloads == false)

            Divider()

            Button("Remove Selected from List") {
                center.removeSelectedDownload()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(center.selectedDownload == nil)

            Button("Clear Completed") {
                center.clearCompleted()
            }
            .disabled(center.hasCompletedDownloads == false)

            Button("Clear Failed") {
                Task {
                    await center.clearFailed()
                }
            }
            .disabled(center.hasFailedDownloads == false)
        }
    }
}

struct FocusDownloadSearchKey: FocusedValueKey {
    typealias Value = () -> Void
}

struct SidebarVisibilityKey: FocusedValueKey {
    typealias Value = Binding<NavigationSplitViewVisibility>
}

extension FocusedValues {
    var sidebarVisibility: Binding<NavigationSplitViewVisibility>? {
        get { self[SidebarVisibilityKey.self] }
        set { self[SidebarVisibilityKey.self] = newValue }
    }

    var focusDownloadSearch: (() -> Void)? {
        get { self[FocusDownloadSearchKey.self] }
        set { self[FocusDownloadSearchKey.self] = newValue }
    }
}
