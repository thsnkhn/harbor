import Foundation

// Safari requires a principal class for the extension bundle. The extension talks to Harbor
// only through harbor:// and magnet: URLs, so this handler never receives native messages.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        context.completeRequest(returningItems: nil)
    }
}
