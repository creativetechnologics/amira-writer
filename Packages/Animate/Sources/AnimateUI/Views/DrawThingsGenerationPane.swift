import AppKit
import SwiftUI

@available(macOS 26.0, *)
struct DrawThingsGenerationPane: View {
    @Bindable var store: AnimateStore
    let place: BackgroundPlate

    // MARK: - Connection
    @State private var connectionStatus: ConnectionStatus = .unknown

    // MARK: - Prompt
    @State private var prompt: String = ""
    @State private var negativePrompt: String = ""
    @State private var isGeneratingPrompt: Bool = false
    @State private var promptError: String?

    // MARK: - Resolution
    @State private var selectedPresetName: String = DrawThingsResolutionPreset.presets[0].name
    @State private var useCustomResolution: Bool = false
    @State private var customWidth: Int = 1536
    @State private var customHeight: Int = 864

    // MARK: - Generation params
    @State private var steps: Double = 6
    @State private var cfgScale: Double = 7.5
    @State private var seedText: String = ""

    // MARK: - img2img
    @State private var selectedSourceImagePath: String? = nil
    @State private var denoisingStrength: Double = 0.6

    // MARK: - Generation state
    @State private var isGenerating: Bool = false
    @State private var generationError: String?

    // MARK: - Staged results
    @State private var stagedImageURLs: [URL] = []
    @State private var selectedStagedURL: URL? = nil

    // MARK: - Types

    enum ConnectionStatus {
        case unknown, checking, connected, failed(String)

        var label: String {
            switch self {
            case .unknown:   return "Not checked"
            case .checking:  return "Checking…"
            case .connected: return "Connected"
            case .failed(let msg): return "Failed: \(msg)"
            }
        }

        var color: Color {
            switch self {
            case .unknown:   return .secondary
            case .checking:  return .orange
            case .connected: return .green
            case .failed:    return .red
            }
        }
    }

    // MARK: - Computed

    private var config: DrawThingsPlaceConfig {
        var c = store.drawThingsPlaceConfig
        let res = resolvedResolution
        c.imageWidth = res.0
        c.imageHeight = res.1
        c.steps = max(4, min(Int(steps), 8))
        c.cfgScale = cfgScale
        c.seed = Int(seedText)
        c.negativePrompt = negativePrompt
        return c
    }

    private var resolvedResolution: (Int, Int) {
        if useCustomResolution {
            return (customWidth, customHeight)
        }
        if let preset = DrawThingsResolutionPreset.presets.first(where: { $0.name == selectedPresetName }) {
            return (preset.width, preset.height)
        }
        return (1536, 864)
    }

