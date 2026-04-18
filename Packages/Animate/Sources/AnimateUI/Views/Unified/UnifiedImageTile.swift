import AppKit
import SwiftUI

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

    private var effectivePath: String { resolvedPath ?? path }

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
        .contentShape(Rectangle())
        .modifier(TapHandlers(onTap: onTap, onDoubleTap: onDoubleTap))
    }

    private var thumbnailLayer: some View {
        CachedThumbnailView(path: effectivePath, size: thumbnailSize)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                    actions: actions
                )
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
        }
    }

    @ViewBuilder
    private var bottomCenterSlot: some View {
        if let bottomCenterOverlay {
            bottomCenterOverlay
        } else if isRejected {
            Image(systemName: "eye.slash.fill")
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
