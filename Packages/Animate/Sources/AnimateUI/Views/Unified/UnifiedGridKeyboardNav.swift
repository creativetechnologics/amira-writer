import SwiftUI

/// Tracks grid width so we can derive column count for up/down arrow keyboard
/// navigation. LazyVGrid with `.adaptive(minimum:maximum:)` doesn't expose
/// its column count, so we compute it from the available width and tile
/// minimum.
///
/// Attach `UnifiedGridColumnTracker` to the grid's container (typically a
/// GeometryReader wrapper), and it writes the computed column count into the
/// provided binding whenever the container resizes. Callers can then use
/// `columnCount` to move focus by a row at a time in up/down handlers.
@available(macOS 26.0, *)
struct UnifiedGridColumnTracker: ViewModifier {
    @Binding var columnCount: Int
    let tileMinWidth: CGFloat
    let spacing: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: GridWidthPreferenceKey.self,
                            value: proxy.size.width
                        )
                }
            )
            .onPreferenceChange(GridWidthPreferenceKey.self) { width in
                let denom = max(1, tileMinWidth + spacing)
                let cols = max(1, Int((width + spacing) / denom))
                if cols != columnCount {
                    columnCount = cols
                }
            }
    }
}

@available(macOS 26.0, *)
private struct GridWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > value { value = next }
    }
}

@available(macOS 26.0, *)
extension View {
    /// Track the visible width of a LazyVGrid container and derive column
    /// count for up/down arrow keyboard navigation.
    func trackGridColumnCount(
        _ columnCount: Binding<Int>,
        tileMinWidth: CGFloat,
        spacing: CGFloat = 12
    ) -> some View {
        modifier(
            UnifiedGridColumnTracker(
                columnCount: columnCount,
                tileMinWidth: tileMinWidth,
                spacing: spacing
            )
        )
    }
}

/// Computes the next focus index for a 2D grid given the current index,
/// total count, column count, and directional input.
///
/// Horizontal arrows wrap to the previous/next row's edge. Vertical arrows
/// jump by `columnCount`; at the edges they clamp (don't wrap), matching
/// Finder's behavior.
@available(macOS 26.0, *)
enum UnifiedGridNavigation {
    enum Direction { case left, right, up, down }

    static func nextIndex(
        currentIndex: Int,
        totalCount: Int,
        columnCount: Int,
        direction: Direction
    ) -> Int? {
        guard totalCount > 0 else { return nil }
        let cols = max(1, columnCount)
        let idx = max(0, min(currentIndex, totalCount - 1))
        switch direction {
        case .left:
            return idx > 0 ? idx - 1 : nil
        case .right:
            return idx < totalCount - 1 ? idx + 1 : nil
        case .up:
            let candidate = idx - cols
            return candidate >= 0 ? candidate : nil
        case .down:
            let candidate = idx + cols
            return candidate < totalCount ? candidate : nil
        }
    }
}
