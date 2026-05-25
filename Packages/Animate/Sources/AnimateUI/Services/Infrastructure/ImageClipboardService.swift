import AppKit

@available(macOS 26.0, *)
@MainActor
enum ImageClipboardService {
    @discardableResult
    static func copyImage(at url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([image])
    }
}
