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
    // LoRA generation path is archived (2026-04-16). All LoRA UI is gated on
    // this flag, which now defaults to `false` — Gemini is the sole generation
    // path. To bring LoRA back, flip the Global Settings toggle (or this
    // default) and the gated sections render again. No Swift source was
    // deleted; see `loraSelectionSection`, `preparePhotorealLORACandidatePlan`,
    // and the `.lora` gallery filter case which all stay callable.
    @AppStorage("animate.features.loraEnabled") private var loraEnabled: Bool = false
    @AppStorage("imagineChars.galleryThumbnailSize") private var thumbnailBaseSize: Double = 120
    @AppStorage("imagineChars.galleryFilter") private var galleryFilterRawValue: String = GalleryFilter.all.rawValue
    /// Minimum rating filter (0 = show all regardless of rating, 1-5 = show only
    /// images rated N or higher). Mirrors the Places "All Images" gallery.
    @AppStorage("imagineChars.galleryMinimumRating") private var galleryMinimumRating: Int = 0
    @AppStorage("imagineChars.galleryCollapsed") private var galleryCollapsed: Bool = false
    @AppStorage("imagineChars.generationStatusCollapsed") private var generationStatusCollapsed: Bool = false
    @State private var inspirationPendingPlan: PendingInspirationGenerationPlan?
    @State private var inspirationDrafts: [GeminiGenerationDraft] = []
    @State private var inspirationActiveWardrobe: CharacterInspirationWardrobe?
    /// Tracks the character whose catalog-driven drafts are in the preflight
    /// sheet so the pose-title refresh button can cycle to the next spec from
    /// CharacterInspirationPromptCatalog.allSpecs. `nil` for freeform drafts
    /// (Edit-with-Gemini, photoreal with-ref generation) where the refresh
    /// button is intentionally hidden.
    @State private var inspirationPendingCharacterID: UUID?
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
    /// Task handle for the in-flight "Generate Now" (standard pricing) worker
    /// that drains `inspirationGenerationQueue`. `nil` when no worker is
    /// running. One long-lived worker processes all enqueued runs serially so
    /// starting a second batch while one is running queues behind it instead
    /// of cancelling. Per-activity cancel buttons in the Gemini activity
    /// popover can abort individual items via `attachGeminiActivityCancel`.
    @State private var inspirationGenerationTask: Task<Void, Never>?
    /// FIFO queue of pending runs. The worker pops the head entry, processes
    /// its drafts, then keeps going while the queue is non-empty.
    @State private var inspirationGenerationQueue: [QueuedInspirationRun] = []
    @State private var isSubmittingInspirationBatch: Bool = false
    @State private var submittingInspirationBatchCharacterID: UUID?
    @ObservedObject private var runpodService = RunPodLORAService.shared
    @FocusState private var galleryKeyboardFocused: Bool
    @State private var hasShownFocusHighlight = false
    @State private var galleryColumnCount: Int = 1
    @State private var pendingGallerySaveTask: Task<Void, Never>?
    private let gallerySaveDebounceNanoseconds: UInt64 = 300_000_000

    /// Transient in-session multi-selection — the yellow ring around
    /// gallery thumbnails. Holds raw `path` values from `preloadedPaths`
    /// (no normalization, since this set never persists to disk). Plain
    /// click replaces, cmd-click toggles, shift-click fills a range from
    /// `rangeAnchorPath`. Reset on character change, project load, and
    /// page switch. Replaced the old persistent `galleryState.selectedPaths`
    /// gray-checkmark system on 2026-04-16 — those checkmarks were
    /// surviving restarts and couldn't be cleared from the UI. Gemini
    /// right-click and "Use Selected as References" now read from here
    /// instead.
    @State private var yellowSelection: Set<String> = []
    /// Anchor for shift-click range selection. Tracks the last path the
    /// user plain- or cmd-clicked so shift+click can fill in everything
    /// between that anchor and the new click target.
    @State private var rangeAnchorPath: String?


    /// Visibility filter for the gallery. Places-style pill group drives
    /// `.all / .unreviewed / .rejected`; `.gemini`, `.lora`, and the legacy
    /// `.hidden` value are retained for persisted backward-compat (old
    /// `@AppStorage` values) and are honored by `isPathVisibleInGallery`
    /// but are not surfaced in the filter pill UI anymore. The per-device
    /// "Hidden" concept was unified into `inspirationRejectedPaths` on
    /// 2026-04-16 — rejected is now the single dim+eye.slash visual.
    private enum GalleryFilter: String, CaseIterable {
        case all
        case unreviewed
        case rejected
        /// Deprecated — retained only so persisted `@AppStorage` values from
        /// older builds still decode. Treated as `.rejected` at read time.
        case hidden
        case gemini
        case lora

        var title: String {
            switch self {
            case .all: return "All"
            case .unreviewed: return "Unreviewed"
            case .rejected: return "Rejected"
            case .hidden: return "Rejected"
            case .gemini: return "Gemini"
            case .lora: return "LoRA"
            }
        }

        var systemImage: String {
            switch self {
            case .all: return "square.grid.2x2"
            case .unreviewed: return "circle.dotted"
            case .rejected: return "eye.slash.fill"
            case .hidden: return "eye.slash.fill"
            case .gemini: return "sparkles"
            case .lora: return "cpu"
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

    /// Cached filter result. Recomputed via `recomputeDisplayedPaths()`
    /// whenever `preloadedPaths`, the filter, or any per-path visibility
    /// dependency (ratings, rejected, reviewed, gallery selection sets)
    /// changes. Avoids re-running the filter on every body evaluation.
    @State private var displayedPaths: [String] = []

    private func recomputeDisplayedPaths() {
        displayedPaths = preloadedPaths.filter(isPathVisibleInGallery)
    }

    /// Combined visibility signature. Used as the sole `.onChange` trigger
    /// for the cached `displayedPaths`, so the outer `inspirationSection`
    /// modifier chain stays short (SwiftUI's type-checker falls over when
    /// too many modifiers stack on the same `some View`).
    private func visibilitySignature(for character: AnimationCharacter) -> ImagineGalleryVisibilitySignature {
        ImagineGalleryVisibilitySignature(
            filterRaw: galleryFilterRawValue,
            minRating: galleryMinimumRating,
            rejected: character.inspirationRejectedPaths,
            reviewed: character.reviewedInspirationImagePaths,
            ratings: character.inspirationRatings,
            // `yellowSelection` drives both the ring visual and (for legacy
            // decode-compat) the `.gemini` filter. Feeding it into the
            // signature keeps the cached `displayedPaths` in sync.
            selected: yellowSelection,
            lora: galleryState.loraSelectedPaths
        )
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
                        inspirationPendingCharacterID = nil
                    },
                    onCancel: {
                        inspirationPendingPlan = nil
                        inspirationPendingBatchTitleOverride = nil
                        inspirationPendingBatchFolderSlugOverride = nil
                        inspirationPendingBatchKind = .inspiration
                        inspirationAutoSelectForLoRA = false
                        inspirationPendingCharacterID = nil
                    },
                    // Refresh button is only meaningful when the draft came
                    // from the pose catalog (inspirationPendingCharacterID is
                    // set). Freeform drafts (Edit-with-Gemini, with-ref
                    // photoreal) leave the character ID nil → button hides.
                    onRefreshSpec: inspirationPendingCharacterID == nil
                        ? nil
                        : { draftID in cycleInspirationDraftSpec(draftID: draftID) }
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

            if loraEnabled {
                Button {
                    showLORATraining = true
                } label: {
                    Label("Train LORA", systemImage: "cpu")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

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
                    if !yellowSelection.isEmpty {
                        Divider()
                        Section("Use Selected as References") {
                            Button("Generate 27-Image Set Now (with \(yellowSelection.count) Selected)") {
                                prepareInspirationWithSelectedReferences(character: character, mode: .immediate)
                            }
                            Button("Submit 27-Image Batch + Watchdog (with \(yellowSelection.count) Selected)") {
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

                // Train LORA with LORA-selected images — hidden when LoRA
                // features are disabled in Global Settings.
                if loraEnabled {
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

            if loraEnabled {
                loraSelectionSection(character)
            }

            // Selection status bar
            if !yellowSelection.isEmpty || !galleryState.loraSelectedPaths.isEmpty || !character.inspirationRejectedPaths.isEmpty {
                HStack(spacing: 8) {
                    if !yellowSelection.isEmpty {
                        Text("\(yellowSelection.count) selected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.yellow)
                    }
                    if loraEnabled && !galleryState.loraSelectedPaths.isEmpty {
                        Text("\(galleryState.loraSelectedPaths.count) LORA")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.purple)
                    }
                    if !character.inspirationRejectedPaths.isEmpty {
                        Text("\(character.inspirationRejectedPaths.count) rejected")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(keyboardShortcutHint)
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
                    .trackGridColumnCount($galleryColumnCount, tileMinWidth: galleryThumbnailBaseSize, spacing: 6)
                }
            }

            if galleryCollapsed && character.inspirationBatchJobs.isEmpty && runpodService.currentJob == nil && runpodService.queuedJobs.isEmpty && runpodService.recentJobs.isEmpty {
                Text("Gallery is collapsed. Expand it to continue.")
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
        .onChange(of: visibilitySignature(for: character)) { _, _ in
            recomputeDisplayedPaths()
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
        .onKeyPress(.upArrow) {
            hasShownFocusHighlight = true
            moveFocus(-max(1, galleryColumnCount))
            return .handled
        }
        .onKeyPress(.downArrow) {
            hasShownFocusHighlight = true
            moveFocus(max(1, galleryColumnCount))
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
        // Yellow multi-select keyboard shortcuts — add/remove focused path
        // from the transient in-session `yellowSelection`. Previously these
        // wrote to the persistent `galleryState.selectedPaths` which caused
        // gray checkmarks to survive restarts; the new set is session-only
        // so the selection naturally clears on navigation away.
        .onKeyPress(.init("g")) {
            if let path = focusedPath {
                yellowSelection.insert(path)
                rangeAnchorPath = path
                hasShownFocusHighlight = true
            }
            return .handled
        }
        .onKeyPress(.init("f")) {
            if let path = focusedPath {
                yellowSelection.remove(path)
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
        // Rejection toggle — matches PlaceAllImagesGallerySection (Places parity).
        // Was "toggle hidden" before 2026-04-16; hidden is now context-menu only
        // via Hide/Show (see contextMenu below).
        .onKeyPress(.init("x")) {
            if let path = focusedPath {
                store.toggleInspirationRejected(path: path, for: character.id)
                hasShownFocusHighlight = true
            }
            return .handled
        }
        // Rating shortcuts 1-5 / 0. Apply to the focused path (single-image),
        // unlike Places which applies to the full selectedPaths set — here the
        // selected set means "Gemini multi-select", so we keep rating on the
        // focus cursor to avoid surprise batch rates.
        .onKeyPress(phases: .down) { press in
            guard let path = focusedPath else { return .ignored }
            switch press.key {
            case "1":
                store.setInspirationRating(1, path: path, for: character.id)
                hasShownFocusHighlight = true
                return .handled
            case "2":
                store.setInspirationRating(2, path: path, for: character.id)
                hasShownFocusHighlight = true
                return .handled
            case "3":
                store.setInspirationRating(3, path: path, for: character.id)
                hasShownFocusHighlight = true
                return .handled
            case "4":
                store.setInspirationRating(4, path: path, for: character.id)
                hasShownFocusHighlight = true
                return .handled
            case "5":
                store.setInspirationRating(5, path: path, for: character.id)
                hasShownFocusHighlight = true
                return .handled
            case "0":
                store.setInspirationRating(nil, path: path, for: character.id)
                hasShownFocusHighlight = true
                return .handled
            default:
                return .ignored
            }
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

    /// Places-style filter pills. Flag filter (All / Unreviewed / Rejected)
    /// in one capsule, then a rating pill group (1★…5★, tap to set min, tap
    /// again to clear). Matches `PlaceAllImagesGallerySection`'s header at
    /// PlacesPageView.swift:1496. The legacy "Hidden" pill was retired on
    /// 2026-04-16 — its concept folded into Rejected (single persistent
    /// dim+eye.slash visual).
    private var galleryFilterControls: some View {
        HStack(spacing: 8) {
            // Flag filter capsule
            HStack(spacing: 8) {
                galleryFilterButton(
                    systemImage: GalleryFilter.all.systemImage,
                    isSelected: galleryFilter == .all
                ) { galleryFilter = .all }
                .help("Show all images")

                galleryFilterButton(
                    systemImage: GalleryFilter.unreviewed.systemImage,
                    isSelected: galleryFilter == .unreviewed
                ) { galleryFilter = .unreviewed }
                .help("Show only unreviewed images")

                galleryFilterButton(
                    systemImage: GalleryFilter.rejected.systemImage,
                    isSelected: galleryFilter == .rejected || galleryFilter == .hidden
                ) { galleryFilter = .rejected }
                .help("Show only rejected images")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)

            // Rating pill capsule
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { rating in
                    galleryFilterButton(
                        systemImage: galleryMinimumRating > 0 && rating <= galleryMinimumRating ? "star.fill" : "star",
                        tint: .yellow,
                        isSelected: galleryMinimumRating == rating
                    ) {
                        galleryMinimumRating = galleryMinimumRating == rating ? 0 : rating
                    }
                    .help("Show \(rating)-star and higher")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.quaternary.opacity(0.12), in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func galleryFilterButton(
        systemImage: String,
        tint: Color = .accentColor,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 24)
                .foregroundStyle(isSelected ? .white : tint)
                .background(
                    Circle()
                        .fill(isSelected ? tint : Color.clear)
                )
                .overlay(
                    Circle()
                        .stroke(isSelected ? tint.opacity(0.9) : Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Single-line keyboard hint shown in the selection status bar. Rewritten
    /// 2026-04-16 to match the Places-style rating/rejection gallery — 1-5 /
    /// 0 / X replace the old G/F (Gemini pick) hint.
    private var keyboardShortcutHint: String {
        "← →: navigate  ·  Space: Quick Look  ·  1-5: rate  ·  0: clear  ·  X: reject"
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
        guard let character = store.selectedCharacter else { return true }

        // Rating filter: images below the minimum are hidden regardless of
        // flag filter. 0 = don't apply this filter.
        if galleryMinimumRating > 0 {
            let rating = character.inspirationRatings?[path] ?? 0
            if rating < galleryMinimumRating { return false }
        }

        switch galleryFilter {
        case .all:
            return true
        case .unreviewed:
            return !character.reviewedInspirationImagePaths.contains(path)
        case .rejected, .hidden:
            // Legacy `.hidden` persisted values redirect to rejected — the
            // two concepts were unified on 2026-04-16.
            return character.inspirationRejectedPaths.contains(path)
        case .gemini:
            // `.gemini` filter pill was retired when the persistent
            // Gemini-reference set was replaced by the transient
            // `yellowSelection` on 2026-04-16. This case is retained only
            // so old persisted `@AppStorage` values decode; it now tracks
            // the transient selection so the filter still makes visual
            // sense if a user somehow lands on it.
            return yellowSelection.contains(path)
        case .lora:
            return galleryState.loraSelectedPaths.contains(selectionKey)
        }
    }

    /// Apply modifier-aware tap selection to `yellowSelection`. Called from
    /// the thumbnail's `.onTapGesture`. Reads the live `NSEvent.modifierFlags`
    /// so shift/cmd-clicks Just Work without a custom gesture recognizer.
    ///
    /// Semantics (mirrors Finder / macOS conventions):
    ///   • plain click         → single-select this path
    ///   • ⌘-click             → toggle this path, move range anchor here
    ///   • ⇧-click (w/ anchor) → union everything between anchor and path
    ///   • ⇧-click (no anchor) → same as plain click
    private func applyGalleryTapSelection(path: String) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift),
           let anchor = rangeAnchorPath,
           let a = displayedPaths.firstIndex(of: anchor),
           let b = displayedPaths.firstIndex(of: path) {
            let lower = min(a, b)
            let upper = max(a, b)
            yellowSelection.formUnion(displayedPaths[lower...upper])
            return
        }
        if flags.contains(.command) {
            if yellowSelection.contains(path) {
                yellowSelection.remove(path)
            } else {
                yellowSelection.insert(path)
            }
            rangeAnchorPath = path
            return
        }
        yellowSelection = [path]
        rangeAnchorPath = path
    }

    private func syncFocusedIndex(preferredPath: String? = nil) {
        let paths = displayedPaths
        guard !paths.isEmpty else {
            focusedIndex = 0
            updatePreviewPath()
            return
        }

        if let preferredPath, let preferredIndex = paths.firstIndex(of: preferredPath) {
            focusedIndex = preferredIndex
            updatePreviewPath()
            return
        }

        if let current = focusedPath, let currentIndex = paths.firstIndex(of: current) {
            focusedIndex = currentIndex
            updatePreviewPath()
            return
        }

        focusedIndex = min(max(focusedIndex, 0), paths.count - 1)
        updatePreviewPath()
    }

    /// Sync `store.imaginePreviewImagePath` to whatever is currently focused so
    /// the Details inspector picks it up. Called after every focusedIndex change.
    private func updatePreviewPath() {
        let paths = displayedPaths
        if paths.isEmpty {
            store.imaginePreviewImagePath = nil
        } else if focusedIndex >= 0, focusedIndex < paths.count {
            store.imaginePreviewImagePath = paths[focusedIndex]
        }
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

            // Cancel — drops any in-flight HTTP request on Google's side via
            // URLSession Task cancellation propagation.
            Button {
                cancelInspirationGeneration()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Cancel this generation run")
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
            } else {
                // Cancel the remote batch on Google's side. The Python helper
                // calls client.batches.cancel(...) and rewrites local
                // metadata to JOB_STATE_CANCELLED — the next refresh will
                // reconcile the UI.
                Button(role: .destructive) {
                    store.cancelInspirationBatchJob(job, for: character.id)
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .help("Cancel this batch on Google's side")
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
            updatePreviewPath()
        }
    }

    private func loadGalleryState(for character: AnimationCharacter) {
        guard let animateURL = store.animateURL else { return }
        galleryState = ImagineGallerySelectionState.load(
            animateURL: animateURL,
            characterSlug: character.assetFolderSlug
        )
        // Wipe legacy persisted "Gemini-reference" selection — the concept
        // was replaced by the transient in-session `yellowSelection` on
        // 2026-04-16. Any pre-existing gray checkmarks in the on-disk JSON
        // get cleared on first load and a debounced save strips them from
        // disk. `loraSelectedPaths` and `dismissedBatchJobKeys` are
        // preserved since those remain legitimately persistent.
        if !galleryState.selectedPaths.isEmpty {
            galleryState.selectedPaths.removeAll()
            scheduleGalleryStateSave(for: character)
        }
        yellowSelection.removeAll()
        rangeAnchorPath = nil
        focusedIndex = 0
        hasShownFocusHighlight = false
        updatePreviewPath()
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

        // Snapshot resolved-path lookup on the main actor so the background
        // sort doesn't have to touch @MainActor state. Per-path filesystem
        // stat() is the real main-thread blocker with 100+ images.
        let resolvedPairs: [(path: String, resolved: String?)] = filtered.map { p in
            (p, resolvedGalleryAssetPath(for: p))
        }

        // Show the pre-sort order immediately so the UI feels instant, then
        // replace with the mtime-sorted order once stat() completes.
        preloadedPaths = filtered
        recomputeDisplayedPaths()
        if focusedIndex >= preloadedPaths.count {
            focusedIndex = max(0, preloadedPaths.count - 1)
        }
        updatePreviewPath()

        let characterID = character.id
        let prefetchSize = Int(galleryThumbnailBaseSize * 2)
        let resolvedForPrefetch = resolvedPairs.compactMap { $0.resolved }

        Task { @MainActor in
            let sorted = await Task.detached(priority: .utility) {
                Self.sortedByModificationTimeDescending(resolvedPairs)
            }.value
            guard store.selectedCharacterID == characterID else { return }
            preloadedPaths = sorted
            recomputeDisplayedPaths()
            if focusedIndex >= preloadedPaths.count {
                focusedIndex = max(0, preloadedPaths.count - 1)
            }
            updatePreviewPath()
        }

        ImagineThumbnailCache.shared.prefetch(
            paths: resolvedForPrefetch,
            maxPixelSize: prefetchSize
        )
    }

    /// Sort paths by file mtime (newest first). Pure function — no @MainActor
    /// state access so it can run on a background task. Callers pre-resolve
    /// relative → absolute paths on the main actor and pass pairs in.
    nonisolated private static func sortedByModificationTimeDescending(
        _ pairs: [(path: String, resolved: String?)]
    ) -> [String] {
        let fm = FileManager.default
        let decorated: [(index: Int, path: String, mtime: Date?)] = pairs.enumerated().map { (idx, pair) in
            let date: Date? = pair.resolved.flatMap { p in
                (try? fm.attributesOfItem(atPath: p)[.modificationDate]) as? Date
            }
            return (idx, pair.path, date)
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
        // Pass 3 (2026-04-17): migrated to the shared `UnifiedImageTile` so
        // this grid renders with the same outer shell (12-corner, 6 padding,
        // accent@10% bg on selection, 2pt accent border) as Characters, All
        // Images, and Places. Grid-specific widgets (LORA L checkbox, "new"
        // green dot) live in the unified overlay slots; the right-click menu
        // routes through `UnifiedImageContextMenuContent` with wardrobe
        // presets folded into `extraGeminiGenerateEntries`.
        let selectionKey = gallerySelectionKey(for: path)
        let resolvedPath = resolvedGalleryAssetPath(for: path)
        let isYellowSelected = yellowSelection.contains(path)
        let isLoraPicked = galleryState.loraSelectedPaths.contains(selectionKey)
        let isFocused = index == focusedIndex
        let shouldShowFocusBorder = isFocused && hasShownFocusHighlight
        let isSelected = isYellowSelected || shouldShowFocusBorder
        let rating = character.inspirationRatings?[path]
        let isRejected = character.inspirationRejectedPaths.contains(path)
        let isNew = !character.reviewedInspirationImagePaths.contains(path)
        let charID = character.id
        let geminiActive = !store.geminiAPIKey.isEmpty && store.geminiMasterSwitch

        UnifiedImageTile(
            path: path,
            resolvedPath: resolvedPath,
            thumbnailSize: galleryThumbnailBaseSize,
            isSelected: isSelected,
            isRejected: isRejected,
            rating: rating,
            selectedCount: yellowSelection.count,
            actions: UnifiedImageActions(
                onSetAsProfile: {
                    store.prepareProfilePicCrop(from: path, for: charID)
                },
                onShowInFinder: {
                    if let resolvedPath {
                        ImagineProjectStorage.revealInFinder(resolvedPath)
                    }
                },
                onCopy: {
                    if let resolvedPath, let image = NSImage(contentsOfFile: resolvedPath) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                },
                onQuickLook: {
                    if let resolvedPath {
                        ImagineQuickLook.preview(url: URL(fileURLWithPath: resolvedPath))
                    }
                },
                onEditWithGemini: geminiActive ? {
                    beginEditWithGemini(characterID: charID, imagePath: path)
                } : nil,
                onGenerateWithGemini: geminiActive ? { count in
                    beginGenerateWithGemini(characterID: charID, imagePath: path, count: count)
                } : nil,
                extraGeminiGenerateEntries: geminiActive ? [
                    UnifiedGeminiGenerateEntry(
                        label: "Soldier: Generate 1",
                        systemImage: "figure.walk",
                        count: 1,
                        action: { _ in beginGenerateWithGeminiWardrobe(characterID: charID, imagePath: path, count: 1, wardrobe: .soldier) }
                    ),
                    UnifiedGeminiGenerateEntry(
                        label: "Soldier: Generate 27",
                        systemImage: "figure.walk",
                        count: 27,
                        action: { _ in beginGenerateWithGeminiWardrobe(characterID: charID, imagePath: path, count: 27, wardrobe: .soldier) }
                    ),
                    UnifiedGeminiGenerateEntry(
                        label: "Civilian: Generate 1",
                        systemImage: "tshirt",
                        count: 1,
                        action: { _ in beginGenerateWithGeminiWardrobe(characterID: charID, imagePath: path, count: 1, wardrobe: .civilian) }
                    ),
                    UnifiedGeminiGenerateEntry(
                        label: "Civilian: Generate 27",
                        systemImage: "tshirt",
                        count: 27,
                        action: { _ in beginGenerateWithGeminiWardrobe(characterID: charID, imagePath: path, count: 27, wardrobe: .civilian) }
                    )
                ] : [],
                onSetRating: { r in
                    store.setInspirationRating(r, path: path, for: charID)
                },
                currentRating: rating,
                onToggleRejected: {
                    store.toggleInspirationRejected(path: path, for: charID)
                },
                isRejected: isRejected,
                onMoveToTrash: {
                    store.deleteInspirationImageToTrash(path: path, for: charID)
                    if let refreshed = store.characters.first(where: { $0.id == charID }) {
                        refreshPreloadedPaths(character: refreshed)
                    }
                }
            ),
            onTap: {
                galleryKeyboardFocused = true
                hasShownFocusHighlight = true
                focusedIndex = index
                store.imaginePreviewImagePath = path
                store.markInspirationImageReviewed(path: path, for: character.id)
                applyGalleryTapSelection(path: path)
            },
            topTrailingOverlay: loraEnabled
                ? AnyView(loraBadge(isPicked: isLoraPicked, path: path, selectionKey: selectionKey, character: character))
                : nil,
            bottomLeadingOverlay: isNew ? AnyView(unreviewedDot) : nil
        )
    }

    /// The purple "L" LORA-pick checkbox that lives in the top-trailing
    /// overlay slot of each Imagine → Characters gallery tile. Extracted so
    /// the `UnifiedImageTile` call site stays readable.
    @ViewBuilder
    private func loraBadge(
        isPicked: Bool,
        path: String,
        selectionKey: String,
        character: AnimationCharacter
    ) -> some View {
        ZStack {
            Image(systemName: isPicked ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(isPicked ? Color.purple : Color.white.opacity(0.85))
                .shadow(color: .black.opacity(0.6), radius: 2, x: 0, y: 1)
            Text("L")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isPicked ? .white : Color.purple)
        }
        .padding(5)
        .contentShape(Rectangle())
        .onTapGesture {
            galleryKeyboardFocused = true
            hasShownFocusHighlight = true
            if isPicked {
                galleryState.loraSelectedPaths.remove(selectionKey)
            } else {
                galleryState.loraSelectedPaths.insert(selectionKey)
            }
            syncFocusedIndex(preferredPath: path)
            flushGalleryStateSaveImmediately(for: character)
        }
        .help("LORA training (L=pick, K=unpick)")
    }

    /// The green "new / unreviewed" dot for the bottom-leading overlay slot.
    private var unreviewedDot: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
            .padding(6)
            .help("New — not yet reviewed")
    }

    /// Right-click "Edit with Gemini…" on an Imagine inspiration thumbnail →
    /// opens the preflight sheet with a single draft that uses this image as
    /// the first included reference. Pulls prompt/model/aspect/size from the
    /// image's JSON metadata sidecar when present.
    private func beginEditWithGemini(characterID: UUID, imagePath: String) {
        guard let character = store.characters.first(where: { $0.id == characterID }) else { return }
        let metadata = store.generationMetadata(for: imagePath)
        let filename = URL(fileURLWithPath: imagePath).lastPathComponent

        let sourceLabel = "Source: \(filename)"
        let ref = GeminiGenerationReferenceDraft(label: sourceLabel, path: imagePath, isIncluded: true)

        let promptText = metadata?.prompt ?? ""
        let aspectRatio = metadata?.aspectRatio ?? CharacterInspirationPromptCatalog.defaultAspectRatio
        let imageSize = metadata?.imageSize ?? CharacterInspirationPromptCatalog.defaultImageSize
        let model = metadata.flatMap { GeminiModel(rawValue: $0.model) } ?? store.selectedGeminiModel

        var draft = GeminiGenerationDraft(
            title: "Edit \(filename)",
            destinationDescription: "\(character.name) • inspiration edit",
            prompt: promptText,
            contextNote: "Editing existing inspiration image — describe only what to change in the Adjustments box below.",
            model: model,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            referenceItems: [ref],
            pricingMode: .standard
        )
        draft.editInstructions = ""
        inspirationDrafts = [draft]
        inspirationActiveWardrobe = character.defaultWardrobeType
        inspirationPendingCharacterID = nil  // freeform — no pose cycle
        inspirationPendingPlan = PendingInspirationGenerationPlan(
            title: "Edit \(filename)",
            confirmTitle: "Regenerate",
            mode: .immediate,
            wardrobe: character.defaultWardrobeType
        )
    }

    /// Right-click "Generate with Gemini…" on an Imagine inspiration thumbnail →
    /// opens the preflight sheet with a fresh generation draft using this image
    /// as the reference. Does NOT auto-call Gemini — the user clicks Generate.
    private func beginGenerateWithGemini(characterID: UUID, imagePath: String, count: Int) {
        guard let character = store.characters.first(where: { $0.id == characterID }) else { return }
        let filename = URL(fileURLWithPath: imagePath).lastPathComponent
        let ref = GeminiGenerationReferenceDraft(label: "Reference: \(filename)", path: imagePath, isIncluded: true)

        let aspectRatio = CharacterInspirationPromptCatalog.defaultAspectRatio
        let imageSize = CharacterInspirationPromptCatalog.defaultImageSize

        let drafts = (0..<count).map { i in
            GeminiGenerationDraft(
                title: count == 1 ? "Generate from \(filename)" : "Batch \(i + 1) from \(filename)",
                destinationDescription: "\(character.name) • inspiration",
                prompt: "",
                model: store.selectedGeminiModel,
                aspectRatio: aspectRatio,
                imageSize: imageSize,
                referenceItems: [ref],
                pricingMode: .standard
            )
        }
        inspirationDrafts = drafts
        inspirationActiveWardrobe = character.defaultWardrobeType
        inspirationPendingCharacterID = nil  // freeform — no pose cycle
        inspirationPendingPlan = PendingInspirationGenerationPlan(
            title: count == 1 ? "Generate from \(filename)" : "Generate \(count) variations",
            confirmTitle: "Generate",
            mode: count > 1 ? .batch : .immediate,
            wardrobe: character.defaultWardrobeType
        )
    }

    /// Right-click "Generate with Gemini…" → Soldier/Civilian section. Uses the
    /// catalog's wardrobe-aware prompts pre-filled (the same ones the top
    /// "Generate" button uses) and prepends the right-clicked thumbnail as
    /// the primary reference image, keeping the character's other inspiration
    /// refs as supporting context. Opens the preflight sheet — does NOT
    /// auto-call Gemini.
    private func beginGenerateWithGeminiWardrobe(
        characterID: UUID,
        imagePath: String,
        count: Int,
        wardrobe: CharacterInspirationWardrobe
    ) {
        guard let character = store.characters.first(where: { $0.id == characterID }) else { return }
        let filename = URL(fileURLWithPath: imagePath).lastPathComponent

        // Right-clicked image is the anchor — put it first so the identity
        // signal is dominant. If the user has multi-selected additional images
        // in the gallery, include them as supporting refs in selection order.
        // Previously this also bundled every character reference ref, which
        // flooded the preflight sheet with images the user didn't ask for.
        let anchorRef = GeminiGenerationReferenceDraft(
            label: "Reference: \(filename)",
            path: imagePath,
            isIncluded: true
        )
        // Pull any additional yellow-selected thumbnails in as supporting
        // refs, de-duped against the right-clicked anchor. `yellowSelection`
        // is transient (cmd/shift-click in the grid) and holds the same raw
        // `path` values as `character.inspirationImagePaths`, so no
        // normalization dance is required.
        let extraRefs: [GeminiGenerationReferenceDraft] = character.inspirationImagePaths.compactMap { p in
            guard p != imagePath, yellowSelection.contains(p) else { return nil }
            let pFilename = URL(fileURLWithPath: p).lastPathComponent
            return GeminiGenerationReferenceDraft(
                label: "Reference: \(pFilename)",
                path: p,
                isIncluded: true
            )
        }
        let combinedRefs = [anchorRef] + extraRefs

        inspirationPendingBatchTitleOverride = nil
        inspirationPendingBatchFolderSlugOverride = nil
        inspirationPendingBatchKind = .inspiration
        inspirationAutoSelectForLoRA = false
        inspirationPendingCharacterID = character.id

        let specs = Array(CharacterInspirationPromptCatalog.allSpecs.prefix(count))
        let mode: CharacterInspirationGenerationMode = count > 1 ? .batch : .immediate

        inspirationDrafts = specs.enumerated().map { index, spec in
            GeminiGenerationDraft(
                title: spec.title,
                destinationDescription: "\(wardrobe.displayName) inspiration image",
                prompt: CharacterInspirationPromptCatalog.prompt(
                    for: spec,
                    character: character,
                    wardrobe: wardrobe,
                    specIndex: index
                ),
                model: store.selectedGeminiModel,
                aspectRatio: CharacterInspirationPromptCatalog.defaultAspectRatio,
                imageSize: CharacterInspirationPromptCatalog.defaultImageSize,
                referenceItems: combinedRefs,
                pricingMode: mode == .batch ? .batch : .standard
            )
        }

        inspirationActiveWardrobe = wardrobe
        inspirationPendingPlan = PendingInspirationGenerationPlan(
            title: count == 1
                ? "\(character.name) • \(wardrobe.displayName) from \(filename)"
                : "\(character.name) • \(wardrobe.displayName) Inspiration (\(count))",
            confirmTitle: mode == .batch
                ? "Submit \(count)-Image Batch"
                : "Generate 1 Image",
            mode: mode,
            wardrobe: wardrobe
        )
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
        if loraEnabled {
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
        }

        Section(wardrobe.displayName) {
            Button("Generate 1 Test Image") {
                prepareInspirationGenerationPlan(for: character, count: 1, wardrobe: wardrobe, mode: .immediate)
            }
            Button("Generate \(CharacterInspirationPromptCatalog.allSpecs.count)-Image Set Now") {
                prepareInspirationGenerationPlan(
                    for: character,
                    count: CharacterInspirationPromptCatalog.allSpecs.count,
                    wardrobe: wardrobe,
                    mode: .immediate
                )
            }
            Button("Submit \(CharacterInspirationPromptCatalog.allSpecs.count)-Image Batch + Watchdog") {
                prepareInspirationGenerationPlan(
                    for: character,
                    count: CharacterInspirationPromptCatalog.allSpecs.count,
                    wardrobe: wardrobe,
                    mode: .batch
                )
            }
        }

        Section("Action Images (Amira-specific)") {
            Button("Generate \(CharacterActionPromptCatalog.allSpecs.count) Action Images Now") {
                prepareActionImageGenerationPlan(
                    for: character,
                    count: CharacterActionPromptCatalog.allSpecs.count,
                    wardrobe: wardrobe,
                    mode: .immediate
                )
            }
            Button("Submit \(CharacterActionPromptCatalog.allSpecs.count)-Image Action Batch + Watchdog") {
                prepareActionImageGenerationPlan(
                    for: character,
                    count: CharacterActionPromptCatalog.allSpecs.count,
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
        inspirationPendingCharacterID = character.id
        // Use the yellow-selected images as reference images for a 27-image
        // set. `yellowSelection` is the transient cmd/shift-click selection
        // from the gallery grid (replaced the persistent gray-checkmark
        // `galleryState.selectedPaths` on 2026-04-16).
        let specs = CharacterInspirationPromptCatalog.allSpecs
        let selectedRefs = yellowSelection.compactMap { path -> GeminiGenerationReferenceDraft? in
            let url = store.resolvedCharacterAssetURL(for: path) ?? URL(fileURLWithPath: path)
            return GeminiGenerationReferenceDraft(
                label: url.deletingPathExtension().lastPathComponent,
                path: url.path,
                isIncluded: true
            )
        }

        inspirationDrafts = specs.enumerated().map { index, spec in
            GeminiGenerationDraft(
                title: spec.title,
                destinationDescription: "\(character.defaultWardrobeType.displayName) inspiration image",
                prompt: CharacterInspirationPromptCatalog.prompt(
                    for: spec,
                    character: character,
                    wardrobe: character.defaultWardrobeType,
                    specIndex: index
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

    /// Called by the preflight sheet's pose-title refresh button. Advances
    /// the draft's title + prompt to the next spec in
    /// `CharacterInspirationPromptCatalog.allSpecs`, wrapping around. Looks
    /// up the current spec by matching title; falls back to spec[0] if the
    /// title has been user-edited away from a known spec. No-op when the
    /// pending character or active wardrobe have been cleared.
    private func cycleInspirationDraftSpec(draftID: UUID) {
        guard let characterID = inspirationPendingCharacterID,
              let character = store.characters.first(where: { $0.id == characterID }),
              let wardrobe = inspirationActiveWardrobe,
              let draftIndex = inspirationDrafts.firstIndex(where: { $0.id == draftID }) else {
            return
        }
        let specs = CharacterInspirationPromptCatalog.allSpecs
        guard !specs.isEmpty else { return }
        let currentTitle = inspirationDrafts[draftIndex].title
        let currentIdx = specs.firstIndex(where: { $0.title == currentTitle }) ?? -1
        let nextIdx = (currentIdx + 1) % specs.count
        let nextSpec = specs[nextIdx]
        inspirationDrafts[draftIndex].title = nextSpec.title
        inspirationDrafts[draftIndex].prompt = CharacterInspirationPromptCatalog.prompt(
            for: nextSpec,
            character: character,
            wardrobe: wardrobe,
            specIndex: nextIdx
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
        // Track character so the preflight sheet's pose-refresh button can
        // cycle to the next catalog spec. Clears on sheet dismiss.
        inspirationPendingCharacterID = character.id
        let specs = Array(CharacterInspirationPromptCatalog.allSpecs.prefix(count))
        inspirationDrafts = specs.enumerated().map { index, spec in
            GeminiGenerationDraft(
                title: spec.title,
                destinationDescription: "\(wardrobe.displayName) inspiration image",
                prompt: CharacterInspirationPromptCatalog.prompt(
                    for: spec,
                    character: character,
                    wardrobe: wardrobe,
                    specIndex: index
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

    private func prepareActionImageGenerationPlan(
        for character: AnimationCharacter,
        count: Int,
        wardrobe: CharacterInspirationWardrobe,
        mode: CharacterInspirationGenerationMode
    ) {
        inspirationPendingBatchTitleOverride = CharacterActionPromptCatalog.batchTitle
        inspirationPendingBatchFolderSlugOverride = CharacterActionPromptCatalog.batchFolderSlug
        inspirationPendingBatchKind = .inspiration
        inspirationAutoSelectForLoRA = false
        inspirationPendingCharacterID = character.id

        let specs = Array(CharacterActionPromptCatalog.allSpecs.prefix(count))
        inspirationDrafts = specs.enumerated().map { index, spec in
            GeminiGenerationDraft(
                title: spec.title,
                destinationDescription: "\(wardrobe.displayName) action image",
                prompt: CharacterActionPromptCatalog.prompt(
                    for: spec,
                    character: character,
                    wardrobe: wardrobe,
                    specIndex: index
                ),
                contextNote: "Amira-specific action image",
                model: store.selectedGeminiModel,
                aspectRatio: CharacterActionPromptCatalog.defaultAspectRatio,
                imageSize: CharacterActionPromptCatalog.defaultImageSize,
                referenceItems: inspirationReferenceDrafts(for: character),
                pricingMode: mode == .batch ? .batch : .standard
            )
        }

        inspirationActiveWardrobe = wardrobe
        inspirationPendingPlan = PendingInspirationGenerationPlan(
            title: "\(character.name) • \(wardrobe.displayName) Action Images",
            confirmTitle: mode == .batch
                ? "Submit \(count)-Image Action Batch"
                : (count == 1 ? "Generate 1 Action Image" : "Generate \(count) Action Images"),
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

        let usingSelectedRefs = !yellowSelection.isEmpty
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

    struct QueuedInspirationRun {
        let drafts: [GeminiGenerationDraft]
        let autoSelectForLoRA: Bool
        let characterID: UUID
        let characterName: String
    }

    private func runInspirationGeneration(
        _ drafts: [GeminiGenerationDraft],
        autoSelectForLoRA: Bool = false
    ) {
        guard let character = store.selectedCharacter else { return }
        guard store.isGeminiAllowed() else {
            inspirationGenerationErrorMessage = "Gemini API calls are blocked. Enable Gemini API Calls in Inspector > Tools."
            return
        }
        guard !drafts.isEmpty else { return }

        // Queue the new run. If a worker is already processing an earlier
        // batch, this one waits its turn — no cancellation of in-flight work.
        inspirationGenerationQueue.append(
            QueuedInspirationRun(
                drafts: drafts,
                autoSelectForLoRA: autoSelectForLoRA,
                characterID: character.id,
                characterName: character.name
            )
        )
        inspirationStatusCharacterID = character.id
        inspirationGenerationErrorMessage = nil

        // Worker already running — just let it pick up the new run when it
        // finishes its current draft.
        if inspirationGenerationTask != nil {
            let pending = inspirationGenerationQueue.reduce(0) { $0 + $1.drafts.count }
            inspirationGenerationStatus = "Queued \(drafts.count) more • \(pending) pending."
            return
        }

        isGeneratingInspiration = true
        generatingInspirationCharacterID = character.id
        inspirationGenerationStatus = nil
        inspirationGenerationProgress = 0

        inspirationGenerationTask = Task { @MainActor in
            let service = GeminiImageService()
            var totalCompleted = 0
            var totalSeen = 0

            outerLoop: while !inspirationGenerationQueue.isEmpty {
                if Task.isCancelled { break outerLoop }
                let run = inspirationGenerationQueue.removeFirst()
                totalSeen += run.drafts.count

                for draft in run.drafts {
                    if Task.isCancelled { break outerLoop }

                    let pending = inspirationGenerationQueue.reduce(0) { $0 + $1.drafts.count }
                    inspirationGenerationStatus = pending > 0
                        ? "Generating \(totalCompleted + 1) of \(totalSeen)… (\(pending) more queued)"
                        : "Generating \(totalCompleted + 1) of \(totalSeen)…"
                    inspirationGenerationProgress = totalSeen == 0 ? 0 : Double(totalCompleted) / Double(totalSeen)

                    let activityID = store.registerGeminiActivity(
                        kind: .immediate,
                        title: draft.title,
                        source: "Imagine • \(run.characterName)"
                    )

                    let referenceImages = buildReferenceImages(from: draft.referenceItems)
                    let request = GeminiImageService.GenerationRequest(
                        prompt: draft.effectivePrompt,
                        referenceImages: referenceImages,
                        model: draft.model,
                        aspectRatio: draft.aspectRatio,
                        imageSize: draft.imageSize
                    )
                    let apiKey = store.geminiAPIKey
                    store.logGeminiAPICall(
                        endpoint: "image-generation",
                        source: "ImagineCharactersPageView.runInspirationGeneration()"
                    )

                    // Wrap the single-image call in its own child Task so the
                    // per-activity cancel button in the Gemini popover can
                    // abort just this one item without killing the queue.
                    let itemTask = Task<GeminiImageService.GenerationResult, Error> {
                        try await service.generate(request: request, apiKey: apiKey)
                    }
                    store.attachGeminiActivityCancel(activityID) { itemTask.cancel() }

                    do {
                        let result = try await withTaskCancellationHandler {
                            try await itemTask.value
                        } onCancel: {
                            itemTask.cancel()
                        }

                        let storedPath = try store.storeGeneratedInspirationImage(
                            result.imageData,
                            prompt: draft.prompt,
                            model: draft.model,
                            filenameStem: sanitizedFilenameStem(for: draft.title),
                            for: run.characterID,
                            aspectRatio: draft.aspectRatio,
                            imageSize: draft.imageSize,
                            recommendedLORACaption: draft.recommendedLORACaption,
                            autoSelectForLoRA: run.autoSelectForLoRA
                        )
                        if run.autoSelectForLoRA, !storedPath.isEmpty {
                            galleryState.loraSelectedPaths.insert(storedPath)
                        }
                        store.updateGeminiActivity(
                            activityID,
                            status: .completed,
                            outputFilename: URL(fileURLWithPath: storedPath).lastPathComponent
                        )
                        store.recordVertexCreditUsage(draft.estimatedCost)
                        if let activeCharacter = store.selectedCharacter,
                           activeCharacter.id == run.characterID {
                            refreshPreloadedPaths(character: activeCharacter)
                        }
                        totalCompleted += 1
                    } catch is CancellationError {
                        store.updateGeminiActivity(activityID, status: .failed, errorMessage: "Canceled")
                        // If the outer worker was cancelled (user clicked the
                        // main Cancel), bail out of the queue entirely.
                        // Otherwise, the cancel came from the per-activity
                        // button — skip this item and keep draining the queue.
                        if Task.isCancelled { break outerLoop }
                        continue
                    } catch {
                        store.updateGeminiActivity(activityID, status: .failed, errorMessage: error.localizedDescription)
                        continue
                    }
                }
            }

            inspirationGenerationProgress = 1
            if Task.isCancelled {
                inspirationGenerationStatus = "Canceled after \(totalCompleted) of \(totalSeen)."
            } else {
                inspirationGenerationStatus = "Finished \(totalCompleted) inspiration image\(totalCompleted == 1 ? "" : "s")."
            }
            isGeneratingInspiration = false
            generatingInspirationCharacterID = nil
            inspirationGenerationQueue.removeAll()
            inspirationGenerationTask = nil
        }
    }

    /// User pressed the cancel button on the instant-generation row.
    /// Cancels the outer Task + clears the queue, which propagates to
    /// URLSession and drops any in-flight HTTP request on Google's side.
    private func cancelInspirationGeneration() {
        inspirationGenerationQueue.removeAll()
        inspirationGenerationTask?.cancel()
        if isGeneratingInspiration {
            inspirationGenerationStatus = "Canceling…"
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

                let outputRoot = ProjectPaths(root: animateURL.deletingLastPathComponent())
                    .characterInspirationBatches(slug: character.assetFolderSlug)
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
        // Photoreal LoRA candidate refs follow the same yellow-selection
        // rule as the rest of the Imagine gallery: if the user has actively
        // multi-selected images in the grid, use those; otherwise fall back
        // to the store-preferred ordering. Previously keyed off the
        // persistent `galleryState.selectedPaths` which was retired on
        // 2026-04-16.
        let selectedLifestylePaths = yellowSelection
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
        let loraDirectory = ProjectPaths(root: animateURL.deletingLastPathComponent())
            .characterLora(slug: character.assetFolderSlug)
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
        let url = ProjectPaths(root: animateURL.deletingLastPathComponent())
            .characterLora(slug: character.assetFolderSlug)
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

// MARK: - displayedPaths invalidator

/// Combined visibility signature. Hashes all of the per-path state that
/// `isPathVisibleInGallery` reads so the surrounding view can observe a
/// single value instead of chaining 6 separate `.onChange` modifiers
/// (which tips SwiftUI's type-checker over the expression-complexity
/// cliff on the already-large `inspirationSection` body).
struct ImagineGalleryVisibilitySignature: Hashable {
    let filterRaw: String
    let minRating: Int
    let rejected: Set<String>
    let reviewed: Set<String>
    let ratings: [String: Int]?
    let selected: Set<String>
    let lora: Set<String>
}

private struct DisplayedPathsInvalidator: ViewModifier {
    let signature: ImagineGalleryVisibilitySignature
    let recompute: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: signature) { _, _ in recompute() }
    }
}
