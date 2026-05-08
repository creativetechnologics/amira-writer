import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct APISettingsSheet: View {
    @Bindable var store: AnimateStore
    let onDismiss: () -> Void

    @State private var geminiKeyDraft: String = ""
    @State private var openAIKeyDraft: String = ""
    @State private var imageAnalysisGeminiKeyDraft: String = ""
    @State private var miniMaxKeyDraft: String = ""
    @State private var deepSeekKeyDraft: String = ""
    @State private var viduKeyDraft: String = ""
    @State private var runPodKeyDraft: String = ""
        @State private var revealGeminiKey: Bool = false
    @State private var revealOpenAIKey: Bool = false
    @State private var revealImageAnalysisGeminiKey: Bool = false
    @State private var revealMiniMaxKey: Bool = false
    @State private var revealDeepSeekKey: Bool = false
    @State private var revealViduKey: Bool = false
    @State private var revealRunPodKey: Bool = false
        @State private var selectedTab: SettingsTab = .gemini

    // Vertex AI backend configuration (persisted in UserDefaults).
    @State private var imageGenBackend: ImageGenBackend = .aiStudio
    @State private var vertexProjectDraft: String = ""
    @State private var vertexRegionDraft: String = "global"
    @State private var vertexProbeMessage: String = ""
    @State private var vertexProbeIsError: Bool = false
    @State private var vertexProbing: Bool = false
    @State private var vertexAttemptLedgerRefreshID = UUID()
    @State private var imageAnalysisBackend: ImageAnalysisBackend = .aiStudio
    @State private var imageAnalysisVertexProjectDraft: String = ""
    @State private var imageAnalysisVertexRegionDraft: String = "global"
    @State private var isResettingImageAnalysisQueue = false
    @State private var imageAnalysisQueueResetMessage = ""
    @State private var imageAnalysisConfigurationRefreshTask: Task<Void, Never>?

    enum SettingsTab: String, CaseIterable {
        case gemini = "Gemini"
        case openAI = "OpenAI"
        case imageAnalysis = "Image Analysis"
        case supplementalLLM = "Supplemental LLM"
        case vidu = "Vidu"
        case runPod = "RunPod"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Divider()

            Picker("Service", selection: $selectedTab) {
                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case .gemini:
                geminiForm
            case .openAI:
                openAIForm
            case .imageAnalysis:
                imageAnalysisForm
            case .supplementalLLM:
                supplementalLLMForm
            case .vidu:
                viduForm
            case .runPod:
                runPodForm
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 680)
        .onAppear {
            geminiKeyDraft = store.geminiAPIKey
            openAIKeyDraft = store.openAIAPIKey
            imageAnalysisGeminiKeyDraft = store.imageAnalysisGeminiAPIKey
            miniMaxKeyDraft = store.miniMaxAPIKey
            deepSeekKeyDraft = store.deepSeekAPIKey
            viduKeyDraft = store.viduAPIKey
            runPodKeyDraft = store.runPodAPIKey
                        imageGenBackend = ImageGenBackendStore.currentBackend()
            let vertex = ImageGenBackendStore.currentVertexSettings()
            vertexProjectDraft = vertex.projectID
            vertexRegionDraft = vertex.region
            imageAnalysisBackend = ImageAnalysisBackendStore.currentBackend()
            imageAnalysisVertexProjectDraft = ImageAnalysisBackendStore.currentVertexProjectID()
            imageAnalysisVertexRegionDraft = ImageAnalysisBackendStore.currentVertexRegion()
            if selectedTab == .runPod {
                Task { await store.refreshRunPodAccountSummary(using: runPodKeyDraft) }
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            guard newValue == .runPod else { return }
            Task { await store.refreshRunPodAccountSummary(using: runPodKeyDraft) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AnimateStore.vertexImageGenerationAttemptLedgerDidChangeNotification)) { _ in
            vertexAttemptLedgerRefreshID = UUID()
        }
        .onDisappear {
            imageAnalysisConfigurationRefreshTask?.cancel()
            imageAnalysisConfigurationRefreshTask = nil
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Settings")
                .font(.title3.weight(.semibold))
            Text("Manage API keys for AI services used by Animate. Keys are stored in the project folder (Settings/api-credentials.json) and synced between machines by Syncthing.")
                .font(.callout)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Gemini

    private var geminiForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            backendPicker

            if imageGenBackend == .aiStudio {
                apiKeyField(
                    label: "Gemini API Key",
                    draft: $geminiKeyDraft,
                    reveal: $revealGeminiKey,
                    placeholder: "Paste Gemini API key...",
                    isSaved: !store.geminiAPIKey.isEmpty,
                    savedLabel: "Gemini key saved.",
                    unsavedLabel: "No Gemini key saved yet."
                )
            } else {
                vertexForm
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Default Model")
                    .font(.body.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Picker("Default Model", selection: $store.selectedGeminiModel) {
                    ForEach(GeminiModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)

                Text("Default for master sheets, head poses, costume poses, accessories, and other Gemini requests.")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - OpenAI

    private var openAIForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            apiKeyField(
                label: "OpenAI API Key",
                draft: $openAIKeyDraft,
                reveal: $revealOpenAIKey,
                placeholder: "Paste OpenAI API key...",
                isSaved: !store.openAIAPIKey.isEmpty,
                savedLabel: "OpenAI key saved.",
                unsavedLabel: "No OpenAI key saved yet."
            )

            Text("Used by the Scenes prompt/image pane for GPT Image generation. The key is stored in the project credential file with the other AI service keys.")
                .font(.caption)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Image Analysis

    private var imageAnalysisForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Backend")
                    .font(.body.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Picker("Image Analysis Backend", selection: $imageAnalysisBackend) {
                    ForEach(ImageAnalysisBackend.allCases, id: \.self) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: imageAnalysisBackend) { _, newValue in
                    ImageAnalysisBackendStore.setBackend(newValue)
                    store.refreshImageAnalysisConfiguration()
                }

                Text(imageAnalysisBackend.description)
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if imageAnalysisBackend == .aiStudio {
                apiKeyField(
                    label: "Image Analysis Gemini API Key",
                    draft: $imageAnalysisGeminiKeyDraft,
                    reveal: $revealImageAnalysisGeminiKey,
                    placeholder: "Paste Gemini API key for image analysis...",
                    isSaved: !store.imageAnalysisGeminiAPIKey.isEmpty,
                    savedLabel: "Image analysis key saved.",
                    unsavedLabel: "No image analysis key saved yet."
                )

                Text("Used for visual analysis and embedding of images. Must be a Google AI Studio key for generativelanguage.googleapis.com. Kept separate from the image generation key above.")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vertex Project ID")
                            .font(.body.bold())
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                        TextField("e.g. vertex-493406", text: $imageAnalysisVertexProjectDraft)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: imageAnalysisVertexProjectDraft) { _, newValue in
                                ImageAnalysisBackendStore.setVertexSettings(
                                    projectID: newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                    region: imageAnalysisVertexRegionDraft
                                )
                                scheduleImageAnalysisConfigurationRefresh()
                            }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Vertex Region")
                            .font(.body.bold())
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                        Picker("Image Analysis Vertex Region", selection: $imageAnalysisVertexRegionDraft) {
                            ForEach(["global", "us-central1", "us-east4", "us-west1", "europe-west4", "asia-southeast1"], id: \.self) { r in
                                Text(r).tag(r)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .onChange(of: imageAnalysisVertexRegionDraft) { _, newValue in
                            ImageAnalysisBackendStore.setVertexSettings(
                                projectID: imageAnalysisVertexProjectDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                region: newValue
                            )
                            scheduleImageAnalysisConfigurationRefresh()
                        }
                    }

                    Text("Uses your existing gcloud application-default login for auth. Run `gcloud auth application-default login` if needed.")
                        .font(.caption)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // Image Intelligence Status
            VStack(alignment: .leading, spacing: 8) {
                Text("Image Intelligence Status")
                    .font(.body.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                HStack {
                    Image(systemName: "brain.head.profile")
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text("Backfill and analysis status will appear here")
                        .font(.caption)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }

                HStack(spacing: 12) {
                    Button("Run Backfill") {
                        store.runImageIntelligenceBackfill(dryRun: false) { report in
                            print("[ImageIntelligence] Backfill complete: \(report.summary)")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Dry Run") {
                        store.runImageIntelligenceBackfill(dryRun: true) { report in
                            print("[ImageIntelligence] Dry run complete: \(report.summary)")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Start Worker") {
                        store.startImageAnalysisWorker()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Stop Worker") {
                        store.stopImageAnalysisWorker()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        resetImageAnalysisQueue()
                    } label: {
                        if isResettingImageAnalysisQueue {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Reset Queue", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isResettingImageAnalysisQueue)
                }

                if !imageAnalysisQueueResetMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(imageAnalysisQueueResetMessage)
                        .font(.caption)
                        .foregroundStyle(imageAnalysisQueueResetMessage.localizedCaseInsensitiveContains("could not") ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func resetImageAnalysisQueue() {
        isResettingImageAnalysisQueue = true
        imageAnalysisQueueResetMessage = "Resetting image analysis queue…"
        Task {
            let message = await store.resetImageAnalysisQueue()
            await MainActor.run {
                imageAnalysisQueueResetMessage = message
                isResettingImageAnalysisQueue = false
            }
        }
    }

    private func scheduleImageAnalysisConfigurationRefresh() {
        imageAnalysisConfigurationRefreshTask?.cancel()
        imageAnalysisConfigurationRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            store.refreshImageAnalysisConfiguration()
            imageAnalysisConfigurationRefreshTask = nil
        }
    }

    private var backendPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backend")
                .font(.body.bold())
                .foregroundStyle(OperaChromeTheme.textPrimary)

            Picker("Backend", selection: $imageGenBackend) {
                ForEach(ImageGenBackend.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: imageGenBackend) { _, newValue in
                ImageGenBackendStore.setBackend(newValue)
            }

            Text(imageGenBackend == .aiStudio
                 ? "Routes Gemini image requests to generativelanguage.googleapis.com with your personal API key."
                 : "Routes Gemini image requests to Vertex AI using a gcloud-issued OAuth token. Useful for burning through GCP credits or running under org billing.")
                .font(.caption)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var vertexForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Project ID")
                    .font(.body.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                TextField("e.g. vertex-493406", text: $vertexProjectDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: vertexProjectDraft) { _, newValue in
                        ImageGenBackendStore.setVertexSettings(
                            VertexSettings(projectID: newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                                           region: vertexRegionDraft))
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Region")
                    .font(.body.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Picker("Region", selection: $vertexRegionDraft) {
                    ForEach(["global", "us-central1", "us-east4", "us-west1", "europe-west4", "asia-southeast1"], id: \.self) { r in
                        Text(r).tag(r)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .onChange(of: vertexRegionDraft) { _, newValue in
                    ImageGenBackendStore.setVertexSettings(
                        VertexSettings(projectID: vertexProjectDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                       region: newValue))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button {
                        probeVertexAuth()
                    } label: {
                        if vertexProbing { ProgressView().controlSize(.small) }
                        else { Label("Test gcloud auth", systemImage: "key.horizontal") }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(vertexProbing)
                    Spacer()
                }
                if !vertexProbeMessage.isEmpty {
                    Text(vertexProbeMessage)
                        .font(.caption)
                        .foregroundStyle(vertexProbeIsError ? .red : .green)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("First-time setup: run `gcloud auth application-default login` in Terminal, then click Test above.")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func probeVertexAuth() {
        vertexProbing = true
        vertexProbeMessage = ""
        Task {
            do {
                let token = try await VertexAIClient.fetchTokenViaGcloud()
                vertexProbeMessage = "OK — token acquired (\(token.count) chars)."
                vertexProbeIsError = false
            } catch {
                vertexProbeMessage = "Auth failed: \(error.localizedDescription)"
                vertexProbeIsError = true
            }
            vertexProbing = false
        }
    }

    private var shouldShowVertexAttemptLedger: Bool {
        imageGenBackend == .vertex || !recentVertexImageAttempts.isEmpty
    }

    private var recentVertexImageAttempts: [AnimateStore.VertexImageGenerationAttemptRecord] {
        _ = vertexAttemptLedgerRefreshID
        return AnimateStore.recentVertexImageGenerationAttempts()
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(8)
            .map { $0 }
    }

    private var recentVertexAttemptLedgerSection: some View {
        let attempts = recentVertexImageAttempts
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if attempts.isEmpty {
                    Text("No Vertex image-generation attempts recorded yet.")
                        .font(.caption)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(Array(attempts.enumerated()), id: \.element.id) { index, attempt in
                        vertexAttemptRow(attempt)

                        if index < attempts.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recent Vertex image-generation attempts")
                        .font(.body.bold())
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                    Text("Latest \(attempts.count) recorded attempts.")
                        .font(.caption)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            }
        }
    }

    private func vertexAttemptRow(_ attempt: AnimateStore.VertexImageGenerationAttemptRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            vertexAttemptStatusBadge(for: attempt.status)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(vertexAttemptTitle(for: attempt))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Text("Started \(attempt.startedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("\(vertexAttemptModelName(for: attempt)) · \(attempt.imageSize) · \(attempt.aspectRatio)")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(attempt.isEditRequest ? "Edit" : "Generate") · refs \(attempt.referenceImageCount) · est \(vertexAttemptCurrencyString(attempt.estimatedCostUSD)) · charged \(vertexAttemptCurrencyString(attempt.chargedEstimatedCostUSD))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if attempt.status == .failed,
                   let errorMessage = attempt.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func vertexAttemptStatusBadge(
        for status: AnimateStore.VertexImageGenerationAttemptRecord.Status
    ) -> some View {
        let presentation = vertexAttemptStatusPresentation(for: status)
        return Label(presentation.title, systemImage: presentation.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(presentation.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(presentation.color.opacity(0.12), in: Capsule())
            .accessibilityLabel(presentation.title)
    }

    private func vertexAttemptStatusPresentation(
        for status: AnimateStore.VertexImageGenerationAttemptRecord.Status
    ) -> (title: String, symbol: String, color: Color) {
        switch status {
        case .running:
            return ("Running", "circle.dashed", .blue)
        case .succeeded:
            return ("Succeeded", "checkmark.circle.fill", .green)
        case .failed:
            return ("Failed", "exclamationmark.triangle.fill", .red)
        }
    }

    private func vertexAttemptTitle(
        for attempt: AnimateStore.VertexImageGenerationAttemptRecord
    ) -> String {
        switch attempt.status {
        case .running:
            return "Running"
        case .succeeded:
            return "Succeeded"
        case .failed:
            return "Failed"
        }
    }

    private func vertexAttemptModelName(
        for attempt: AnimateStore.VertexImageGenerationAttemptRecord
    ) -> String {
        GeminiModel(rawValue: attempt.model)?.displayName ?? attempt.model
    }

    private func vertexAttemptCurrencyString(_ value: Double) -> String {
        String(format: "$%.4f", value)
    }

    // MARK: - Supplemental LLM

    private var supplementalLLMForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Provider")
                    .font(.body.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Picker("Supplemental LLM Provider", selection: $store.supplementalLLMProvider) {
                    ForEach(SupplementalLLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: store.supplementalLLMProvider) { _, provider in
                    if !provider.knownModels.contains(store.supplementalLLMModel) {
                        store.supplementalLLMModel = provider.defaultModel
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Model")
                    .font(.body.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Picker("Supplemental LLM Model", selection: $store.supplementalLLMModel) {
                    ForEach(store.supplementalLLMProvider.knownModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                .pickerStyle(.menu)
            }

            apiKeyField(
                label: "MiniMax API Key",
                draft: $miniMaxKeyDraft,
                reveal: $revealMiniMaxKey,
                placeholder: "Paste MiniMax API key...",
                isSaved: !store.miniMaxAPIKey.isEmpty,
                savedLabel: "MiniMax key saved.",
                unsavedLabel: "No MiniMax key saved yet."
            )

            apiKeyField(
                label: "DeepSeek API Key",
                draft: $deepSeekKeyDraft,
                reveal: $revealDeepSeekKey,
                placeholder: "Paste DeepSeek API key...",
                isSaved: !store.deepSeekAPIKey.isEmpty,
                savedLabel: "DeepSeek key saved.",
                unsavedLabel: "No DeepSeek key saved yet."
            )

            Text("Used for Canvas prompt generation, continuity-rule extraction, and other supplemental text features. DeepSeek uses https://api.deepseek.com/chat/completions with V4 Flash by default.")
                .font(.caption)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Vidu

    private var viduForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            apiKeyField(
                label: "Vidu API Key",
                draft: $viduKeyDraft,
                reveal: $revealViduKey,
                placeholder: "Paste Vidu API key...",
                isSaved: !store.viduAPIKey.isEmpty,
                savedLabel: "Vidu key saved.",
                unsavedLabel: "No Vidu key saved yet."
            )

            Text("Used for video generation. Get a key at platform.vidu.com.")
                .font(.caption)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - RunPod

    private var runPodForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            apiKeyField(
                label: "RunPod API Key",
                draft: $runPodKeyDraft,
                reveal: $revealRunPodKey,
                placeholder: "Paste RunPod API key...",
                isSaved: !store.runPodAPIKey.isEmpty,
                savedLabel: "RunPod key saved.",
                unsavedLabel: "No RunPod key saved yet."
            )

            Text("Used for RunPod GPU instances (mouth-sync). Get a key at runpod.io/console/user/settings.")
                .font(.caption)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("RunPod Account")
                        .font(.body.bold())
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                    Spacer()
                    Button {
                        Task { await store.refreshRunPodAccountSummary(using: runPodKeyDraft) }
                    } label: {
                        if store.isRefreshingRunPodAccountSummary {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(runPodKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isRefreshingRunPodAccountSummary)
                }

                if let summary = store.runPodAccountSummary {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "Funds left: $%.2f", summary.clientBalance))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(summary.underBalance ? .red : OperaChromeTheme.textPrimary)
                        Text(String(format: "Current spend: $%.3f/hr", summary.currentSpendPerHr))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                        if let minBalance = summary.minBalance {
                            Text(String(format: "Minimum balance threshold: $%.2f", minBalance))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        }
                    }
                }

                if !store.runPodGPUPriceSummaries.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live GPU pricing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                        ForEach(store.runPodGPUPriceSummaries.filter {
                            $0.displayName == "NVIDIA RTX A6000" || $0.displayName == "NVIDIA A100 80GB PCIe"
                        }, id: \.displayName) { price in
                            Text(runPodPriceLine(for: price))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        }
                    }
                }

                if let status = store.runPodAccountStatusMessage,
                   !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(status.localizedCaseInsensitiveContains("under the minimum balance") ? .orange : .red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }


    // MARK: - Shared API Key Field

    private func apiKeyField(
        label: String,
        draft: Binding<String>,
        reveal: Binding<Bool>,
        placeholder: String,
        isSaved: Bool,
        savedLabel: String,
        unsavedLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.body.bold())
                .foregroundStyle(OperaChromeTheme.textPrimary)

            HStack(spacing: 8) {
                Group {
                    if reveal.wrappedValue {
                        TextField(placeholder, text: draft)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField(placeholder, text: draft)
                            .textFieldStyle(.roundedBorder)
                    }
                }
                .font(.callout)

                Button(reveal.wrappedValue ? "Hide" : "Show") {
                    reveal.wrappedValue.toggle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Image(systemName: isSaved ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(isSaved ? .green : .orange)
                Text(isSaved ? savedLabel : unsavedLabel)
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Clear Keys", role: .destructive) {
                switch selectedTab {
                case .gemini:
                    geminiKeyDraft = ""
                    store.clearGeminiAPIKey()
                case .openAI:
                    openAIKeyDraft = ""
                    store.clearOpenAIAPIKey()
                case .imageAnalysis:
                    imageAnalysisGeminiKeyDraft = ""
                    store.clearImageAnalysisGeminiAPIKey()
                    store.refreshImageAnalysisConfiguration()
                case .supplementalLLM:
                    miniMaxKeyDraft = ""
                    deepSeekKeyDraft = ""
                    store.clearMiniMaxAPIKey()
                    store.clearDeepSeekAPIKey()
                case .vidu:
                    viduKeyDraft = ""
                    store.clearViduAPIKey()
                case .runPod:
                    runPodKeyDraft = ""
                    store.runPodAPIKey = ""
                case .meshy:
                    meshyKeyDraft = ""
                    store.clearMeshyAPIKey()
                }
            }
            .buttonStyle(.bordered)
            .disabled(currentKeyIsEmpty)

            Spacer()

            Button("Cancel") {
                onDismiss()
            }
            .buttonStyle(.bordered)

            Button("Save") {
                store.setGeminiAPIKey(geminiKeyDraft)
                store.setOpenAIAPIKey(openAIKeyDraft)
                store.setImageAnalysisGeminiAPIKey(imageAnalysisGeminiKeyDraft)
                store.refreshImageAnalysisConfiguration()
                store.setMiniMaxAPIKey(miniMaxKeyDraft)
                store.setDeepSeekAPIKey(deepSeekKeyDraft)
                store.setViduAPIKey(viduKeyDraft)
                store.runPodAPIKey = runPodKeyDraft
                // User saved fresh credentials — clear any auth-halt so a
                // subsequent call doesn't still refuse.
                GeminiImageService.acknowledgeAuthFailureResolved()
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var currentKeyIsEmpty: Bool {
        switch selectedTab {
        case .gemini:
            return store.geminiAPIKey.isEmpty && geminiKeyDraft.isEmpty
        case .openAI:
            return store.openAIAPIKey.isEmpty && openAIKeyDraft.isEmpty
        case .imageAnalysis:
            return store.imageAnalysisGeminiAPIKey.isEmpty && imageAnalysisGeminiKeyDraft.isEmpty
        case .supplementalLLM:
            return store.miniMaxAPIKey.isEmpty && miniMaxKeyDraft.isEmpty
                && store.deepSeekAPIKey.isEmpty && deepSeekKeyDraft.isEmpty
        case .vidu:
            return store.viduAPIKey.isEmpty && viduKeyDraft.isEmpty
        case .runPod:
            return store.runPodAPIKey.isEmpty && runPodKeyDraft.isEmpty
        }
    }

    private func runPodPriceLine(for price: RunPodAccountService.GPUPriceSummary) -> String {
        var segments: [String] = [price.displayName]
        if let community = price.communityPrice {
            segments.append(String(format: "community $%.3f/hr", community))
        }
        if let secure = price.securePrice {
            segments.append(String(format: "secure $%.3f/hr", secure))
        }
        if let communitySpot = price.communitySpotPrice {
            segments.append(String(format: "community spot $%.3f/hr", communitySpot))
        }
        if let secureSpot = price.secureSpotPrice {
            segments.append(String(format: "secure spot $%.3f/hr", secureSpot))
        }
        return segments.joined(separator: " • ")
    }
}

// Keep backward-compatible typealias during transition
@available(macOS 26.0, *)
typealias GeminiSettingsSheet = APISettingsSheet
