import AppKit
import Quartz

@available(macOS 26.0, *)
@MainActor
final class QuickLookPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    static let shared = QuickLookPreviewController()

    private var previewItems: [NSURL] = []

    private override init() {
        super.init()
    }

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func toggle(
        urls: [URL],
        startAt index: Int = 0
    ) {
        if isVisible {
            dismiss()
        } else {
            present(urls: urls, startAt: index)
        }
    }

    func dismiss() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func present(
        urls: [URL],
        startAt index: Int = 0
    ) {
        guard !urls.isEmpty else { return }

        previewItems = urls.map { $0 as NSURL }
        let clampedIndex = max(0, min(index, previewItems.count - 1))

        guard let panel = QLPreviewPanel.shared() else {
            NSWorkspace.shared.activateFileViewerSelecting([urls[clampedIndex]])
            return
        }

        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = clampedIndex
        panel.makeKeyAndOrderFront(nil)
    }

    func navigateTo(index: Int) {
        guard isVisible, previewItems.indices.contains(index) else { return }
        QLPreviewPanel.shared().currentPreviewItemIndex = index
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(
        in panel: QLPreviewPanel!
    ) -> Int {
        previewItems.count
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> QLPreviewItem! {
        previewItems[index]
    }
}
