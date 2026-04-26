import AppKit
import SwiftUI

/// A `TextEditor` with a drag-to-resize handle on its bottom edge.
///
/// Height is persisted to `UserDefaults` per-`persistenceID`, so the field
/// stays the same height inside one session AND across launches. Use this
/// anywhere there's a prompt / instruction / notes box the user might want
/// to make bigger.
///
/// The persistence key is `amira.promptEditor.height.<persistenceID>` —
/// keep the ID stable for a given field across releases or the user will
/// silently lose their last height when the key changes.
@available(macOS 26.0, *)
struct ResizablePromptEditor: View {
    @Binding var text: String
    let persistenceID: String

    let minHeight: CGFloat
    let maxHeight: CGFloat

    private let defaultsKey: String
    @State private var height: CGFloat
    @State private var dragStartHeight: CGFloat?

    init(
        text: Binding<String>,
        persistenceID: String,
        minHeight: CGFloat = 60,
        maxHeight: CGFloat = 800,
        defaultHeight: CGFloat = 110
    ) {
        self._text = text
        self.persistenceID = persistenceID
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        let key = "amira.promptEditor.height.\(persistenceID)"
        self.defaultsKey = key
        let storedRaw = UserDefaults.standard.object(forKey: key) as? Double
        let stored = storedRaw.map { CGFloat($0) } ?? defaultHeight
        self._height = State(initialValue: min(max(stored, minHeight), maxHeight))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextEditor(text: $text)
                .frame(height: height)

            resizeHandle
        }
    }

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 10)
                .contentShape(Rectangle())

            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 40, height: 4)
        }
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartHeight == nil {
                        dragStartHeight = height
                    }
                    let proposed = (dragStartHeight ?? height) + value.translation.height
                    height = min(max(proposed, minHeight), maxHeight)
                }
                .onEnded { _ in
                    dragStartHeight = nil
                    UserDefaults.standard.set(Double(height), forKey: defaultsKey)
                }
        )
    }
}
