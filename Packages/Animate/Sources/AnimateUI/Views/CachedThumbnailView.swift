import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct CachedThumbnailView: View {
    let path: String
    let size: CGFloat
    let maxPixelSize: Int

    @State private var image: NSImage?

    init(path: String, size: CGFloat) {
        self.path = path
        self.size = size
        // Load at 2x size for retina
        self.maxPixelSize = Int(size * 2)
    }

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else if let cached = ImagineThumbnailCache.shared.cached(for: path, maxPixelSize: maxPixelSize) {
                Image(nsImage: cached)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(width: size, height: size)
            }
        }
        .task(id: path) {
            image = nil
            if let cached = ImagineThumbnailCache.shared.cached(for: path, maxPixelSize: maxPixelSize) {
                image = cached
            } else {
                image = await ImagineThumbnailCache.shared.thumbnail(for: path, maxPixelSize: maxPixelSize)
            }
        }
    }
}

@available(macOS 26.0, *)
enum SharedAsyncImageContentMode {
    case fit
    case fill
}

@available(macOS 26.0, *)
func loadSharedPreviewImage(at path: String, maxPixelSize: Int) async -> NSImage? {
    if let cached = ImagineThumbnailCache.shared.cached(for: path, maxPixelSize: maxPixelSize) {
        return cached
    }
    return await ImagineThumbnailCache.shared.thumbnail(for: path, maxPixelSize: maxPixelSize)
}

@available(macOS 26.0, *)
struct AsyncResolvedImageView: View {
    let path: String
    let maxPixelSize: Int
    var contentMode: SharedAsyncImageContentMode = .fit

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                render(image)
            } else if let cached = ImagineThumbnailCache.shared.cached(for: path, maxPixelSize: maxPixelSize) {
                render(cached)
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.1))
            }
        }
        .task(id: "\(path)#\(maxPixelSize)") {
            image = await loadSharedPreviewImage(at: path, maxPixelSize: maxPixelSize)
        }
    }

    private func render(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode == .fill ? .fill : .fit)
    }
}
