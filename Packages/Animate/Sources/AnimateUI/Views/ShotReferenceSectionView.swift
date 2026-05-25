import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct ShotReferenceSectionView: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter
    @Binding var showPicker: Bool
    let onQuickLook: ([String], Int) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 16
        ) {
            ForEach(character.shotReferenceImages) { reference in
                tile(for: reference)
            }

            addTile
        }
        .dropDestination(for: URL.self) { urls, _ in
            let imageURLs = urls.filter { ["png", "jpg", "jpeg", "webp", "heic"].contains($0.pathExtension.lowercased()) }
            guard !imageURLs.isEmpty else { return false }
            store.importShotReferenceImages(from: imageURLs, for: character.id)
            return true
        }
    }

    private func tile(for reference: CharacterShotReferenceImage) -> some View {
        let resolvedURL = store.resolvedCharacterAssetURL(for: reference.imagePath)

        return VStack(alignment: .leading, spacing: 8) {
            UnifiedImageTile(
                path: reference.imagePath,
                resolvedPath: resolvedURL?.path,
                thumbnailSize: 138,
                sourceLabel: reference.view.displayName,
                sourceSystemImage: reference.view == .front ? "person.fill" : "person.crop.square",
                actions: UnifiedImageActions(
                    onShowInFinder: {
                        if let resolvedURL {
                            NSWorkspace.shared.activateFileViewerSelecting([resolvedURL])
                        }
                    },
                    onQuickLook: {
                        onQuickLook(character.shotReferenceImages.map(\.imagePath),
                                    character.shotReferenceImages.firstIndex(where: { $0.id == reference.id }) ?? 0)
                    },
                    onRemoveFromCollection: {
                        store.removeShotReferenceImage(reference.id, for: character.id)
                    }
                ),
                onDoubleTap: {
                    onQuickLook(character.shotReferenceImages.map(\.imagePath),
                                character.shotReferenceImages.firstIndex(where: { $0.id == reference.id }) ?? 0)
                },
                topTrailingOverlay: AnyView(
                    Button {
                        store.removeShotReferenceImage(reference.id, for: character.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .padding(5)
                    .help("Remove shot reference")
                )
            )

            shotReferencePicker(
                "Framing",
                selection: reference.framing,
                options: CharacterShotReferenceFraming.allCases,
                characterID: character.id,
                referenceID: reference.id
            )

            shotReferencePicker(
                "Wardrobe",
                selection: reference.wardrobe,
                options: CharacterShotReferenceWardrobe.allCases,
                characterID: character.id,
                referenceID: reference.id
            )

            shotReferencePicker(
                "View",
                selection: reference.view,
                options: CharacterShotReferenceView.allCases,
                characterID: character.id,
                referenceID: reference.id
            )
        }
        .frame(width: 150, alignment: .topLeading)
    }

    private var addTile: some View {
        Button {
            showPicker = true
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                Text("Add")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(width: 138, height: 138)
            .foregroundStyle(.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(Color.secondary.opacity(0.45))
            )
        }
        .buttonStyle(.plain)
        .help("Add shot reference images")
        .frame(width: 150, alignment: .topLeading)
    }

    private func shotReferencePicker<Option: CaseIterable & Hashable & Identifiable>(
        _ title: String,
        selection: Option,
        options: [Option],
        characterID: UUID,
        referenceID: UUID
    ) -> some View where Option.AllCases == [Option] {
        Picker(
            title,
            selection: Binding<Option>(
                get: { selection },
                set: { newValue in
                    if let framing = newValue as? CharacterShotReferenceFraming {
                        store.updateShotReferenceImage(referenceID, for: characterID, framing: framing)
                    } else if let wardrobe = newValue as? CharacterShotReferenceWardrobe {
                        store.updateShotReferenceImage(referenceID, for: characterID, wardrobe: wardrobe)
                    } else if let view = newValue as? CharacterShotReferenceView {
                        store.updateShotReferenceImage(referenceID, for: characterID, view: view)
                    }
                }
            )
        ) {
            ForEach(options) { option in
                Text(optionLabel(option))
                    .tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(width: 138)
        .help(title)
    }

    private func optionLabel<Option>(_ option: Option) -> String {
        if let framing = option as? CharacterShotReferenceFraming { return framing.displayName }
        if let wardrobe = option as? CharacterShotReferenceWardrobe { return wardrobe.displayName }
        if let view = option as? CharacterShotReferenceView { return view.displayName }
        return String(describing: option)
    }
}
