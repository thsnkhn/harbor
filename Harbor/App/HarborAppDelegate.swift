import AppKit

@MainActor
final class HarborAppDelegate: NSObject, NSApplicationDelegate {
    weak var center: DownloadCenter?
    let dockProgress = DockDownloadProgress()
    private var isTerminating = false

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard HarborTestRuntime.isUITesting else { return }

        DispatchQueue.main.async {
            let windows = NSApp.windows.filter(\.isVisible)
            windows.dropFirst().forEach { $0.close() }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating {
            return .terminateLater
        }

        guard let center else {
            return .terminateNow
        }

        isTerminating = true
        Task { @MainActor in
            let didSave = await center.shutdownForTermination()
            if didSave == false {
                isTerminating = false
            }
            sender.reply(toApplicationShouldTerminate: didSave)
        }
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handleOpenRequest(urls)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        let didHandle = handleOpenRequest(urls)

        sender.reply(toOpenOrPrint: didHandle ? .success : .failure)
    }

    @discardableResult
    private func handleOpenRequest(_ urls: [URL]) -> Bool {
        ExternalAddDownloadOpenCoordinator.shared.receive(urls: urls)
    }
}
