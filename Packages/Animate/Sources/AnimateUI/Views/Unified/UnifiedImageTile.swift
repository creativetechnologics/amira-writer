import AppKit
import SwiftUI

@available(macOS 26.0, *)
typealias UnifiedImageFlipHandler = @MainActor (String) -> Void

@available(macOS 26.0, *)
private struct UnifiedImageFlipHandlerKey: EnvironmentKey {
    static let defaultValue: UnifiedImageFlipHandler? = nil
}

@available(macOS 26.0, *)
extension EnvironmentValues {
    var unifiedImageFlipHandler: UnifiedImageFlipHandler? {
        get { self[UnifiedImageFlipHandlerKey.self] }
        set { self[UnifiedImageFlipHandlerKey.self] = newValue }
    }
}

/// The single, canonical image tile used by every photo grid in the app.
///
/// Rationale (Gary, Pass 3): "EVERY photo grid in this application needs to be
/// EXACTLY THE SAME." Prior passes unified the right-click menu but each grid
/// still had its own tile view, so corner radii / padding / borders drifted.
/// This view is the one-and-only tile anyone should render. If you want a
/// photo grid, you build a `LazyVGrid` full of these.
///
/// Visual spec (matches the Characters page `ImageGalleryThumbnail` Gary
/// explicitly called out as "the clean one"):
/// - Outer 12-corner-radius container, 6pt padding
/// - `accent @ 10%` background fill + 2pt accent stroke when `isSelected`
/// - Thumbnail body uses the shared `CachedThumbnailView` so async decode
///   happens off-main with a per-path NSCache hit
/// - Built-in optional overlays: source badge (top-leading), selection
///   checkmark (top-trailing), rejection eye.slash (bottom center),
///   rating pill (bottom-trailing). Each is opt-in via data.
/// - Grid-specific overlays inject via `topLeadingOverlay`,
///   `topTrailingOverlay`, `bottomLeadingOverlay`, `bottomCenterOverlay`,
///   `bottomTrailingOverlay`. When provided they REPLACE the built-in at
///   that slot.
/// - Caption row under the tile: optional curated star + optional text.
/// - Right-click menu always routes through `UnifiedImageContextMenuContent`.
@available(macOS 26.0, *)
struct UnifiedImageTile: View {
    @Environment(\.unifiedImageFlipHandler) private var flipHandler

    /// Identity/display path (may be relative). Kept separate from
    /// `resolvedPath` so callers pass whatever their selection/persistence
    /// layer uses, without double-resolving every render.
    let path: String
    /// Absolute path used for disk I/O. Falls back to `path` when nil.
    var resolvedPath: String? = nil
    let thumbnailSize: CGFloat
    var caption: String? = nil
    var sourceLabel: String? = nil
    var sourceSystemImage: String? = nil
    var isSelected: Bool = false
    var isCurated: Bool = false
    var isRejected: Bool = false
    var isLiked: Bool = false
    var hasNotes: Bool = false
    /// 1...5 star rating. Nil or 0 hides the badge.
    var rating: Int? = nil
    /// When true, a checkmark overlay is drawn at top-trailing on selection.
    /// Defaults to false so a plain selection paints only the border; grids
    /// that want the classic accent checkmark (Characters, Places) opt in.
    var showsSelectionCheckmark: Bool = false
    /// Used by the "Remove N Selected" right-click label.
    var selectedCount: Int = 0
    var actions: UnifiedImageActions = UnifiedImageActions()
    var onTap: () -> Void = {}
    var onDoubleTap: (() -> Void)? = nil
    /// Override slots. When non-nil, replace the built-in overlay at that
    /// corner. Use these for grid-specific widgets (LORA L, queue badges,
    /// "new" dots, inline remove buttons) that need custom interactivity.
    var topLeadingOverlay: AnyView? = nil
    var topTrailingOverlay: AnyView? = nil
    var bottomLeadingOverlay: AnyView? = nil
    var bottomCenterOverlay: AnyView? = nil
    var bottomTrailingOverlay: AnyView? = nil

    @State private var rightClickSpatialTagPoint: UnifiedImageSpatialTagPoint?
    @State private var imagePixelSize: CGSize?

