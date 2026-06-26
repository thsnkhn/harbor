import AppKit

@MainActor
final class HarborAppDelegate: NSObject, NSApplicationDelegate {
    weak var center: DownloadCenter?
    private var isTerminating = false

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
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
            await center.shutdownForTermination()
            sender.reply(toApplicationShouldTerminate: true)
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
