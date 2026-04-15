import SwiftUI
import AppKit
import ProjectKit
import Quartz
import UniformTypeIdentifiers

@available(macOS 26.0, *)
struct ImagineCharactersPageView: View {
    @Bindable var store: AnimateStore
    @State private var showLORATraining = false
    /// Selection state is a value type (Set-backed struct). Mutations copy-on-write and stay cheap at this gallery size.
    @State private var galleryState: ImagineGallerySelectionState = .init()
    @State private var focusedIndex: Int = 0
    @State private var preloadedPaths: [String] = []
    @AppStorage("imagineChars.galleryThumbnailSize") private var thumbnailBaseSize: Double = 120
    @AppStorage("imagineChars.galleryFilter") private var galleryFilterRawValue: String = GalleryFilter.all.rawValue
    /// Default preview pane height.
    @AppStorage("imagineChars.previewHeight") private var previewHeight: Double = 320
    @AppStorage("imagineChars.previewCollapsed") private var previewCollapsed: Bool = false
    @AppStorage("imagineChars.galleryCollapsed") private var galleryCollapsed: Bool = false
    @AppStorage("imagineChars.generationStatusCollapsed") private var generationStatusCollapsed: Bool = false
    @State private var dragStartHeight: Double?
    @State private var inspirationPendingPlan: PendingInspirationGenerationPlan?
    @State private var inspirationDrafts: [GeminiGenerationDraft] = []
    @State private var inspirationActiveWardrobe: CharacterInspirationWardrobe?
    @State private var inspirationPendingBatchTitleOverride: String?
    @State private var inspirationPendingBatchFolderSlugOverride: String?
    @State private var inspirationPendingBatchKind: CharacterInspirationBatchJob.Kind = .inspiration
    @State private var inspirationAutoSelectForLoRA = false
    @State private var inspirationGenerationErrorMessage: String?
    @State private var inspirationGenerationStatus: String?
    @State private var inspirationStatusCharacterID: UUID?
    @State private var inspirationGenerationProgress: Double = 0
    @State private var isGeneratingInspiration: Bool = false
    @State private var generatingInspirationCharacterID: UUID?
    @State private var isSubmittingInspirationBatch: Bool = false
    @State private var submittingInspirationBatchCharacterID: UUID?
    @ObservedObject private var runpodService = RunPodLORAService.shared
    @FocusState private var galleryKeyboardFocused: Bool
    @State private var hasShownFocusHighlight = false
    @State private var pendingGallerySaveTask: Task<Void, Never>?
    private let gallerySaveDebounceNanoseconds: UInt64 = 300_000_000


    private enum GalleryFilter: String, CaseIterable {
        case all
        case gemini
        case lora
        case hidden

        var title: String {
            switch self {
            case .all: return "All"
            case .gemini: return "Gemini"
            case .lora: return "LoRA"
            case .hidden: return "Hidden"
            }
        }
    }

    private var galleryFilter: GalleryFilter {
        get { GalleryFilter(rawValue: galleryFilterRawValue) ?? .all }
        nonmutating set { galleryFilterRawValue = newValue.rawValue }
    }

    private var galleryThumbnailBaseSize: CGFloat {
        CGFloat(thumbnailBaseSize)
    }

    private var displayedPaths: [String] {
        preloadedPaths.filter(isPathVisibleInGallery)
    }

