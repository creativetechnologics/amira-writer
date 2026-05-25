import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct ExpressionLibraryView: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter

    @State private var selectedCategory: EmotionLibrary.EmotionCategory?
    @State private var searchText: String = ""
    @State private var expandedPresetID: String?
    @State private var generatingPresetIDs: Set<String> = []
    @State private var generationError: String?

    private let minimumCardWidth: CGFloat = 180
    private let maximumCardWidth: CGFloat = 220
    private let gridSpacing: CGFloat = 10

    private var filteredPresets: [EmotionLibrary.ExpressionPreset] {
        var result = EmotionLibrary.presets
        if let category = selectedCategory {
            result = result.filter { $0.category == category }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.displayName.lowercased().contains(query) ||
                $0.id.lowercased().contains(query) ||
                $0.aliases.contains(where: { $0.lowercased().contains(query) })
            }
        }
        return result
    }

    private var frontNeutralVariant: CharacterLookDevelopmentVariant? {
        character.headTurnaroundSlots.first(where: { $0.pose == .frontNeutral })?.approvedVariant
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if frontNeutralVariant == nil {
                Label("Generate or choose the Head Turnaround Grid → Front Neutral image first. Expressions always use that selected image as their reference.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            GeometryReader { proxy in
                let rows = presetRows(for: proxy.size.width)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: gridSpacing) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            HStack(alignment: .top, spacing: gridSpacing) {
                                ForEach(row) { preset in
                                    expressionCard(preset)
                                        .frame(width: cardWidth(for: proxy.size.width))
                                }
                                Spacer(minLength: 0)
                            }

                            if let expandedPresetID,
                               row.contains(where: { $0.id == expandedPresetID }),
                               let preset = EmotionLibrary.presets.first(where: { $0.id == expandedPresetID }) {
                                expressionVariantRow(for: preset)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .clipped()
            }
        }
        .alert("Expression Library", isPresented: Binding(
            get: { generationError != nil },
            set: { if !$0 { generationError = nil } }
        )) {
            Button("OK", role: .cancel) { generationError = nil }
        } message: {
            Text(generationError ?? "Unknown error")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Search expressions...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)

            Picker("Category", selection: $selectedCategory) {
                Text("All").tag(EmotionLibrary.EmotionCategory?.none)
                ForEach(EmotionLibrary.EmotionCategory.allCases, id: \.self) { cat in
                    Text(cat.rawValue.capitalized).tag(EmotionLibrary.EmotionCategory?.some(cat))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Spacer()

            Text("\(filteredPresets.count) expressions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func presetRows(for availableWidth: CGFloat) -> [[EmotionLibrary.ExpressionPreset]] {
        let columns = max(1, Int((availableWidth + gridSpacing) / (minimumCardWidth + gridSpacing)))
        return stride(from: 0, to: filteredPresets.count, by: columns).map { start in
            Array(filteredPresets[start..<min(start + columns, filteredPresets.count)])
        }
    }

    private func cardWidth(for availableWidth: CGFloat) -> CGFloat {
        let columns = max(1, Int((availableWidth + gridSpacing) / (minimumCardWidth + gridSpacing)))
        let raw = (availableWidth - CGFloat(columns - 1) * gridSpacing) / CGFloat(columns)
        return min(maximumCardWidth, max(minimumCardWidth, raw))
    }

    // MARK: - Expression Card

    private func expressionCard(_ preset: EmotionLibrary.ExpressionPreset) -> some View {
        let isExpanded = expandedPresetID == preset.id
        let entry = character.expressionLibraryEntry(for: preset.id)
        let isGenerating = generatingPresetIDs.contains(preset.id)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(preset.displayName)
                    .font(.callout.weight(.medium))
                Spacer()
                categoryBadge(preset.category)
            }

            HStack(spacing: 6) {
                parameterBar(label: "Brow", value: preset.browLift, range: -1...1)
                parameterBar(label: "Eyes", value: preset.eyeOpen - 1.0, range: -1...1)
                parameterBar(label: "Smile", value: preset.smile, range: -1...1)
            }

            HStack(spacing: 6) {
                if isGenerating {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Generating…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let approved = entry?.approvedVariant {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Master selected")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let url = store.resolvedCharacterAssetURL(for: approved.imagePath) {
                        CachedThumbnailView(path: url.path, size: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                } else if let entry, !entry.variants.isEmpty {
                    Text("\(entry.variants.count) variant\(entry.variants.count == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if !preset.aliases.isEmpty {
                    Text(preset.aliases.prefix(3).joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(height: 28, alignment: .leading)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isExpanded ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isExpanded ? Color.accentColor.opacity(0.45) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.16)) {
                expandedPresetID = isExpanded ? nil : preset.id
            }
        }
        .contextMenu {
            Button("Generate", systemImage: "sparkles") {
                generateExpression(preset)
            }
            .disabled(frontNeutralVariant == nil || isGenerating || !store.canGenerateGeminiImagesImmediately)

            if entry != nil {
                Button(isExpanded ? "Hide Variants" : "Show Variants", systemImage: "rectangle.grid.1x2") {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        expandedPresetID = isExpanded ? nil : preset.id
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func expressionVariantRow(for preset: EmotionLibrary.ExpressionPreset) -> some View {
        let entry = character.expressionLibraryEntry(for: preset.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(preset.displayName) References")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    generateExpression(preset)
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(frontNeutralVariant == nil || generatingPresetIDs.contains(preset.id) || !store.canGenerateGeminiImagesImmediately)
            }

            if let variants = entry?.variants, !variants.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(variants) { variant in
                            expressionVariantTile(variant, preset: preset, isMaster: entry?.approvedVariantID == variant.id)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text("No generated references yet. Right-click \(preset.displayName) and choose Generate, or use the Generate button here.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.18))
        )
    }

    private func expressionVariantTile(
        _ variant: CharacterLookDevelopmentVariant,
        preset: EmotionLibrary.ExpressionPreset,
        isMaster: Bool
    ) -> some View {
        let resolvedURL = store.resolvedCharacterAssetURL(for: variant.imagePath)
        return UnifiedImageTile(
            path: variant.imagePath,
            resolvedPath: resolvedURL?.path,
            thumbnailSize: 92,
            sourceLabel: isMaster ? "Master" : preset.displayName,
            sourceSystemImage: isMaster ? "checkmark.circle.fill" : "face.smiling",
            isSelected: isMaster,
            actions: UnifiedImageActions(
                onChooseAsMaster: {
                    store.setApprovedExpressionVariant(variant.id, presetID: preset.id, for: character.id)
                },
                isMaster: isMaster,
                chooseAsMasterLabel: "Choose as Master",
                chosenAsMasterLabel: "Chosen as Master",
                onShowPrompt: {
                    store.statusMessage = variant.prompt
                },
                onShowInFinder: {
                    if let url = store.resolvedCharacterAssetURL(for: variant.imagePath) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                },
                onCopy: {
                    if let url = store.resolvedCharacterAssetURL(for: variant.imagePath),
                       ImageClipboardService.copyImage(at: url) {
                        store.statusMessage = "Copied expression image"
                    } else {
                        store.statusMessage = "Could not copy expression image"
                    }
                },
                onQuickLook: {
                    QuickLookPreviewController.shared.present(urls: [resolvedURL ?? URL(fileURLWithPath: variant.imagePath)], startAt: 0)
                },
                onRemoveFromCollection: {
                    store.removeExpressionVariant(variant.id, presetID: preset.id, for: character.id)
                },
                removeFromCollectionLabel: "Remove Variant"
            ),
            onTap: {
                store.imaginePreviewImagePath = variant.imagePath
            },
            onDoubleTap: {
                QuickLookPreviewController.shared.present(urls: [resolvedURL ?? URL(fileURLWithPath: variant.imagePath)], startAt: 0)
            },
            bottomTrailingOverlay: isMaster ? AnyView(
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.green)
                    .background(Circle().fill(.black.opacity(0.5)).padding(-2))
                    .padding(5)
            ) : nil
        )
    }

    // MARK: - Generation

    private func generateExpression(_ preset: EmotionLibrary.ExpressionPreset) {
        guard let reference = frontNeutralVariant else {
            generationError = "Choose a Head Turnaround Grid → Front Neutral image for this character first."
            return
        }
        guard store.canGenerateGeminiImagesImmediately else {
            generationError = store.geminiImageGenerationAvailabilityError?.localizedDescription ?? "Gemini image generation is not available."
            return
        }
        guard !generatingPresetIDs.contains(preset.id) else { return }

        generatingPresetIDs.insert(preset.id)
        expandedPresetID = preset.id

        Task { @MainActor in
            defer { generatingPresetIDs.remove(preset.id) }
            do {
                let prompt = ExpressionBatchService.buildExpressionPrompt(
                    emotionName: preset.displayName,
                    character: character
                )
                let referenceURL = store.resolvedCharacterAssetURL(for: reference.imagePath) ?? URL(fileURLWithPath: reference.imagePath)
                guard let referenceImage = GeminiImageService.referenceImage(from: referenceURL) else {
                    throw ExpressionGenerationError.missingReference
                }
                let request = GeminiImageService.GenerationRequest(
                    prompt: prompt,
                    referenceImages: [referenceImage],
                    model: store.selectedGeminiModel,
                    aspectRatio: "1:1",
                    imageSize: "2K"
                )
                store.logGeminiAPICall(endpoint: "image-generation", source: "ExpressionLibraryView.generateExpression")
                let result = try await GeminiImageService().generate(request: request, apiKey: store.geminiAPIKey)
                try store.storeExpressionVariant(
                    result.imageData,
                    presetID: preset.id,
                    displayName: preset.displayName,
                    prompt: prompt,
                    model: store.selectedGeminiModel,
                    for: character.id,
                    referencePath: reference.imagePath
                )
                store.statusMessage = "Generated \(preset.displayName) expression"
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private enum ExpressionGenerationError: LocalizedError {
        case missingReference
        var errorDescription: String? {
            "Could not read the selected Head Turnaround Front Neutral reference image."
        }
    }

    // MARK: - Parameter Bar

    private func parameterBar(label: String, value: Double, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)

            GeometryReader { geo in
                let width = geo.size.width
                let midX = width / 2
                let normalized = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let barX = width * normalized

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(height: 4)
                    Rectangle()
                        .fill(.tertiary)
                        .frame(width: 1, height: 6)
                        .position(x: midX, y: 3)
                    Circle()
                        .fill(value >= 0 ? Color.blue : Color.orange)
                        .frame(width: 6, height: 6)
                        .position(x: max(3, min(width - 3, barX)), y: 3)
                }
            }
            .frame(height: 6)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Category Badge

    private func categoryBadge(_ category: EmotionLibrary.EmotionCategory) -> some View {
        let color: Color = switch category {
        case .positive: .green
        case .negative: .red
        case .surprise: .yellow
        case .social: .blue
        case .neutral: .gray
        case .compound: .purple
        case .microExpression: .orange
        }

        return Text(category.rawValue.prefix(3).uppercased())
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
    }
}
