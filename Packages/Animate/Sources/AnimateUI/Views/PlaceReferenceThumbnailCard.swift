import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct PlaceReferenceThumbnailCard: View {
    let store: AnimateStore
    let reference: PlaceReferenceImage
    let onRemove: () -> Void
    let onShowInFinder: () -> Void

    var body: some View {
        let resolvedURL = store.resolvedCharacterAssetURL(for: reference.imagePath)
            ?? (FileManager.default.fileExists(atPath: reference.imagePath) ? URL(fileURLWithPath: reference.imagePath) : nil)
        VStack(alignment: .leading, spacing: 6) {
            UnifiedImageTile(
                path: reference.imagePath,
                resolvedPath: resolvedURL?.path,
                thumbnailSize: 150,
                caption: reference.title,
                actions: UnifiedImageActions(
                    onShowInFinder: { onShowInFinder() },
                    onRemoveFromCollection: { onRemove() },
                    removeFromCollectionLabel: "Remove Reference"
                )
            )

            Text(reference.category.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.quaternary.opacity(0.2), in: Capsule())
        }
        .frame(width: 162, alignment: .leading)
    }
}
