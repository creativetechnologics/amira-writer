import SwiftUI
import AppKit
import ProjectKit

@available(macOS 26.0, *)
struct CharacterPartsLibraryPane: View {
    @Bindable var store: AnimateStore
    let characterID: UUID

    @State private var isGenerating: Bool = false
    @State private var generationStatus: String? = nil
    @State private var parts: [CharacterPart] = []
    @State private var selectedPartID: UUID? = nil
    @FocusState private var gridFocused: Bool

    private let thumbnailSize: CGFloat = 120

    private var character: AnimationCharacter? {
        store.characters.first(where: { $0.id == characterID })
    }

    private var costumes: [CharacterCostumeReferenceSet] {
        character?.costumeReferenceSets ?? []
    }

    private var selectedCostume: CharacterCostumeReferenceSet? {
        costumes.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Character Parts Library", systemImage: "square.grid.3x2")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let status = generationStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
            }

            if costumes.isEmpty {
                Text("No costumes defined. Create a costume in the Costumes section first.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.15),
                                in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Costume: \(selectedCostume?.name ?? "None")")
                        .font(.caption).foregroundStyle(.secondary)

                    Text("Single 4K call generates a 4×3 grid: front, quarter-left, quarter-right, back + 6 emotion variants — then auto-slices into individual parts.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineLimit(3)

                    HStack {
                        Spacer()
                        Button {
                            Task { await generateGrid() }
                        } label: {
                            Label("Generate Parts Grid", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .disabled(isGenerating || !store.canGenerateGeminiImagesImmediately)
                    }
                }

                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Generating 4×3 grid in 4K...").font(.caption)
                    }
                    .padding(.vertical, 4)
                }

                Divider()

                if parts.isEmpty {
                    Text("No parts generated yet.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("\(parts.count) parts — click to select, spacebar to preview")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: thumbnailSize + 16, maximum: thumbnailSize + 16), spacing: 8)],
                            spacing: 8
                        ) {
                            ForEach(parts) { part in
                                partTile(part)
                            }
                        }
                        .padding(4)
                    }
                    .focusable()
                    .focused($gridFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.space) {
                        if let selectedID = selectedPartID,
                           let index = parts.firstIndex(where: { $0.id == selectedID }) {
                            let previewURLs = parts.compactMap { part -> URL? in
                                guard let projectURL = store.owpURL,
                                      let character = character else { return nil }
                                let dir = CharacterPartsLibraryService(store: store)
                                    .partsDirectory(projectRoot: projectURL, characterSlug: character.owpSlug)
                                let url = dir.appendingPathComponent(part.imagePath)
                                return FileManager.default.fileExists(atPath: url.path) ? url : nil
                            }
                            if index < previewURLs.count {
                                QuickLookPreviewController.shared.toggle(urls: previewURLs, startAt: index)
                            }
                        }
                        return .handled
                    }
                    .onKeyPress(.leftArrow) {
                        if let selectedID = selectedPartID,
                           let index = parts.firstIndex(where: { $0.id == selectedID }),
                           index > 0 {
                            selectedPartID = parts[index - 1].id
                        }
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        if let selectedID = selectedPartID,
                           let index = parts.firstIndex(where: { $0.id == selectedID }),
                           index < parts.count - 1 {
                            selectedPartID = parts[index + 1].id
                        }
                        return .handled
                    }
                }
            }
        }
        .onAppear { loadParts() }
        .onChange(of: characterID) { _, _ in loadParts() }
    }

    private func partTile(_ part: CharacterPart) -> some View {
        let resolvedPath: String? = {
            guard let projectURL = store.owpURL,
                  let character = character else { return nil }
            return CharacterPartsLibraryService(store: store)
                .partsDirectory(projectRoot: projectURL, characterSlug: character.owpSlug)
                .appendingPathComponent(part.imagePath).path
        }()

        return UnifiedImageTile(
            path: part.imagePath,
            resolvedPath: resolvedPath,
            thumbnailSize: thumbnailSize,
            sourceLabel: part.partKind.displayName,
            sourceSystemImage: part.emotion != nil ? "face.smiling" : "person.fill",
            isSelected: selectedPartID == part.id,
            showsSelectionCheckmark: true,
            actions: UnifiedImageActions(
                onMoveToTrash: {
                    removePart(part)
                }
            ),
            onTap: {
                claimFocus()
                if selectedPartID == part.id {
                    selectedPartID = nil
                } else {
                    selectedPartID = part.id
                }
            },
            onDoubleTap: {
                if let resolvedPath,
                   FileManager.default.fileExists(atPath: resolvedPath) {
                    let previewURLs = parts.compactMap { p -> URL? in
                        guard let projectURL = store.owpURL,
                              let character = character else { return nil }
                        let url = CharacterPartsLibraryService(store: store)
                            .partsDirectory(projectRoot: projectURL, characterSlug: character.owpSlug)
                            .appendingPathComponent(p.imagePath)
                        return FileManager.default.fileExists(atPath: url.path) ? url : nil
                    }
                    if let index = previewURLs.firstIndex(where: { $0.path == resolvedPath }) {
                        QuickLookPreviewController.shared.toggle(urls: previewURLs, startAt: index)
                    }
                }
            }
        )
        .id(part.id)
    }

    private func claimFocus() {
        gridFocused = true
    }

    private func removePart(_ part: CharacterPart) {
        guard let character = character, let projectURL = store.owpURL else { return }
        let dir = CharacterPartsLibraryService(store: store)
            .partsDirectory(projectRoot: projectURL, characterSlug: character.owpSlug)
        let imageURL = dir.appendingPathComponent(part.imagePath)
        try? FileManager.default.removeItem(at: imageURL)
        var manifest = CharacterPartsLibraryService(store: store)
            .loadManifest(projectRoot: projectURL, characterSlug: character.owpSlug)
        manifest.parts.removeAll { $0.id == part.id }
        try? CharacterPartsLibraryService(store: store).saveManifest(manifest, projectRoot: projectURL)
        loadParts()
    }

    private func loadParts() {
        guard let character = character, let projectURL = store.owpURL else { return }
        parts = CharacterPartsLibraryService(store: store)
            .loadManifest(projectRoot: projectURL, characterSlug: character.owpSlug).parts
    }

    private func generateGrid() async {
        guard let character = character,
              let costume = selectedCostume,
              let projectURL = store.owpURL
        else { return }

        isGenerating = true
        generationStatus = "Calling Gemini 4K..."

        do {
            let service = CharacterPartsLibraryService(store: store)
            let newParts = try await service.generatePartsGrid(
                character: character,
                costume: costume,
                projectRoot: projectURL
            )
            generationStatus = "Done: \(newParts.count) parts"
            loadParts()
        } catch {
            generationStatus = "Failed: \(error.localizedDescription)"
        }

        isGenerating = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if generationStatus?.hasPrefix("Done") == true || generationStatus?.hasPrefix("Failed") == true {
                generationStatus = nil
            }
        }
    }
}
