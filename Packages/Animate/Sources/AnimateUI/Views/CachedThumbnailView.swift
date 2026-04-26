import AppKit
import ImageIO
import SwiftUI

@available(macOS 26.0, *)
func projectImageDragURL(forResolvedPath path: String?) -> URL? {
    guard let path,
          !path.isEmpty,
          path.hasPrefix("/") else {
        return nil
    }
    return URL(fileURLWithPath: path)
}

@available(macOS 26.0, *)
struct ProjectImageFileDragModifier: ViewModifier {
    let url: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let url {
            content.draggable(url)
        } else {
            content
        }
    }
}

@available(macOS 26.0, *)
struct CachedThumbnailView: View {
    let path: String
    let size: CGFloat
    let maxPixelSize: Int

    @State private var image: NSImage?
    @State private var loadedPath: String?
    @State private var loadedSize: Int = 0
    @State private var dragURL: URL?

    init(path: String, size: CGFloat) {
        self.path = path
        self.size = size
        // Load at 2x size for retina
        self.maxPixelSize = Int(size * 2)
    }

    var body: some View {
        let resolved = (loadedPath == path && loadedSize == maxPixelSize) ? image : nil
        return Group {
            if let resolved {
                Image(nsImage: resolved)
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
        .modifier(ProjectImageFileDragModifier(url: dragURL ?? projectImageDragURL(forResolvedPath: path)))
        .task(id: "\(path)#\(maxPixelSize)") {
            let currentPath = path
            let currentSize = maxPixelSize
            dragURL = projectImageDragURL(forResolvedPath: currentPath)

            if Task.isCancelled {
                return
            }

            if let cached = ImagineThumbnailCache.shared.cached(for: currentPath, maxPixelSize: currentSize) {
                image = cached
                loadedPath = currentPath
                loadedSize = currentSize
                return
            }

            if Task.isCancelled {
                return
            }

            if let best = ImagineThumbnailCache.shared.bestCached(for: currentPath, minimumPixelSize: currentSize / 2) {
                if Task.isCancelled {
                    return
                }
                image = best
            } else {
                image = nil
            }
            loadedPath = currentPath
            loadedSize = currentSize

            if let loaded = await ImagineThumbnailCache.shared.thumbnail(for: currentPath, maxPixelSize: currentSize),
               !Task.isCancelled,
               currentPath == path,
               currentSize == maxPixelSize {
                image = loaded
                loadedPath = currentPath
                loadedSize = currentSize
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
func loadSharedFullResolutionImage(at path: String) async -> NSImage? {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                continuation.resume(returning: NSImage(contentsOf: url))
                return
            }
            let options: [CFString: Any] = [
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary) {
                continuation.resume(returning: NSImage(
                    cgImage: cgImage,
                    size: NSSize(width: cgImage.width, height: cgImage.height)
                ))
                return
            }
            continuation.resume(returning: NSImage(contentsOf: url))
        }
    }
}

@available(macOS 26.0, *)
struct AsyncResolvedImageView: View {
    let path: String
    let maxPixelSize: Int
    var contentMode: SharedAsyncImageContentMode = .fit

    @State private var image: NSImage?
    @State private var loadedPath: String?
    @State private var loadedSize: Int = 0

    private var immediatePreviewMinimumPixelSize: Int {
        max(1, min(maxPixelSize / 6, 192))
    }

    var body: some View {
        let resolved = (loadedPath == path && loadedSize == maxPixelSize) ? image : nil
        return Group {
            if let resolved {
                render(resolved)
            } else {
                RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.1))
            }
        }
        .task(id: "\(path)#\(maxPixelSize)") {
            let currentPath = path
            let currentSize = maxPixelSize

            if let best = ImagineThumbnailCache.shared.bestCached(
                for: path,
                minimumPixelSize: immediatePreviewMinimumPixelSize
            ) {
                if Task.isCancelled { return }
                image = best
            } else {
                image = nil
            }
            loadedPath = currentPath
            loadedSize = currentSize

            if let loaded = await loadSharedPreviewImage(at: currentPath, maxPixelSize: currentSize),
               !Task.isCancelled,
               currentPath == path,
               currentSize == maxPixelSize {
                image = loaded
                loadedPath = currentPath
                loadedSize = currentSize
            }
        }
    }

    private func render(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode == .fill ? .fill : .fit)
    }
}
