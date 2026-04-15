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
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView()
            }
        }
        .task(id: path) {
            // Load at larger size for preview pane
            image = await ImagineThumbnailCache.shared.thumbnail(for: path, maxPixelSize: 1600)
        }
    }
}
