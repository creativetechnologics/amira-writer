import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct CharacterLookDevelopmentBoardSheet: View {
    @Bindable var store: AnimateStore
    let characterID: UUID
    let onDismiss: () -> Void

    @State private var selectedSlotID: UUID?
    @State private var selectedFilter: CostumeFilter = .all
    @State private var isGenerating = false
    @State private var generationError: String?
    @State private var generationMessage: String?
    @State private var previewImageIndex: Int?
    @State private var previewImagePaths: [String] = []

    private enum CostumeFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case identity = "Identity"
        case military = "Military"
        case civilian = "Civilian"

        var id: String { rawValue }

        var costume: CharacterLookDevelopmentCostume? {
            switch self {
            case .all: nil
            case .identity: .identity
            case .military: .military
            case .civilian: .civilian
            }
        }
    }

    private var character: AnimationCharacter? {
        store.characters.first(where: { $0.id == characterID })
    }

    private var slots: [CharacterLookDevelopmentSlot] {
        character?.lookDevelopmentSlots ?? []
    }

    private var visibleSlots: [CharacterLookDevelopmentSlot] {
        guard let costume = selectedFilter.costume else { return slots }
        return slots.filter { $0.costume == costume }
    }

    private var selectedSlot: CharacterLookDevelopmentSlot? {
        guard let selectedSlotID else { return visibleSlots.first }
        return slots.first(where: { $0.id == selectedSlotID }) ?? visibleSlots.first
    }

    private let categoryOrder: [CharacterLookDevelopmentCategory] = [
        .identityAnchor, .militaryWardrobe, .civilianWardrobe,
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            HStack(spacing: 0) {
                slotList
                    .frame(width: 320)

                Divider()

                slotDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 1120, minHeight: 760)
        .task {
            store.seedLookDevelopmentSlotsIfNeeded(for: characterID)
            if selectedSlotID == nil {
                selectedSlotID = visibleSlots.first?.id
            }
        }
        .onChange(of: selectedFilter) { _, _ in
            if let selectedSlotID,
               visibleSlots.contains(where: { $0.id == selectedSlotID }) {
                return
            }
            self.selectedSlotID = visibleSlots.first?.id
        }
        .overlay {
            if let index = previewImageIndex {
                ImagePreviewOverlay(
                    store: store,
                    paths: previewImagePaths,
                    currentIndex: Binding(
                        get: { index },
                        set: { previewImageIndex = $0 }
                    ),
                    onDismiss: { previewImageIndex = nil }
                )
            }
        }
        .alert("Look Development", isPresented: Binding(
            get: { generationError != nil || generationMessage != nil },
            set: { newValue in
                if !newValue {
                    generationError = nil
                    generationMessage = nil
                }
            }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(generationError ?? generationMessage ?? "Unknown status")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Look Development Pose Library")
                    .font(.headline)
                if let character {
                    Text(character.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Picker("Filter", selection: $selectedFilter) {
                ForEach(CostumeFilter.allCases) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            Button("Reset 50 Slots") {
                store.resetLookDevelopmentSlots(for: characterID)
                selectedSlotID = store.characters.first(where: { $0.id == characterID })?.lookDevelopmentSlots.first?.id
            }
            .buttonStyle(.bordered)

            Button("Done") {
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var slotList: some View {
        List(selection: Binding(
            get: { selectedSlotID },
            set: { selectedSlotID = $0 }
        )) {
            ForEach(categoryOrder, id: \.self) { category in
                let sectionSlots = visibleSlots.filter { $0.category == category }
                if !sectionSlots.isEmpty {
                    Section(category.displayName) {
                        ForEach(sectionSlots) { slot in
                            lookDevelopmentSlotRow(slot)
                                .tag(slot.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func lookDevelopmentSlotRow(_ slot: CharacterLookDevelopmentSlot) -> some View {
        HStack(spacing: 10) {
            approvedThumbnail(for: slot)

            VStack(alignment: .leading, spacing: 2) {
                Text(slot.title)
                    .font(.subheadline)
                Text("\(slot.costume.displayName) • \(slot.framing.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if slot.approvedVariant != nil {
                    Label("Approved", systemImage: "checkmark.seal.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
                Text("\(slot.variants.count) variants")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func approvedThumbnail(for slot: CharacterLookDevelopmentSlot) -> some View {
        if let approvedVariant = slot.approvedVariant,
           let image = store.thumbnailImage(for: approvedVariant.imagePath, maxSize: 40) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.3))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: slot.costume.systemImage)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
        }
    }

    @ViewBuilder
    private var slotDetail: some View {
        if let slot = selectedSlot {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(slot.title)
                                .font(.title3)
                                .fontWeight(.semibold)
                            Text(slot.poseNotes)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 6) {
                            Label(slot.costume.displayName, systemImage: slot.costume.systemImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(slot.recommendedImageSize) • \(slot.recommendedAspectRatio)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    HStack(spacing: 12) {
                        statPill(title: "Category", value: slot.category.displayName)
                        statPill(title: "Framing", value: slot.framing.displayName)
                        statPill(title: "Variants", value: "\(slot.variants.count)")
                    }

                    HStack(spacing: 12) {
                        Button {
                            generateSelectedSlot()
                        } label: {
                            Label(slot.variants.isEmpty ? "Generate First Variant" : "Generate New Variant", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isGenerating || !store.canGenerateGeminiImagesImmediately)

                        if isGenerating {
                            ProgressView()
                                .controlSize(.small)
                            Text("Generating…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let error = store.geminiImageGenerationAvailabilityError {
                            Text(error.localizedDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }

                    Toggle(
                        "Use the approved variant from this slot in the curated reference pack",
                        isOn: Binding(
                            get: { slot.includeApprovedVariantInReferencePack },
                            set: {
                                store.setLookDevelopmentReferenceInclusion(
                                    $0,
                                    slotID: slot.id,
                                    for: characterID
                                )
                            }
                        )
                    )
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompt")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Text(slot.prompt)
                            .textSelection(.enabled)
                            .font(.callout)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Variants")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if slot.variants.isEmpty {
                            ContentUnavailableView(
                                "No variants yet",
                                systemImage: "photo.stack",
                                description: Text("Generate this slot to start building the curated reference board.")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 20)
                        } else {
                            LazyVGrid(columns: [
                                GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 12)
                            ], spacing: 12) {
                                ForEach(Array(slot.variants.enumerated()), id: \.element.id) { index, variant in
                                    LookDevelopmentVariantCard(
                                        store: store,
                                        variant: variant,
                                        isApproved: slot.approvedVariantID == variant.id || (slot.approvedVariantID == nil && slot.variants.last?.id == variant.id),
                                        onPreview: {
                                            previewImagePaths = slot.variants.map(\.imagePath)
                                            previewImageIndex = index
                                        },
                                        onApprove: {
                                            store.setLookDevelopmentApprovedVariant(
                                                variant.id,
                                                slotID: slot.id,
                                                for: characterID
                                            )
                                        },
                                        onDelete: {
                                            store.removeLookDevelopmentVariant(
                                                variant.id,
                                                slotID: slot.id,
                                                for: characterID
                                            )
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView(
                "Select a slot",
                systemImage: "square.grid.3x3.topleft.filled",
                description: Text("Choose a look-development slot to inspect its prompt, generate variants, and approve the best result.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 10))
    }

    private func generateSelectedSlot() {
        guard let character, let slot = selectedSlot else { return }
        if let error = store.geminiImageGenerationAvailabilityError {
            generationError = error.localizedDescription
            return
        }

        isGenerating = true
        generationError = nil
        generationMessage = nil

        let service = GeminiImageService()
        let request = GeminiImageService.GenerationRequest(
            prompt: slot.prompt,
            referenceImages: buildReferenceImages(for: character, slot: slot),
            model: store.selectedGeminiModel,
            aspectRatio: slot.recommendedAspectRatio,
            imageSize: slot.recommendedImageSize
        )

        Task {
            do {
                store.logGeminiAPICall(endpoint: "image-generation", source: "CharacterLookDevelopmentBoardSheet.generateSlot()")
                let result = try await service.generate(request: request, apiKey: store.geminiAPIKey)
                try store.storeLookDevelopmentVariant(
                    result.imageData,
                    prompt: slot.prompt,
                    model: store.selectedGeminiModel,
                    slotID: slot.id,
                    for: character.id,
                    aspectRatio: slot.recommendedAspectRatio,
                    imageSize: slot.recommendedImageSize
                )
                generationMessage = "Saved a new variant for “\(slot.title)”."
            } catch {
                generationError = error.localizedDescription
            }
            isGenerating = false
        }
    }

    private func buildReferenceImages(
        for character: AnimationCharacter,
        slot: CharacterLookDevelopmentSlot
    ) -> [GeminiImageService.ReferenceImage] {
        let preferredCostume = slot.costume == .identity ? nil : slot.costume
        let curatedPaths = store.curatedLookDevelopmentReferencePaths(
            for: character.id,
            preferredCostume: preferredCostume,
            limit: 8
        )

        let curatedImages = curatedPaths.compactMap { path -> GeminiImageService.ReferenceImage? in
            guard let url = store.resolvedCharacterAssetURL(for: path) else { return nil }
            return GeminiImageService.referenceImage(from: url)
        }

        if !curatedImages.isEmpty {
            return curatedImages
        }

        return character.inspirationImagePaths.prefix(6).compactMap { path in
            guard let url = store.resolvedCharacterAssetURL(for: path) else { return nil }
            return GeminiImageService.referenceImage(from: url)
        }
    }
}

@available(macOS 26.0, *)
private struct LookDevelopmentVariantCard: View {
    let store: AnimateStore
    let variant: CharacterLookDevelopmentVariant
    let isApproved: Bool
    let onPreview: () -> Void
    let onApprove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onPreview) {
                thumbnail
            }
            .buttonStyle(.plain)

            Text(variant.createdAt, style: .date)
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Text(variant.imageSize + " • " + variant.aspectRatio)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Button(isApproved ? "Approved" : "Approve") {
                    onApprove()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isApproved)

                Spacer()

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = store.thumbnailImage(for: variant.imagePath, maxSize: 160) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if isApproved {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .padding(8)
                    }
                }
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.25))
                .frame(height: 160)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.tertiary)
                }
        }
    }
}
