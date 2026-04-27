import AppKit
import Observation
import ProjectKit
import Quartz
import SwiftUI

@available(macOS 26.0, *)
public struct CanvasWorkspace: View {
    private let controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        self.controller = controller
    }

    public var body: some View {
        ZStack {
            CanvasWorkspaceContent(
                store: controller.store,
                libraryState: controller.canvasLibraryState,
                canvasFormState: controller.canvasFormState
            )
            .environment(\.unifiedImageFlipHandler) { path in
                controller.store.flipImageHorizontallyAndAttachLikeOriginal(path: path)
            }
            .environment(\.unifiedImageRecategorizeHandler) { path, category in
                controller.store.recategorizeImageReviewScope(path: path, semanticRole: category.semanticRole)
            }

            CanvasWorkspaceLoadingOverlay(controller: controller)
        }
    }
}

@available(macOS 26.0, *)
private struct CanvasWorkspaceLoadingOverlay: View {
    @ObservedObject var controller: AnimateWorkspaceController

    var body: some View {
        let isBusy = controller.isLoadingProject || controller.isSelectionRestorePending
        Group {
            if isBusy {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Canvas" : "Refreshing Canvas",
                    message: controller.loadStatusMessage
                )
                .background(Color.black.opacity(0.001))
            }
        }
        .allowsHitTesting(isBusy)
    }
}

@available(macOS 26.0, *)
private struct CanvasWorkspaceContent: View {
    @Bindable var store: AnimateStore
    @Bindable var libraryState: AllProjectImagesState
    @Bindable var canvasFormState: CanvasFormState
    @State private var selectedGenerationID: UUID? = nil

    @AppStorage("novotro.canvas.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.canvas.sidebar.width") private var sidebarWidth: Double = 420
    @AppStorage("novotro.canvas.showInspector") private var inspectorVisible = true
    @AppStorage("novotro.canvas.inspector.width") private var inspectorWidth: Double = 340

