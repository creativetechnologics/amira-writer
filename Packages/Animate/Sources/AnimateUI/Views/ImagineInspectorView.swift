import SwiftUI

@available(macOS 26.0, *)
struct ImagineInspectorView: View {
    @Bindable var store: AnimateStore
    @State private var showAPISettings = false
    @State private var drawThingsStatus: String?
    @State private var drawThingsStatusIcon: String = "network"

    @State private var showLORATraining = false
    @ObservedObject private var runpodService = RunPodLORAService.shared

    private enum InspectorTab: String { case tools, bulk, lora, properties }
    @AppStorage("imagine.inspector.selectedTab") private var selectedTab = InspectorTab.tools.rawValue

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                tabButton("Tools", tab: .tools, icon: "gearshape.fill")
                tabButton("Bulk", tab: .bulk, icon: "tray.full")
                tabButton("LORA", tab: .lora, icon: "cpu")
                tabButton("Props", tab: .properties, icon: "slider.horizontal.3")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            ScrollView {
                switch InspectorTab(rawValue: selectedTab) ?? .tools {
                case .tools:
                    toolsContent
                case .bulk:
                    bulkContent
                case .lora:
                    loraContent
                case .properties:
                    propertiesContent
                }
            }
        }
    }

    // MARK: - Tools Tab

    private var toolsContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(isOn: $store.geminiMasterSwitch) {
                        Label("Gemini API Calls", systemImage: "bolt.fill")
                            .font(.headline)
                    }
                    .toggleStyle(.switch)

                    Text(store.geminiMasterSwitch
                         ? "Gemini API calls are ENABLED. Image generation via Gemini is allowed."
                         : "Gemini API calls are BLOCKED. No Gemini requests will be sent.")
                        .font(.caption)
                        .foregroundStyle(store.geminiMasterSwitch ? .green : .red)
                }
            } label: {
                Label("API Control", systemImage: "shield.checkered")
                    .font(.subheadline.weight(.semibold))
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("Host") {
                        TextField("http://127.0.0.1", text: Binding(
                            get: { store.drawThingsPlaceConfig.apiHost },
                            set: { newValue in
                                var updated = store.drawThingsPlaceConfig
                                updated.apiHost = newValue
                                store.updateDrawThingsPlacesConfig(updated)
                            }
                        ))
                            .font(.caption.monospaced())
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                    }
                    LabeledContent("Port") {
                        TextField("7860", value: Binding(
                            get: { store.drawThingsPlaceConfig.apiPort },
                            set: { newValue in
                                var updated = store.drawThingsPlaceConfig
                                updated.apiPort = newValue
                                store.updateDrawThingsPlacesConfig(updated)
                            }
                        ), format: IntegerFormatStyle<Int>().grouping(.never))
                            .font(.caption.monospaced())
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 80)
                    }

                    Button {
                        checkDrawThingsConnection()
                    } label: {
                        Label(drawThingsStatus ?? "Check Connection", systemImage: drawThingsStatusIcon)
                    }
                    .controlSize(.small)
                }
            } label: {
                Label("Draw Things", systemImage: "paintbrush.pointed")
                    .font(.subheadline.weight(.semibold))
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("API Key") {
                        Text(store.geminiAPIKey.isEmpty ? "Not set" : "Configured")
                            .font(.caption)
                            .foregroundStyle(store.geminiAPIKey.isEmpty ? .red : .green)
                    }
                    LabeledContent("Model") {
                        Text(store.selectedGeminiModel.displayName)
                            .font(.caption)
                    }
                }
            } label: {
                Label("Gemini", systemImage: "sparkle")
                    .font(.subheadline.weight(.semibold))
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("API Key") {
                        Text(store.miniMaxAPIKey.isEmpty ? "Not set" : "Configured")
                            .font(.caption)
                            .foregroundStyle(store.miniMaxAPIKey.isEmpty ? .red : .green)
                    }
                }
            } label: {
                Label("MiniMax", systemImage: "text.bubble")
                    .font(.subheadline.weight(.semibold))
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("API Key") {
                        Text(store.runPodAPIKey.isEmpty ? "Not set" : "Configured")
                            .font(.caption)
                            .foregroundStyle(store.runPodAPIKey.isEmpty ? .red : .green)
                    }
                }
            } label: {
                Label("RunPod", systemImage: "server.rack")
                    .font(.subheadline.weight(.semibold))
            }

            Button("Open API Settings…") {
                showAPISettings = true
            }
            .controlSize(.small)
        }
        .padding()
        .sheet(isPresented: $showAPISettings) {
            GeminiSettingsSheet(
                store: store,
                onDismiss: { showAPISettings = false }
            )
        }
    }

    // MARK: - Bulk Tab

    private var bulkContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("DrawThings Bulk Generation")
                .font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Model")
                        Spacer()
                        Text(ImagineDrawThingsModel.fluxKlein9B.displayName)
                            .foregroundStyle(.secondary)
                    }

                    Stepper("Images per DT call: \(store.imagineBulkRunConfig.batchSize)",
                            value: $store.imagineBulkRunConfig.batchSize,
                            in: 1...4)
                    Text("DrawThings generates this many images per API call")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Stepper("Repeats per prompt: \(store.imagineBulkRunConfig.repeatsPerPrompt)",
                            value: $store.imagineBulkRunConfig.repeatsPerPrompt,
                            in: 1...10)
                    Text("Re-runs each prompt this many times")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Divider()

                    let perMoment = store.imagineBulkRunConfig.imagesPerMoment
                    Text("= \(perMoment) images per moment per shot")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Divider()

                    Toggle("Auto-generate prompts (GPT 5.4)", isOn: $store.imagineBulkRunConfig.autoGeneratePrompts)

                    Divider()

                    Text("Include Moments:")
                        .font(.subheadline.weight(.semibold))
                    Toggle("Beginning", isOn: $store.imagineBulkRunConfig.includeBeginning)
                    Toggle("Middle", isOn: $store.imagineBulkRunConfig.includeMiddle)
                    Toggle("End", isOn: $store.imagineBulkRunConfig.includeEnd)
                }
            }

            // Estimated total
            let momentCount = [store.imagineBulkRunConfig.includeBeginning, store.imagineBulkRunConfig.includeMiddle, store.imagineBulkRunConfig.includeEnd].filter { $0 }.count
            let shotCount = store.scenes.reduce(0) { $0 + $1.shots.count }
            let totalEst = shotCount * momentCount * store.imagineBulkRunConfig.imagesPerMoment
            if totalEst > 0 {
                Text("Estimated total: ~\(totalEst) images across \(store.scenes.count) scenes")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if store.imagineBulkRunProgress.isRunning {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: store.imagineBulkRunProgress.fractionComplete)
                        Text("\(store.imagineBulkRunProgress.completedImages)/\(store.imagineBulkRunProgress.totalImages) images")
                            .font(.caption)
                        Text("Scene: \(store.imagineBulkRunProgress.currentSceneName) • Shot \(store.imagineBulkRunProgress.currentShotIndex + 1) • \(store.imagineBulkRunProgress.currentMoment.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let error = store.imagineBulkRunProgress.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        Button(role: .destructive) {
                            store.imagineBulkRunProgress.isCancelled = true
                        } label: {
                            Label("Cancel Bulk Run", systemImage: "stop.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                    }
                }
            } else {
                Button {
                    startBulkRun()
                } label: {
                    Label("Start Bulk Generation", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Text("Gemini bulk is not available here. Use the Gemini controls in Imagine > Characters for the 27-scene character inspiration workflow.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func startBulkRun() {
        store.imagineBulkRunProgress = ImagineBulkRunProgress(isRunning: true)
        Task {
            let service = ImagineGenerationService()
            try? await service.runBulk(
                config: store.imagineBulkRunConfig,
                scenes: store.scenes,
                store: store,
                onProgress: { progress in
                    store.imagineBulkRunProgress = progress
                }
            )
        }
    }

    // MARK: - Properties Tab

    // MARK: - LORA Tab

    private var loraContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LORA Training")
                .font(.headline)

            // RunPod API Key status
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("RunPod Key") {
                        Text(store.runPodAPIKey.isEmpty ? "Not set" : "Configured")
                            .font(.caption)
                            .foregroundStyle(store.runPodAPIKey.isEmpty ? .red : .green)
                    }
                    LabeledContent("GPU") {
                        Text("RTX A6000 (48GB) — $0.33/hr")
                            .font(.caption)
                    }
                    LabeledContent("Training Steps") {
                        Text("3000 hard-coded (~90 min, ~$0.24)")
                            .font(.caption)
                    }
                }
            } label: {
                Label("RunPod", systemImage: "server.rack")
                    .font(.subheadline.weight(.semibold))
            }

            // Current job status
            if let job = runpodService.currentJob {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle()
                                .fill(job.status.isActive ? Color.green : (job.status == .error ? Color.red : Color.secondary))
                                .frame(width: 8, height: 8)
                            Text(job.status.displayName)
                                .font(.caption.weight(.semibold))
                        }
                        Text(job.characterName)
                            .font(.caption)
                        if job.totalSteps > 0 {
                            ProgressView(value: job.progress)
                            Text("Step \(job.currentStep)/\(job.totalSteps)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        if let error = job.errorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                        if job.status.isActive {
                            Button(role: .destructive) {
                                runpodService.terminateAllPods()
                            } label: {
                                Label("Cancel & Terminate Pod", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .controlSize(.small)
                        }
                    }
                } label: {
                    Label("Active Job", systemImage: "cpu")
                        .font(.subheadline.weight(.semibold))
                }
            }

            // Train button
            if let character = store.selectedCharacter, store.selectedImaginePage == .characters {
                Button {
                    showLORATraining = true
                } label: {
                    Label("Train LORA for \(character.name)", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(store.runPodAPIKey.isEmpty || runpodService.currentJob?.status.isActive == true)
            } else {
                Text("Select a character in the Imagine > Characters page to train a LORA.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Existing LORAs
            if let character = store.selectedCharacter, let animateURL = store.animateURL {
                let loraDir = animateURL.appendingPathComponent("characters/\(character.assetFolderSlug)/lora")
                let loras = (try? FileManager.default.contentsOfDirectory(at: loraDir, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "safetensors" } ?? []
                if !loras.isEmpty {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(loras, id: \.path) { url in
                                HStack {
                                    Image(systemName: "doc.fill")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(url.lastPathComponent)
                                        .font(.caption.monospaced())
                                    Spacer()
                                    Button("Reveal") {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                    .controlSize(.mini)
                                }
                            }
                        }
                    } label: {
                        Label("Trained LORAs", systemImage: "archivebox")
                            .font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $showLORATraining) {
            if let character = store.selectedCharacter {
                let initialLoraPaths: Set<String> = {
                    guard let animateURL = store.animateURL else { return [] }
                    return ImagineGallerySelectionState.load(
                        animateURL: animateURL,
                        characterSlug: character.assetFolderSlug
                    ).loraSelectedPaths
                }()
                LORATrainingSheet(
                    store: store,
                    character: character,
                    initialSelectedPaths: initialLoraPaths
                )
            }
        }
    }

    // MARK: - Properties Tab

    private var propertiesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let path = store.imaginePreviewImagePath {
                Text("Selected Image")
                    .font(.headline)

                LabeledContent("Path") {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption.monospaced())
                        .lineLimit(2)
                }

                Button("Show in Finder") {
                    ImagineProjectStorage.revealInFinder(path)
                }
                .controlSize(.small)
            } else {
                Text("No image selected")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }

    // MARK: - Tab Button

    private func tabButton(_ title: String, tab: InspectorTab, icon: String) -> some View {
        Button {
            selectedTab = tab.rawValue
        } label: {
            Label(title, systemImage: icon)
                .font(.caption)
                .fontWeight(selectedTab == tab.rawValue ? .semibold : .regular)
                .foregroundStyle(selectedTab == tab.rawValue ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .background(
                    selectedTab == tab.rawValue
                        ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                        : AnyShapeStyle(Color.clear),
                    in: RoundedRectangle(cornerRadius: 8)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - DrawThings Connection Check

    private func checkDrawThingsConnection() {
        drawThingsStatus = "Checking…"
        drawThingsStatusIcon = "arrow.triangle.2.circlepath"
        let config = store.drawThingsPlaceConfig
        guard var components = URLComponents(string: config.apiHost) else {
            drawThingsStatus = "Invalid host"
            drawThingsStatusIcon = "xmark.circle.fill"
            return
        }
        if components.scheme == nil { components.scheme = "http" }
        components.port = config.apiPort
        components.path = "/sdapi/v1/options"
        guard let url = components.url else {
            drawThingsStatus = "Invalid URL"
            drawThingsStatusIcon = "xmark.circle.fill"
            return
        }
        Task {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    drawThingsStatus = "Connected"
                    drawThingsStatusIcon = "checkmark.circle.fill"
                } else {
                    drawThingsStatus = "Error (HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0))"
                    drawThingsStatusIcon = "xmark.circle.fill"
                }
            } catch {
                drawThingsStatus = "Offline — \(error.localizedDescription)"
                drawThingsStatusIcon = "xmark.circle.fill"
            }
        }
    }
}
