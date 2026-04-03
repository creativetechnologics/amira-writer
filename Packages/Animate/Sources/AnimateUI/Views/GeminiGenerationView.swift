import SwiftUI

/// Sheet for AI-assisted character asset generation.
///
/// Shows a generation mode picker (turnaround, expressions, visemes, part breakdown),
/// cost estimation with confirmation, progress tracking, and result preview.
@available(macOS 26.0, *)
struct GeminiGenerationView: View {
    @Bindable var store: AnimateStore
    @Environment(\.dismiss) private var dismiss

    @State private var generationMode: GenerationMode = .turnaround
    @State private var isGenerating = false
    @State private var generationProgress: Double = 0
    @State private var progressMessage = ""
    @State private var generatedImages: [GeneratedImageEntry] = []
    @State private var errorMessage: String?
    @State private var generationTask: Task<Void, Never>?
    @State private var preflightDrafts: [GeminiGenerationDraft] = []
    @State private var showPreflight = false

    enum GenerationMode: String, CaseIterable {
        case turnaround = "Turnaround Views"
        case expressions = "Expressions"
        case visemes = "Viseme Mouths"
        case partBreakdown = "Part Breakdown"
    }

    struct GeneratedImageEntry: Identifiable {
        var id = UUID()
        var label: String
        var image: NSImage
        var data: Data
        var accepted: Bool = false
    }

    private var character: AnimationCharacter? {
        store.selectedCharacter
    }

