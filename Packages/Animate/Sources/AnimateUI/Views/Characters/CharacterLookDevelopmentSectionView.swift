import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct CharacterLookDevelopmentSectionView: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter

    var body: some View {
        let approvedHeadCount = character.headTurnaroundSlots.filter { $0.approvedVariant != nil }.count
        let approvedMaster = character.approvedMasterReferenceSheetVariant
        let costumeCount = max(character.costumeReferenceSets.count, CharacterReferenceWorkflowCatalog.defaultCostumeSets(for: character.name).count)
        let approvedFullBodyCount = character.costumeReferenceSets.flatMap(\.fullBodySlots).filter { $0.approvedVariant != nil }.count
        let approvedAccessoryCount = character.costumeReferenceSets.flatMap(\.accessorySlots).filter { $0.approvedVariant != nil }.count

        VStack(alignment: .leading, spacing: 12) {
            Text("Start with inspiration photos, generate several master sheets, approve the best one, then generate the six-pose head grid, each costume's six-pose full-body grid, and accessories. Every NB2 request now previews prompt, reference images, size, and estimated cost before sending.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                summaryPill(title: "Master Sheets", value: character.masterReferenceSheetVariants.count, icon: "rectangle.3.group")
                summaryPill(title: "Head Poses", value: approvedHeadCount, icon: "person.crop.square")
                summaryPill(title: "Costumes", value: costumeCount, icon: "figure.stand")
                summaryPill(title: "Full Body", value: approvedFullBodyCount, icon: "figure.walk")
                summaryPill(title: "Accessories", value: approvedAccessoryCount, icon: "briefcase")
            }

            if approvedMaster == nil {
                emptyState(
                    icon: "square.grid.3x3.topleft.filled",
                    message: "No approved master sheet yet. Generate several sheet variants first, pick the best one, then use it to drive head, full-body, and accessory requests."
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        if let approvedMaster {
                            approvedMasterPreview(variant: approvedMaster, title: "Approved Master", characterID: character.id)
                        }
                        ForEach(Array(character.headTurnaroundSlots.filter { $0.approvedVariant != nil }.prefix(5))) { slot in
                            approvedPosePreview(title: slot.title, variant: slot.approvedVariant, characterID: character.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func summaryPill(title: String, value: Int, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text("\(title) \(value)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.24), in: Capsule())
    }

    @ViewBuilder
    private func approvedMasterPreview(variant: CharacterLookDevelopmentVariant, title: String, characterID: UUID) -> some View {
        AsyncApprovedVariantView(
            store: store,
            variant: variant,
            title: title,
            width: 156, height: 92,
            onQuickLook: { openQuickLook(for: [variant.imagePath], startingAt: 0) },
            onShowInFinder: { showInFinder(at: variant.imagePath) },
            onCopy: { copyImage(at: variant.imagePath) },
            onSetAsProfilePic: { store.prepareProfilePicCrop(from: variant.imagePath, for: characterID) }
        )
    }

    @ViewBuilder
    private func approvedPosePreview(title: String, variant: CharacterLookDevelopmentVariant?, characterID: UUID) -> some View {
        if let variant {
            AsyncApprovedVariantView(
                store: store,
                variant: variant,
                title: title,
                width: 92, height: 92,
                onQuickLook: { openQuickLook(for: [variant.imagePath], startingAt: 0) },
                onShowInFinder: { showInFinder(at: variant.imagePath) },
                onCopy: { copyImage(at: variant.imagePath) },
                onSetAsProfilePic: { store.prepareProfilePicCrop(from: variant.imagePath, for: characterID) }
            )
        }
    }

    private func emptyState(icon: String, message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 8)
    }

    private func openQuickLook(for paths: [String], startingAt index: Int) {
        let resolvedItems = paths.enumerated().compactMap { offset, path -> (Int, URL)? in
            guard let url = store.resolvedCharacterAssetURL(for: path) else { return nil }
            return (offset, url)
        }

        guard !resolvedItems.isEmpty else { return }

        let quickLookIndex = resolvedItems.firstIndex(where: { $0.0 == index }) ?? 0
        QuickLookPreviewController.shared.present(
            urls: resolvedItems.map(\.1),
            startAt: quickLookIndex
        )
    }

    private func showInFinder(at path: String) {
        guard let url = store.resolvedCharacterAssetURL(for: path) else {
            store.statusMessage = "Could not locate image"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func copyImage(at path: String) {
        guard let url = store.resolvedCharacterAssetURL(for: path),
              ImageClipboardService.copyImage(at: url) else {
            store.statusMessage = "Could not copy image"
            return
        }
        store.statusMessage = "Copied image"
    }
}
