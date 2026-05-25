import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct AsyncApprovedVariantView: View {
    let store: AnimateStore
    let variant: CharacterLookDevelopmentVariant
    let title: String
    let width: CGFloat
    let height: CGFloat
    let onQuickLook: () -> Void
    let onShowInFinder: () -> Void
    let onCopy: () -> Void
    let onSetAsProfilePic: () -> Void

    @State private var image: NSImage?
    @State private var dragURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.22))
                    .frame(width: width, height: height)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .transition(.opacity.animation(.easeIn(duration: 0.15)))
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: width, height: height)
            .onTapGesture(count: 2) { onQuickLook() }
            .onTapGesture(count: 1) {
                store.imaginePreviewImagePath = variant.imagePath
            }
            .contextMenu {
                UnifiedImageContextMenuContent(
                    selectedCount: 0,
                    isSelected: false,
                    actions: UnifiedImageActions(
                        onSetAsProfile: onSetAsProfilePic,
                        onShowInFinder: onShowInFinder,
                        onCopy: onCopy,
                        onFlipHorizontally: {
                            store.flipImageHorizontallyAndAttachLikeOriginal(path: variant.imagePath)
                        },
                        onQuickLook: onQuickLook
                    )
                )
            }

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: width, alignment: .leading)
                .lineLimit(2)
        }
        .task(id: variant.imagePath) {
            dragURL = store.resolvedCharacterAssetURL(for: variant.imagePath)
            image = store.cachedThumbnailImage(for: variant.imagePath, maxSize: max(width, height) * 2)
            if image != nil { return }
            let loaded = await store.thumbnailImageAsync(for: variant.imagePath, maxSize: max(width, height) * 2)
            if !Task.isCancelled { image = loaded }
        }
        .modifier(ProjectImageFileDragModifier(url: dragURL))
    }
}