    private var stagingDirectory: URL? {
        guard let animateURL = store.animateURL else { return nil }
        let slug = PlacesScriptIndexService.fileStem(for: place.name)
        return animateURL
            .appendingPathComponent("backgrounds")
            .appendingPathComponent(slug)
            .appendingPathComponent("staging")
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            connectionRow
            promptSection
            negativePromptSection
            resolutionSection
            generationParamsSection
            img2imgSection
            actionSection
            if !stagedImageURLs.isEmpty {
                stagedResultsSection
            }
        }
        .onAppear {
            loadStagedImages()
            pingDrawThings()
        }
    }

    // MARK: - Connection Row

    private var connectionRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionStatus.color)
                .frame(width: 8, height: 8)
            Text(connectionStatus.label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(store.drawThingsPlaceConfig.apiHost):\(String(store.drawThingsPlaceConfig.apiPort))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("Ping") { pingDrawThings() }
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
    }

    // MARK: - Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Prompt")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button {
                    autoGeneratePrompt()
                } label: {
                    if isGeneratingPrompt {
                        ProgressView().controlSize(.mini)
                    } else {
                        Label("Auto-Generate", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGeneratingPrompt || store.miniMaxAPIKey.isEmpty)
                .help(store.miniMaxAPIKey.isEmpty ? "Set a MiniMax API key in settings to auto-generate prompts." : "Generate a Stable Diffusion prompt using MiniMax AI")
            }

            TextEditor(text: $prompt)
                .font(.system(size: 12))
                .frame(minHeight: 72, maxHeight: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1))
                )

            if let err = promptError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if store.miniMaxAPIKey.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("No MiniMax API key — auto-generate disabled.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Negative Prompt

    private var negativePromptSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Negative Prompt")
                .font(.subheadline.weight(.medium))
            TextEditor(text: $negativePrompt)
                .font(.system(size: 12))
                .frame(minHeight: 48, maxHeight: 80)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1))
                )
        }
    }

    // MARK: - Resolution

    private var resolutionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resolution")
                .font(.subheadline.weight(.medium))

            Toggle("Custom resolution", isOn: $useCustomResolution)
                .toggleStyle(.checkbox)
                .font(.caption)

            if useCustomResolution {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Width").font(.caption).foregroundStyle(.secondary)
                        TextField("Width", value: $customWidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                    Text("×").font(.callout).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Height").font(.caption).foregroundStyle(.secondary)
                        TextField("Height", value: $customHeight, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                    }
                }
            } else {
                Picker("Preset", selection: $selectedPresetName) {
                    ForEach(DrawThingsResolutionPreset.presets, id: \.name) { preset in
                        Text(preset.name).tag(preset.name)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Generation Params

    private var generationParamsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generation Parameters")
                .font(.subheadline.weight(.medium))

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Steps")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(steps))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $steps, in: 4...8, step: 1)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("CFG Scale")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.1f", cfgScale))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $cfgScale, in: 1...20, step: 0.5)
                }
            }

            HStack(spacing: 8) {
                Text("Seed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Random", text: $seedText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .font(.system(size: 12, design: .monospaced))
                Button("Random") { seedText = "" }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
        }
    }

    // MARK: - img2img

    private var img2imgSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("img2img (optional)")
                .font(.subheadline.weight(.medium))

            if place.imagePaths.isEmpty {
                Text("No existing images to use as source — generate one first or import images to this place.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Source Image", selection: $selectedSourceImagePath) {
                    Text("None (txt2img)").tag(Optional<String>.none)
                    ForEach(place.imagePaths, id: \.self) { path in
                        Text(URL(fileURLWithPath: path).lastPathComponent)
                            .tag(Optional(path))
                    }
                }
                .pickerStyle(.menu)

                if selectedSourceImagePath != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Denoising Strength")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(String(format: "%.2f", denoisingStrength))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $denoisingStrength, in: 0.1...1.0, step: 0.05)
                    }
                }
            }
        }
    }

    // MARK: - Action Section

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = generationError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    runGeneration(count: 1)
                } label: {
                    if isGenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Generating…")
                        }
                    } else {
                        Label("Generate", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    runGeneration(count: 4)
                } label: {
                    Label("Generate 4×", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    runAllAngles()
                } label: {
                    Label("All Angles", systemImage: "camera.viewfinder")
                }
                .buttonStyle(.bordered)
                .disabled(isGenerating || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
        }
    }

    // MARK: - Staged Results

    private var stagedResultsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Staged Results")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(stagedImageURLs.count) image\(stagedImageURLs.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Refresh") { loadStagedImages() }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 150), spacing: 8)], spacing: 8) {
                ForEach(stagedImageURLs, id: \.path) { url in
                    stagedThumbnail(url: url)
                }
            }
        }
    }

    @ViewBuilder
    private func stagedThumbnail(url: URL) -> some View {
        let isSelected = selectedStagedURL == url
        AsyncResolvedImageView(path: url.path, maxPixelSize: 220, contentMode: .fill)
            .frame(width: 100, height: 64)
            .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .onTapGesture { selectedStagedURL = url }
        .contextMenu {
            Button("Add to Place Images") {
                store.addImageToPlace(from: url, placeID: place.id)
            }
            Button("Set as Approved") {
                store.addImageToPlace(from: url, placeID: place.id)
                if let added = store.backgrounds.first(where: { $0.id == place.id })?.imagePaths.last {
                    store.setApprovedPlaceImage(added, placeID: place.id)
                }
            }
            Divider()
            Button("Open in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            Divider()
            Button("Delete", role: .destructive) {
                deleteStagedImage(url)
            }
        }
    }

    // MARK: - Actions

    private func pingDrawThings() {
        connectionStatus = .checking
        let cfg = store.drawThingsPlaceConfig
        Task { @MainActor in
            do {
                guard var components = URLComponents(string: cfg.apiHost) else {
                    connectionStatus = .failed("Invalid host")
                    return
                }
                if components.scheme == nil { components.scheme = "http" }
                components.port = cfg.apiPort
                components.path = "/sdapi/v1/options"
                guard let url = components.url else {
                    connectionStatus = .failed("Invalid URL")
                    return
                }
                var request = URLRequest(url: url)
                request.timeoutInterval = 5
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) {
                    connectionStatus = .connected
                } else {
                    connectionStatus = .failed("Unexpected status")
                }
            } catch {
                connectionStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func autoGeneratePrompt() {
        guard !store.miniMaxAPIKey.isEmpty else { return }
        isGeneratingPrompt = true
        promptError = nil
        let service = MiniMaxPromptService(apiKey: store.miniMaxAPIKey)
        let placeName = place.name
        let category = place.locationCategory
        let notes = place.notes
        Task { @MainActor in
            defer { isGeneratingPrompt = false }
            do {
                let generated = try await service.generateSDPrompt(
                    placeName: placeName,
                    category: category,
                    notes: notes
                )
                prompt = generated
            } catch {
                promptError = error.localizedDescription
            }
        }
    }

    private func runGeneration(count: Int) {
        guard !isGenerating else { return }
        guard let stagingDir = stagingDirectory else { return }
        isGenerating = true
        generationError = nil

        let cfg = config
        let promptText = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourcePath = selectedSourceImagePath
        let denoising = denoisingStrength
        let service = DrawThingsPlaceGenerationService()
        let fm = FileManager.default

        Task { @MainActor in
            defer {
                isGenerating = false
                loadStagedImages()
            }
            do {
                try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                for _ in 0..<count {
                    let filename = "staged-\(UUID().uuidString).png"
                    let outputURL = stagingDir.appendingPathComponent(filename)

                    if let sourcePath,
                       let sourceURL = store.resolvedCharacterAssetURL(for: sourcePath),
                       fm.fileExists(atPath: sourceURL.path) {
                        try await service.generateImg2ImgImage(
                            prompt: promptText,
                            sourceImageURL: sourceURL,
                            denoisingStrength: denoising,
                            config: cfg,
                            outputURL: outputURL
                        )
                    } else {
                        try await service.generateImage(
                            prompt: promptText,
                            config: cfg,
                            outputURL: outputURL
                        )
                    }
                }
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private func runAllAngles() {
        let angleLabels = ["wide", "medium", "closeup", "overhead"]
        guard !isGenerating else { return }
        guard let stagingDir = stagingDirectory else { return }
        isGenerating = true
        generationError = nil

        let cfg = config
        let basePrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let service = DrawThingsPlaceGenerationService()
        let fm = FileManager.default

        Task { @MainActor in
            defer {
                isGenerating = false
                loadStagedImages()
            }
            do {
                try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
                for angle in angleLabels {
                    let anglePrompt = "\(basePrompt), \(angle) shot"
                    let filename = "staged-\(angle)-\(UUID().uuidString).png"
                    let outputURL = stagingDir.appendingPathComponent(filename)
                    try await service.generateImage(
                        prompt: anglePrompt,
                        config: cfg,
                        outputURL: outputURL
                    )
                }
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private func loadStagedImages() {
        guard let stagingDir = stagingDirectory else {
            stagedImageURLs = []
            return
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: stagingDir.path) else {
            stagedImageURLs = []
            return
        }
        let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "webp"]
        let contents = (try? fm.contentsOfDirectory(
            at: stagingDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        )) ?? []
        stagedImageURLs = contents
            .filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted {
                let d0 = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let d1 = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return d0 > d1
            }
    }

    private func deleteStagedImage(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        stagedImageURLs.removeAll { $0 == url }
        if selectedStagedURL == url { selectedStagedURL = nil }
    }
}
