import AppKit

// Keep the native About panel as the single home for dependency credits.
enum HarborAcknowledgments {
    static var credits: NSAttributedString {
        let text = "Open Source Software\n\n" + OpenSourceAcknowledgment.all.map {
            "\($0.name)\n\($0.purpose)\n\($0.license)"
        }.joined(separator: "\n\n")
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
    }
}

private struct OpenSourceAcknowledgment: Identifiable {
    let name: String
    let license: String
    let purpose: String

    var id: String { name }

    static let all: [OpenSourceAcknowledgment] = [
        OpenSourceAcknowledgment(
            name: "aria2",
            license: "GNU GPL v2 or later",
            purpose: "Torrent and magnet downloads."
        ),
        OpenSourceAcknowledgment(
            name: "OpenVPN 3 Core",
            license: "Mozilla Public License 2.0",
            purpose: "Private OpenVPN connections for torrents."
        ),
        OpenSourceAcknowledgment(
            name: "WireGuard, gVisor, and BATorrent",
            license: "MIT and Apache 2.0",
            purpose: "Private WireGuard connections and the in-memory VPN network."
        ),
        OpenSourceAcknowledgment(
            name: "yt-dlp",
            license: "The Unlicense",
            purpose: "Media extraction and downloads."
        ),
        OpenSourceAcknowledgment(
            name: "Deno",
            license: "MIT License",
            purpose: "JavaScript execution for media extraction."
        ),
        OpenSourceAcknowledgment(
            name: "FFmpeg",
            license: "GNU GPL (bundled build)",
            purpose: "Media probing, conversion, and merging."
        )
    ]
}
