import AppKit
import SwiftUI

/// Reusable thumbnail view that never blocks the main thread for image decode.
///
/// On every render it first asks the store for a **cached** thumbnail
/// (`cachedThumbnailImage`, which never generates). If the cache has it, we
/// render immediately. If not, we show a lightweight placeholder and kick
/// off an async load in a `.task`, which decodes off the main actor via
/// `thumbnailImageAsync` and populates the cache for next time.
///
/// This replaces the `store.thumbnailImage(for: …)` calls that were being
/// made directly from SwiftUI bodies — those calls decoded full images on
/// the MainActor whenever a character was selected, causing beach balls.
@available(macOS 26.0, *)
struct AsyncStoreThumbnailImage<Placeholder: View>: View {
    let store: AnimateStore
    let path: String?
    let maxSize: CGFloat
    let width: CGFloat?
    let height: CGFloat?
    let contentMode: ContentMode
    let cornerRadius: CGFloat
    @ViewBuilder let placeholder: () -> Placeholder

    @State private var loadedImage: NSImage?
    @State private var loadedPath: String?
    @State private var loadedSize: CGFloat = 0

    private var dragURL: URL? {
        guard let path else { return nil }
        return store.resolvedCharacterAssetURL(for: path)
            ?? projectImageDragURL(forResolvedPath: path)
    }

    init(
        store: AnimateStore,
        path: String?,
        maxSize: CGFloat,
        width: CGFloat?,
        height: CGFloat?,
        contentMode: ContentMode = .fit,
        cornerRadius: CGFloat = 10,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.store = store
        self.path = path
        self.maxSize = maxSize
        self.width = width
        self.height = height
        self.contentMode = contentMode
        self.cornerRadius = cornerRadius
        self.placeholder = placeholder
    }

    var body: some View {
        // Resolve from cache first — NSCache lookups are effectively free.
        // Only fall through to the async path on a miss, which then paints
        // a placeholder and decodes off the main actor.
        let cached = store.cachedThumbnailImage(for: path, maxSize: maxSize)
        let displayImage: NSImage? = cached ?? (loadedPath == path && loadedSize == maxSize ? loadedImage : nil)

        Group {
            if let image = displayImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .applyFrame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                placeholder()
                    .applyFrame(width: width, height: height)
            }
        }
        .modifier(ProjectImageFileDragModifier(url: dragURL))
        .task(id: "\(path ?? "")#\(Int(maxSize.rounded()))") {
            // If we've already got it cached, nothing to do.
            if store.cachedThumbnailImage(for: path, maxSize: maxSize) != nil {
                loadedImage = nil
                loadedPath = path
                loadedSize = maxSize
                return
            }
            let target = path
            let size = maxSize
            let loaded = await store.thumbnailImageAsync(for: target, maxSize: size)
            if Task.isCancelled { return }
            if target == path && size == maxSize {
                loadedImage = loaded
                loadedPath = target
                loadedSize = size
            }
        }
    }
}

@available(macOS 26.0, *)
extension AsyncStoreThumbnailImage where Placeholder == AnyView {
    /// Convenience for the common "soft-filled rectangle while loading" case.
    static func rounded(
        store: AnimateStore,
        path: String?,
        maxSize: CGFloat,
        width: CGFloat?,
        height: CGFloat?,
        contentMode: ContentMode = .fit,
        cornerRadius: CGFloat = 10,
        placeholderOpacity: Double = 0.22
    ) -> AsyncStoreThumbnailImage<AnyView> {
        AsyncStoreThumbnailImage<AnyView>(
            store: store,
            path: path,
            maxSize: maxSize,
            width: width,
            height: height,
            contentMode: contentMode,
            cornerRadius: cornerRadius,
            placeholder: {
                AnyView(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.quaternary.opacity(placeholderOpacity))
                )
            }
        )
    }
}

@available(macOS 26.0, *)
private extension View {
    /// Apply a frame only when a dimension is provided. Lets the async
    /// thumbnail view support both fixed and flexible-width layouts.
    @ViewBuilder
    func applyFrame(width: CGFloat?, height: CGFloat?) -> some View {
        switch (width, height) {
        case let (w?, h?): self.frame(width: w, height: h)
        case let (w?, nil): self.frame(width: w)
        case let (nil, h?): self.frame(maxWidth: .infinity).frame(height: h)
        case (nil, nil): self
        }
    }
}
