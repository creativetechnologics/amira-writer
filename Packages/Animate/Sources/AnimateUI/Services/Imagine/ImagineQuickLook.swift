import AppKit
import Quartz

/// Opens the native macOS Quick Look panel (QLPreviewPanel) for a file URL.
/// This is the same panel that Finder uses when you press spacebar.
@available(macOS 26.0, *)
@MainActor
enum ImagineQuickLook {

    private static var currentDataSource: QuickLookDataSource?

    static func preview(url: URL) {
        let dataSource = QuickLookDataSource(urls: [url])
        currentDataSource = dataSource

        guard let panel = QLPreviewPanel.shared() else { return }

        panel.dataSource = dataSource
        panel.delegate = dataSource

        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.reloadData()
    }

    static func preview(urls: [URL], selectedIndex: Int = 0) {
        guard !urls.isEmpty else { return }
        let dataSource = QuickLookDataSource(urls: urls)
        currentDataSource = dataSource

        guard let panel = QLPreviewPanel.shared() else { return }

        panel.dataSource = dataSource
        panel.delegate = dataSource

        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        panel.currentPreviewItemIndex = selectedIndex
    }
}

@available(macOS 26.0, *)
private class QuickLookDataSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
        super.init()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }
}