    private var projectTitle: String {
        store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "paintpalette",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
                    .sheet(item: $libraryState.edit.pendingPreflight) { _ in
                        GeminiGenerationPreflightSheet(
                            store: store,
                            drafts: $libraryState.edit.pendingDrafts,
                            title: "Edit with Gemini",
                            confirmTitle: "Generate",
                            onConfirm: { finalDrafts, _ in
                                if let first = finalDrafts.first {
                                    libraryState.edit.aspectRatio = first.aspectRatio
                                    libraryState.edit.imageSize = first.imageSize
                                }
                                let sourceRecord = libraryState.selectedRecord
                                libraryState.edit.pendingPreflight = nil
                                runLibraryEditGeneration(finalDrafts, sourceRecord: sourceRecord)
                            },
                            onCancel: {
                                if let first = libraryState.edit.pendingDrafts.first {
                                    libraryState.edit.aspectRatio = first.aspectRatio
                                    libraryState.edit.imageSize = first.imageSize
                                }
                                libraryState.edit.pendingPreflight = nil
                                libraryState.edit.pendingDrafts = []
                            }
                        )
                        .onChange(of: libraryState.edit.pendingDrafts.first?.aspectRatio) { _, newValue in
                            if let newValue { libraryState.edit.aspectRatio = newValue }
                        }
                        .onChange(of: libraryState.edit.pendingDrafts.first?.imageSize) { _, newValue in
                            if let newValue { libraryState.edit.imageSize = newValue }
                        }
                    }
                    .alert(
                        "Generation Error",
                        isPresented: Binding(
                            get: { libraryState.edit.errorMessage != nil },
                            set: { if !$0 { libraryState.edit.errorMessage = nil } }
                        ),
                        actions: { Button("OK") { libraryState.edit.errorMessage = nil } },
                        message: { Text(libraryState.edit.errorMessage ?? "") }
                    )
            }
        }
        .onAppear {
            store.refreshGeneratedBackgroundLibraryIfNeededInBackground()
            ensureValidCanvasSelection()
        }
        .onChange(of: canvasGenerationSelectionSignature) { _, _ in
            ensureValidCanvasSelection()
        }
    }

    private struct CanvasGenerationSelectionSignature: Equatable {
        var revision: Int
    }

    private var canvasGenerationSelectionSignature: CanvasGenerationSelectionSignature {
        CanvasGenerationSelectionSignature(revision: store.canvasGenerationsRevision)
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                OperaChromeFlatPane(
                    headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                    OperaChromePaneHeader(
                        eyebrow: "ALL IMAGES",
                        title: "Library",
                        subtitle: libraryState.cachedAllRecords.isEmpty
                            ? "No images yet"
                            : "\(libraryState.cachedAllRecords.count) total"
                    ) {
                        OperaChromeActionButton(systemImage: "sidebar.left") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible = false
                            }
                        }
                    }
                } content: {
                    AllProjectImagesPageView(
                        store: store,
                        state: libraryState,
                        layout: .canvasSidebar
                    )
                }
                .frame(width: max(sidebarWidth, 320))

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    if !sidebarVisible {
                        OperaChromeActionButton(systemImage: "sidebar.left") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible = true
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("CANVAS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(projectTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text("Free-form image generation with shared references")
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    if !inspectorVisible {
                        OperaChromeActionButton(systemImage: "sidebar.right") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = true
                            }
                        }
                    }
                }
            } content: {
                ImagineCanvasPageView(
                    store: store,
                    canvasState: canvasFormState,
                    selectedGenerationID: $selectedGenerationID
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )
                .zIndex(2)

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "CANVAS",
                        title: "Inspector",
                        subtitle: "Generations"
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = false
                            }
                        }
                    }
                } content: {
                    CanvasInspectorView(
                        store: store,
                        selectedGenerationID: $selectedGenerationID
                    )
                }
                .frame(width: max(inspectorWidth, 280))
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), 320),
            760
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        let anchor = max(inspectorWidth, 280.0)
        inspectorWidth = min(max(anchor - Double(delta), 280.0), 600.0)
    }

    private func ensureValidCanvasSelection() {
        let sorted = store.canvasGenerationsNewestFirst()
        guard !sorted.isEmpty else {
            selectedGenerationID = nil
            return
        }
        if let selectedGenerationID,
           sorted.contains(where: { $0.id == selectedGenerationID }) {
            return
        }
        self.selectedGenerationID = sorted.first?.id
    }

    private func runLibraryEditGeneration(
        _ drafts: [GeminiGenerationDraft],
        sourceRecord: ProjectImageRecord?
    ) {
        if let error = store.geminiImageGenerationAvailabilityError {
            libraryState.edit.errorMessage = error.localizedDescription
            return
        }
        Task { @MainActor in
            let service = GeminiImageService()
            var finishedCount = 0
            for draft in drafts {
                let activityID = store.registerGeminiActivity(
                    kind: .immediate,
                    title: draft.title,
                    source: "Canvas • All Images • Edit with Gemini"
                )
                let refs: [GeminiImageService.ReferenceImage] = draft.referenceItems
                    .filter(\.isIncluded)
                    .compactMap { ref in
                        let url = store.resolvedCharacterAssetURL(for: ref.path)
                            ?? (ref.path.hasPrefix("/") ? URL(fileURLWithPath: ref.path) : nil)
                        guard let url else { return nil }
                        return GeminiImageService.referenceImage(from: url)
                    }
                let request = GeminiImageService.GenerationRequest(
                    prompt: draft.effectivePrompt,
                    referenceImages: refs,
                    model: draft.model,
                    aspectRatio: draft.aspectRatio,
                    imageSize: draft.imageSize
                )
                store.logGeminiAPICall(
                    endpoint: "image-generation",
                    source: "CanvasWorkspace.runLibraryEditGeneration()"
                )
                do {
                    let result = try await service.generate(request: request, apiKey: store.geminiAPIKey)
                    let storedPath = try store.storeUnattachedGeneratedImage(
                        imageData: result.imageData,
                        prompt: draft.effectivePrompt,
                        model: draft.model,
                        aspectRatio: draft.aspectRatio,
                        imageSize: draft.imageSize,
                        referencePaths: draft.referenceItems.filter(\.isIncluded).map(\.path)
                    )
                    store.updateGeminiActivity(
                        activityID,
                        status: .completed,
                        outputFilename: URL(fileURLWithPath: storedPath).lastPathComponent
                    )
                    finishedCount += 1
                } catch {
                    store.updateGeminiActivity(
                        activityID,
                        status: .failed,
                        errorMessage: error.localizedDescription
                    )
                    libraryState.edit.errorMessage = error.localizedDescription
                    break
                }
            }
            if finishedCount > 0 {
                store.statusMessage = "Generated \(finishedCount) edited image\(finishedCount == 1 ? "" : "s")"
                libraryState.edit.adjustments = ""
            }
            _ = sourceRecord
            libraryState.edit.pendingDrafts = []
        }
    }
}

@available(macOS 26.0, *)
private struct CanvasInspectorView: View {
    @Bindable var store: AnimateStore
    @Binding var selectedGenerationID: UUID?
    @FocusState private var recentGenerationsKeyboardFocused: Bool
    @State private var quickLookKeyMonitor: Any?

    private func sortedGenerations() -> [AnimateStore.CanvasGeneration] {
        store.canvasGenerationsNewestFirst()
    }

    private func selectedGeneration(
        from generations: [AnimateStore.CanvasGeneration]
    ) -> AnimateStore.CanvasGeneration? {
        guard let selectedGenerationID else { return generations.first }
        return generations.first(where: { $0.id == selectedGenerationID }) ?? generations.first
    }

