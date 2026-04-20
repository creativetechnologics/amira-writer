import ProjectKit
import SwiftUI

@available(macOS 26.0, *)
struct ImagineInspectorView: View {
    @Bindable var store: AnimateStore

    @State private var showLORATraining = false
    @ObservedObject private var runpodService = RunPodLORAService.shared

    private enum InspectorTab: String, Identifiable {
        case details, bulk, lora, properties

        var id: String { rawValue }
    }
    @AppStorage("imagine.inspector.selectedTab.v3") private var selectedTab = InspectorTab.details.rawValue

    var body: some View {
        VStack(spacing: 0) {
            SharedInspectorTabBar(selection: selectedTabBinding, items: [
                SharedInspectorTabItem(value: .details, title: "Details", systemImage: "info.circle"),
                SharedInspectorTabItem(value: .bulk, title: "Bulk", systemImage: "tray.full")
            ])

            Divider()

            ScrollView {
                // Resolve the tab, falling back to Details if an older
                // persisted value (lora/properties) is still selected.
                let activeTab: InspectorTab = {
                    switch InspectorTab(rawValue: selectedTab) ?? .details {
                    case .details: return .details
                    case .bulk: return .bulk
                    case .lora, .properties: return .details
                    }
                }()
                switch activeTab {
                case .details:
                    VStack(alignment: .leading, spacing: 16) {
                        UnifiedDetailsInspectorSection(selection: CharacterImageSelection(store: store))
                    }
                    .padding()
                case .bulk:
                    bulkContent
                case .lora, .properties:
                    EmptyView()
                }
            }
        }
    }

    // MARK: - Bulk Tab

    private var selectedTabBinding: Binding<InspectorTab> {
        Binding(
            get: { InspectorTab(rawValue: selectedTab) ?? .details },
            set: { selectedTab = $0.rawValue }
        )
    }

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
                let loraDir = ProjectPaths(root: animateURL.deletingLastPathComponent())
                    .characterLora(slug: character.assetFolderSlug)
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

}
