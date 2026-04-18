import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct ImagineScenesPageView: View {
    private enum ReferencePickerMode: Identifiable {
        case gemini
        case drawThingsSource

        var id: String {
            switch self {
            case .gemini: return "gemini"
            case .drawThingsSource: return "drawThingsSource"
            }
        }
    }

    @Bindable var store: AnimateStore
    @State private var selectedMoment: ImagineShotMoment = .beginning
    @State private var previewImagePath: String?
    @State private var generationPrompt: String = ""
    @State private var isGeneratingPrompt: Bool = false
    @State private var isGenerating: Bool = false
    @State private var generationError: String?
    @State private var selectedDrawThingsModel: ImagineDrawThingsModel = .fluxKlein9B
    @State private var generationPromptHeight: CGFloat = 110
    @State private var generationPromptDragStartHeight: CGFloat?
    @State private var useGemini: Bool = false
    @State private var geminiReferenceImages: [GeminiImageService.ReferenceImage] = []
    @State private var drawThingsSourceImagePath: String?
    @State private var drawThingsDenoisingStrength: Double = 0.35
    @State private var activeReferencePicker: ReferencePickerMode?
    @State private var isBulkRunningScene: Bool = false
    @State private var isBulkRunningAll: Bool = false
    @State private var bulkProgressMessage: String?
    @State private var promptPopoverText: String?
    @State private var showPromptPopover: Bool = false

    private var selectedScene: AnimationScene? { store.selectedScene }
    private var shots: [AnimationSceneShot] { selectedScene?.shots ?? [] }

    private var currentGallery: ImagineSceneShotGallery? {
        guard let scene = selectedScene, let idx = store.imagineSelectedShotIndex else { return nil }
        return store.imagineGallery(for: scene.id, shotIndex: idx)
    }

    private var currentMomentPaths: [String] {
        currentGallery?.paths(for: selectedMoment) ?? []
    }

    private var usesReferenceDrivenPromptStyle: Bool {
        useGemini || drawThingsSourceImagePath != nil
    }

    private var scenePromptSubjectStyle: ImagineScenePromptService.SubjectStyle {
        usesReferenceDrivenPromptStyle ? .neutralSubjects : .loraTokens
    }

    var body: some View {
        if let scene = selectedScene {
            VStack(spacing: 0) {
                shotTimeline(scene: scene)

                // Bulk generation bar
                bulkBar(scene: scene)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        previewSection
                        momentTabBar
                        galleryGrid
                    }
                    .padding()
                }

                Divider()
                generationControls
            }
            .onChange(of: store.selectedSceneID) { _, _ in
                store.imagineSelectedShotIndex = shots.isEmpty ? nil : 0
                if let sceneID = store.selectedSceneID {
                    store.ensureImagineDirectories(for: sceneID)
                    store.refreshImagineGalleryFromDisk(sceneID: sceneID)
                }
                // Prompt is scene/shot/moment-specific — wipe it so the user
                // never accidentally generates with stale context from a
                // previous scene. Same for preview + last error.
                resetGenerationState()
            }
            .onChange(of: store.imagineSelectedShotIndex) { _, _ in
                previewImagePath = nil
                // New shot → fresh prompt. See comment on selectedSceneID above.
                resetGenerationState()
            }
            .onChange(of: selectedMoment) { _, _ in
                // New moment within the same shot → different beat of action,
                // different prompt. Wipe so the user writes intentionally.
                resetGenerationState()
            }
            .onAppear {
                if store.imagineSelectedShotIndex == nil && !shots.isEmpty {
                    store.imagineSelectedShotIndex = 0
                }
                if let sceneID = store.selectedSceneID {
                    store.ensureImagineDirectories(for: sceneID)
                    store.refreshImagineGalleryFromDisk(sceneID: sceneID)
                }
            }
            .sheet(item: $activeReferencePicker) { pickerMode in
                UniversalImagePickerSheet(
                    store: store,
                    maxSelections: pickerMode == .gemini ? 5 : 1,
                    onConfirm: { selectedPaths in
                        activeReferencePicker = nil
                        handleSelectedReferenceImages(selectedPaths, mode: pickerMode)
                    },
                    onCancel: { activeReferencePicker = nil }
                )
            }
            .sheet(isPresented: $showPromptPopover) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Generation Prompt")
                            .font(.headline)
                        Spacer()
                        Button("Close") { showPromptPopover = false }
                            .keyboardShortcut(.cancelAction)
                    }
                    Divider()
                    ScrollView {
                        Text(promptPopoverText ?? "No prompt found for this image.")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Spacer()
                        Button("Copy") {
                            if let text = promptPopoverText {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                .padding()
                .frame(width: 550, height: 350)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a scene to generate images")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Shot Timeline

    private func shotTimeline(scene: AnimationScene) -> some View {
        HStack(spacing: 8) {
            Button {
                if let idx = store.imagineSelectedShotIndex, idx > 0 { store.imagineSelectedShotIndex = idx - 1 }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(store.imagineSelectedShotIndex == nil || store.imagineSelectedShotIndex == 0)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(scene.shots.enumerated()), id: \.element.id) { index, shot in
                            shotChip(index: index, shot: shot, sceneID: scene.id)
                                .id(index)
                                .onTapGesture { store.imagineSelectedShotIndex = index }
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .onChange(of: store.imagineSelectedShotIndex) { _, newIndex in
                    if let idx = newIndex {
                        withAnimation { proxy.scrollTo(idx, anchor: .center) }
                    }
                }
            }

            Button {
                if let idx = store.imagineSelectedShotIndex, idx < shots.count - 1 { store.imagineSelectedShotIndex = idx + 1 }
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
            .disabled(store.imagineSelectedShotIndex == nil || store.imagineSelectedShotIndex == shots.count - 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func shotChip(index: Int, shot: AnimationSceneShot, sceneID: UUID) -> some View {
        let isSelected = store.imagineSelectedShotIndex == index
        let gallery = store.imagineGallery(for: sceneID, shotIndex: index)
        let totalImages = (gallery?.beginningImagePaths.count ?? 0) + (gallery?.middleImagePaths.count ?? 0) + (gallery?.endImagePaths.count ?? 0)

        return VStack(spacing: 2) {
            Text("S\(index + 1)")
                .font(.caption.weight(.bold))
            Text(shot.cameraShot?.rawValue ?? "—")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            if totalImages > 0 {
                Text("\(totalImages)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    // MARK: - Preview

    private var previewSection: some View {
        Group {
            if let path = previewImagePath ?? currentGallery?.selectedPath(for: selectedMoment) {
                AsyncStoreThumbnailImage<AnyView>.rounded(
                    store: store,
                    path: path,
                    maxSize: 1600,
                    width: nil,
                    height: 400,
                    contentMode: .fit,
                    cornerRadius: 8
                )
            } else {
                previewPlaceholder
            }
        }
    }

    private var previewPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.05))
            .frame(maxWidth: .infinity).frame(height: 300)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                    Text("Select a thumbnail below to preview").font(.caption).foregroundStyle(.tertiary)
                }
            }
    }

    // MARK: - Moment Tab Bar

    private var momentTabBar: some View {
        HStack(spacing: 0) {
            ForEach(ImagineShotMoment.allCases) { moment in
                Button {
                    selectedMoment = moment
                } label: {
                    Text(moment.rawValue)
                        .font(.subheadline.weight(selectedMoment == moment ? .semibold : .regular))
                        .foregroundStyle(selectedMoment == moment ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(
                            selectedMoment == moment ? Color.accentColor.opacity(0.12) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Gallery Grid

    private var galleryGrid: some View {
        Group {
            if currentMomentPaths.isEmpty {
                Text("No \(selectedMoment.rawValue.lowercased()) images for this shot yet.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                    ForEach(currentMomentPaths, id: \.self) { path in
                        galleryThumbnail(path: path)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func galleryThumbnail(path: String) -> some View {
        let isSelected = previewImagePath == path
        AsyncStoreThumbnailImage<AnyView>.rounded(
            store: store,
            path: path,
            maxSize: 200,
            width: 100,
            height: 100,
            contentMode: .fill,
            cornerRadius: 6
        )
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2))
        .onTapGesture {
            previewImagePath = path
            store.imaginePreviewImagePath = path
        }
        .contextMenu {
            Button("Show Prompt") {
                showPromptForImage(path: path)
            }
            Button("Show in Finder") { ImagineProjectStorage.revealInFinder(path) }
            Button("Copy Image") {
                if let image = NSImage(contentsOfFile: path) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                try? FileManager.default.removeItem(atPath: path)
                if let sceneID = selectedScene?.id { store.refreshImagineGalleryFromDisk(sceneID: sceneID) }
            }
        }
        .draggable(URL(fileURLWithPath: path))
    }

    // MARK: - Generation Controls (pinned bottom)

    private var generationControls: some View {
        VStack(spacing: 10) {
            promptResizeHandle

            HStack(spacing: 12) {
                Picker("Generator", selection: $useGemini) {
                    Text("Draw Things").tag(false)
                    Text("Gemini").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 300)

                if !useGemini {
                    HStack(spacing: 6) {
                        Text("Model")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(ImagineDrawThingsModel.fluxKlein9B.displayName)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quaternary.opacity(0.2), in: Capsule())
                    }
                    .frame(maxWidth: 220, alignment: .leading)
                } else {
                    Picker("Model", selection: $store.selectedGeminiModel) {
                        ForEach(GeminiModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .frame(maxWidth: 200)
                    .disabled(!store.geminiMasterSwitch)

                    Button {
                        activeReferencePicker = .gemini
                    } label: {
                        Label("\(geminiReferenceImages.count)/5 Refs", systemImage: "photo.on.rectangle.angled")
                    }
                    .controlSize(.small)
                    .disabled(!store.geminiMasterSwitch)
                }
            }

            if !useGemini {
                drawThingsReferenceSection
            }

            HStack(spacing: 8) {
                TextEditor(text: $generationPrompt)
                    .font(.caption)
                    .frame(height: generationPromptHeight)
                    .padding(4)
                    .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))

                VStack(spacing: 4) {
                    if isGeneratingPrompt {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 60)
                    } else {
                        Button { autoGeneratePrompt() } label: {
                            Label("Auto (GPT)", systemImage: "wand.and.stars")
                        }
                        .controlSize(.small)

                        Button { prefillPrompt() } label: {
                            Label("Pre-fill", systemImage: "text.insert")
                        }
                        .controlSize(.small)
                    }

                    Button { generateImage() } label: {
                        Label("Generate", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(generationPrompt.isEmpty || isGenerating || isGeneratingPrompt || (useGemini && !store.geminiMasterSwitch))
                }
            }

            if useGemini && !geminiReferenceImages.isEmpty {
                HStack(spacing: 6) {
                    Text("References:").font(.caption).foregroundStyle(.secondary)
                    ForEach(0..<geminiReferenceImages.count, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.2))
                            .frame(width: 30, height: 30)
                            .overlay { Text("\(i + 1)").font(.caption2) }
                    }
                    Button("Clear") { geminiReferenceImages = [] }.controlSize(.mini)
                }
            }

            if isGeneratingPrompt {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Generating prompt via GPT 5.4…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = generationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if isGenerating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Generating image…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var promptResizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(.quaternary.opacity(0.18))
                .frame(height: 1)

            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 72, height: 5)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let start = generationPromptDragStartHeight ?? generationPromptHeight
                    if generationPromptDragStartHeight == nil {
                        generationPromptDragStartHeight = generationPromptHeight
                    }
                    generationPromptHeight = min(340, max(72, start - value.translation.height))
                }
                .onEnded { _ in
                    generationPromptDragStartHeight = nil
                }
        )
        .accessibilityLabel("Resize prompt area")
        .help("Drag to resize the prompt editor.")
    }

    private var drawThingsReferenceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    activeReferencePicker = .drawThingsSource
                } label: {
                    Label(
                        drawThingsSourceImagePath == nil ? "0/1 Source" : "1/1 Source",
                        systemImage: "photo"
                    )
                }
                .controlSize(.small)

                if let sourcePath = drawThingsSourceImagePath {
                    Text(URL(fileURLWithPath: sourcePath).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Button("Clear") {
                        drawThingsSourceImagePath = nil
                    }
                    .controlSize(.mini)
                } else {
                    Text("Optional base image for Draw Things img2img. The result keeps the source image dimensions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if drawThingsSourceImagePath != nil {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Reference Strength")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f", drawThingsDenoisingStrength))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $drawThingsDenoisingStrength, in: 0.15...0.75, step: 0.05)
                    Text("Lower values preserve the source image more. Start around 0.30–0.40.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Actions

    /// Wipe prompt, preview, and last error when the scene/shot/moment
    /// context changes. Prompts are context-specific and reusing an old one
    /// would generate the wrong image — the user made it clear this was a
    /// dangerous UX issue. Reference images are NOT cleared because the
    /// user has to pick those manually and may legitimately reuse them.
    private func resetGenerationState() {
        generationPrompt = ""
        generationError = nil
        previewImagePath = nil
    }

    private func prefillPrompt() {
        guard let scene = selectedScene,
              let shotIndex = store.imagineSelectedShotIndex,
              shotIndex < scene.shots.count else { return }
        let service = ImagineScenePromptService(store: store)
        generationPrompt = service.prefillPrompt(
            scene: scene,
            shotIndex: shotIndex,
            moment: selectedMoment,
            subjectStyle: scenePromptSubjectStyle
        )
    }

    private func autoGeneratePrompt() {
        guard let scene = selectedScene, let shotIndex = store.imagineSelectedShotIndex, shotIndex < scene.shots.count else { return }
        isGeneratingPrompt = true
        Task {
            defer { isGeneratingPrompt = false }
            do {
                let service = ImagineScenePromptService(store: store)
                generationPrompt = try await service.generatePrompt(
                    scene: scene,
                    shotIndex: shotIndex,
                    moment: selectedMoment,
                    subjectStyle: scenePromptSubjectStyle
                )
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    private func generateImage() {
        guard let scene = selectedScene, let owpURL = store.fileOWPURL, let shotIndex = store.imagineSelectedShotIndex else { return }
        isGenerating = true
        generationError = nil
        let sceneSlug = scene.name.lowercased().replacingOccurrences(of: " ", with: "-").replacingOccurrences(of: "/", with: "-")

        Task {
            defer {
                isGenerating = false
                store.refreshImagineGalleryFromDisk(sceneID: scene.id)
            }
            do {
                let service = ImagineGenerationService()
                if useGemini {
                    guard store.isGeminiAllowed() else {
                        generationError = "Gemini API calls are blocked. Enable in Inspector > Tools."
                        return
                    }
                    try await service.generateWithGemini(
                        prompt: generationPrompt, referenceImages: geminiReferenceImages,
                        model: store.selectedGeminiModel, apiKey: store.geminiAPIKey,
                        owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex, moment: selectedMoment
                    )
                } else {
                    _ = try await service.generateWithDrawThings(
                        prompt: generationPrompt, model: selectedDrawThingsModel,
                        config: store.drawThingsPlaceConfig, owpURL: owpURL,
                        sceneSlug: sceneSlug, shotIndex: shotIndex, moment: selectedMoment,
                        characters: drawThingsSourceImagePath == nil ? store.characters : [],
                        sourceImageURL: drawThingsSourceImagePath.map { URL(fileURLWithPath: $0) },
                        denoisingStrength: drawThingsDenoisingStrength,
                        useCharacterLoRAs: drawThingsSourceImagePath == nil
                    )
                }
            } catch {
                if !useGemini {
                    generationError = "Draw Things: \(error.localizedDescription) — Verify Draw Things is running with API enabled on port \(store.drawThingsPlaceConfig.apiPort)."
                } else {
                    generationError = error.localizedDescription
                }
            }
        }
    }

    private func showPromptForImage(path: String) {
        // Look for a .prompt.txt file alongside the image
        let url = URL(fileURLWithPath: path)
        let promptURL = url.deletingPathExtension().appendingPathExtension("prompt.txt")
        if let text = try? String(contentsOf: promptURL, encoding: .utf8), !text.isEmpty {
            promptPopoverText = text
        } else {
            // Try with the full extension replaced (e.g., "dt_123_0.png" -> "dt_123_0.prompt.txt")
            let dir = url.deletingLastPathComponent()
            let stem = url.deletingPathExtension().lastPathComponent
            let altURL = dir.appendingPathComponent("\(stem).prompt.txt")
            if let text = try? String(contentsOf: altURL, encoding: .utf8), !text.isEmpty {
                promptPopoverText = text
            } else {
                promptPopoverText = nil
            }
        }
        showPromptPopover = true
    }

    private func handleSelectedReferenceImages(
        _ paths: [String],
        mode: ReferencePickerMode
    ) {
        switch mode {
        case .gemini:
            geminiReferenceImages = makeGeminiReferenceImages(from: paths)
        case .drawThingsSource:
            drawThingsSourceImagePath = paths.first
        }
    }

    private func makeGeminiReferenceImages(from paths: [String]) -> [GeminiImageService.ReferenceImage] {
        paths.compactMap { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
            let mime: String
            switch ext {
            case "png": mime = "image/png"
            case "webp": mime = "image/webp"
            default: mime = "image/jpeg"
            }
            return GeminiImageService.ReferenceImage(data: data.base64EncodedString(), mimeType: mime)
        }
    }

    // MARK: - Bulk Bar

    private func bulkBar(scene: AnimationScene) -> some View {
        HStack(spacing: 8) {
            if isBulkRunningScene || isBulkRunningAll {
                ProgressView().controlSize(.small)
                Text(bulkProgressMessage ?? "Generating…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(role: .destructive) {
                    store.imagineBulkRunProgress.isCancelled = true
                } label: {
                    Label("Cancel", systemImage: "stop.fill")
                }
                .controlSize(.small)
            } else {
                Button {
                    bulkGenerateScene(scene)
                } label: {
                    Label("Bulk: This Scene", systemImage: "photo.stack")
                }
                .controlSize(.small)

                Button {
                    bulkGenerateAllScenes()
                } label: {
                    Label("Bulk: All Scenes", systemImage: "film.stack")
                }
                .controlSize(.small)

                Spacer()

                let cfg = store.imagineBulkRunConfig
                Text("\(cfg.batchSize)×\(cfg.repeatsPerPrompt) per moment")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func bulkGenerateScene(_ scene: AnimationScene) {
        isBulkRunningScene = true
        var config = store.imagineBulkRunConfig
        config.sceneFilter = [scene.id]

        Task {
            defer { isBulkRunningScene = false; bulkProgressMessage = nil }
            let service = ImagineGenerationService()
            try? await service.runBulk(
                config: config,
                scenes: store.scenes,
                store: store,
                onProgress: { progress in
                    bulkProgressMessage = "\(progress.completedImages)/\(progress.totalImages) — \(progress.currentMoment.rawValue)"
                    store.imagineBulkRunProgress = progress
                }
            )
            store.refreshImagineGalleryFromDisk(sceneID: scene.id)
        }
    }

    private func bulkGenerateAllScenes() {
        isBulkRunningAll = true
        var config = store.imagineBulkRunConfig
        config.sceneFilter = nil

        Task {
            defer { isBulkRunningAll = false; bulkProgressMessage = nil }
            let service = ImagineGenerationService()
            try? await service.runBulk(
                config: config,
                scenes: store.scenes,
                store: store,
                onProgress: { progress in
                    bulkProgressMessage = "\(progress.currentSceneName) S\(progress.currentShotIndex + 1) \(progress.currentMoment.rawValue) — \(progress.completedImages)/\(progress.totalImages)"
                    store.imagineBulkRunProgress = progress
                }
            )
        }
    }
}
