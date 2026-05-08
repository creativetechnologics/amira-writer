import SwiftUI
import AppKit
import ProjectKit

@available(macOS 26.0, *)
struct CharacterPartsLibraryPane: View {
    @Bindable var store: AnimateStore
    let characterID: UUID

    @State private var selectedPartKind: PartKind = .front
    @State private var selectedEmotion: String? = nil
    @State private var isGenerating: Bool = false
    @State private var generationStatus: String? = nil
    @State private var parts: [CharacterPart] = []
    @State private var manifestLoaded = false

    private let emotions = ["neutral", "angry", "sad", "happy", "surprised", "fearful"]

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
                    Text("Using costume: \(selectedCostume?.name ?? "None")")
                        .font(.caption).foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Picker("Part", selection: $selectedPartKind) {
                            ForEach(PartKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 380)
                    }

                    HStack(spacing: 8) {
                        Picker("Emotion", selection: Binding(
                            get: { selectedEmotion ?? "neutral" },
                            set: { selectedEmotion = $0 == "neutral" ? nil : $0 }
                        )) {
                            ForEach(emotions, id: \.self) { em in
                                Text(em.capitalized).tag(em)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 140)

                        Spacer()

                        Button {
                            Task { await generateSelectedPart() }
                        } label: {
                            Label("Generate Part", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isGenerating || !store.canGenerateGeminiImagesImmediately)
                    }
                }

                if isGenerating {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Generating...").font(.caption)
                    }
                    .padding(.vertical, 4)
                }

                Divider()

                if parts.isEmpty {
                    Text("No parts generated yet. Use Generate Part above to create character parts for storyboarding.")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 8))
                } else {
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
        .onAppear {
            loadParts()
        }
        .onChange(of: store.selectedCharacterID) { _, _ in
            loadParts()
        }
    }

    private func partThumbnail(_ part: CharacterPart) -> some View {
        VStack(spacing: 4) {
            if let projectURL = store.owpURL,
               let character = character {
                let dir = CharacterPartsLibraryService(store: store)
                    .partsDirectory(projectRoot: projectURL, characterSlug: character.owpSlug)
                let imageURL = dir.appendingPathComponent(part.imagePath)

                if let image = NSImage(contentsOf: imageURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 70, height: 100)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 70, height: 100)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }

            Text(part.partKind.displayName)
                .font(.system(size: 9, weight: .medium)).lineLimit(1)
            if let em = part.emotion {
                Text(em).font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 76)
    }

    private func loadParts() {
        guard let character = character,
              let projectURL = store.owpURL else { return }
        let manifest = CharacterPartsLibraryService(store: store)
            .loadManifest(projectRoot: projectURL, characterSlug: character.owpSlug)
        parts = manifest.parts
        manifestLoaded = true
    }

    private func generateSelectedPart() async {
        guard let character = character,
              let costume = selectedCostume,
              let projectURL = store.owpURL
        else { return }

        isGenerating = true
        generationStatus = "Generating \(selectedPartKind.displayName)..."

        do {
            let service = CharacterPartsLibraryService(store: store)
            let part = try await service.generatePart(
                character: character,
                costume: costume,
                partKind: selectedPartKind,
                emotion: selectedEmotion,
                projectRoot: projectURL
            )
            generationStatus = "Done: \(part.partKind.displayName)"
            loadParts()
        } catch {
            generationStatus = "Failed: \(error.localizedDescription)"
        }

        isGenerating = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if generationStatus?.hasPrefix("Done") == true || generationStatus?.hasPrefix("Failed") == true {
                generationStatus = nil
            }
        }
    }
}
