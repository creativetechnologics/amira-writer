import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct CachedPreviewImage: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
                    // drawingGroup() forces GPU-composited rasterisation so
                    // resize drags don't re-rasterise the source NSImage on
                    // every frame — eliminates the "jitter between original
                    // and expanded size" Gary was seeing when dragging the
                    // resize handle. Metal-backed via Core Animation.
                    .drawingGroup(opaque: false, colorMode: .nonLinear)
            } else {
                ProgressView()
            }
        }
        // Disable implicit animations on layout size changes so the image
        // scales cleanly under the drag gesture.
        .animation(nil, value: image)
        .task(id: path) {
            // Load at larger size for preview pane. Task is keyed to path so
            // a resize doesn't re-fetch — only a new path does.
            image = await ImagineThumbnailCache.shared.thumbnail(for: path, maxPixelSize: 1600)
        }
    }
}