    private var costEstimate: GeminiImageService.CostEstimate {
        GeminiImageService.CostEstimate(
            model: store.selectedGeminiModel,
            imageCount: plannedDrafts.count,
            estimatedCost: plannedDrafts.reduce(0) { $0 + $1.estimatedCost }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()

            if isGenerating {
                generationProgressView
            } else if !generatedImages.isEmpty {
                resultsView
            } else {
                configurationView
            }

            Divider()

            // Footer buttons
            footer
        }
        .frame(width: 600, height: 500)
        .sheet(isPresented: $showPreflight) {
            GeminiGenerationPreflightSheet(
                store: store,
                drafts: $preflightDrafts,
                title: "Preview AI Character Generation",
                confirmTitle: "Run \(preflightDrafts.count) Request\(preflightDrafts.count == 1 ? "" : "s")",
                onConfirm: { drafts, _ in
                    showPreflight = false
                    startGeneration(with: drafts)
                },
                onCancel: {
                    showPreflight = false
                }
            )
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .foregroundStyle(.purple)
            Text("AI Character Generation")
                .font(.headline)
            Spacer()
            if let character {
                Text(character.name)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    // MARK: - Configuration

    @ViewBuilder
    private var configurationView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Mode picker
                VStack(alignment: .leading, spacing: 8) {
                    Text("Generation Type")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("Mode", selection: $generationMode) {
                        ForEach(GenerationMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Description
                modeDescription

                Divider()

                // Model selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Model")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("Model", selection: $store.selectedGeminiModel) {
                        ForEach(GeminiModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                // Cost estimate
                costEstimateSection

                // Reference image info
                referenceImageSection

                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private var modeDescription: some View {
        Text(modeDescriptionText)
            .font(.callout)
            .foregroundStyle(.secondary)
    }

    private var modeDescriptionText: String {
        switch generationMode {
        case .turnaround:
            "Generate 5 turnaround views (front, 3/4 front, side, 3/4 back, back) of the character in a neutral A-pose. Each view is generated using the front reference image for consistency."
        case .expressions:
            "Generate 10 facial expression variants (neutral, happy, sad, angry, surprised, worried, disgusted, fearful, smirking, laughing). Uses the character's front face as reference."
        case .visemes:
            "Generate 10 Preston Blair viseme mouth shapes for lip sync animation. Each mouth shape corresponds to a phoneme group used in speech and singing."
        case .partBreakdown:
            "Break down the character into individual body parts for puppet animation. Each part is isolated on a transparent background."
        }
    }

    @ViewBuilder
    private var costEstimateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Cost Estimate")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Image(systemName: "creditcard")
                    .foregroundStyle(.orange)
                Text(costEstimate.description)
                    .font(.body)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Actual costs may vary. This is an estimate based on average image generation costs.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var referenceImageSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference Images")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            let count = plannedDrafts.first?.referenceItems.count ?? 0

            if count > 0 {
                Label("\(count) references will be previewed before sending", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Label("No reference images are currently selected. You can still generate, but results may be less consistent.", systemImage: "exclamationmark.circle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var generationProgressView: some View {
        VStack(spacing: 20) {
            Spacer()

            ProgressView(value: generationProgress) {
                Text(progressMessage)
                    .font(.callout)
            }
            .progressViewStyle(.linear)
            .frame(maxWidth: 400)

            Text("\(Int(generationProgress * 100))%")
                .font(.title2)
                .monospacedDigit()

            if !generatedImages.isEmpty {
                Text("\(generatedImages.count) images generated so far")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Generated Images")
                    .font(.headline)
                Spacer()
                Text("\(generatedImages.count) images")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 12) {
                    ForEach($generatedImages) { $entry in
                        VStack(spacing: 4) {
                            Image(nsImage: entry.image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .overlay {
                                    if entry.accepted {
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.green, lineWidth: 2)
                                    }
                                }

                            Text(entry.label)
                                .font(.caption)
                                .lineLimit(1)

                            Toggle("Accept", isOn: $entry.accepted)
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                        }
                    }
                }
                .padding()
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            if isGenerating {
                Button("Cancel") {
                    generationTask?.cancel()
                    isGenerating = false
                    progressMessage = "Cancelled"
                }
                .keyboardShortcut(.cancelAction)
            } else if !generatedImages.isEmpty {
                Button("Discard All") {
                    generatedImages.removeAll()
                }

                Spacer()

                let acceptedCount = generatedImages.filter(\.accepted).count
                Button("Save \(acceptedCount) Accepted") {
                    saveAcceptedImages()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(acceptedCount == 0)
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Generate") {
                    preflightDrafts = plannedDrafts
                    showPreflight = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.geminiAPIKey.isEmpty || character == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - Generation Logic

    private func startGeneration(with drafts: [GeminiGenerationDraft]) {
        isGenerating = true
        generationProgress = 0
        generatedImages.removeAll()
        errorMessage = nil

        let service = GeminiImageService()
        let apiKey = store.geminiAPIKey

        generationTask = Task {
            do {
                try await generate(drafts: drafts, service: service, apiKey: apiKey)
            } catch is CancellationError {
                progressMessage = "Cancelled"
            } catch {
                errorMessage = error.localizedDescription
            }

            isGenerating = false
        }
    }

    private func generate(
        drafts: [GeminiGenerationDraft],
        service: GeminiImageService,
        apiKey: String
    ) async throws {
        let total = Double(max(drafts.count, 1))

        for (index, draft) in drafts.enumerated() {
            try Task.checkCancellation()

            progressMessage = "Generating \(draft.title) (\(index + 1)/\(drafts.count))..."
            generationProgress = Double(index) / total

            let request = GeminiImageService.GenerationRequest(
                prompt: draft.prompt,
                referenceImages: buildReferenceImages(from: draft.referenceItems),
                model: draft.model,
                aspectRatio: draft.aspectRatio,
                imageSize: draft.imageSize
            )

            store.logGeminiAPICall(endpoint: "image-generation", source: "GeminiGenerationView.generate()")
            let result = try await service.generate(request: request, apiKey: apiKey)

            generatedImages.append(GeneratedImageEntry(
                label: draft.title,
                image: result.image,
                data: result.imageData,
                accepted: true
            ))
        }

        generationProgress = 1.0
        progressMessage = "Complete!"
    }

    // MARK: - Helpers

    private var plannedDrafts: [GeminiGenerationDraft] {
        guard let character else { return [] }
        let referenceDrafts = referenceDrafts(from: store.curatedLookDevelopmentReferencePaths(for: character.id))

        switch generationMode {
        case .turnaround:
            return GeminiImageService.TurnaroundPrompts.generationOrder.map { angle in
                GeminiGenerationDraft(
                    title: "\(angle.rawValue) view",
                    destinationDescription: "Turnaround asset",
                    prompt: GeminiImageService.TurnaroundPrompts.prompt(for: angle, characterName: character.name),
                    model: store.selectedGeminiModel,
                    aspectRatio: "1:1",
                    imageSize: "2K",
                    referenceItems: referenceDrafts
                )
            }
        case .expressions:
            return GeminiImageService.ExpressionPrompts.expressions.map { expression in
                GeminiGenerationDraft(
                    title: expression,
                    destinationDescription: "Expression asset",
                    prompt: GeminiImageService.ExpressionPrompts.prompt(for: expression, characterName: character.name),
                    model: store.selectedGeminiModel,
                    aspectRatio: "1:1",
                    imageSize: "1K",
                    referenceItems: referenceDrafts
                )
            }
        case .visemes:
            return PrestonBlairViseme.allCases.map { viseme in
                GeminiGenerationDraft(
                    title: "Viseme: \(viseme.label)",
                    destinationDescription: "Viseme asset",
                    prompt: GeminiImageService.VisemePrompts.prompt(for: viseme, characterName: character.name),
                    model: store.selectedGeminiModel,
                    aspectRatio: "1:1",
                    imageSize: "1K",
                    referenceItems: referenceDrafts
                )
            }
        case .partBreakdown:
            let parts = character.parts.isEmpty ? defaultPartTypes() : character.parts.map(\.partType)
            let angle = store.generationTargetAngle ?? .front
            return parts.map { partType in
                GeminiGenerationDraft(
                    title: partType.rawValue,
                    destinationDescription: "Part breakdown asset",
                    prompt: GeminiImageService.PartBreakdownPrompts.prompt(
                        for: partType,
                        characterName: character.name,
                        angle: angle
                    ),
                    model: store.selectedGeminiModel,
                    aspectRatio: "1:1",
                    imageSize: "2K",
                    referenceItems: referenceDrafts
                )
            }
        }
    }

    private func buildReferenceImages(from references: [GeminiGenerationReferenceDraft]) -> [GeminiImageService.ReferenceImage] {
        references.filter(\.isIncluded).compactMap { reference in
            guard let url = store.resolvedCharacterAssetURL(for: reference.path) ?? resolvedAbsoluteURL(for: reference.path) else {
                return nil
            }
            return GeminiImageService.referenceImage(from: url)
        }
    }

    private func referenceDrafts(from paths: [String]) -> [GeminiGenerationReferenceDraft] {
        paths.map { path in
            GeminiGenerationReferenceDraft(
                label: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                path: path,
                isIncluded: true
            )
        }
    }

    private func resolvedAbsoluteURL(for path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func buildReferenceImages(for character: AnimationCharacter) -> [GeminiImageService.ReferenceImage] {
        store.curatedLookDevelopmentReferencePaths(for: character.id).compactMap { path in
            guard let url = store.resolvedCharacterAssetURL(for: path) else { return nil }
            return GeminiImageService.referenceImage(from: url)
        }
    }

    private func defaultPartTypes() -> [PartType] {
        [.head, .torso, .upperArmLeft, .upperArmRight, .lowerArmLeft, .lowerArmRight,
         .handLeft, .handRight, .upperLegLeft, .upperLegRight, .lowerLegLeft, .lowerLegRight,
         .footLeft, .footRight, .hips, .face, .hairFront]
    }

    private func saveAcceptedImages() {
        guard let character, let animateURL = store.animateURL else { return }

        let charDir = animateURL.appendingPathComponent("characters").appendingPathComponent(
            character.assetFolderSlug
        )

        let subDir: String
        switch generationMode {
        case .turnaround: subDir = "turnaround"
        case .expressions: subDir = "expressions"
        case .visemes: subDir = "visemes"
        case .partBreakdown: subDir = "parts"
        }

        let outputDir = charDir.appendingPathComponent(subDir)

        for entry in generatedImages where entry.accepted {
            let filename = entry.label
                .lowercased()
                .replacingOccurrences(of: " ", with: "_")
                .replacingOccurrences(of: "/", with: "_")
                + ".png"

            _ = try? GeminiImageService.saveImage(entry.data, to: outputDir, filename: filename)
        }

        store.statusMessage = "Saved \(generatedImages.filter(\.accepted).count) images to \(subDir)/"
    }
}
