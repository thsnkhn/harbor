import AppKit
import SwiftUI

struct DownloadTagEditor: NSViewRepresentable {
    @Binding var tags: [String]
    var suggestions: [String]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTokenField {
        let field = NSTokenField()
        field.delegate = context.coordinator
        field.placeholderString = String(localized: "Add Tags")
        field.tokenStyle = .rounded
        field.tokenizingCharacterSet = .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        field.completionDelay = 0.15
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setAccessibilityLabel(String(localized: "Tags"))
        field.setAccessibilityIdentifier("download.tags")
        field.objectValue = tags
        return field
    }

    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastPublished != tags {
            field.objectValue = tags
            context.coordinator.lastPublished = tags
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTokenField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 180, height: 24)
    }

    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var parent: DownloadTagEditor
        var lastPublished: [String]

        init(_ parent: DownloadTagEditor) {
            self.parent = parent
            self.lastPublished = parent.tags
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTokenField else { return }
            let tags = DownloadTags.normalized(field.objectValue as? [String] ?? [])
            lastPublished = tags
            parent.tags = tags
            field.objectValue = tags
        }

        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            DownloadTags.normalized(tokens.compactMap { $0 as? String })
        }

        func tokenField(_ tokenField: NSTokenField, displayStringForRepresentedObject representedObject: Any) -> String? {
            (representedObject as? String).map { "#" + $0 }
        }

        func tokenField(_ tokenField: NSTokenField, editingStringForRepresentedObject representedObject: Any) -> String? {
            representedObject as? String
        }

        func tokenField(
            _ tokenField: NSTokenField,
            completionsForSubstring substring: String,
            indexOfToken tokenIndex: Int,
            indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
        ) -> [Any]? {
            let query = substring.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            let existing = Set((tokenField.objectValue as? [String] ?? []).map(DownloadTags.key))
            return parent.suggestions.filter {
                $0.localizedStandardContains(query) && !existing.contains(DownloadTags.key($0))
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            control.window?.makeFirstResponder(nil)
            return true
        }
    }
}
