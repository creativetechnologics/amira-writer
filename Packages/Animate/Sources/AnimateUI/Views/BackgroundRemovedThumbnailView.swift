import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct BackgroundRemovedThumbnailView: View {
    let path: String
    let size: CGFloat
    let resolvedURL: URL?

    @State private var processedImage: NSImage?
    @State private var isProcessing = false

    private var displayURL: URL {
        resolvedURL ?? URL(fileURLWithPath: path)
    }

    var body: some View {
        ZStack {
            if let processed = processedImage {
                Image(nsImage: processed)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
                    .transition(.opacity)
            } else {
                AsyncImage(url: displayURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: size, height: size)
                            .clipped()
                    default:
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.secondary.opacity(0.1))
                            .frame(width: size, height: size)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: path) {
            await loadProcessedThumbnail()
        }
    }

    private func loadProcessedThumbnail() async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        let effectivePath = displayURL.path
        if let result = await ThumbnailBackgroundRemover.shared.thumbnail(for: effectivePath, size: size) {
            withAnimation(.easeInOut(duration: 0.2)) {
                processedImage = result
            }
        }
    }
}
