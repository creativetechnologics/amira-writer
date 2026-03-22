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
    @State private var hasConfirmedCost = false
    @State private var generationTask: Task<Void, Never>?

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
        let count: Int
        switch generationMode {
        case .turnaround: count = AngleView.allCases.count
        case .expressions: count = GeminiImageService.ExpressionPrompts.expressions.count
        case .visemes: count = PrestonBlairViseme.allCases.count
        case .partBreakdown: count = (character?.parts.count ?? 0) > 0 ? character!.parts.count : 17
        }
        return GeminiImageService.estimateCost(model: store.selectedGeminiModel, imageCount: count)
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
            Text("Reference Image")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let character, !character.parts.isEmpty,
               let frontSet = character.parts.first?.drawingSets[.front],
               !frontSet.variants.isEmpty {
                Label("Reference image available", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
                Label("No reference image set. You can still generate, but results may be less consistent.", systemImage: "exclamationmark.circle")
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
                    hasConfirmedCost = false
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
                    startGeneration()
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.geminiAPIKey.isEmpty || character == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - Generation Logic

    private func startGeneration() {
        guard let character else { return }

        isGenerating = true
        generationProgress = 0
        generatedImages.removeAll()
        errorMessage = nil

        let service = GeminiImageService()
        let apiKey = store.geminiAPIKey
        let model = store.selectedGeminiModel

        generationTask = Task {
            do {
                switch generationMode {
                case .turnaround:
                    try await generateTurnaround(service: service, character: character, apiKey: apiKey, model: model)
                case .expressions:
                    try await generateExpressions(service: service, character: character, apiKey: apiKey, model: model)
                case .visemes:
                    try await generateVisemes(service: service, character: character, apiKey: apiKey, model: model)
                case .partBreakdown:
                    try await generatePartBreakdown(service: service, character: character, apiKey: apiKey, model: model)
                }
            } catch is CancellationError {
                progressMessage = "Cancelled"
            } catch {
                errorMessage = error.localizedDescription
            }

            isGenerating = false
        }
    }

    private func generateTurnaround(
        service: GeminiImageService, character: AnimationCharacter,
        apiKey: String, model: GeminiModel
    ) async throws {
        let angles = GeminiImageService.TurnaroundPrompts.generationOrder
        let total = Double(angles.count)

        // Build reference from existing front image if available
        let refImages = buildReferenceImages(for: character)

        for (i, angle) in angles.enumerated() {
            try Task.checkCancellation()

            progressMessage = "Generating \(angle.rawValue) view (\(i + 1)/\(angles.count))..."
            generationProgress = Double(i) / total

            let prompt = GeminiImageService.TurnaroundPrompts.prompt(for: angle, characterName: character.name)
            let request = GeminiImageService.GenerationRequest(
                prompt: prompt,
                referenceImages: refImages,
                model: model,
                aspectRatio: "3:4"
            )

            let result = try await service.generate(request: request, apiKey: apiKey)

            generatedImages.append(GeneratedImageEntry(
                label: "\(angle.rawValue) view",
                image: result.image,
                data: result.imageData,
                accepted: true
            ))
        }

        generationProgress = 1.0
        progressMessage = "Complete!"
    }

    private func generateExpressions(
        service: GeminiImageService, character: AnimationCharacter,
        apiKey: String, model: GeminiModel
    ) async throws {
        let expressions = GeminiImageService.ExpressionPrompts.expressions
        let total = Double(expressions.count)
        let refImages = buildReferenceImages(for: character)

        for (i, expression) in expressions.enumerated() {
            try Task.checkCancellation()

            progressMessage = "Generating \(expression) (\(i + 1)/\(expressions.count))..."
            generationProgress = Double(i) / total

            let prompt = GeminiImageService.ExpressionPrompts.prompt(for: expression, characterName: character.name)
            let request = GeminiImageService.GenerationRequest(
                prompt: prompt,
                referenceImages: refImages,
                model: model,
                aspectRatio: "1:1"
            )

            let result = try await service.generate(request: request, apiKey: apiKey)

            generatedImages.append(GeneratedImageEntry(
                label: expression,
                image: result.image,
                data: result.imageData,
                accepted: true
            ))
        }

        generationProgress = 1.0
        progressMessage = "Complete!"
    }

    private func generateVisemes(
        service: GeminiImageService, character: AnimationCharacter,
        apiKey: String, model: GeminiModel
    ) async throws {
        let visemes = PrestonBlairViseme.allCases
        let total = Double(visemes.count)
        let refImages = buildReferenceImages(for: character)

        for (i, viseme) in visemes.enumerated() {
            try Task.checkCancellation()

            progressMessage = "Generating \(viseme.label) mouth (\(i + 1)/\(visemes.count))..."
            generationProgress = Double(i) / total

            let prompt = GeminiImageService.VisemePrompts.prompt(for: viseme, characterName: character.name)
            let request = GeminiImageService.GenerationRequest(
                prompt: prompt,
                referenceImages: refImages,
                model: model,
                aspectRatio: "1:1"
            )

            let result = try await service.generate(request: request, apiKey: apiKey)

            generatedImages.append(GeneratedImageEntry(
                label: "Viseme: \(viseme.label)",
                image: result.image,
                data: result.imageData,
                accepted: true
            ))
        }

        generationProgress = 1.0
        progressMessage = "Complete!"
    }

    private func generatePartBreakdown(
        service: GeminiImageService, character: AnimationCharacter,
        apiKey: String, model: GeminiModel
    ) async throws {
        let parts = character.parts.isEmpty ? defaultPartTypes() : character.parts.map(\.partType)
        let total = Double(parts.count)
        let refImages = buildReferenceImages(for: character)
        let angle = store.generationTargetAngle ?? .front

        for (i, partType) in parts.enumerated() {
            try Task.checkCancellation()

            progressMessage = "Extracting \(partType.rawValue) (\(i + 1)/\(parts.count))..."
            generationProgress = Double(i) / total

            let prompt = GeminiImageService.PartBreakdownPrompts.prompt(
                for: partType, characterName: character.name, angle: angle
            )
            let request = GeminiImageService.GenerationRequest(
                prompt: prompt,
                referenceImages: refImages,
                model: model,
                aspectRatio: "1:1"
            )

            let result = try await service.generate(request: request, apiKey: apiKey)

            generatedImages.append(GeneratedImageEntry(
                label: partType.rawValue,
                image: result.image,
                data: result.imageData,
                accepted: true
            ))
        }

        generationProgress = 1.0
        progressMessage = "Complete!"
    }

    // MARK: - Helpers

    private func buildReferenceImages(for character: AnimationCharacter) -> [GeminiImageService.ReferenceImage] {
        guard let animateURL = store.animateURL else { return [] }

        // Look for any existing character images to use as reference
        let charDir = animateURL.appendingPathComponent("characters").appendingPathComponent(
            character.owpSlug
        )

        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        guard let contents = try? FileManager.default.contentsOfDirectory(at: charDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var refs: [GeminiImageService.ReferenceImage] = []
        for url in contents where imageExtensions.contains(url.pathExtension.lowercased()) {
            if let ref = GeminiImageService.referenceImage(from: url) {
                refs.append(ref)
                break  // Use only first reference image
            }
        }

        return refs
    }

    private func defaultPartTypes() -> [PartType] {
        [.head, .torso, .upperArmLeft, .upperArmRight, .lowerArmLeft, .lowerArmRight,
         .handLeft, .handRight, .upperLegLeft, .upperLegRight, .lowerLegLeft, .lowerLegRight,
         .footLeft, .footRight, .hips, .face, .hairFront]
    }

    private func saveAcceptedImages() {
        guard let character, let animateURL = store.animateURL else { return }

        let charDir = animateURL.appendingPathComponent("characters").appendingPathComponent(
            character.owpSlug
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