    var body: some View {
        let generations = sortedGenerations()
        let selectedGeneration = selectedGeneration(from: generations)

        VStack(spacing: 0) {
            if generations.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "paintpalette")
                        .font(.system(size: 28))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text("No generations yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text("Generate on the canvas and the history will appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recent Generations")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(OperaChromeTheme.textSecondary)

                            ForEach(generations) { generation in
                                CanvasInspectorRow(
                                    generation: generation,
                                    isSelected: selectedGeneration?.id == generation.id
                                ) {
                                    selectedGenerationID = generation.id
                                    recentGenerationsKeyboardFocused = true
                                }
                            }
                        }

                        if let generation = selectedGeneration {
                            Divider()

                            VStack(alignment: .leading, spacing: 10) {
                                AsyncResolvedImageView(
                                    path: generation.imagePath,
                                    maxPixelSize: 1200,
                                    contentMode: .fit
                                )
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .frame(maxWidth: .infinity)
                                .frame(height: 220)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(.black.opacity(0.12))
                                )

                                detailRow("Prompt", generation.prompt)
                                detailRow("Model", generation.model.displayName)
                                detailRow("Aspect", generation.aspectRatio)
                                detailRow("Size", generation.imageSize)
                                detailRow("References", "\(generation.referenceCount)")
                                detailRow("Created", generation.createdAt.formatted(date: .abbreviated, time: .shortened))

                                HStack(spacing: 8) {
                                    Button("Reveal in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([
                                            URL(fileURLWithPath: generation.imagePath)
                                        ])
                                    }
                                    .buttonStyle(.bordered)

                                    Button("Copy Prompt") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(generation.prompt, forType: .string)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                    .padding(14)
                }
                .focusable()
                .focused($recentGenerationsKeyboardFocused)
                .focusEffectDisabled()
                .onTapGesture {
                    recentGenerationsKeyboardFocused = true
                }
                .onKeyPress(.space) {
                    openQuickLook(generations: generations, selected: selectedGeneration)
                    return selectedGeneration == nil ? .ignored : .handled
                }
                .onKeyPress(.upArrow) {
                    navigateSelection(delta: -1, generations: generations)
                }
                .onKeyPress(.downArrow) {
                    navigateSelection(delta: 1, generations: generations)
                }
            }
        }
        .onAppear {
            ensureSelection(in: generations)
            recentGenerationsKeyboardFocused = true
            installQuickLookKeyMonitor()
        }
        .onChange(of: generations.map(\.id)) { _, _ in
            ensureSelection(in: generations)
        }
        .onDisappear {
            removeQuickLookKeyMonitor()
        }
    }


    private func navigateSelection(delta: Int, generations: [AnimateStore.CanvasGeneration]) -> KeyPress.Result {
        guard !generations.isEmpty else { return .ignored }
        let currentIndex = selectedGenerationID.flatMap { selected in
            generations.firstIndex(where: { $0.id == selected })
        } ?? 0
        let newIndex = min(max(currentIndex + delta, 0), generations.count - 1)
        selectedGenerationID = generations[newIndex].id
        if let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.currentPreviewItemIndex = newIndex
        }
        return .handled
    }

    private func installQuickLookKeyMonitor() {
        guard quickLookKeyMonitor == nil else { return }
        quickLookKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard QLPreviewPanel.sharedPreviewPanelExists(),
                  let panel = QLPreviewPanel.shared(),
                  panel.isVisible else {
                return event
            }
            switch event.keyCode {
            case 126: // Up arrow
                _ = navigateSelection(delta: -1, generations: sortedGenerations())
                return nil
            case 125: // Down arrow
                _ = navigateSelection(delta: 1, generations: sortedGenerations())
                return nil
            default:
                return event
            }
        }
    }

    private func removeQuickLookKeyMonitor() {
        if let quickLookKeyMonitor {
            NSEvent.removeMonitor(quickLookKeyMonitor)
            self.quickLookKeyMonitor = nil
        }
    }

    private func openQuickLook(generations: [AnimateStore.CanvasGeneration], selected: AnimateStore.CanvasGeneration?) {
        guard let selected else { return }
        let urls = generations.map { URL(fileURLWithPath: $0.imagePath) }
        let index = generations.firstIndex(where: { $0.id == selected.id }) ?? 0
        ImagineQuickLook.preview(urls: urls, selectedIndex: index)
    }

    @ViewBuilder
    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ensureSelection(in generations: [AnimateStore.CanvasGeneration]) {
        guard !generations.isEmpty else {
            selectedGenerationID = nil
            return
        }
        if let selectedGenerationID,
           generations.contains(where: { $0.id == selectedGenerationID }) {
            return
        }
        self.selectedGenerationID = generations.first?.id
    }
}

@available(macOS 26.0, *)
private struct CanvasInspectorRow: View {
    let generation: AnimateStore.CanvasGeneration
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 8) {
                CachedThumbnailView(path: generation.imagePath, size: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .frame(width: 72, height: 72)

                VStack(alignment: .leading, spacing: 4) {
                    Text(generation.prompt)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .lineLimit(3)
                    Text("\(generation.model.displayName) · \(generation.aspectRatio) · \(generation.imageSize)")
                        .font(.system(size: 10))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text(generation.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }

                Spacer(minLength: 0)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .draggable(URL(fileURLWithPath: generation.imagePath))
    }
}
