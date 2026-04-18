import SwiftUI

@available(macOS 26.0, *)
struct LORATrainingSheet: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter
    /// Pre-selected paths (e.g., from the gallery's persistent selection). If empty, selects all.
    var initialSelectedPaths: Set<String> = []
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runpodService = RunPodLORAService.shared

    @State private var config = LORATrainingModels.TrainingConfig()
    @State private var selectedPaths: Set<String> = []
    @State private var triggerWord: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("LORA Training")
                        .font(.headline)
                    Text("\(character.name) — trigger: \(triggerWord)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    imageSelectionGrid
                    configSection
                }
                .padding()
            }

            Divider()

            // Footer
            HStack {
                Text("\(selectedPaths.count) images selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    queueTraining()
                } label: {
                    Label(queueButtonTitle, systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
                .disabled(!canSubmitTraining)

                Button {
                    startTraining()
                } label: {
                    Label("Start Now", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmitTraining || runpodService.hasActiveJob)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 650, height: 550)
        .onAppear {
            config.preset = .high
            config.baseModel = .fluxKlein9B
            config.networkDim = 64
            config.networkAlpha = 32
            triggerWord = LORATrainingModels.generateTriggerWord(for: character.name)
            config.triggerWord = triggerWord
            config.subjectClassNoun = character.genderType.promptNoun
            selectedPaths = initialSelectedPaths
            runpodService.loadAPIKey()
            if !store.runPodAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               store.runPodGPUPriceSummaries.isEmpty {
                Task { await store.refreshRunPodAccountSummary() }
            }
        }
    }

    // MARK: - Image Preview (read-only)

    /// Read-only preview of the exact set of images that will be sent to training.
    /// Path-format note: `galleryState.loraSelectedPaths` stores ABSOLUTE paths, but
    /// `character.inspirationImagePaths` stores RELATIVE paths. We iterate the
    /// selected set directly and let the URL resolver handle any path shape.
    private var imageSelectionGrid: some View {
        let previewPaths = selectedPaths.sorted()

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Training Images (preview)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(previewPaths.count) image\(previewPaths.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("This is exactly what will be uploaded to RunPod. To change the set, close this sheet and adjust LORA picks in the gallery (L / K).")
                .font(.caption)
                .foregroundStyle(.tertiary)

            if previewPaths.isEmpty {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("No images selected for LORA training. Pick images with L in the gallery.")
                        .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 6) {
                    ForEach(previewPaths, id: \.self) { path in
                        AsyncStoreThumbnailImage<AnyView>.rounded(
                            store: store,
                            path: path,
                            maxSize: 160,
                            width: 80,
                            height: 80,
                            contentMode: .fill,
                            cornerRadius: 4
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.purple.opacity(0.6), lineWidth: 1.5)
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    // MARK: - Config

    private var configSection: some View {
        GroupBox("Training Configuration") {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Training Steps") {
                    Text("3000 (hard-coded)")
                        .font(.body.monospacedDigit())
                }

                Text("Character LORA training is now always run at 3000 steps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                LabeledContent("Training Profile") {
                    Text(LORATrainingModels.TrainingPreset.high.displayName)
                }

                LabeledContent("Base Model") {
                    Picker("", selection: $config.baseModel) {
                        ForEach(LORATrainingModels.BaseModel.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .frame(maxWidth: 220)
                }

                Text(baseModelHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let livePricing = liveGPUPriceSummaryText {
                    Text(livePricing)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Trigger Word") {
                    TextField("trigger", text: $triggerWord)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 150)
                        .onChange(of: triggerWord) { _, new in config.triggerWord = new }
                }

                LabeledContent("Network Rank") {
                    Picker("", selection: $config.networkDim) {
                        Text("32").tag(32)
                        Text("64").tag(64)
                        Text("128").tag(128)
                        Text("256").tag(256)
                    }
                    .frame(maxWidth: 120)
                    .onChange(of: config.networkDim) { _, newValue in
                        config.networkAlpha = max(1, newValue / 2)
                    }
                }

                LabeledContent("Learning Rate") {
                    TextField("1e-4", value: $config.learningRate, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                }

                LabeledContent("Resolution") {
                    Picker("", selection: $config.resolution) {
                        Text("512").tag(512)
                        Text("768").tag(768)
                        Text("1024").tag(1024)
                    }
                    .frame(maxWidth: 100)
                }

                if !runpodService.hasAPIKey {
                    Text("RunPod API key not set. Go to API Settings → RunPod tab to enter your key.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                if !runpodService.hasHuggingFaceToken {
                    Text("HuggingFace token not found. FLUX.2 model downloads look for `~/.lora-maker/hf_token` (the laptop setup script copies it automatically).")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Actions

    /// Kicks off training and dismisses the sheet immediately. Progress is
    /// shown in the sidebar's `generationStatusSection` (`loraJobRow`), which
    /// reads from `RunPodLORAService.shared.currentJob` and also provides the
    /// Cancel & Terminate Pod button. The sheet never blocks the app.
    private func startTraining() {
        let resolvedPaths = selectedPaths.compactMap { path -> String? in
            store.resolvedCharacterAssetURL(for: path)?.path ?? path
        }
        config.selectedImagePaths = resolvedPaths
        config.subjectClassNoun = character.genderType.promptNoun

        let animateURL = store.animateURL ?? URL(fileURLWithPath: "/tmp")
        let characterName = character.name
        let characterSlug = character.assetFolderSlug
        let submittedConfig = config

        dismiss()

        Task {
            do {
                try await runpodService.startTraining(
                    config: submittedConfig,
                    characterName: characterName,
                    characterSlug: characterSlug,
                    imagePaths: resolvedPaths,
                    animateURL: animateURL,
                    autoStartQueuedJobsAfterSuccess: true,
                    onProgress: { _ in }
                )

                let trainedFilename = submittedConfig.baseModel.outputFilename(for: submittedConfig.triggerWord)
                let syncedCharacter = await MainActor.run { () -> AnimationCharacter? in
                    let preservedWeight = store.characters.first(where: { $0.id == character.id })?.activeLORAWeight ?? 1.0
                    store.setCharacterActiveLORA(
                        filename: trainedFilename,
                        triggerWord: submittedConfig.triggerWord,
                        weight: preservedWeight,
                        for: character.id
                    )
                    return store.characters.first(where: { $0.id == character.id })
                }

                if let syncedCharacter {
                    _ = try? await DrawThingsLoRAService().syncActiveLoRA(
                        for: syncedCharacter,
                        animateURL: animateURL,
                        config: store.drawThingsPlaceConfig
                    )
                }
            } catch {
                // Error surfaces through RunPodLORAService.currentJob.errorMessage
                // which the sidebar renders in loraJobRow.
            }
        }
    }

    private func queueTraining() {
        let resolvedPaths = selectedPaths.compactMap { path -> String? in
            store.resolvedCharacterAssetURL(for: path)?.path ?? path
        }
        config.selectedImagePaths = resolvedPaths
        config.subjectClassNoun = character.genderType.promptNoun

        let animateURL = store.animateURL ?? URL(fileURLWithPath: "/tmp")
        let submittedConfig = config
        let characterName = character.name
        let characterSlug = character.assetFolderSlug

        dismiss()

        Task {
            try? runpodService.enqueueTraining(
                config: submittedConfig,
                characterName: characterName,
                characterSlug: characterSlug,
                imagePaths: resolvedPaths,
                animateURL: animateURL
            )
        }
    }

    private var baseModelHelpText: String {
        switch config.baseModel {
        case .fluxKlein4B:
            return "4B is the cheaper FLUX option and uses RunPod + Hugging Face downloads."
        case .fluxKlein9B:
            return "9B is now the default FLUX target for higher identity fidelity and uses a larger RunPod GPU."
        }
    }

    private var canSubmitTraining: Bool {
        !selectedPaths.isEmpty && runpodService.hasAPIKey && runpodService.hasHuggingFaceToken
    }

    private var queueButtonTitle: String {
        if runpodService.queuedJobs.isEmpty {
            return "Queue"
        }
        return "Queue (\(runpodService.queuedJobs.count))"
    }

    private var liveGPUPriceSummaryText: String? {
        guard let pricing = store.runPodGPUPriceSummary(for: config.baseModel.gpuType) else { return nil }
        var segments: [String] = []
        if let community = pricing.communityPrice {
            segments.append(String(format: "community $%.3f/hr", community))
        }
        if let secure = pricing.securePrice {
            segments.append(String(format: "secure $%.3f/hr", secure))
        }
        if let communitySpot = pricing.communitySpotPrice {
            segments.append(String(format: "community spot $%.3f/hr", communitySpot))
        }
        if let secureSpot = pricing.secureSpotPrice {
            segments.append(String(format: "secure spot $%.3f/hr", secureSpot))
        }
        guard !segments.isEmpty else { return nil }
        return "Live RunPod pricing for \(config.baseModel.gpuType): " + segments.joined(separator: " • ")
    }
}