    private var effectivePath: String { resolvedPath ?? path }
    private var dragURL: URL? { projectImageDragURL(forResolvedPath: resolvedPath ?? (path.hasPrefix("/") ? path : nil)) }
    private var effectiveActions: UnifiedImageActions {
        var updated = actions
        if updated.onFlipHorizontally == nil, let flipHandler {
            let flipPath = resolvedPath ?? path
            if !flipPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                updated.onFlipHorizontally = { flipHandler(flipPath) }
            }
        }
        return updated
    }

    var body: some View {
        // No captions under tiles, per Gary (2026-04-17): "All thumbnails
        // should be equidistant from each other. In ALL grids. NO FILENAMES."
        // The `caption` / `isCurated` params are still accepted so callers
        // don't have to change their call sites, but they no longer render.
        // The curated ★ is moved into the thumbnail's top-leading corner in
        // the rare cases callers want it (handled by sourceLabel overlay).
        VStack(spacing: 0) {
            thumbnailLayer
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : Color.clear,
                    lineWidth: isSelected ? 2 : 0
                )
        )
        .modifier(ProjectImageFileDragModifier(url: dragURL))
        .contentShape(Rectangle())
        .modifier(TapHandlers(onTap: onTap, onDoubleTap: onDoubleTap))
    }

    private var thumbnailLayer: some View {
        CachedThumbnailView(path: effectivePath, size: thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                UnifiedImageRightClickLocationReader(
                    imagePixelSize: imagePixelSize,
                    contentMode: .fill,
                    onRightClick: { point in
                        rightClickSpatialTagPoint = point
                    }
                )
            }
            .overlay(alignment: .topLeading) { topLeadingSlot }
            .overlay(alignment: .topTrailing) { topTrailingSlot }
            .overlay(alignment: .bottomLeading) { bottomLeadingSlot }
            .overlay(alignment: .bottom) { bottomCenterSlot }
            .overlay(alignment: .bottomTrailing) { bottomTrailingSlot }
            .opacity(isRejected ? 0.45 : 1.0)
            .contextMenu {
                UnifiedImageContextMenuContent(
                    selectedCount: selectedCount,
                    isSelected: isSelected,
                    actions: effectiveActions,
                    spatialTagPoint: rightClickSpatialTagPoint
                )
            }
            .task(id: effectivePath) {
                let currentPath = effectivePath
                let props = await Task.detached(priority: .utility) {
                    ImageAssetInspector.imageProperties(path: currentPath)
                }.value
                guard !Task.isCancelled, currentPath == effectivePath else { return }
                if let props {
                    imagePixelSize = CGSize(width: CGFloat(props.width), height: CGFloat(props.height))
                } else {
                    imagePixelSize = nil
                }
            }
    }

    // MARK: - Overlay slots

    @ViewBuilder
    private var topLeadingSlot: some View {
        if let topLeadingOverlay {
            topLeadingOverlay
        } else if let sourceLabel {
            HStack(spacing: 3) {
                if let sourceSystemImage {
                    Image(systemName: sourceSystemImage)
                }
                Text(sourceLabel)
            }
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.white)
            .padding(4)
        }
    }

    @ViewBuilder
    private var topTrailingSlot: some View {
        if let topTrailingOverlay {
            topTrailingOverlay
        } else if isSelected && showsSelectionCheckmark {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.white, Color.accentColor)
                .padding(6)
        }
    }

    @ViewBuilder
    private var bottomLeadingSlot: some View {
        if let bottomLeadingOverlay {
            bottomLeadingOverlay
        } else if hasNotes {
            Image(systemName: "note.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 4)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(4)
        }
    }

    @ViewBuilder
    private var bottomCenterSlot: some View {
        if let bottomCenterOverlay {
            bottomCenterOverlay
        } else if isRejected {
            Image(systemName: "hand.thumbsdown.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                .padding(6)
        } else if isLiked {
            Image(systemName: "hand.thumbsup.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                .padding(6)
        }
    }

    @ViewBuilder
    private var bottomTrailingSlot: some View {
        if let bottomTrailingOverlay {
            bottomTrailingOverlay
        } else if let rating, rating > 0 {
            HStack(spacing: 1) {
                ForEach(0..<min(rating, 5), id: \.self) { _ in
                    Image(systemName: "star.fill")
                        .font(.system(size: 7))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Color.black.opacity(0.55), in: Capsule())
            .foregroundStyle(.yellow)
            .padding(4)
        }
    }

    // `captionLayer` intentionally removed per app-wide "no filenames under
    // thumbnails" rule (see top-level comment in `body`). The `caption` and
    // `isCurated` parameters are retained on the public API so grid call
    // sites compile unchanged; they are inert at render time.
}

/// Separate modifier so the single/double tap pair doesn't fight SwiftUI's
/// gesture precedence. Double tap (if provided) always runs first; single
/// tap runs only when no double tap is installed or the double didn't fire.
@available(macOS 26.0, *)
private struct TapHandlers: ViewModifier {
    let onTap: () -> Void
    let onDoubleTap: (() -> Void)?

    func body(content: Content) -> some View {
        if let onDoubleTap {
            content
                .onTapGesture(count: 2) { onDoubleTap() }
                .onTapGesture { onTap() }
        } else {
            content.onTapGesture { onTap() }
        }
    }
}

@available(macOS 26.0, *)
private struct UnifiedImageRightClickLocationReader: NSViewRepresentable {
    let imagePixelSize: CGSize?
    let contentMode: ContentMode
    let onRightClick: (UnifiedImageSpatialTagPoint?) -> Void

    func makeNSView(context: Context) -> RightClickLocationView {
        let view = RightClickLocationView()
        view.onRightClick = onRightClick
        view.imagePixelSize = imagePixelSize
        view.contentMode = contentMode
        return view
    }

    func updateNSView(_ nsView: RightClickLocationView, context: Context) {
        nsView.onRightClick = onRightClick
        nsView.imagePixelSize = imagePixelSize
        nsView.contentMode = contentMode
    }

    final class RightClickLocationView: NSView {
        var imagePixelSize: CGSize?
        var contentMode: ContentMode = .fill
        var onRightClick: ((UnifiedImageSpatialTagPoint?) -> Void)?
        private var monitor: Any?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installMonitorIfNeeded()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                removeMonitor()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        override func removeFromSuperview() {
            removeMonitor()
            super.removeFromSuperview()
        }

        private func installMonitorIfNeeded() {
            guard monitor == nil, window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown]) { [weak self] event in
                self?.capture(event)
                return event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func capture(_ event: NSEvent) {
            guard let window,
                  event.window === window,
                  !isHiddenOrHasHiddenAncestor else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard bounds.contains(point) else { return }
            onRightClick?(normalizedImagePoint(for: point))
        }

        private func normalizedImagePoint(for point: CGPoint) -> UnifiedImageSpatialTagPoint? {
            guard let imagePixelSize,
                  imagePixelSize.width > 0,
                  imagePixelSize.height > 0,
                  bounds.width > 0,
                  bounds.height > 0 else { return nil }

            let imageAspect = imagePixelSize.width / imagePixelSize.height
            let boundsAspect = bounds.width / bounds.height
            let displaySize: CGSize
            switch contentMode {
            case .fill:
                if imageAspect > boundsAspect {
                    displaySize = CGSize(width: bounds.height * imageAspect, height: bounds.height)
                } else {
                    displaySize = CGSize(width: bounds.width, height: bounds.width / imageAspect)
                }
            default:
                if imageAspect > boundsAspect {
                    displaySize = CGSize(width: bounds.width, height: bounds.width / imageAspect)
                } else {
                    displaySize = CGSize(width: bounds.height * imageAspect, height: bounds.height)
                }
            }

            let imageRect = CGRect(
                x: (bounds.width - displaySize.width) / 2,
                y: (bounds.height - displaySize.height) / 2,
                width: displaySize.width,
                height: displaySize.height
            )
            guard imageRect.contains(point) else { return nil }

            let x = (point.x - imageRect.minX) / imageRect.width
            let y = (point.y - imageRect.minY) / imageRect.height
            return UnifiedImageSpatialTagPoint(
                normalizedX: min(max(Double(x), 0), 1),
                normalizedY: min(max(Double(y), 0), 1)
            )
        }
    }
}
