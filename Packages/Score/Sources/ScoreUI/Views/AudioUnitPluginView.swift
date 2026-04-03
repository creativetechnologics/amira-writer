#if canImport(AppKit)
import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit
import SwiftUI

// MARK: - Audio Unit Plugin View
// A SwiftUI view that wraps an AUViewController via NSViewControllerRepresentable.
// Loads the view controller from the AU's requestViewController method.
// Intended to be shown in a floating panel/window.

@available(macOS 26.0, *)
struct AudioUnitPluginView: NSViewControllerRepresentable {

    let audioUnit: AUAudioUnit

    func makeNSViewController(context: Context) -> AudioUnitPluginHostController {
        AudioUnitPluginHostController(audioUnit: audioUnit)
    }

    func updateNSViewController(_ nsViewController: AudioUnitPluginHostController, context: Context) {
        // No dynamic updates needed
    }
}

@available(macOS 26.0, *)
final class AudioUnitPluginHostController: NSViewController {

    private let audioUnit: AUAudioUnit
    private var auViewController: NSViewController?
    private let placeholderLabel: NSTextField

    init(audioUnit: AUAudioUnit) {
        self.audioUnit = audioUnit
        self.placeholderLabel = NSTextField(labelWithString: "Loading plugin UI...")
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        container.wantsLayer = true

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.font = .systemFont(ofSize: 14)
        placeholderLabel.textColor = .secondaryLabelColor
        placeholderLabel.alignment = .center
        container.addSubview(placeholderLabel)

        NSLayoutConstraint.activate([
            placeholderLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            placeholderLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        requestPluginView()
    }

    private func requestPluginView() {
        audioUnit.requestViewController { [weak self] viewController in
            DispatchQueue.main.async {
                guard let self else { return }
                if let vc = viewController {
                    self.embedPluginViewController(vc)
                } else {
                    self.showFallbackUI()
                }
            }
        }
    }

    private func embedPluginViewController(_ vc: NSViewController) {
        placeholderLabel.removeFromSuperview()

        addChild(vc)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(vc.view)

        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: view.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        auViewController = vc
    }

    private func showFallbackUI() {
        placeholderLabel.stringValue = "No UI available for this Audio Unit.\n\(audioUnit.componentName ?? "Unknown")"
        placeholderLabel.maximumNumberOfLines = 0
    }
}

// MARK: - Floating Panel Helper

@available(macOS 26.0, *)
@MainActor
func showAudioUnitPluginPanel(audioUnit: AUAudioUnit, title: String? = nil, onClose: (() -> Void)? = nil) {
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
        styleMask: [.titled, .closable, .resizable, .utilityWindow],
        backing: .buffered,
        defer: true
    )
    panel.title = title ?? audioUnit.componentName ?? "Audio Unit"
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true

    // Observe panel close to save AU preset state
    if let onClose {
        let delegate = AUPanelCloseDelegate(onClose: onClose)
        panel.delegate = delegate
        // Prevent delegate from being deallocated while panel is open
        objc_setAssociatedObject(panel, "closeDelegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    }

    let hostingView = NSHostingView(rootView: AudioUnitPluginView(audioUnit: audioUnit))
    panel.contentView = hostingView
    panel.center()
    panel.makeKeyAndOrderFront(nil)
}

@available(macOS 26.0, *)
private class AUPanelCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
#endif
