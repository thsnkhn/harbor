import AppKit

@MainActor
final class HarborAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
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
