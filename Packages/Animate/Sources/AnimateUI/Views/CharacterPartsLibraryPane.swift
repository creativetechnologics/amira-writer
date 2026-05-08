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
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)

                    HStack {
                        Spacer()
                        Button {
                            Task { await generateGrid() }
                        } label: {
                            Label("Generate Parts Grid", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
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
                    Text("No parts generated yet. Click \"Generate Parts Grid\" above to create all views in one call.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text("\(parts.count) parts available").font(.caption).foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(parts) { part in
                                partThumbnail(part)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { loadParts() }
        .onChange(of: characterID) { _, _ in loadParts() }
    }

    private func partThumbnail(_ part: CharacterPart) -> some View {
        VStack(spacing: 2) {
            if let projectURL = store.owpURL, let character = character {
                let dir = CharacterPartsLibraryService(store: store)
                    .partsDirectory(projectRoot: projectURL, characterSlug: character.owpSlug)
                let imageURL = dir.appendingPathComponent(part.imagePath)

                if let image = NSImage(contentsOf: imageURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 64, height: 90)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 64, height: 90)
                }
            }
            Text(part.partKind.displayName)
                .font(.system(size: 8, weight: .medium)).lineLimit(1)
            if let em = part.emotion {
                Text(em).font(.system(size: 7)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 66)
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