    var body: some View {
        if let character = store.selectedCharacter {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    characterHeader(character)
                    inspirationSection(character)
                }
                .padding()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .sheet(item: $inspirationPendingPlan) { plan in
                GeminiGenerationPreflightSheet(
                    store: store,
                    drafts: $inspirationDrafts,
                    title: plan.title,
                    confirmTitle: plan.confirmTitle,
                    onConfirm: { drafts, mode in
                        let batchTitleOverride = inspirationPendingBatchTitleOverride
                        let batchFolderSlugOverride = inspirationPendingBatchFolderSlugOverride
                        let pendingBatchKind = inspirationPendingBatchKind
                        let autoSelectForLoRA = inspirationAutoSelectForLoRA
                        inspirationPendingPlan = nil
                        switch mode {
                        case .standard:
                            runInspirationGeneration(drafts, autoSelectForLoRA: autoSelectForLoRA)
                        case .batch:
                            submitInspirationBatch(
                                drafts,
                                wardrobe: inspirationActiveWardrobe ?? .soldier,
                                batchTitleOverride: batchTitleOverride,
                                batchFolderSlugOverride: batchFolderSlugOverride,
                                kind: pendingBatchKind
                            )
                        }
                        inspirationPendingBatchTitleOverride = nil
                        inspirationPendingBatchFolderSlugOverride = nil
                        inspirationPendingBatchKind = .inspiration
                        inspirationAutoSelectForLoRA = false
                    },
                    onCancel: {
                        inspirationPendingPlan = nil
                        inspirationPendingBatchTitleOverride = nil
                        inspirationPendingBatchFolderSlugOverride = nil
                        inspirationPendingBatchKind = .inspiration
                        inspirationAutoSelectForLoRA = false
                    }
                )
            }
            .sheet(isPresented: $store.showImageCropper) {
                if let imagePath = store.pendingCropImagePath,
                   let characterID = store.pendingCropCharacterID {
                    ImageCropperView(
                        imagePath: imagePath,
                        onCrop: { cropRect in
                            store.cropAndSetProfileImage(cropRect: cropRect, for: characterID)
                        },
                        onCancel: {
                            store.cancelImageCrop()
                        }
                    )
                }
            }
            .alert("Inspiration Image Generation", isPresented: inspirationGenerationAlertBinding) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(inspirationGenerationErrorMessage ?? "Unknown error.")
            }
            .onChange(of: store.selectedCharacterID) { _, _ in
                store.saveCharacterPromptEdits()
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text("Select a character to view inspiration images")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Character Header

    @ViewBuilder
    private func characterHeader(_ character: AnimationCharacter) -> some View {
        HStack(spacing: 16) {
            Circle()
                .fill(Color.secondary.opacity(0.2))
                .frame(width: 80, height: 80)
                .overlay {
                    Text(character.name.prefix(1))
                        .font(.title)
                        .foregroundStyle(.secondary)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(character.name)
                    .font(.title2.weight(.semibold))
                Text("\(character.inspirationImagePaths.count) inspiration images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                showLORATraining = true
            } label: {
                Label("Train LORA", systemImage: "cpu")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()
        }
    }

    // MARK: - Inspiration Section

    @ViewBuilder
    private func inspirationSection(_ character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with generate + import
            HStack {
                Text("Inspiration Gallery")
                    .font(.headline)
                Spacer()

                // Diagnostic: show WHY the button is disabled so it's never a mystery
                if let reason = generateButtonDisabledReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1), in: Capsule())
                }

                Menu {
                    inspirationGenerationMenuItems(for: character, wardrobe: character.defaultWardrobeType)
                    if !galleryState.selectedPaths.isEmpty {
                        Divider()
                        Section("Use Selected as References") {
                            Button("Generate 27-Image Set Now (with Selected Refs)") {
                                prepareInspirationWithSelectedReferences(character: character, mode: .immediate)
                            }
                            Button("Submit 27-Image Batch + Watchdog (with Selected Refs)") {
                                prepareInspirationWithSelectedReferences(character: character, mode: .batch)
                            }
                        }
                    }
                } label: {
                    Label("Generate", systemImage: "sparkles")
                }
                .menuStyle(.button)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(generateButtonDisabledReason != nil)

                Button("Import") {
                    store.importInspirationImages(for: character.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Train LORA with LORA-selected images
                Button {
                    flushGalleryStateSaveImmediately(for: character)
                    loadGalleryState(for: character)
                    showLORATraining = true
                } label: {
                    Label(
                        galleryState.loraSelectedPaths.isEmpty
                            ? "Train LORA"
                            : "Train LORA (\(galleryState.loraSelectedPaths.count))",
                        systemImage: "cpu"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!runpodService.hasAPIKey)
            }
            .sheet(isPresented: $showLORATraining) {
                LORATrainingSheet(
                    store: store,
                    character: character,
                    initialSelectedPaths: galleryState.loraSelectedPaths
                )
            }

            // Image Generation Status (instant Gemini + Gemini batches + LORA training) — above everything
            if !character.inspirationBatchJobs.isEmpty
                || runpodService.currentJob != nil
                || !runpodService.queuedJobs.isEmpty
                || !runpodService.recentJobs.isEmpty
                || (isGeneratingInspiration && generatingInspirationCharacterID == character.id) {
                generationStatusSection(character: character)
            }

            loraSelectionSection(character)

            // Preview pane header with collapse toggle
            if !displayedPaths.isEmpty, focusedIndex < displayedPaths.count {
                HStack(spacing: 6) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            previewCollapsed.toggle()
                        }
                    } label: {
                        Image(systemName: previewCollapsed ? "chevron.right" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Text("Preview")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if previewCollapsed {
                        Text("(hidden)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }

                    Spacer()
                }
                .padding(.vertical, 2)

                // Large preview pane
                if !previewCollapsed {
                    let focusedPath = displayedPaths[focusedIndex]
                    if let url = store.resolvedCharacterAssetURL(for: focusedPath) {
                        CachedPreviewImage(path: url.path)
                            .frame(maxWidth: .infinity)
                            .frame(height: previewHeight)
                            .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                            )

                        // Draggable resize handle
                        previewResizeHandle
                    }
                }
            }

            // Selection status bar
            if !galleryState.selectedPaths.isEmpty || !galleryState.loraSelectedPaths.isEmpty || !galleryState.hiddenPaths.isEmpty {
                HStack(spacing: 8) {
                    if !galleryState.selectedPaths.isEmpty {
                        Text("\(galleryState.selectedPaths.count) Gemini")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.blue)
                    }
                    if !galleryState.loraSelectedPaths.isEmpty {
                        Text("\(galleryState.loraSelectedPaths.count) LORA")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                    }
                    if !galleryState.hiddenPaths.isEmpty {
                        Text("\(galleryState.hiddenPaths.count) hidden")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("← →: navigate | G: Gemini pick | F: unpick | L: LORA pick | K: unpick | X: hide | Space: Quick Look")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // Gallery header with collapse toggle
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        galleryCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: galleryCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("Gallery")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(galleryCountLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if galleryCollapsed {
                    Text("— hidden")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if !preloadedPaths.isEmpty {
                    galleryFilterControls
                    galleryZoomControls
                }
            }
            .padding(.vertical, 2)

            // Gallery grid (collapsible)
            if !galleryCollapsed {
                if character.inspirationImagePaths.isEmpty {
                    emptyGalleryPlaceholder
                } else if displayedPaths.isEmpty {
                    filteredGalleryPlaceholder
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: galleryThumbnailBaseSize, maximum: galleryThumbnailBaseSize), spacing: 6)], spacing: 6) {
                        ForEach(Array(displayedPaths.enumerated()), id: \.element) { index, path in
                            cachedThumbnail(path: path, index: index, character: character)
                        }
                    }
                }
            }

            if previewCollapsed && galleryCollapsed && character.inspirationBatchJobs.isEmpty && runpodService.currentJob == nil && runpodService.queuedJobs.isEmpty && runpodService.recentJobs.isEmpty {
                Text("Preview and Gallery are both collapsed. Expand one section to continue.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .onAppear {
            loadGalleryState(for: character)
            refreshPreloadedPaths(character: character)
            // Refresh batch jobs immediately on appear
            store.refreshInspirationBatchJobs()
            galleryKeyboardFocused = true
        }
        .task(id: character.id) {
            // Poll batch jobs every 20 seconds while any are active
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                if Task.isCancelled { break }
                guard store.selectedCharacterID == character.id,
                      let liveCharacter = store.selectedCharacter else { continue }
                let hasActive = liveCharacter.inspirationBatchJobs.contains { !$0.isTerminal }
                if hasActive {
                    store.refreshInspirationBatchJobs()
                }
            }
        }
        .onChange(of: store.selectedCharacterID) { oldID, _ in
            if let oldID,
               let oldChar = store.characters.first(where: { $0.id == oldID }) {
                pendingGallerySaveTask?.cancel()
                saveGalleryState(for: oldChar)
            }
            if let newChar = store.selectedCharacter {
                loadGalleryState(for: newChar)
                refreshPreloadedPaths(character: newChar)
                galleryKeyboardFocused = true
            }
        }
        .onChange(of: character.inspirationImagePaths.count) { _, _ in
            loadGalleryState(for: character)
            refreshPreloadedPaths(character: character)
            ImagineThumbnailCache.shared.prefetch(
                paths: preloadedPaths.compactMap(resolvedGalleryAssetPath(for:)),
                maxPixelSize: Int(galleryThumbnailBaseSize * 2)
            )
        }
        .onChange(of: thumbnailBaseSize) { _, _ in
            ImagineThumbnailCache.shared.prefetch(
                paths: preloadedPaths.compactMap(resolvedGalleryAssetPath(for:)),
                maxPixelSize: Int(galleryThumbnailBaseSize * 2)
            )
        }
        .onChange(of: galleryFilterRawValue) { _, _ in
            syncFocusedIndex()
        }
        .focusable()
        .focused($galleryKeyboardFocused)
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) {
            hasShownFocusHighlight = true
            moveFocus(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            hasShownFocusHighlight = true
            moveFocus(1)
            return .handled
        }
        .onKeyPress(.space) {
            if let path = focusedPath,
               let url = store.resolvedCharacterAssetURL(for: path) {
                hasShownFocusHighlight = true
                ImagineQuickLook.preview(url: url)
                return .handled
            }
            return .ignored
        }
        // Gemini reference shortcuts
        .onKeyPress(.init("g")) {
            if let path = focusedPath {
                let selectionKey = gallerySelectionKey(for: path)
                galleryState.selectedPaths.insert(selectionKey)
                syncFocusedIndex(preferredPath: path)
                scheduleGalleryStateSave(for: character)
                hasShownFocusHighlight = true
            }
            return .handled
        }
        .onKeyPress(.init("f")) {
            if let path = focusedPath {
                let selectionKey = gallerySelectionKey(for: path)
                galleryState.selectedPaths.remove(selectionKey)
                syncFocusedIndex(preferredPath: path)
                scheduleGalleryStateSave(for: character)
                hasShownFocusHighlight = true
            }
            return .handled
        }
        // LORA training shortcuts
        .onKeyPress(.init("l")) {
            if let path = focusedPath {
                let selectionKey = gallerySelectionKey(for: path)
                galleryState.loraSelectedPaths.insert(selectionKey)
                syncFocusedIndex(preferredPath: path)
                flushGalleryStateSaveImmediately(for: character)
                hasShownFocusHighlight = true
            }
            return .handled
        }
        .onKeyPress(.init("k")) {
            if let path = focusedPath {
                let selectionKey = gallerySelectionKey(for: path)
                galleryState.loraSelectedPaths.remove(selectionKey)
                syncFocusedIndex(preferredPath: path)
                flushGalleryStateSaveImmediately(for: character)
                hasShownFocusHighlight = true
            }
            return .handled
        }
        .onKeyPress(.init("x")) {
            if let path = focusedPath {
                let selectionKey = gallerySelectionKey(for: path)
                if galleryState.hiddenPaths.contains(selectionKey) {
                    galleryState.hiddenPaths.remove(selectionKey)
                } else {
                    galleryState.hiddenPaths.insert(selectionKey)
                }
                syncFocusedIndex(preferredPath: path)
                scheduleGalleryStateSave(for: character)
                hasShownFocusHighlight = true
            }
            return .handled
        }
        .onDisappear {
            pendingGallerySaveTask?.cancel()
        }
    }

    private var galleryCountLabel: String {
        if displayedPaths.count == preloadedPaths.count {
            return "(\(displayedPaths.count))"
        }
        return "(\(displayedPaths.count)/\(preloadedPaths.count))"
    }

    private var galleryFilterControls: some View {
        Picker("Filter", selection: Binding(
            get: { galleryFilter },
            set: { galleryFilter = $0 }
        )) {
            ForEach(GalleryFilter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 92)
        .help("Filter gallery to all images, Gemini picks, LoRA picks, or hidden images")
    }

    private var galleryZoomControls: some View {
        HStack(spacing: 4) {
            Button {
                thumbnailBaseSize = max(80, thumbnailBaseSize - 20)
            } label: {
                Image(systemName: "minus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(thumbnailBaseSize <= 80)

            Slider(value: $thumbnailBaseSize, in: 80...220, step: 20)
                .frame(width: 70)

            Button {
                thumbnailBaseSize = min(220, thumbnailBaseSize + 20)
            } label: {
                Image(systemName: "plus.magnifyingglass")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .disabled(thumbnailBaseSize >= 220)
        }
        .help("Adjust inspiration gallery thumbnail size")
    }

    private func isPathVisibleInGallery(_ path: String) -> Bool {
        let selectionKey = gallerySelectionKey(for: path)
        switch galleryFilter {
        case .all:
            return true
        case .gemini:
            return galleryState.selectedPaths.contains(selectionKey)
        case .lora:
            return galleryState.loraSelectedPaths.contains(selectionKey)
        case .hidden:
            return galleryState.hiddenPaths.contains(selectionKey)
        }
    }

    private func syncFocusedIndex(preferredPath: String? = nil) {
        let paths = displayedPaths
        guard !paths.isEmpty else {
            focusedIndex = 0
            return
        }

        if let preferredPath, let preferredIndex = paths.firstIndex(of: preferredPath) {
            focusedIndex = preferredIndex
            return
        }

        if let current = focusedPath, let currentIndex = paths.firstIndex(of: current) {
            focusedIndex = currentIndex
            return
        }

        focusedIndex = min(max(focusedIndex, 0), paths.count - 1)
    }

    private var previewResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 10)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 60, height: 4)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let start = dragStartHeight ?? previewHeight
                        if dragStartHeight == nil { dragStartHeight = start }
                        let newHeight = start + value.translation.height
                        previewHeight = min(max(newHeight, 120), 1200)
                    }
                    .onEnded { _ in
                        dragStartHeight = nil
                    }
            )
    }

    @ViewBuilder
    private func generationStatusSection(character: AnimationCharacter) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        generationStatusCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: generationStatusCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text("Image Generation Status")
                    .font(.subheadline.weight(.semibold))

                Text("(\(generationStatusItemCount(for: character)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                if generationStatusCollapsed {
                    Text("hidden")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
                Button {
                    store.refreshInspirationBatchJobs()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.mini)
            }

            if !generationStatusCollapsed {
                // Instant Gemini generation row (if actively generating for this character)
                if isGeneratingInspiration, generatingInspirationCharacterID == character.id {
                    instantGenerationRow(character: character)
                }

                // LORA training row (if any active or recently completed)
                if let loraJob = runpodService.currentJob {
                    loraJobRow(job: loraJob) {
                        runpodService.clearCurrentJob()
                    }
                }

                ForEach(runpodService.queuedJobs) { queuedJob in
                    queuedLoraJobRow(job: queuedJob)
                }

                ForEach(runpodService.recentJobs) { recentJob in
                    loraJobRow(job: recentJob) {
                        runpodService.clearRecentJob(recentJob.id)
                    }
                }

                // Gemini batch jobs (newest first)
                ForEach(character.inspirationBatchJobs.sorted(by: { $0.submittedAt > $1.submittedAt })) { job in
                    batchJobRow(job: job, character: character)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func generationStatusItemCount(for character: AnimationCharacter) -> Int {
        var count = character.inspirationBatchJobs.count
        count += runpodService.queuedJobs.count
        count += runpodService.recentJobs.count
        if runpodService.currentJob != nil {
            count += 1
        }
        if isGeneratingInspiration, generatingInspirationCharacterID == character.id {
            count += 1
        }
        return count
    }

    @ViewBuilder
    private func instantGenerationRow(character: AnimationCharacter) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.blue)
                .frame(width: 10, height: 10)
                .overlay(
                    Circle()
                        .stroke(Color.blue.opacity(0.4), lineWidth: 2)
                        .scaleEffect(1.8)
                        .opacity(0.6)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: "sparkles")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("Gemini Instant — \(character.name)")
                        .font(.caption.weight(.semibold))
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text("generating")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }

                if let status = inspirationGenerationStatus, !status.isEmpty {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: inspirationGenerationProgress)
                    .controlSize(.mini)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func loraJobRow(
        job: LORATrainingModels.TrainingJob,
        clearAction: @escaping () -> Void
    ) -> some View {
        let stateColor: Color = {
            switch job.status {
            case .inactive: return .green
            case .error: return .red
            case .stopping: return .orange
            default: return .purple
            }
        }()

        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
                .overlay(
                    job.status.isActive
                        ? Circle().stroke(stateColor.opacity(0.4), lineWidth: 2).scaleEffect(1.8).opacity(0.6)
                        : nil
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: "cpu")
                        .font(.caption)
                        .foregroundStyle(stateColor)
                    Text("LORA Training — \(job.characterName)")
                        .font(.caption.weight(.semibold))
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(job.status.displayName)
                        .font(.caption)
                        .foregroundStyle(stateColor)
                }

                if job.totalSteps > 0 {
                    HStack(spacing: 8) {
                        Text("Step \(job.currentStep)/\(job.totalSteps)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text("Trigger: \(job.triggerWord)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            HStack(spacing: 8) {
                                Text("•")
                                    .foregroundStyle(.tertiary)
                                Text(job.elapsedDisplay)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                Text("•")
                                    .foregroundStyle(.tertiary)
                                Text(String(format: "$%.2f", job.estimatedCostUSD))
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    if job.status.isActive {
                        ProgressView(value: job.progress)
                            .controlSize(.mini)
                    }
                }

                if let error = job.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                if let loraPath = job.outputLORAPath {
                    Text(URL(fileURLWithPath: loraPath).lastPathComponent)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.green)
                }

                // Open the on-disk RunPod/LORA log file so Gary can see the
                // full command trace (ssh/scp stdout+stderr, lifecycle events)
                // without having to dig through Console.app or the RunPod
                // web dashboard.
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: runpodService.logFilePath))
                } label: {
                    Label("Open Log", systemImage: "doc.text.magnifyingglass")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .help(runpodService.logFilePath)
            }

