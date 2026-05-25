import SwiftUI
import AppKit
import ProjectKit

@available(macOS 26.0, *)
struct ImagineScenesPageView: View {
    private enum ReferencePickerMode: Identifiable {
        case gemini

        var id: String {
            switch self {
            case .gemini: return "gemini"
            }
        }
    }

    private enum SceneGallerySortMode: String, CaseIterable, Identifiable {
        case newest, oldest, highestRated
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .newest: "Newest"
            case .oldest: "Oldest"
            case .highestRated: "Highest Rated"
            }
        }
    }

    private enum SceneGalleryFlagFilter: String, CaseIterable, Identifiable {
        case all, unflagged, rejected
        var id: String { rawValue }
    }

    private enum SceneImageGenerator: String, CaseIterable, Identifiable {
        case openAI = "openai"
        case nanoBanana2 = "nano_banana_2"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openAI: "GPT Image 2"
            case .nanoBanana2: "Nano Banana 2"
            }
        }
    }

    private struct AutomaticReferenceAttachment: Identifiable, Hashable {
        var id: String { path }
        var path: String
        var role: ReferenceRole
        var label: String
        var source: String
        var guidance: String?

        var debugSummary: String {
            [
                role.rawValue,
                label,
                source,
                guidance
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
        }
    }

    @Bindable var store: AnimateStore
    @State private var selectedMoment: ImagineShotMoment = .beginning
    @State private var previewImagePath: String?
    @State private var generationPrompt: String = ""
    @State private var isGeneratingPrompt: Bool = false
    @State private var isGenerating: Bool = false
    @State private var generationError: String?
    @State private var geminiReferenceImages: [GeminiImageService.ReferenceImage] = []
    /// Source-of-truth for manual reference images on this page. The
    /// `geminiReferenceImages` array (which holds base64-encoded payloads)
    /// is derived from this whenever the URLs change, and again right before
    /// generation.
    @State private var manualReferenceURLs: [URL] = []
    @State private var automaticReferenceAttachments: [AutomaticReferenceAttachment] = []
    @State private var automaticReferenceImagePaths: [String] = []
    @State private var automaticReferenceStatus: String?
    @State private var cachedGenerationPlanPreview: ShotFrameGenerationPlan?
    @State private var activeReferencePicker: ReferencePickerMode?
    @AppStorage("animate.scenes.imageGenerator") private var selectedGeneratorRaw: String = SceneImageGenerator.openAI.rawValue
    @AppStorage("animate.scenes.openAIImageQuality") private var openAIImageQualityRaw: String = OpenAIImageQuality.low.rawValue
    @State private var isDryRunningShotPipeline: Bool = false
    @State private var bulkProgressMessage: String?
    @State private var dryRunSummaryMessage: String?
    @State private var promptPopoverText: String?
    @State private var showPromptPopover: Bool = false
    @State private var scenePreparationTask: Task<Void, Never>?
    @State private var galleryThumbnailSize: CGFloat = 120
    @State private var gallerySortMode: SceneGallerySortMode = .newest
    @State private var galleryMinimumRating: Int? = nil
    @State private var galleryFlagFilter: SceneGalleryFlagFilter = .all
    @State private var deleteConfirmationPath: String? = nil
    @State private var galleryMetadataRevision: Int = 0
    @State private var filteredMomentPaths: [String] = []
    @State private var scenePreflightDrafts: [GeminiGenerationDraft] = []
    @State private var scenePendingPreflight: GeminiGenerationDraft? = nil

    @AppStorage("animate.scenes.storyboardDrawingsCollapsed") private var storyboardDrawingsCollapsed: Bool = true

    private var selectedScene: AnimationScene? { store.selectedScene }
    private var shots: [AnimationSceneShot] { selectedScene?.shots ?? [] }

    private var currentGallery: ImagineSceneShotGallery? {
        guard let scene = selectedScene, let idx = store.imagineSelectedShotIndex else { return nil }
        return store.imagineGallery(for: scene.id, shotIndex: idx)
    }

    private var currentMomentPaths: [String] {
        currentGallery?.paths(for: selectedMoment) ?? []
    }

    private var currentShot: AnimationSceneShot? {
        guard let scene = selectedScene,
              let idx = store.imagineSelectedShotIndex,
              idx >= 0, idx < scene.shots.count else { return nil }
        return scene.shots[idx]
    }

    private var selectedGeneratorBinding: Binding<SceneImageGenerator> {
        Binding(
            get: { SceneImageGenerator(rawValue: selectedGeneratorRaw) ?? .openAI },
            set: { selectedGeneratorRaw = $0.rawValue }
        )
    }

    private var selectedGenerator: SceneImageGenerator {
        SceneImageGenerator(rawValue: selectedGeneratorRaw) ?? .openAI
    }

    private var selectedGeneratorActivityKind: AnimateStore.GeminiActivityEntry.Kind {
        switch selectedGenerator {
        case .openAI: return .openAIImage
        case .nanoBanana2: return .geminiImage
        }
    }

    private var openAIImageQualityBinding: Binding<OpenAIImageQuality> {
        Binding(
            get: { OpenAIImageQuality(rawValue: openAIImageQualityRaw) ?? .low },
            set: { openAIImageQualityRaw = $0.rawValue }
        )
    }

    private var selectedOpenAIImageQuality: OpenAIImageQuality {
        OpenAIImageQuality(rawValue: openAIImageQualityRaw) ?? .low
    }

    private var featuredFramePath: String? {
        guard let scene = selectedScene,
              let idx = store.imagineSelectedShotIndex else { return nil }
        return store.imagineGallery(for: scene.id, shotIndex: idx)?.selectedPath(for: selectedMoment)
    }

    @ViewBuilder
    private var featuredFrameLargeView: some View {
        if let path = featuredFramePath, FileManager.default.fileExists(atPath: path),
           let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(4/3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                )
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.06))
                .aspectRatio(4/3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.badge.plus")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                        Text("Right-click a thumbnail to set as frame")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                            .multilineTextAlignment(.center)
                    }
                }
        }
    }

    private var filteredMomentPathsKey: String {
        [
            selectedScene?.id.uuidString ?? "none",
            currentShot?.id.uuidString ?? "none",
            selectedMoment.directoryName,
            currentMomentPaths.joined(separator: ","),
            gallerySortMode.rawValue,
            "\(galleryMinimumRating ?? 0)",
            galleryFlagFilter.rawValue,
            "\(galleryMetadataRevision)"
        ].joined(separator: "|")
    }

    private var usesReferenceDrivenPromptStyle: Bool {
        true
    }

    private var currentStoredPrompt: String {
        guard let scene = selectedScene,
              let shotIndex = store.imagineSelectedShotIndex else { return "" }
        return store.imaginePrompt(for: scene.id, shotIndex: shotIndex, moment: selectedMoment)
    }

    private var currentGenerationPlanPreview: ShotFrameGenerationPlan? {
        cachedGenerationPlanPreview
    }

    private var automaticReferenceRefreshKey: String {
        guard let scene = selectedScene,
              let shotIndex = store.imagineSelectedShotIndex,
              shotIndex >= 0,
              shotIndex < scene.shots.count else {
            return "none|\(selectedGeneratorRaw)"
        }
        let shot = scene.shots[shotIndex]
        let characterIDs = resolvedCharacterIDs(for: scene, shot: shot).joined(separator: ",")
        return [
            selectedGeneratorRaw,
            scene.id.uuidString,
            shot.id.uuidString,
            selectedMoment.directoryName,
            scene.backgroundID?.uuidString ?? "no-place",
            characterIDs
        ].joined(separator: "|")
    }

    private var generationPlanPreviewRefreshKey: String {
        guard let scene = selectedScene,
              let owpURL = store.fileOWPURL,
              let shotIndex = store.imagineSelectedShotIndex,
              shotIndex >= 0,
              shotIndex < scene.shots.count else {
            return "none"
        }
        let shot = scene.shots[shotIndex]
        let gallery = store.imagineGallery(for: scene.id, shotIndex: shotIndex)
        let previousGallery = shotIndex > 0
            ? store.imagineGallery(for: scene.id, shotIndex: shotIndex - 1)
            : nil
        return [
            owpURL.path,
            scene.id.uuidString,
            shot.id.uuidString,
            shot.cameraShot?.rawValue ?? "",
            shot.shotIntent?.rawValue ?? "",
            "\(shotIndex)",
            selectedMoment.directoryName,
            "\(generationPrompt.hashValue)",
            automaticReferenceImagePaths.joined(separator: ","),
            "\(geminiReferenceImages.count)",
            generationPlanGallerySignature(gallery),
            generationPlanGallerySignature(previousGallery)
        ].joined(separator: "|")
    }


    var body: some View {
        if let scene = selectedScene {
            VStack(spacing: 0) {
                shotTimeline(scene: scene)
                bulkBar(scene: scene)
                Divider()
                middlePaneSplit(scene: scene)
            }
            .onChange(of: store.selectedSceneID) { _, _ in
                store.imagineSelectedShotIndex = shots.isEmpty ? nil : 0
                scheduleSelectedScenePreparation()
                // Prompt is scene/shot/moment-specific. Load only the stored
                // prompt for the current context so we never carry stale text
                // across scenes while still preserving intentional work.
                syncGenerationStateFromCurrentContext()
            }
            .onChange(of: store.selectedShotID) { _, shotID in
                syncImagineSelectionFromSidebarShotID(shotID)
            }
            .onChange(of: store.imagineSelectedShotIndex) { _, _ in
                syncSidebarShotIDFromImagineSelection()
                syncGenerationStateFromCurrentContext()
            }
            .onChange(of: selectedMoment) { _, _ in
                syncGenerationStateFromCurrentContext()
            }
            .onAppear {
                if store.imagineSelectedShotIndex == nil && !shots.isEmpty {
                    store.imagineSelectedShotIndex = 0
                }
                syncImagineSelectionFromSidebarShotID(store.selectedShotID)
                scheduleSelectedScenePreparation()
                syncGenerationStateFromCurrentContext()
            }
            .onDisappear {
                scenePreparationTask?.cancel()
            }
            .onChange(of: generationPrompt) { _, _ in
                persistCurrentPrompt(debounced: true)
            }
            .onChange(of: manualReferenceURLs) { _, urls in
                // The composer is the source of truth for manual references.
                // Keep the encoded GeminiImageService.ReferenceImage payload
                // in sync so the plan-preview refresh key, the Generate
                // button's preview summary, and any downstream consumer all
                // see the live count + content immediately.
                geminiReferenceImages = makeGeminiReferenceImages(from: urls.map(\.path))
                refreshGenerationPlanPreview()
            }
            .task(id: filteredMomentPathsKey) {
                let paths = currentMomentPaths
                let sortMode = gallerySortMode
                let flagFilter = galleryFlagFilter
                let minRating = galleryMinimumRating

                let result = await Task.detached(priority: .userInitiated) {
                    let metadataByPath: [String: ImageLibraryReviewMetadata] = paths.reduce(into: [:]) { result, path in
                        result[path] = ImageLibraryMetadataSidecarService.load(forImagePath: path)
                    }

                    var filtered = paths

                    switch flagFilter {
                    case .all: break
                    case .unflagged:
                        filtered = filtered.filter { !(metadataByPath[$0]?.isRejected ?? false) }
                    case .rejected:
                        filtered = filtered.filter { metadataByPath[$0]?.isRejected ?? false }
                    }

                    if let minRating {
                        filtered = filtered.filter { (metadataByPath[$0]?.rating ?? 0) >= minRating }
                    }

                    let modificationDates: [String: Date]
                    switch sortMode {
                    case .newest, .oldest:
                        modificationDates = filtered.reduce(into: [:]) { result, path in
                            result[path] = ((try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast)
                        }
                    case .highestRated:
                        modificationDates = [:]
                    }

                    switch sortMode {
                    case .newest:
                        filtered.sort { (modificationDates[$0] ?? .distantPast) > (modificationDates[$1] ?? .distantPast) }
                    case .oldest:
                        filtered.sort { (modificationDates[$0] ?? .distantPast) < (modificationDates[$1] ?? .distantPast) }
                    case .highestRated:
                        filtered.sort { (metadataByPath[$0]?.rating ?? 0) > (metadataByPath[$1]?.rating ?? 0) }
                    }

                    return filtered
                }.value

                if !Task.isCancelled {
                    filteredMomentPaths = result
                }
            }
            .task(id: automaticReferenceRefreshKey) {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                await refreshAutomaticReferenceImages()
            }
            .task(id: generationPlanPreviewRefreshKey) {
                refreshGenerationPlanPreview()
            }
            .sheet(item: $scenePendingPreflight) { _ in
                GeminiGenerationPreflightSheet(
                    store: store,
                    drafts: $scenePreflightDrafts,
                    title: scenePreflightDrafts.first?.title ?? "Generate Animated",
                    confirmTitle: "Generate",
                    onConfirm: { drafts, mode in
                        scenePendingPreflight = nil
                        switch mode {
                        case .standard:
                            runScenePreflightGeneration(drafts)
                        case .batch:
                            generationError = "Scene shot batch queue is not available here yet. Use Generate Now."
                        }
                    },
                    onCancel: {
                        scenePendingPreflight = nil
                        scenePreflightDrafts = []
                    }
                )
            }
            .sheet(item: $activeReferencePicker) { pickerMode in
                UniversalImagePickerSheet(
                    store: store,
                    maxSelections: 5,
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
                        proxy.scrollTo(idx, anchor: .center)
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

    private func scheduleSelectedScenePreparation() {
        scenePreparationTask?.cancel()
        guard let sceneID = store.selectedSceneID else { return }
        scenePreparationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  store.selectedSceneID == sceneID else { return }
            store.ensureImagineDirectories(for: sceneID)
            store.refreshImagineGalleryFromDisk(sceneID: sceneID)
        }
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

    // MARK: - Middle Pane

    @ViewBuilder
    private func middlePaneSplit(scene: AnimationScene) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                momentTabBar
                galleryFilterBar
                galleryGrid
                storyboardDrawingsSection(scene: scene)
                generationControls
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Inspector Pane

    private var inspectorPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                UnifiedDetailsInspectorSection(
                    selection: SceneShotImageSelection(
                        path: previewImagePath ?? currentGallery?.selectedPath(for: selectedMoment),
                        store: store,
                        scene: selectedScene,
                        shotIndex: store.imagineSelectedShotIndex,
                        moment: selectedMoment,
                        onSetRating: { rating in
                            guard let path = previewImagePath ?? currentGallery?.selectedPath(for: selectedMoment) else { return }
                            setSceneShotImageRating(rating, path: path)
                        },
                        onToggleRejected: {
                            guard let path = previewImagePath ?? currentGallery?.selectedPath(for: selectedMoment) else { return }
                            toggleSceneShotImageRejected(path)
                        },
                        onSetNotes: { notes in
                            guard let path = previewImagePath ?? currentGallery?.selectedPath(for: selectedMoment) else { return }
                            setSceneShotImageNotes(notes, path: path)
                        }
                    )
                )
            }
            .padding()
        }
        .frame(width: 280)
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

    // MARK: - Gallery Filter Bar

    private var galleryFilterBar: some View {
        HStack(spacing: 10) {
            Text("\(filteredMomentPaths.count) of \(currentMomentPaths.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 50, alignment: .leading)

            Picker("Sort", selection: $gallerySortMode) {
                ForEach(SceneGallerySortMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            // Rating filter
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        galleryMinimumRating = galleryMinimumRating == star ? nil : star
                    } label: {
                        Image(systemName: galleryMinimumRating != nil && star <= (galleryMinimumRating ?? 0) ? "star.fill" : "star")
                            .font(.caption2)
                            .foregroundStyle(galleryMinimumRating != nil && star <= (galleryMinimumRating ?? 0) ? .yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.12), in: Capsule())

            // Flag filter
            HStack(spacing: 2) {
                Button { galleryFlagFilter = .all } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .foregroundStyle(galleryFlagFilter == .all ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                Button { galleryFlagFilter = .unflagged } label: {
                    Image(systemName: "flag.slash")
                        .foregroundStyle(galleryFlagFilter == .unflagged ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                Button { galleryFlagFilter = .rejected } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(galleryFlagFilter == .rejected ? .red : .secondary)
                }
                .buttonStyle(.plain)
            }
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.12), in: Capsule())

            Spacer()

            // Thumbnail size slider
            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Slider(value: $galleryThumbnailSize, in: 80...260)
                    .frame(width: 100)
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Gallery Grid

    private var galleryGrid: some View {
        Group {
            if filteredMomentPaths.isEmpty {
                if currentMomentPaths.isEmpty {
                    Text("No \(selectedMoment.rawValue.lowercased()) images for this shot yet.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    Text("No images match the current filters.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
            } else {
                ScrollView(.horizontal, showsIndicators: true) {
                    LazyHStack(alignment: .top, spacing: 10) {
                        ForEach(filteredMomentPaths, id: \.self) { path in
                            galleryThumbnail(path: path)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .frame(minHeight: galleryThumbnailSize + 34, alignment: .topLeading)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            return importDroppedImagesToCurrentMoment(urls: urls)
        }
        .confirmationDialog(
            "Delete Image",
            isPresented: Binding(
                get: { deleteConfirmationPath != nil },
                set: { if !$0 { deleteConfirmationPath = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) {
                if let path = deleteConfirmationPath {
                    trashSceneShotImage(path)
                }
            }
            Button("Cancel", role: .cancel) {
                deleteConfirmationPath = nil
            }
        } message: {
            Text("This image will be moved to the Trash and removed from the project.")
        }
    }

    private func storyboardDrawingsSection(scene: AnimationScene) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    storyboardDrawingsCollapsed.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: storyboardDrawingsCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 14)
                    Text("STORYBOARD DRAWINGS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 12)
                    Text(storyboardDrawingsCollapsed ? "Show" : "Hide")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !storyboardDrawingsCollapsed {
                SceneStoryboardDrawingsStrip(
                    projectRoot: store.fileOWPURL,
                    sceneID: scene.id,
                    shot: currentShot
                )
                .frame(height: 150, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 2)
    }

    @ViewBuilder
    private func galleryThumbnail(path: String) -> some View {
        let isSelected = previewImagePath == path
        let metadata = ImageLibraryMetadataSidecarService.load(forImagePath: path)
        let featuredMoment = featuredMoment(forPath: path)

        UnifiedImageTile(
            path: path,
            thumbnailSize: galleryThumbnailSize,
            isSelected: isSelected,
            isRejected: metadata?.isRejected ?? false,
            isLiked: metadata?.isLiked ?? false,
            rating: metadata?.rating,
            actions: UnifiedImageActions(
                onShowPrompt: { showPromptForImage(path: path) },
                onShowInFinder: { ImagineProjectStorage.revealInFinder(path) },
                onCopy: { copyImageToPasteboardAsync(path: path) },
                onGenerateAnimated: {
                    beginGenerateAnimated(path: path)
                },
                onSetRating: { newRating in
                    setSceneShotImageRating(newRating, path: path)
                },
                currentRating: metadata?.rating,
                onToggleLiked: {
                    toggleSceneShotImageLiked(path)
                },
                isLiked: metadata?.isLiked ?? false,
                onToggleRejected: {
                    toggleSceneShotImageRejected(path)
                },
                isRejected: metadata?.isRejected ?? false,
                onMoveToTrash: {
                    deleteConfirmationPath = path
                },
                onSetAsFrame: { moment in
                    setFeaturedFrame(path: path, moment: moment)
                },
                featuredFrameMoment: featuredMoment
            ),
            onTap: {
                previewImagePath = path
                store.imaginePreviewImagePath = path
            }
        )
    }

    private func setFeaturedFrame(path: String, moment: ImagineShotMoment) {
        guard let scene = selectedScene,
              let idx = store.imagineSelectedShotIndex else { return }
        store.setImagineSelectedPath(path, sceneID: scene.id, shotIndex: idx, moment: moment)
    }

    private func featuredMoment(forPath path: String) -> ImagineShotMoment? {
        guard let scene = selectedScene,
              let idx = store.imagineSelectedShotIndex,
              let gallery = store.imagineGallery(for: scene.id, shotIndex: idx) else { return nil }
        for moment in ImagineShotMoment.allCases where gallery.selectedPath(for: moment) == path {
            return moment
        }
        return nil
    }

    // MARK: - Scene Shot Image Metadata

    private func setSceneShotImageRating(_ rating: Int?, path: String) {
        var metadata = ImageLibraryMetadataSidecarService.load(forImagePath: path)
            ?? ImageLibraryReviewMetadata(rating: nil, isRejected: false, notes: "", updatedAt: nil)
        metadata.rating = rating
        metadata.updatedAt = Date()
        ImageLibraryMetadataSidecarService.save(metadata, forImagePath: path)
        ImagePreferenceProfileService.scheduleRebuild(store: store, projectRoot: store.fileOWPURL)
        galleryMetadataRevision += 1
    }

    private func toggleSceneShotImageRejected(_ path: String) {
        var metadata = ImageLibraryMetadataSidecarService.load(forImagePath: path)
            ?? ImageLibraryReviewMetadata(rating: nil, isRejected: false, notes: "", updatedAt: nil)
        metadata.isRejected.toggle()
        if metadata.isRejected {
            metadata.isLiked = false
        }
        metadata.updatedAt = Date()
        ImageLibraryMetadataSidecarService.save(metadata, forImagePath: path)
        ImagePreferenceProfileService.scheduleRebuild(store: store, projectRoot: store.fileOWPURL)
        galleryMetadataRevision += 1
    }

    private func toggleSceneShotImageLiked(_ path: String) {
        var metadata = ImageLibraryMetadataSidecarService.load(forImagePath: path)
            ?? ImageLibraryReviewMetadata(rating: nil, isRejected: false, notes: "", updatedAt: nil)
        metadata.isLiked.toggle()
        if metadata.isLiked {
            metadata.isRejected = false
        }
        metadata.updatedAt = Date()
        ImageLibraryMetadataSidecarService.save(metadata, forImagePath: path)
        ImagePreferenceProfileService.scheduleRebuild(store: store, projectRoot: store.fileOWPURL)
        galleryMetadataRevision += 1
    }

    private func setSceneShotImageNotes(_ notes: String, path: String) {
        var metadata = ImageLibraryMetadataSidecarService.load(forImagePath: path)
            ?? ImageLibraryReviewMetadata(rating: nil, isRejected: false, notes: "", updatedAt: nil)
        metadata.notes = notes
        metadata.updatedAt = Date()
        ImageLibraryMetadataSidecarService.save(metadata, forImagePath: path)
        ImagePreferenceProfileService.scheduleRebuild(store: store, projectRoot: store.fileOWPURL)
        galleryMetadataRevision += 1
    }

    private func trashSceneShotImage(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let fileExists = FileManager.default.fileExists(atPath: path)

        if fileExists {
            do {
                var resultingURL: NSURL? = nil
                try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            } catch {
                print("[ImagineScenesPageView] trashItem failed for \(path): \(error.localizedDescription)")
                return
            }
        }

        store.moveAnyProjectImageToTrash(path: path, resolvedPath: path)

        // Refresh gallery from disk to pick up the deletion
        if let sceneID = selectedScene?.id {
            store.refreshImagineGalleryFromDisk(sceneID: sceneID)
        }

        // Clear preview if it was the deleted image
        if previewImagePath == path {
            previewImagePath = nil
            store.imaginePreviewImagePath = nil
        }

        deleteConfirmationPath = nil
    }

    // MARK: - Generation Controls (pinned bottom)

    private var generationControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Picker("Model", selection: selectedGeneratorBinding) {
                    ForEach(SceneImageGenerator.allCases) { generator in
                        Text(generator.displayName).tag(generator)
                    }
                }
                .frame(maxWidth: 180)

                if selectedGenerator == .openAI {
                    Picker("Quality", selection: openAIImageQualityBinding) {
                        ForEach(OpenAIImageQuality.allCases) { quality in
                            Text(quality.displayName).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                } else {
                    Picker("Gemini Model", selection: $store.selectedGeminiModel) {
                        ForEach(GeminiModel.allCases, id: \.self) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .frame(maxWidth: 190)
                    .disabled(!store.geminiMasterSwitch)
                }

                Spacer()

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
                .controlSize(.regular)
                .disabled(!canSubmitGeneration)

                Button { composeStoryboard() } label: {
                    Label("Compose", systemImage: "perspective")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!canComposeStoryboard)
            }

            // Shared composer: same prompt-editor + references drop-target box
            // used on the Canvas page. Drag images (including storyboard
            // drawings from the strip above) into the dashed area.
            GeminiPromptComposer(
                prompt: $generationPrompt,
                referenceURLs: $manualReferenceURLs,
                promptPersistenceID: "scenes.generationPrompt",
                promptPlaceholder: "Describe this shot frame…",
                maxReferenceCount: 5
            )

            automaticReferenceStrip

            if let plan = currentGenerationPlanPreview {
                generationPlanSummary(plan)
            }

            if let automaticReferenceStatus {
                Text(automaticReferenceStatus)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if isGeneratingPrompt {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Generating scene-aware prompt via GPT…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = generationError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if isGenerating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Generating \(selectedGenerator.displayName) image…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSubmitGeneration: Bool {
        guard !generationPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !isGenerating,
              !isGeneratingPrompt else { return false }
        switch selectedGenerator {
        case .openAI:
            return !store.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .nanoBanana2:
            return store.geminiMasterSwitch && store.hasGeminiImageGenerationConfiguration
        }
    }

    @ViewBuilder
    private var automaticReferenceStrip: some View {
        if !automaticReferenceAttachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label("Automatic References", systemImage: "photo.on.rectangle.angled")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("\(automaticReferenceAttachments.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(automaticReferenceAttachments) { attachment in
                            AsyncStoreThumbnailImage<AnyView>.rounded(
                                store: store,
                                path: attachment.path,
                                maxSize: 256,
                                width: 92,
                                height: 58,
                                contentMode: .fill,
                                cornerRadius: 6,
                                placeholderOpacity: 0.18
                            )
                            .overlay(alignment: .bottomLeading) {
                                Text(URL(fileURLWithPath: attachment.path).deletingPathExtension().lastPathComponent)
                                    .font(.system(size: 8))
                                    .lineLimit(1)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4))
                                    .foregroundStyle(.white.opacity(0.9))
                                    .padding(4)
                            }
                            .help(attachment.debugSummary)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    // MARK: - Actions

    /// Prompts are scene/shot/moment-specific. Always load the prompt stored
    /// for the exact current context so we preserve intentional work without
    /// leaking stale text across shots or moments. Reference images are NOT
    /// cleared because the user has to pick those manually and may
    /// legitimately reuse them.
    private func syncGenerationStateFromCurrentContext() {
        generationPrompt = currentStoredPrompt
        generationError = nil
        previewImagePath = nil
        store.imaginePreviewImagePath = nil
        filteredMomentPaths = []
        automaticReferenceAttachments = []
        automaticReferenceImagePaths = []
        automaticReferenceStatus = nil
        cachedGenerationPlanPreview = nil
    }

    private func syncImagineSelectionFromSidebarShotID(_ shotID: UUID?) {
        guard let scene = selectedScene else { return }
        guard let shotID else { return }
        guard let index = scene.shots.firstIndex(where: { $0.id == shotID }),
              store.imagineSelectedShotIndex != index else { return }
        store.imagineSelectedShotIndex = index
    }

    private func syncSidebarShotIDFromImagineSelection() {
        guard let scene = selectedScene,
              let index = store.imagineSelectedShotIndex,
              index >= 0,
              index < scene.shots.count else { return }
        let shotID = scene.shots[index].id
        if store.selectedShotID != shotID {
            store.selectedShotID = shotID
        }
    }

    private func persistCurrentPrompt(debounced: Bool) {
        guard let scene = selectedScene,
              let shotIndex = store.imagineSelectedShotIndex else { return }
        store.setImaginePrompt(
            generationPrompt,
            sceneID: scene.id,
            shotIndex: shotIndex,
            moment: selectedMoment
        )
        if debounced {
            store.scheduleDebouncedSave()
        } else {
            store.save()
        }
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
            subjectStyle: .neutralSubjects
        )
        persistCurrentPrompt(debounced: false)
    }

    private func autoGeneratePrompt() {
        guard let scene = selectedScene, let shotIndex = store.imagineSelectedShotIndex, shotIndex < scene.shots.count else { return }
        isGeneratingPrompt = true
        let activityID = store.registerGeminiActivity(
            kind: .openAIText,
            title: "Auto prompt S\(shotIndex + 1) \(selectedMoment.rawValue)",
            source: "Scenes • \(scene.name)",
            initialStatus: .running
        )
        Task {
            defer { isGeneratingPrompt = false }
            do {
                let service = ImagineScenePromptService(store: store)
                generationPrompt = try await service.generatePrompt(
                    scene: scene,
                    shotIndex: shotIndex,
                    moment: selectedMoment,
                    subjectStyle: .neutralSubjects
                )
                persistCurrentPrompt(debounced: false)
                store.updateGeminiActivity(activityID, status: .completed)
            } catch {
                generationError = error.localizedDescription
                store.updateGeminiActivity(activityID, status: .failed, errorMessage: error.localizedDescription)
            }
        }
    }

    private func generateImage() {
        guard let scene = selectedScene, let owpURL = store.fileOWPURL, let shotIndex = store.imagineSelectedShotIndex else { return }
        persistCurrentPrompt(debounced: false)
        // Sync URL-based composer state to the GeminiImageService payload
        // immediately before submitting — the composer is the source of truth.
        geminiReferenceImages = makeGeminiReferenceImages(from: manualReferenceURLs.map(\.path))
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
                let automaticResult = await resolveAutomaticReferences(
                    scene: scene,
                    shotIndex: shotIndex,
                    moment: selectedMoment
                )
                let automaticReferences = automaticResult.attachments.map(\.path)
                automaticReferenceAttachments = automaticResult.attachments
                automaticReferenceImagePaths = automaticReferences
                automaticReferenceStatus = automaticResult.status
                let plan = makeShotFrameGenerationPlan(
                    scene: scene,
                    owpURL: owpURL,
                    shotIndex: shotIndex,
                    moment: selectedMoment,
                    prompt: generationPrompt,
                    automaticReferenceImagePaths: automaticReferences
                )
                cachedGenerationPlanPreview = plan

                let activityID = store.registerGeminiActivity(
                    kind: selectedGeneratorActivityKind,
                    title: "\(selectedMoment.rawValue) frame S\(shotIndex + 1)",
                    source: "Scenes • \(scene.name)",
                    initialStatus: .running
                )
                switch selectedGenerator {
                case .nanoBanana2:
                    guard store.isGeminiAllowed() else {
                        generationError = "Gemini API calls are blocked. Enable in Inspector > Tools."
                        store.updateGeminiActivity(activityID, status: .failed, errorMessage: generationError)
                        return
                    }
                    do {
                        let savedURL = try await service.generateWithGemini(
                            plan: plan,
                            manualReferenceImages: geminiReferenceImages,
                            model: store.selectedGeminiModel, apiKey: store.geminiAPIKey,
                            owpURL: owpURL, sceneSlug: sceneSlug, shotIndex: shotIndex, moment: selectedMoment
                        )
                        registerGeneratedShotImage(
                            savedURL,
                            scene: scene,
                            shotIndex: shotIndex,
                            moment: selectedMoment,
                            generator: "gemini",
                            mode: plan.mode.rawValue
                        )
                        store.updateGeminiActivity(activityID, status: .completed, outputFilename: savedURL.lastPathComponent)
                    } catch {
                        store.updateGeminiActivity(activityID, status: .failed, errorMessage: error.localizedDescription)
                        throw error
                    }
                case .openAI:
                    do {
                        let savedURL = try await service.generateWithOpenAI(
                            plan: plan,
                            manualReferenceURLs: manualReferenceURLs,
                            apiKey: store.openAIAPIKey,
                            quality: selectedOpenAIImageQuality,
                            owpURL: owpURL,
                            sceneSlug: sceneSlug,
                            shotIndex: shotIndex,
                            moment: selectedMoment
                        )
                        registerGeneratedShotImage(
                            savedURL,
                            scene: scene,
                            shotIndex: shotIndex,
                            moment: selectedMoment,
                            generator: "openai",
                            mode: "\(plan.mode.rawValue):\(selectedOpenAIImageQuality.rawValue)"
                        )
                        store.updateGeminiActivity(activityID, status: .completed, outputFilename: savedURL.lastPathComponent)
                    } catch {
                        store.updateGeminiActivity(activityID, status: .failed, errorMessage: error.localizedDescription)
                        throw error
                    }
                }
            } catch {
                generationError = error.localizedDescription
            }
        }
    }

    /// Right-click "Generate Animated" for a scene-shot gallery thumbnail.
    /// Opens the shared Gemini preflight sheet with the clicked image attached
    /// as the only manual reference and the master animated-look prompt enabled.
    private func beginGenerateAnimated(path: String) {
        guard let scene = selectedScene,
              let shotIndex = store.imagineSelectedShotIndex,
              shotIndex >= 0,
              shotIndex < scene.shots.count else { return }
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let reference = GeminiGenerationReferenceDraft(
            label: "Reference: \(filename)",
            path: path,
            isIncluded: true
        )
        UserDefaults.standard.set(true, forKey: AnimatedLookPromptSettings.preflightToggleDefaultsKey)
        let draft = GeminiGenerationDraft(
            title: "Generate Animated from \(filename)",
            destinationDescription: "\(scene.name) • Shot \(shotIndex + 1) • \(selectedMoment.rawValue)",
            prompt: "",
            contextNote: "Animated-look variation — the master animated prompt is composed into the request automatically.",
            model: store.selectedGeminiModel,
            aspectRatio: ShotFrameOpenMattePlan.defaultGeneratedAspectRatio,
            imageSize: ShotFrameOpenMattePlan.defaultGeneratedImageSize,
            referenceItems: [reference],
            usesMasterAnimatedLookPrompt: true
        )
        scenePreflightDrafts = [draft]
        scenePendingPreflight = draft
    }

    private func runScenePreflightGeneration(_ drafts: [GeminiGenerationDraft]) {
        guard let scene = selectedScene,
              let owpURL = store.fileOWPURL,
              let shotIndex = store.imagineSelectedShotIndex,
              shotIndex >= 0,
              shotIndex < scene.shots.count else { return }
        guard store.isGeminiAllowed() else {
            generationError = "Gemini API calls are blocked. Enable in Inspector > Tools."
            return
        }
        guard !drafts.isEmpty else { return }

        let sceneSlug = scene.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let generationMoment = selectedMoment

        isGenerating = true
        generationError = nil
        Task { @MainActor in
            defer {
                isGenerating = false
                store.refreshImagineGalleryFromDisk(sceneID: scene.id)
                scenePreflightDrafts = []
            }

            let service = ImagineGenerationService()
            for draft in drafts {
                let activityID = store.registerGeminiActivity(
                    kind: .immediate,
                    title: draft.title,
                    source: "Imagine Scenes • \(scene.name)"
                )
                do {
                    store.logGeminiAPICall(endpoint: "image-generation", source: "ImagineScenesPageView.runScenePreflightGeneration()")
                    let savedURL = try await service.generateWithGemini(
                        prompt: draft.effectivePrompt,
                        referenceImages: buildPreflightReferenceImages(from: draft.referenceItems),
                        model: draft.model,
                        apiKey: store.geminiAPIKey,
                        owpURL: owpURL,
                        sceneSlug: sceneSlug,
                        shotIndex: shotIndex,
                        moment: generationMoment,
                        aspectRatio: draft.aspectRatio,
                        imageSize: draft.imageSize
                    )
                    registerGeneratedShotImage(
                        savedURL,
                        scene: scene,
                        shotIndex: shotIndex,
                        moment: generationMoment,
                        generator: "gemini",
                        mode: "animated"
                    )
                    store.updateGeminiActivity(
                        activityID,
                        status: .completed,
                        outputFilename: savedURL.lastPathComponent
                    )
                } catch {
                    store.updateGeminiActivity(activityID, status: .failed, errorMessage: error.localizedDescription)
                    generationError = error.localizedDescription
                    break
                }
            }
        }
    }

    private func buildPreflightReferenceImages(from references: [GeminiGenerationReferenceDraft]) -> [GeminiImageService.ReferenceImage] {
        references
            .filter(\.isIncluded)
            .compactMap { reference in
                GeminiImageService.referenceImage(from: URL(fileURLWithPath: reference.path).standardizedFileURL)
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

    private func importDroppedImagesToCurrentMoment(urls: [URL]) -> Bool {
        let valid = AnimateStore.filterImportableImageURLs(urls)
        guard !valid.isEmpty,
              let scene = selectedScene,
              let owpURL = store.fileOWPURL,
              let shotIndex = store.imagineSelectedShotIndex else {
            return false
        }

        let sceneSlug = scene.name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let destinationDirectory = ImagineProjectStorage.momentDirectory(
            owpURL: owpURL,
            sceneSlug: sceneSlug,
            shotIndex: shotIndex,
            moment: selectedMoment
        )

        var importedAny = false
        for url in valid {
            do {
                _ = try ImagineProjectStorage.importImage(from: url.standardizedFileURL, to: destinationDirectory)
                importedAny = true
            } catch {
                generationError = error.localizedDescription
            }
        }

        if importedAny {
            store.refreshImagineGalleryFromDisk(sceneID: scene.id)
        }
        return importedAny
    }

    private func handleSelectedReferenceImages(
        _ paths: [String],
        mode: ReferencePickerMode
    ) {
        switch mode {
        case .gemini:
            // Keep composer URL list and the encoded payloads in lockstep.
            manualReferenceURLs = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
            geminiReferenceImages = makeGeminiReferenceImages(from: paths)
            refreshGenerationPlanPreview()
        }
    }

    private func refreshGenerationPlanPreview() {
        guard let scene = selectedScene,
              let owpURL = store.fileOWPURL,
              let shotIndex = store.imagineSelectedShotIndex,
              shotIndex >= 0,
              shotIndex < scene.shots.count else {
            cachedGenerationPlanPreview = nil
            return
        }
        cachedGenerationPlanPreview = makeShotFrameGenerationPlan(
            scene: scene,
            owpURL: owpURL,
            shotIndex: shotIndex,
            moment: selectedMoment,
            prompt: generationPrompt,
            automaticReferenceImagePaths: automaticReferenceImagePaths
        )
    }

    private func generationPlanGallerySignature(_ gallery: ImagineSceneShotGallery?) -> String {
        guard let gallery else { return "none" }
        return [
            gallery.selectedBeginningPath ?? "",
            gallery.selectedMiddlePath ?? "",
            gallery.selectedEndPath ?? "",
            "\(gallery.beginningImagePaths.count)",
            "\(gallery.middleImagePaths.count)",
            "\(gallery.endImagePaths.count)"
        ].joined(separator: "#")
    }

    private func refreshAutomaticReferenceImages() async {
        let refreshKey = automaticReferenceRefreshKey
        guard let scene = selectedScene,
              let shotIndex = store.imagineSelectedShotIndex,
              shotIndex >= 0,
              shotIndex < scene.shots.count else {
            automaticReferenceAttachments = []
            automaticReferenceImagePaths = []
            automaticReferenceStatus = nil
            return
        }

        let result = await resolveAutomaticReferences(
            scene: scene,
            shotIndex: shotIndex,
            moment: selectedMoment
        )
        guard refreshKey == automaticReferenceRefreshKey else { return }
        let paths = result.attachments.map(\.path)
        automaticReferenceAttachments = result.attachments
        automaticReferenceImagePaths = paths
        automaticReferenceStatus = result.status
        refreshGenerationPlanPreview()
    }

    private func resolveAutomaticReferences(
        scene: AnimationScene,
        shotIndex: Int,
        moment: ImagineShotMoment
    ) async -> (attachments: [AutomaticReferenceAttachment], status: String?) {
        guard shotIndex >= 0,
              shotIndex < scene.shots.count,
              let owpURL = store.fileOWPURL else {
            return ([], nil)
        }

        do {
            let spec = EffectiveShotSpecBuilder(store: store).build(
                scene: scene,
                shotIndex: shotIndex,
                projectRoot: owpURL
            )
            guard hasCanonicalShotCardMapping(spec) else {
                return (
                    [],
                    "Image Intelligence stopped: this UI shot is not mapped to the active .ows camera card, so no automatic references were attached."
                )
            }
            let resolved = try ReferenceContractResolver(store: store).resolve(
                spec: spec,
                projectRoot: owpURL,
                write: false
            )
            var seen = Set<String>()
            let attachments = resolved.contract.usableReferences.compactMap { item -> AutomaticReferenceAttachment? in
                let path = URL(fileURLWithPath: item.path).standardizedFileURL.path
                guard FileManager.default.fileExists(atPath: path),
                      isAutomaticReferenceImagePath(path),
                      seen.insert(path).inserted else { return nil }
                return AutomaticReferenceAttachment(
                    path: path,
                    role: item.role,
                    label: item.label,
                    source: item.source,
                    guidance: item.guidance
                )
            }
            .prefix(5)

            let status: String
            if attachments.isEmpty {
                let blocker = resolved.contract.blockers.first?.message
                status = blocker ?? "Image Intelligence has no automatic references for this shot yet."
            } else {
                let debug = attachments
                    .map { "\($0.role.rawValue): \($0.source)" }
                    .joined(separator: " • ")
                status = "Image Intelligence attached \(attachments.count) contract reference\(attachments.count == 1 ? "" : "s"). \(debug)"
            }
            _ = moment
            return (Array(attachments), status)
        } catch {
            return ([], "Image Intelligence reference selection failed: \(error.localizedDescription)")
        }
    }

    private func hasCanonicalShotCardMapping(_ spec: EffectiveShotSpec) -> Bool {
        if spec.shotCardLabel?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        if spec.shotCardFocus?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        if spec.shotCardNotes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        if spec.shotCardContinuityNotes?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { return true }
        if spec.shotCardPlaces?.isEmpty == false { return true }
        if spec.shotCardProps?.isEmpty == false { return true }
        if spec.shotCardLandmarks?.isEmpty == false { return true }
        return false
    }

    private func isAutomaticReferenceImagePath(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "webp"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private func resolvedCharacterIDs(
        for scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> [String] {
        var ids: [UUID] = scene.characterIDs
        if let focusCharacterID = scene.directionTemplate?.focusCharacterID {
            ids.append(focusCharacterID)
        }
        if let focusCharacterID = shot.focusCharacterID {
            ids.append(focusCharacterID)
        }

        let slugs = (
            scene.characterSlugs +
            [scene.directionTemplate?.focusCharacterSlug, shot.focusCharacterSlug].compactMap { $0 }
        )
        for slug in slugs {
            if let character = store.characters.first(where: { character in
                character.owpSlug == slug || character.storageSlug == slug
            }) {
                ids.append(character.id)
            }
        }

        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }.map(\.uuidString)
    }

    private func automaticReferenceQueryText(
        scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> String {
        [
            scene.name,
            scene.directionTemplate?.notes,
            shot.name,
            shot.notes,
            shot.sourceLyricExcerpt
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private func registerGeneratedShotImage(
        _ url: URL,
        scene: AnimationScene,
        shotIndex: Int,
        moment: ImagineShotMoment,
        generator: String,
        mode: String
    ) {
        guard shotIndex >= 0,
              shotIndex < scene.shots.count else { return }
        let shot = scene.shots[shotIndex]
        store.registerImageAsset(
            path: url.standardizedFileURL.path,
            linkKind: .sceneShotImage,
            ownerID: shot.id.uuidString,
            ownerParentID: scene.id.uuidString,
            moment: moment.directoryName,
            workflow: "imagine_scene",
            context: [
                "sceneID": scene.id.uuidString,
                "sceneName": scene.name,
                "shotID": shot.id.uuidString,
                "shotName": shot.name,
                "shotOrder": "\(shotIndex + 1)",
                "moment": moment.directoryName,
                "generator": generator,
                "mode": mode
            ],
            analysisMode: .immediate
        )
    }

    private func makeShotFrameGenerationPlan(
        scene: AnimationScene,
        owpURL: URL,
        shotIndex: Int,
        moment: ImagineShotMoment,
        prompt: String,
        automaticReferenceImagePaths: [String]? = nil
    ) -> ShotFrameGenerationPlan {
        let shot = scene.shots[shotIndex]
        let shotSettings = ShotGenerationSettingsStore.load(projectRoot: owpURL)
        return ShotFrameGenerationPlanResolver.resolve(
            input: ShotFrameGenerationPlanResolver.Input(
                projectRoot: owpURL,
                sceneID: scene.id,
                shotID: shot.id,
                shotIndex: shotIndex,
                moment: moment,
                prompt: prompt,
                gallery: store.imagineGallery(for: scene.id, shotIndex: shotIndex),
                previousShotGallery: shotIndex > 0
                    ? store.imagineGallery(for: scene.id, shotIndex: shotIndex - 1)
                    : nil,
                automaticReferenceImagePaths: automaticReferenceImagePaths ?? self.automaticReferenceImagePaths,
                manualReferenceCount: geminiReferenceImages.count,
                cameraShot: resolvedCameraShot(for: scene, shot: shot),
                cameraMovement: resolvedCameraMovement(for: shot),
                generatedAspectRatio: shotSettings.generatedAspectRatio,
                generatedImageSize: shotSettings.generatedImageSize,
                extractionTargetAspectRatio: shotSettings.extractionTargetAspectRatio,
                finalDeliveryAspectRatio: shotSettings.finalDeliveryAspectRatio
            )
        )
    }

    private func generationPlanSummary(_ plan: ShotFrameGenerationPlan) -> some View {
        HStack(spacing: 8) {
            Label(plan.mode.displayName, systemImage: plan.usesEditPrompt ? "wand.and.rays.inverse" : "sparkles")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    plan.usesEditPrompt ? Color.orange.opacity(0.16) : Color.accentColor.opacity(0.14),
                    in: Capsule()
                )

            if let source = plan.sourceImage {
                Text("Source: \(source.source.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Full prompt + references")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if plan.storyboardImagePath != nil {
                Label("Storyboard attached", systemImage: "pencil.and.outline")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !plan.referenceImagePaths.isEmpty {
                Text("\(plan.referenceImagePaths.count) plan ref\(plan.referenceImagePaths.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            if let openMatte = plan.openMattePlan {
                Label(
                    "\(openMatte.generatedAspectRatio) \(openMatte.generatedImageSize) → \(openMatte.extractionTargetAspectRatio) · \(openMatte.cropMotion.displayName)",
                    systemImage: "crop"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .help(plan.decision.reasons.map(\.label).joined(separator: " • "))
    }

    private func makeGeminiReferenceImages(from paths: [String]) -> [GeminiImageService.ReferenceImage] {
        paths.compactMap { path in
            GeminiImageService.referenceImage(from: URL(fileURLWithPath: path).standardizedFileURL)
        }
    }

    // MARK: - Bulk Bar

    private func bulkBar(scene: AnimationScene) -> some View {
        HStack(spacing: 8) {
            if isDryRunningShotPipeline {
                ProgressView().controlSize(.small)
                Text(bulkProgressMessage ?? "Planning shot frame pipeline…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            } else {
                Button {
                    dryRunShotFramePipeline(scene)
                } label: {
                    Label("Dry Run: Scene", systemImage: "checklist")
                }
                .controlSize(.small)

                Spacer()

                if let dryRunSummaryMessage {
                    Text(dryRunSummaryMessage)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func dryRunShotFramePipeline(_ scene: AnimationScene) {
        guard let owpURL = store.fileOWPURL else { return }
        isDryRunningShotPipeline = true
        bulkProgressMessage = "Planning \(scene.shots.count) shot\(scene.shots.count == 1 ? "" : "s") × 3 frames…"
        dryRunSummaryMessage = nil

        Task {
            defer {
                isDryRunningShotPipeline = false
                bulkProgressMessage = nil
            }
            let planner = ShotFrameGenerationDryRunPlanner(store: store)
            let shotSettings = ShotGenerationSettingsStore.load(projectRoot: owpURL)
            let report = await planner.buildReport(
                scenes: store.scenes,
                projectRoot: owpURL,
                sceneFilter: [scene.id],
                model: store.selectedGeminiModel,
                imageSize: shotSettings.generatedImageSize
            )
            do {
                let reportURL = try await planner.writeReportAsync(report, projectRoot: owpURL)
                dryRunSummaryMessage = "Dry run: \(report.totalFrames) frames, \(report.generateFrames) generate / \(report.editFrames) edit, \(report.openMatteFrames) open-matte, \(report.automaticReferenceCount) auto refs, est. image cost $\(String(format: "%.2f", report.estimatedVertexCostUSD)) — \(reportURL.lastPathComponent)"
            } catch {
                generationError = "Dry run failed to save report: \(error.localizedDescription)"
            }
        }
    }

    private func resolvedCameraShot(
        for scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> CameraShot {
        shot.cameraShot
            ?? scene.directionTemplate?.defaultCameraShot
            ?? shot.shotIntent?.recommendedCameraShot
            ?? .medium
    }

    private func resolvedCameraMovement(for shot: AnimationSceneShot) -> CameraMovement? {
        shot.shotIntent?.recommendedCameraMovement
    }

    private var canComposeStoryboard: Bool {
        selectedScene != nil && store.imagineSelectedShotIndex != nil
    }

    private func composeStoryboard() {
        guard let scene = selectedScene,
              let owpURL = store.fileOWPURL,
              let shotIndex = store.imagineSelectedShotIndex,
              shotIndex < scene.shots.count
        else { return }
        let shot = scene.shots[shotIndex]

        Task {
            store.statusMessage = "Composing storyboard..."
            do {
                let service = StoryboardComposerService(store: store)
                let url = try await service.composeStoryboard(
                    scene: scene,
                    shot: shot,
                    projectRoot: owpURL
                )
                store.statusMessage = "Storyboard composed: \(url.lastPathComponent)"
            } catch {
                store.statusMessage = "Compose failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Scene Shot Image Selection

@available(macOS 26.0, *)
@MainActor
struct SceneShotImageSelection: DetailedImageSelection {
    let path: String?
    let store: AnimateStore
    let scene: AnimationScene?
    let shotIndex: Int?
    let moment: ImagineShotMoment
    let onSetRating: (Int?) -> Void
    let onToggleRejected: () -> Void
    let onSetNotes: (String) -> Void

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    var imageURL: URL? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path)
    }

    var title: String {
        guard let path else { return "" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var subtitle: String? {
        var parts: [String] = []
        if let scene { parts.append(scene.name) }
        if let shotIndex, let scene, shotIndex < scene.shots.count {
            let shot = scene.shots[shotIndex]
            parts.append("S\(shotIndex + 1)")
            if !shot.name.isEmpty { parts.append(shot.name) }
        }
        parts.append(moment.rawValue)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var rating: Int? {
        guard let path else { return nil }
        return ImageLibraryMetadataSidecarService.load(forImagePath: path)?.rating
    }

    var isRejected: Bool {
        guard let path else { return false }
        return ImageLibraryMetadataSidecarService.load(forImagePath: path)?.isRejected ?? false
    }

    var notes: String {
        guard let path else { return "" }
        return ImageLibraryMetadataSidecarService.load(forImagePath: path)?.notes ?? ""
    }

    var projectRootURL: URL? { store.fileOWPURL }

    var generationReferenceImages: [GenerationReferenceImageItem] {
        guard let path else { return [] }
        let resolvedPath = store.resolvedCharacterAssetURL(for: path)?.path ?? path
        return GenerationReferenceImageResolver.referenceItems(forImagePath: resolvedPath, projectRoot: store.fileOWPURL)
    }

    var metadataRows: [(label: String, value: String)] {
        guard let path else { return [] }
        var rows: [(label: String, value: String)] = []

        // Generation metadata from .json sidecar
        if let metadata = store.generationMetadata(for: path) {
            if !metadata.model.isEmpty {
                rows.append(("Model", metadata.model))
            }
            let sizing = [metadata.imageSize, metadata.aspectRatio]
                .filter { !$0.isEmpty }.joined(separator: " · ")
            if !sizing.isEmpty {
                rows.append(("Generation", sizing))
            }
            if !metadata.prompt.isEmpty {
                rows.append(("Prompt", metadata.prompt))
            }
        } else {
            // Fallback: .prompt.txt sidecar
            let url = URL(fileURLWithPath: path)
            let promptURL = url.deletingPathExtension().appendingPathExtension("prompt.txt")
            if let text = try? String(contentsOf: promptURL, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rows.append(("Prompt", text))
            }
        }

        // Resolution
        if let resolution = store.imageResolutionDescription(for: path), !resolution.isEmpty {
            rows.append(("Resolution", resolution))
        }

        // File attributes
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            if let size = attrs[.size] as? Int64 {
                rows.append(("File Size", Self.byteFormatter.string(fromByteCount: size)))
            }
            if let created = attrs[.creationDate] as? Date {
                rows.append(("Created", created.formatted(date: .abbreviated, time: .shortened)))
            }
        }

        rows.append(("Path", path))
        return rows
    }

    var emptyStateMessage: String {
        "Select an image to see details."
    }

    func setRating(_ newValue: Int?) {
        onSetRating(newValue)
    }

    func toggleRejected() {
        onToggleRejected()
    }

    func setNotes(_ newValue: String) {
        onSetNotes(newValue)
    }
}
