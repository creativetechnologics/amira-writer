import SwiftUI

@available(macOS 26.0, *)
struct CharacterPoseVariantCarouselTile: View {
    let store: AnimateStore
    let title: String
    let variants: [CharacterLookDevelopmentVariant]
    let approvedVariantID: UUID?
    let isGenerating: Bool
    let statusText: String
    let onQuickLook: (UUID) -> Void
    let onCopy: (CharacterLookDevelopmentVariant) -> Void
    let onEdit: (UUID) -> Void
    let onShowPrompt: (UUID) -> Void
    let onApprove: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onAdjustCrop: (UUID) -> Void
    let onShowInFinder: (String) -> Void

    @State private var isHovering = false

    private var selectedIndex: Int {
        guard !variants.isEmpty else { return 0 }
        if let approvedVariantID,
           let index = variants.firstIndex(where: { $0.id == approvedVariantID }) {
            return index
        }
        return max(0, variants.count - 1)
    }

    private var selectedVariant: CharacterLookDevelopmentVariant? {
        guard variants.indices.contains(selectedIndex) else { return nil }
        return variants[selectedIndex]
    }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                if let variant = selectedVariant {
                    tile(for: variant)
                } else {
                    emptyTile
                }

                if variants.count > 1 {
                    carouselControls
                        .opacity(isHovering ? 1 : 0)
                        .animation(.easeInOut(duration: 0.12), value: isHovering)
                }

                if isGenerating {
                    generationOverlay
                }
            }
            .onHover { isHovering = $0 }

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 132)
        }
    }

    private func tile(for variant: CharacterLookDevelopmentVariant) -> some View {
        let resolvedURL = store.resolvedCharacterAssetURL(for: variant.imagePath)
        return UnifiedImageTile(
            path: variant.imagePath,
            resolvedPath: resolvedURL?.path,
            thumbnailSize: 132,
            isSelected: true,
            actions: UnifiedImageActions(
                onChooseAsMaster: { onApprove(variant.id) },
                isMaster: true,
                chooseAsMasterLabel: "Choose as Master",
                chosenAsMasterLabel: "Chosen",
                onShowPrompt: { onShowPrompt(variant.id) },
                onShowInFinder: { onShowInFinder(variant.imagePath) },
                onCopy: { onCopy(variant) },
                onQuickLook: { onQuickLook(variant.id) },
                onEditWithGemini: { onEdit(variant.id) },
                onAdjustCrop: { onAdjustCrop(variant.id) },
                onRemoveFromCollection: { onDelete(variant.id) },
                removeFromCollectionLabel: "Delete Variant"
            ),
            onTap: { store.imaginePreviewImagePath = variant.imagePath },
            onDoubleTap: { onQuickLook(variant.id) }
        )
    }

    private var emptyTile: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.quaternary.opacity(0.16))
            .frame(width: 132, height: 132)
            .overlay {
                Image(systemName: "photo")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }

    private var carouselControls: some View {
        HStack {
            Button {
                select(delta: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.black.opacity(0.48), in: Capsule())
            .accessibilityLabel("Previous Variant")

            Spacer()

            Button {
                select(delta: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.black.opacity(0.48), in: Capsule())
            .accessibilityLabel("Next Variant")
        }
        .padding(.horizontal, 4)
        .frame(width: 132, height: 132)
    }

    private var generationOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.black.opacity(0.42))
            .frame(width: 132, height: 132)
            .overlay {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(statusText)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .padding(.horizontal, 8)
                }
            }
    }

    private func select(delta: Int) {
        guard !variants.isEmpty else { return }
        let nextIndex = (selectedIndex + delta + variants.count) % variants.count
        onApprove(variants[nextIndex].id)
    }
}