            Spacer()

            if job.status.isActive {
                Button(role: .destructive) {
                    runpodService.terminateAllPods()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Cancel training & terminate pod")
            } else {
                // Clear completed/failed LORA job
                Button(action: clearAction) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear from list")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func queuedLoraJobRow(job: LORATrainingModels.QueuedTrainingJob) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.orange)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text("Queued LORA — \(job.characterName)")
                        .font(.caption.weight(.semibold))
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text("Waiting")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack(spacing: 8) {
                    Text(job.summaryLabel)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text("Queued \(job.queuedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button {
                runpodService.removeQueuedJob(job.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from queue")
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func batchJobRow(job: CharacterInspirationBatchJob, character: AnimationCharacter) -> some View {
        let stateColor: Color = {
            switch job.state {
            case "JOB_STATE_SUCCEEDED": return .green
            case "JOB_STATE_FAILED", "JOB_STATE_CANCELLED", "JOB_STATE_EXPIRED": return .red
            case "JOB_STATE_RUNNING", "JOB_STATE_PENDING": return .blue
            default: return .orange
            }
        }()
        let prettyState: String = {
            switch job.state {
            case "JOB_STATE_SUCCEEDED": return "Succeeded"
            case "JOB_STATE_FAILED": return "Failed"
            case "JOB_STATE_CANCELLED": return "Cancelled"
            case "JOB_STATE_EXPIRED": return "Expired"
            case "JOB_STATE_RUNNING": return "Running"
            case "JOB_STATE_PENDING": return "Pending"
            case "JOB_STATE_QUEUED": return "Queued"
            default: return job.state.replacingOccurrences(of: "JOB_STATE_", with: "").capitalized
            }
        }()
        let generatedCount = min(job.remoteSuccessfulCount ?? job.downloadedImagePaths.count, job.promptCount)
        let hasProviderCompletionCount = job.remoteSuccessfulCount != nil
        let hasDeterminateProgress = hasProviderCompletionCount || !job.downloadedImagePaths.isEmpty || job.isTerminal

        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
                .overlay(
                    job.isTerminal
                        ? nil
                        : Circle().stroke(stateColor.opacity(0.4), lineWidth: 2).scaleEffect(1.8).opacity(0.6)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(job.title)
                        .font(.caption.weight(.semibold))
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text(prettyState)
                        .font(.caption)
                        .foregroundStyle(stateColor)
                }

                HStack(spacing: 8) {
                    Text(
                        hasProviderCompletionCount
                            ? "\(generatedCount)/\(job.promptCount) completed"
                            : "\(job.downloadedImagePaths.count)/\(job.promptCount) downloaded"
                    )
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text("•")
                        .foregroundStyle(.tertiary)
                    Text("Submitted \(job.submittedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let lastChecked = job.lastCheckedAt {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text("Checked \(lastChecked.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if let remoteUpdatedAt = job.remoteUpdatedAt {
                        Text("•")
                            .foregroundStyle(.tertiary)
                        Text("Provider updated \(remoteUpdatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !job.isTerminal {
                    if hasDeterminateProgress {
                        ProgressView(
                            value: Double(generatedCount),
                            total: Double(max(job.promptCount, 1))
                        )
                        .controlSize(.mini)
                    } else {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                if !job.isTerminal && !hasDeterminateProgress {
                    Text("Gemini is still reporting this batch as \(prettyState.lowercased()). Partial item counts are not available yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let error = job.lastErrorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                Text(job.batchName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if job.isTerminal {
                Button {
                    store.dismissInspirationBatchJob(job, for: character.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
        }
        .padding(.vertical, 4)
    }

    private var filteredGalleryPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.03))
            .frame(minHeight: 120)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No images match the \(galleryFilter.title) filter.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
    }

    private var emptyGalleryPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.secondary.opacity(0.03))
            .frame(minHeight: 120)
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "photo.stack")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No inspiration images yet. Use Generate or Import.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
    }

    /// Returns a human-readable reason why the Generate button is disabled, or nil if it should be enabled.
    private var generateButtonDisabledReason: String? {
        if store.geminiAPIKey.isEmpty {
            return "No Gemini API key"
        }
        if !store.geminiMasterSwitch {
            return "Gemini blocked (Tools tab)"
        }
        if isGeneratingInspiration {
            return "Generating…"
        }
        if isSubmittingInspirationBatch {
            return "Submitting batch…"
        }
        return nil
    }

    private var focusedPath: String? {
        guard focusedIndex >= 0, focusedIndex < displayedPaths.count else { return nil }
        return displayedPaths[focusedIndex]
    }

    private func moveFocus(_ delta: Int) {
        let newIndex = focusedIndex + delta
        if newIndex >= 0 && newIndex < displayedPaths.count {
            focusedIndex = newIndex
        }
    }

    private func loadGalleryState(for character: AnimationCharacter) {
        guard let animateURL = store.animateURL else { return }
        galleryState = ImagineGallerySelectionState.load(
            animateURL: animateURL,
            characterSlug: character.assetFolderSlug
        )
        focusedIndex = 0
        hasShownFocusHighlight = false
    }

    private func saveGalleryState(_ state: ImagineGallerySelectionState, for character: AnimationCharacter) {
        guard let animateURL = store.animateURL else {
            NSLog("[ImagineCharactersPageView] Cannot save gallery state: animateURL missing")
            return
        }

        let normalizedState = state.normalized(animateURL: animateURL)
        normalizedState.save(animateURL: animateURL, characterSlug: character.assetFolderSlug)
        if store.selectedCharacterID == character.id {
            galleryState = normalizedState
        }
    }

    private func gallerySelectionKey(for path: String) -> String {
        guard let animateURL = store.animateURL,
              let normalized = ImagineGallerySelectionState.normalizedPath(path, animateURL: animateURL) else {
            return path
        }
        return normalized
    }

    private func saveGalleryState(for character: AnimationCharacter) {
        saveGalleryState(galleryState, for: character)
    }

    private func scheduleGalleryStateSave(for character: AnimationCharacter) {
        pendingGallerySaveTask?.cancel()
        let snapshot = galleryState
        pendingGallerySaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: gallerySaveDebounceNanoseconds)
            guard !Task.isCancelled else { return }
            saveGalleryState(snapshot, for: character)
        }
    }

    /// Cancel any pending debounced save and persist the current gallery state
    /// immediately. Call this before any code path that reads the saved state
    /// from disk (e.g. opening the LORA training sheet), or for infrequent
    /// deliberate actions like LORA picks that don't benefit from debouncing.
    private func flushGalleryStateSaveImmediately(for character: AnimationCharacter) {
        pendingGallerySaveTask?.cancel()
        pendingGallerySaveTask = nil
        saveGalleryState(galleryState, for: character)
    }

    private func refreshPreloadedPaths(character: AnimationCharacter) {
        guard store.selectedCharacterID == character.id else { return }
        // Resolve once, outside the ForEach. Start with the store's preferred
        // ordering (newest inspiration batch first), restrict to paths the
        // character actually owns, then re-sort by file modification time
        // descending so a freshly generated image surfaces at the top even if
        // the batch bookkeeping hasn't fully propagated yet.
        let preferredPaths = store.preferredInspirationReferencePaths(for: character)
        let owned = Set(character.inspirationImagePaths)
        let filtered = preferredPaths.filter { owned.contains($0) }
        preloadedPaths = sortPathsByModificationTimeDescending(filtered)
        ImagineThumbnailCache.shared.prefetch(
            paths: preloadedPaths.compactMap(resolvedGalleryAssetPath(for:)),
            maxPixelSize: Int(galleryThumbnailBaseSize * 2)
        )
        if focusedIndex >= preloadedPaths.count {
            focusedIndex = max(0, preloadedPaths.count - 1)
        }
    }

    /// Sort paths by file mtime (newest first). Paths without a resolvable
    /// file fall to the end in their original relative order.
    private func sortPathsByModificationTimeDescending(_ paths: [String]) -> [String] {
        let fm = FileManager.default
        let decorated: [(index: Int, path: String, mtime: Date?)] = paths.enumerated().map { (idx, path) in
            let resolved = resolvedGalleryAssetPath(for: path)
            let date: Date? = resolved.flatMap { p in
                (try? fm.attributesOfItem(atPath: p)[.modificationDate]) as? Date
            }
            return (idx, path, date)
        }
        return decorated.sorted { lhs, rhs in
            switch (lhs.mtime, rhs.mtime) {
            case let (l?, r?):
                if l != r { return l > r }
                return lhs.index < rhs.index
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.index < rhs.index
            }
        }.map(\.path)
    }

    private func resolvedGalleryAssetPath(for path: String) -> String? {
        if let resolvedPath = store.resolvedCharacterAssetURL(for: path)?.path {
            return resolvedPath
        }
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            return path
        }
        return nil
    }

    @ViewBuilder
    private func cachedThumbnail(path: String, index: Int, character: AnimationCharacter) -> some View {
        let selectionKey = gallerySelectionKey(for: path)
        let resolvedPath = resolvedGalleryAssetPath(for: path)
        let isGeminiPicked = galleryState.selectedPaths.contains(selectionKey)
        let isLoraPicked = galleryState.loraSelectedPaths.contains(selectionKey)
        let isHidden = galleryState.hiddenPaths.contains(selectionKey)
        let isFocused = index == focusedIndex
        let shouldShowFocusBorder = isFocused && hasShownFocusHighlight

        CachedThumbnailView(path: resolvedPath ?? path, size: galleryThumbnailBaseSize)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .opacity(isHidden ? 0.3 : 1.0)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        shouldShowFocusBorder ? Color.yellow : Color.clear,
                        lineWidth: shouldShowFocusBorder ? 3 : 0
                    )
            )
            // Gemini checkbox — TOP LEFT (blue)
            .overlay(alignment: .topLeading) {
                ZStack {
                    Image(systemName: isGeminiPicked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isGeminiPicked ? Color.blue : Color.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    Text("G")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isGeminiPicked ? .white : Color.blue)
                }
                .padding(5)
                .contentShape(Rectangle())
                .onTapGesture {
                    galleryKeyboardFocused = true
                    hasShownFocusHighlight = true
                    if isGeminiPicked {
                        galleryState.selectedPaths.remove(selectionKey)
                    } else {
                        galleryState.selectedPaths.insert(selectionKey)
                    }
                    syncFocusedIndex(preferredPath: path)
                    scheduleGalleryStateSave(for: character)
                }
                .help("Gemini reference (G=pick, F=unpick)")
            }
            // LORA checkbox — TOP RIGHT (purple)
            .overlay(alignment: .topTrailing) {
                ZStack {
                    Image(systemName: isLoraPicked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18))
                        .foregroundStyle(isLoraPicked ? Color.purple : Color.white.opacity(0.85))
                        .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
                    Text("L")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(isLoraPicked ? .white : Color.purple)
                }
                .padding(5)
                .contentShape(Rectangle())
                .onTapGesture {
                    galleryKeyboardFocused = true
                    hasShownFocusHighlight = true
                    if isLoraPicked {
                        galleryState.loraSelectedPaths.remove(selectionKey)
                    } else {
                        galleryState.loraSelectedPaths.insert(selectionKey)
                    }
                    syncFocusedIndex(preferredPath: path)
                    flushGalleryStateSaveImmediately(for: character)
                }
                .help("LORA training (L=pick, K=unpick)")
            }
            // Hidden indicator (bottom-center)
            .overlay(alignment: .bottom) {
                if isHidden {
                    Image(systemName: "eye.slash.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        .padding(4)
                }
            }
        .contentShape(Rectangle())
        // Single-tap = instant selection. We intentionally do NOT use a
        // double-tap + .exclusively(before:) combo here because SwiftUI has to
        // wait the full macOS double-click interval (~250-500ms) before firing
        // the single-tap, which the user experienced as a "click lag".
        // Quick Look is still available via Space (keyboard) and context menu.
        .onTapGesture {
            galleryKeyboardFocused = true
            hasShownFocusHighlight = true
            focusedIndex = index
        }
        .contextMenu {
            Button("Quick Look") {
                if let resolvedPath {
                    ImagineQuickLook.preview(url: URL(fileURLWithPath: resolvedPath))
                }
            }
            Button("Show in Finder") {
                if let resolvedPath {
                    ImagineProjectStorage.revealInFinder(resolvedPath)
                }
            }
            Button("Copy Image") {
                if let resolvedPath, let image = NSImage(contentsOfFile: resolvedPath) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([image])
                }
            }
            if let charID = store.selectedCharacter?.id {
                Divider()
                Button("Set as Profile Pic") {
                    store.prepareProfilePicCrop(from: path, for: charID)
                }
                Divider()
                Button("Move to Trash", role: .destructive) {
                    store.deleteInspirationImageToTrash(path: path, for: charID)
                    if let refreshed = store.characters.first(where: { $0.id == charID }) {
                        refreshPreloadedPaths(character: refreshed)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func loraSelectionSection(_ character: AnimationCharacter) -> some View {
        let availableLoRAs = availableLoRAURLs(for: character)
        let activeLoRAURL = activeLoRAProjectURL(for: character)
        let promptNames = characterPromptNameTokens(for: character).joined(separator: " or ")
        let hasActiveLoRA = character.activeLORAFilename != nil

        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if availableLoRAs.isEmpty {
                    Text("No trained LORAs yet. Completed RunPod jobs will land in Characters/\(character.assetFolderSlug)/lora and become selectable here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 10) {
                    if !availableLoRAs.isEmpty {
                        Picker("Active LoRA", selection: activeLoRASelectionBinding(for: character)) {
                            Text("None").tag("__none__")
                            ForEach(availableLoRAs, id: \.path) { url in
                                Text(url.lastPathComponent).tag(url.lastPathComponent)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: 320, alignment: .leading)
                    }

                    Button("Import…") {
                        importLoRA(for: character)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let activeLoRAURL {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([activeLoRAURL])
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Button("Open Folder") {
                            revealLoRAFolder(for: character)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()
                }

                if hasActiveLoRA {
                    LabeledContent("Trigger Word") {
                        TextField(
                            "trigger",
                            text: activeLORATriggerBinding(for: character)
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    }

                    LabeledContent("Weight") {
                        Stepper(
                            value: activeLORAWeightBinding(for: character),
                            in: 0.05...2.0,
                            step: 0.05
                        ) {
                            Text(String(format: "%.2f", max(0.05, character.activeLORAWeight)))
                                .font(.caption.monospacedDigit())
                                .frame(minWidth: 44, alignment: .leading)
                        }
                        .frame(maxWidth: 180, alignment: .leading)
                    }

                    Text("When a Draw Things prompt mentions \(promptNames), Amira Writer auto-syncs this LoRA into Draw Things and attaches it to the txt2img request.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose or import a LoRA to have Imagine auto-apply it when prompts mention \(promptNames).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } label: {
            Label("Character LoRA", systemImage: "person.crop.rectangle.stack")
                .font(.subheadline.weight(.semibold))
        }
    }


    private var inspirationGenerationAlertBinding: Binding<Bool> {
        Binding(
            get: { inspirationGenerationErrorMessage != nil },
            set: { if !$0 { inspirationGenerationErrorMessage = nil } }
        )
    }

    // MARK: - Generation Menu

    @ViewBuilder
    private func inspirationGenerationMenuItems(
        for character: AnimationCharacter,
        wardrobe: CharacterInspirationWardrobe
    ) -> some View {
        Section("Photoreal LoRA Candidates") {
            Button("Generate 1 Test Candidate") {
                preparePhotorealLORACandidatePlan(for: character, count: 1, mode: .immediate)
            }
            Button("Generate 50 Candidates Now") {
                preparePhotorealLORACandidatePlan(
                    for: character,
                    count: PhotorealLORACandidateCatalog.allSpecs.count,
                    mode: .immediate
                )
            }
            Button("Submit 50-Candidate Batch + Watchdog") {
                preparePhotorealLORACandidatePlan(
                    for: character,
                    count: PhotorealLORACandidateCatalog.allSpecs.count,
                    mode: .batch
                )
            }
        }

        Section(wardrobe.displayName) {
            Button("Generate 1 Test Image") {
                prepareInspirationGenerationPlan(for: character, count: 1, wardrobe: wardrobe, mode: .immediate)
            }
            Button("Generate 27-Image Set Now") {
                prepareInspirationGenerationPlan(
                    for: character,
                    count: CharacterInspirationPromptCatalog.allSpecs.count,
                    wardrobe: wardrobe,
                    mode: .immediate
                )
            }
            Button("Submit 27-Image Batch + Watchdog") {
                prepareInspirationGenerationPlan(
                    for: character,
                    count: CharacterInspirationPromptCatalog.allSpecs.count,
                    wardrobe: wardrobe,
                    mode: .batch
                )
            }
        }
    }

    private func prepareInspirationWithSelectedReferences(
        character: AnimationCharacter,
        mode: CharacterInspirationGenerationMode
    ) {
        inspirationPendingBatchTitleOverride = nil
        inspirationPendingBatchFolderSlugOverride = nil
        inspirationPendingBatchKind = .inspiration
        inspirationAutoSelectForLoRA = false
        // Use the selected images as reference images for a 27-image set.
        let specs = CharacterInspirationPromptCatalog.allSpecs
        let selectedRefs = galleryState.selectedPaths.compactMap { path -> GeminiGenerationReferenceDraft? in
            let url = store.resolvedCharacterAssetURL(for: path) ?? URL(fileURLWithPath: path)
            return GeminiGenerationReferenceDraft(
                label: url.deletingPathExtension().lastPathComponent,
                path: url.path,
                isIncluded: true
            )
        }

        inspirationDrafts = specs.map { spec in
            GeminiGenerationDraft(
                title: spec.title,
                destinationDescription: "\(character.defaultWardrobeType.displayName) inspiration image",
                prompt: CharacterInspirationPromptCatalog.prompt(
                    for: spec,
                    character: character,
                    wardrobe: character.defaultWardrobeType
                ),
                model: store.selectedGeminiModel,
                aspectRatio: CharacterInspirationPromptCatalog.defaultAspectRatio,
                imageSize: CharacterInspirationPromptCatalog.defaultImageSize,
                referenceItems: selectedRefs,
                pricingMode: mode == .batch ? .batch : .standard
            )
        }

        inspirationActiveWardrobe = character.defaultWardrobeType
        let modeLabel = mode == .batch ? "Batch + Watchdog" : "27-Image Set"
        let confirmTitle = mode == .batch
            ? "Submit \(specs.count)-Image Batch"
            : "Generate \(specs.count) Images"

        inspirationPendingPlan = PendingInspirationGenerationPlan(
            title: "\(character.name) • \(modeLabel) (\(selectedRefs.count) refs)",
            confirmTitle: confirmTitle,
            mode: mode,
            wardrobe: character.defaultWardrobeType
        )
    }

    private func prepareInspirationGenerationPlan(
        for character: AnimationCharacter,
        count: Int,
        wardrobe: CharacterInspirationWardrobe,
        mode: CharacterInspirationGenerationMode
    ) {
        inspirationPendingBatchTitleOverride = nil
        inspirationPendingBatchFolderSlugOverride = nil
        inspirationPendingBatchKind = .inspiration
        inspirationAutoSelectForLoRA = false
        let specs = Array(CharacterInspirationPromptCatalog.allSpecs.prefix(count))
        inspirationDrafts = specs.map { spec in
            GeminiGenerationDraft(
                title: spec.title,
                destinationDescription: "\(wardrobe.displayName) inspiration image",
                prompt: CharacterInspirationPromptCatalog.prompt(
                    for: spec,
                    character: character,
                    wardrobe: wardrobe
                ),
                model: store.selectedGeminiModel,
                aspectRatio: CharacterInspirationPromptCatalog.defaultAspectRatio,
                imageSize: CharacterInspirationPromptCatalog.defaultImageSize,
                referenceItems: inspirationReferenceDrafts(for: character),
                pricingMode: mode == .batch ? .batch : .standard
            )
        }

        inspirationActiveWardrobe = wardrobe
        inspirationPendingPlan = PendingInspirationGenerationPlan(
            title: "\(character.name) • \(wardrobe.displayName) Inspiration",
            confirmTitle: mode == .batch
                ? "Submit \(count)-Image Batch"
                : (count == 1 ? "Generate 1 Image" : "Generate \(count) Images"),
            mode: mode,
            wardrobe: wardrobe
        )
    }

    private func preparePhotorealLORACandidatePlan(
        for character: AnimationCharacter,
        count: Int,
        mode: CharacterInspirationGenerationMode
    ) {
        let referenceDrafts = photorealLORACandidateReferenceDrafts(for: character)
        guard !referenceDrafts.isEmpty else {
            inspirationGenerationErrorMessage = "Choose or curate at least one real lifestyle reference image before generating photoreal LoRA candidates."
            return
        }

        let specs = Array(PhotorealLORACandidateCatalog.allSpecs.prefix(count))
        inspirationDrafts = specs.map { spec in
            GeminiGenerationDraft(
                title: spec.title,
                destinationDescription: "Photoreal LoRA candidate image",
                prompt: PhotorealLORACandidateCatalog.prompt(for: spec, character: character),
                recommendedLORACaption: PhotorealLORACandidateCatalog.recommendedLORACaption(for: spec),
                contextNote: "Photoreal LoRA candidate",
                model: store.selectedGeminiModel,
                aspectRatio: PhotorealLORACandidateCatalog.defaultAspectRatio,
                imageSize: PhotorealLORACandidateCatalog.defaultImageSize,
                referenceItems: referenceDrafts,
                pricingMode: mode == .batch ? .batch : .standard
            )
        }

        inspirationActiveWardrobe = .soldier
        inspirationPendingBatchTitleOverride = PhotorealLORACandidateCatalog.batchTitle
        inspirationPendingBatchFolderSlugOverride = PhotorealLORACandidateCatalog.batchFolderSlug
        inspirationPendingBatchKind = .loraCandidate
        inspirationAutoSelectForLoRA = true

        let usingSelectedRefs = !galleryState.selectedPaths.isEmpty
        inspirationPendingPlan = PendingInspirationGenerationPlan(
            title: "\(character.name) • Photoreal LoRA Candidates\(usingSelectedRefs ? " (selected refs)" : "")",
            confirmTitle: mode == .batch
                ? "Submit \(count)-Candidate Batch"
                : (count == 1 ? "Generate 1 Candidate" : "Generate \(count) Candidates"),
            mode: mode,
            wardrobe: .soldier
        )
    }

    // MARK: - Generation Execution

    private func runInspirationGeneration(
        _ drafts: [GeminiGenerationDraft],
        autoSelectForLoRA: Bool = false
    ) {
        guard let character = store.selectedCharacter else { return }
        guard store.isGeminiAllowed() else {
            inspirationGenerationErrorMessage = "Gemini API calls are blocked. Enable Gemini API Calls in Inspector > Tools."
            return
        }

        isGeneratingInspiration = true
        generatingInspirationCharacterID = character.id
        inspirationStatusCharacterID = character.id
        inspirationGenerationStatus = nil
        inspirationGenerationProgress = 0
        inspirationGenerationErrorMessage = nil

        Task { @MainActor in
            let service = GeminiImageService()

            do {
                let total = Double(max(drafts.count, 1))

                for (index, draft) in drafts.enumerated() {
                    inspirationGenerationStatus = "Generating \(index + 1) of \(drafts.count)…"
                    inspirationGenerationProgress = Double(index) / total

                    let request = GeminiImageService.GenerationRequest(
                        prompt: draft.effectivePrompt,
                        referenceImages: buildReferenceImages(from: draft.referenceItems),
                        model: draft.model,
                        aspectRatio: draft.aspectRatio,
                        imageSize: draft.imageSize
                    )

                    store.logGeminiAPICall(endpoint: "image-generation", source: "ImagineCharactersPageView.runInspirationGeneration()")
                    let result = try await service.generate(request: request, apiKey: store.geminiAPIKey)

                    let storedPath = try store.storeGeneratedInspirationImage(
                        result.imageData,
                        prompt: draft.prompt,
                        model: draft.model,
                        filenameStem: sanitizedFilenameStem(for: draft.title),
                        for: character.id,
                        aspectRatio: draft.aspectRatio,
                        imageSize: draft.imageSize,
                        recommendedLORACaption: draft.recommendedLORACaption,
                        autoSelectForLoRA: autoSelectForLoRA
                    )
                    if autoSelectForLoRA, !storedPath.isEmpty {
                        galleryState.loraSelectedPaths.insert(storedPath)
                    }
                    refreshPreloadedPaths(character: character)
                }

                inspirationGenerationProgress = 1
                inspirationGenerationStatus = "Finished \(drafts.count) inspiration image\(drafts.count == 1 ? "" : "s")."
            } catch {
                inspirationGenerationErrorMessage = error.localizedDescription
            }

            isGeneratingInspiration = false
            generatingInspirationCharacterID = nil
        }
    }

    private func submitInspirationBatch(
        _ drafts: [GeminiGenerationDraft],
        wardrobe: CharacterInspirationWardrobe,
        batchTitleOverride: String? = nil,
        batchFolderSlugOverride: String? = nil,
        kind: CharacterInspirationBatchJob.Kind = .inspiration
    ) {
        guard let character = store.selectedCharacter,
              let animateURL = store.animateURL else { return }
        guard store.isGeminiAllowed() else {
            inspirationGenerationErrorMessage = "Gemini API calls are blocked. Enable Gemini API Calls in Inspector > Tools."
            return
        }

        let batchTitle = batchTitleOverride ?? "\(wardrobe.displayName) Inspiration Batch"
        if character.inspirationBatchJobs.contains(where: { !$0.isTerminal && $0.title == batchTitle }) {
            inspirationStatusCharacterID = character.id
            inspirationGenerationErrorMessage = "A batch named “\(batchTitle)” is already active. Wait for it to finish."
            return
        }

        isSubmittingInspirationBatch = true
        submittingInspirationBatchCharacterID = character.id
        inspirationStatusCharacterID = character.id
        inspirationGenerationErrorMessage = nil

        Task { @MainActor in
            defer {
                isSubmittingInspirationBatch = false
                submittingInspirationBatchCharacterID = nil
            }

            do {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
                let stamp = formatter.string(from: Date())

                let outputRoot = animateURL
                    .appendingPathComponent("characters")
                    .appendingPathComponent(character.assetFolderSlug)
                    .appendingPathComponent("inspiration-batches")
                    .appendingPathComponent("\(stamp)-\(batchFolderSlugOverride ?? wardrobe.rawValue)")

                let promptRequests = try drafts.map { draft in
                    GeminiBatchSubmissionPlan.PromptRequest(
                        id: sanitizedFilenameStem(for: draft.title),
                        title: draft.title,
                        prompt: draft.prompt,
                        referencePaths: try resolvedBatchReferencePaths(from: draft.includedReferenceItems),
                        recommendedLORACaption: draft.recommendedLORACaption
                    )
                }

                let submissionPlan = GeminiBatchSubmissionPlan(
                    characterName: character.name,
                    characterSlug: character.assetFolderSlug,
                    displayName: "\(character.name.lowercased().replacingOccurrences(of: " ", with: "-"))-\((batchFolderSlugOverride ?? wardrobe.rawValue))-inspiration-\(stamp.lowercased())",
                    model: drafts.first?.model ?? store.selectedGeminiModel,
                    aspectRatio: drafts.first?.aspectRatio ?? CharacterInspirationPromptCatalog.defaultAspectRatio,
                    imageSize: drafts.first?.imageSize ?? CharacterInspirationPromptCatalog.defaultImageSize,
                    outputRoot: outputRoot,
                    prompts: promptRequests
                )

                let service = GeminiBatchService()
                let submission = try await service.submit(plan: submissionPlan, apiKey: store.geminiAPIKey)
                try service.launchWatchdog(metadataPath: submission.metadataPath, apiKey: store.geminiAPIKey)

                store.registerInspirationBatchJob(
                    CharacterInspirationBatchJob(
                        kind: kind,
                        title: batchTitle,
                        batchName: submission.batchName,
                        metadataPath: submission.metadataPath.path,
                        outputRootPath: submission.outputRoot.path,
                        state: submission.state,
                        promptCount: submission.promptCount,
                        submittedAt: submission.submittedAt
                    ),
                    for: character.id
                )
                store.refreshInspirationBatchJobs()
                inspirationGenerationStatus = "Submitted \(submission.promptCount)-image batch. Watchdog is active."
            } catch {
                inspirationGenerationErrorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Reference Helpers

    private func inspirationReferenceDrafts(for character: AnimationCharacter) -> [GeminiGenerationReferenceDraft] {
        let ordered = store.preferredInspirationReferencePaths(for: character)

        return ordered.map { path in
            GeminiGenerationReferenceDraft(
                label: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                path: path,
                isIncluded: true
            )
        }
    }

    private func photorealLORACandidateReferenceDrafts(for character: AnimationCharacter) -> [GeminiGenerationReferenceDraft] {
        let selectedLifestylePaths = galleryState.selectedPaths
        if !selectedLifestylePaths.isEmpty {
            return selectedLifestylePaths.sorted().map { path in
                GeminiGenerationReferenceDraft(
                    label: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                    path: path,
                    isIncluded: true
                )
            }
        }

        return inspirationReferenceDrafts(for: character)
    }

    /// Hard cap on Gemini reference images. Too many references push the model
    /// into "multi-image fusion / copy" mode instead of identity-locked new
    /// generation. 3 gives the model enough identity signal (front/left/right)
    /// without overwhelming it. Picked based on Gemini 2.5 Flash Image ("nano
    /// banana") best practices for identity preservation.
    private static let maxGeminiReferenceImages = 3

    private func buildReferenceImages(from references: [GeminiGenerationReferenceDraft]) -> [GeminiImageService.ReferenceImage] {
        references
            .filter(\.isIncluded)
            .prefix(Self.maxGeminiReferenceImages)
            .compactMap { reference in
                let url = store.resolvedCharacterAssetURL(for: reference.path) ?? URL(fileURLWithPath: reference.path)
                return GeminiImageService.referenceImage(from: url)
            }
    }

    private func resolvedBatchReferencePaths(
        from references: [GeminiGenerationReferenceDraft]
    ) throws -> [String] {
        let included = Array(references.filter(\.isIncluded).prefix(Self.maxGeminiReferenceImages))
        return try included.map { reference in
            if let resolvedURL = store.resolvedCharacterAssetURL(for: reference.path) {
                return resolvedURL.path
            }
            let candidate = URL(fileURLWithPath: reference.path)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
            throw NSError(domain: "ImagineCharacters", code: 1, userInfo: [NSLocalizedDescriptionKey: "Reference image not found: \(reference.path)"])
        }
    }

    private func sanitizedFilenameStem(for input: String) -> String {
        var result = input
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).inverted)
            .joined(separator: "-")
            .lowercased()
        while result.contains("--") {
            result = result.replacingOccurrences(of: "--", with: "-")
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func availableLoRAURLs(for character: AnimationCharacter) -> [URL] {
        guard let animateURL = store.animateURL else { return [] }
        let loraDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(character.assetFolderSlug)
            .appendingPathComponent("lora")
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: loraDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "safetensors" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func activeLoRAProjectURL(for character: AnimationCharacter) -> URL? {
        guard let filename = character.activeLORAFilename?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filename.isEmpty,
              let animateURL = store.animateURL else {
            return nil
        }
        let url = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(character.assetFolderSlug)
            .appendingPathComponent("lora")
            .appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func characterPromptNameTokens(for character: AnimationCharacter) -> [String] {
        let firstName = character.name
            .split(separator: " ")
            .first
            .map(String.init) ?? character.name
        return Array(NSOrderedSet(array: [firstName, character.name])).compactMap { $0 as? String }
    }

    private func importLoRA(for character: AnimationCharacter) {
        let panel = NSOpenPanel()
        panel.title = "Import Character LoRA"
        panel.message = "Choose a .safetensors LoRA file to store inside this character’s project folder."
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "safetensors") ?? .data]

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                do {
                    let storedURL = try store.importCharacterLoRA(from: url, for: character.id)
                    activateLoRA(
                        filename: storedURL.lastPathComponent,
                        for: character
                    )
                    store.statusMessage = "Imported LoRA: \(storedURL.lastPathComponent)"
                } catch {
                    store.statusMessage = "Failed to import LoRA: \(error.localizedDescription)"
                }
            }
        }
    }

    private func revealLoRAFolder(for character: AnimationCharacter) {
        guard let directory = store.characterLoRADirectoryURL(
            for: character.id,
            createIfNeeded: true
        ) else {
            return
        }
        NSWorkspace.shared.open(directory)
    }

    private func activateLoRA(
        filename: String?,
        for character: AnimationCharacter
    ) {
        let triggerWord = filename.map(Self.defaultTriggerWord(forLoRAFilename:))
        let weight = store.characters.first(where: { $0.id == character.id })?.activeLORAWeight ?? 1.0
        store.setCharacterActiveLORA(
            filename: filename,
            triggerWord: triggerWord,
            weight: weight,
            for: character.id
        )

        guard filename != nil else { return }
        syncSelectedLoRA(for: character.id)
    }

    private func syncSelectedLoRA(for characterID: UUID) {
        guard let syncedCharacter = store.characters.first(where: { $0.id == characterID }),
              let animateURL = store.animateURL else {
            return
        }

        Task { @MainActor in
            do {
                _ = try await DrawThingsLoRAService().syncActiveLoRA(
                    for: syncedCharacter,
                    animateURL: animateURL,
                    config: store.drawThingsPlaceConfig
                )
            } catch {
                store.statusMessage = "LoRA selected but Draw Things sync failed: \(error.localizedDescription)"
            }
        }
    }

    private func activeLoRASelectionBinding(for character: AnimationCharacter) -> Binding<String> {
        Binding(
            get: { character.activeLORAFilename ?? "__none__" },
            set: { newValue in
                let filename = newValue == "__none__" ? nil : newValue
                activateLoRA(filename: filename, for: character)
            }
        )
    }

    private func activeLORATriggerBinding(for character: AnimationCharacter) -> Binding<String> {
        Binding(
            get: {
                character.activeLORATriggerWord
                    ?? character.activeLORAFilename.map(Self.defaultTriggerWord(forLoRAFilename:))
                    ?? ""
            },
            set: { newValue in
                store.updateCharacterActiveLORATriggerWord(newValue, for: character.id)
            }
        )
    }

    private func activeLORAWeightBinding(for character: AnimationCharacter) -> Binding<Double> {
        Binding(
            get: { max(0.05, character.activeLORAWeight) },
            set: { newValue in
                store.updateCharacterActiveLORAWeight(newValue, for: character.id)
            }
        )
    }

    private static func defaultTriggerWord(forLoRAFilename filename: String) -> String {
        URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
    }
}
