import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct ResizableSheetWindowAccessor: NSViewRepresentable {
    let minSize: NSSize
    let initialSize: NSSize?

    init(minSize: NSSize, initialSize: NSSize? = nil) {
        self.minSize = minSize
        self.initialSize = initialSize
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view, minSize: minSize, initialSize: initialSize)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView, minSize: minSize, initialSize: initialSize)
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private weak var window: NSWindow?
        private var appliedInitialSize = false
        private var minSize: NSSize = .zero
        private var initialSize: NSSize?

        func attach(to view: NSView, minSize: NSSize, initialSize: NSSize?) {
            self.view = view
            self.minSize = minSize
            self.initialSize = initialSize
            Task { @MainActor [weak self] in
                self?.installIfPossible()
            }
        }

        private func installIfPossible() {
            guard let view else { return }
            guard let resolvedWindow = view.window else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(20))
                    self?.installIfPossible()
                }
                return
            }

            if window !== resolvedWindow {
                window = resolvedWindow
                appliedInitialSize = false
            }

            resolvedWindow.styleMask.insert(.resizable)
            resolvedWindow.minSize = minSize
            if let initialSize, !appliedInitialSize {
                resolvedWindow.setContentSize(initialSize)
                appliedInitialSize = true
            }
        }
    }
}
