import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct APISettingsSheet: View {
    @Bindable var store: AnimateStore
    let onDismiss: () -> Void

    @State private var geminiKeyDraft: String = ""
    @State private var miniMaxKeyDraft: String = ""
    @State private var viduKeyDraft: String = ""
    @State private var runPodKeyDraft: String = ""
    @State private var revealGeminiKey: Bool = false
    @State private var revealMiniMaxKey: Bool = false
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

    enum SettingsTab: String, CaseIterable {
        case gemini = "Gemini"
        case miniMax = "MiniMax"
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
            case .miniMax:
                miniMaxForm
            case .vidu:
                viduForm
            case .runPod:
                runPodForm
            }

            Divider()
            footer
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            geminiKeyDraft = store.geminiAPIKey
            miniMaxKeyDraft = store.miniMaxAPIKey
            viduKeyDraft = store.viduAPIKey
            runPodKeyDraft = store.runPodAPIKey
            imageGenBackend = ImageGenBackendStore.currentBackend()
            let vertex = ImageGenBackendStore.currentVertexSettings()
            vertexProjectDraft = vertex.projectID
            vertexRegionDraft = vertex.region
            if selectedTab == .runPod {
                Task { await store.refreshRunPodAccountSummary(using: runPodKeyDraft) }
            }
        }
        .onChange(of: selectedTab) { _, newValue in
            guard newValue == .runPod else { return }
            Task { await store.refreshRunPodAccountSummary(using: runPodKeyDraft) }
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

    // MARK: - MiniMax

    private var miniMaxForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            apiKeyField(
                label: "MiniMax API Key",
                draft: $miniMaxKeyDraft,
                reveal: $revealMiniMaxKey,
                placeholder: "Paste MiniMax API key...",
                isSaved: !store.miniMaxAPIKey.isEmpty,
                savedLabel: "MiniMax key saved.",
                unsavedLabel: "No MiniMax key saved yet."
            )

            Text("Used for video generation from character reference images. Get a key at platform.minimaxi.com.")
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
                case .miniMax:
                    miniMaxKeyDraft = ""
                    store.clearMiniMaxAPIKey()
                case .vidu:
                    viduKeyDraft = ""
                    store.clearViduAPIKey()
                case .runPod:
                    runPodKeyDraft = ""
                    store.runPodAPIKey = ""
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
                store.setMiniMaxAPIKey(miniMaxKeyDraft)
                store.setViduAPIKey(viduKeyDraft)
                store.runPodAPIKey = runPodKeyDraft
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var currentKeyIsEmpty: Bool {
        switch selectedTab {
        case .gemini: store.geminiAPIKey.isEmpty && geminiKeyDraft.isEmpty
        case .miniMax: store.miniMaxAPIKey.isEmpty && miniMaxKeyDraft.isEmpty
        case .vidu: store.viduAPIKey.isEmpty && viduKeyDraft.isEmpty
        case .runPod: store.runPodAPIKey.isEmpty && runPodKeyDraft.isEmpty
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
