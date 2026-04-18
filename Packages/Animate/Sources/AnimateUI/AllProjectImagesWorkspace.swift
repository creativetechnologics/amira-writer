import AppKit
import SwiftUI
import ProjectKit

// MARK: - Shared State (observable across the 3 panes)

/// Single source of truth for the All Project Images workspace.
/// Owned by the workspace content view and shared into the sidebar, page,
/// and inspector so every pane stays in sync without binding boilerplate.
@available(macOS 26.0, *)
@Observable @MainActor
final class AllProjectImagesState {
    // Filter / selection
    var selectedSource: AllProjectImagesSource? = nil
    var selectedRecordID: String? = nil
    var sortMode: AllProjectImagesSortMode = .newest
    var thumbnailSize: CGFloat = 140
    var searchText: String = ""
    var inspectorTab: AllProjectImagesInspectorTab = .details

    // Edit-with-Gemini state
    var editAdjustments: String = ""
    var editModel: GeminiModel = .flash
    var editAspectRatio: String = "1:1"
    var editImageSize: String = "1K"
    var editPendingDrafts: [GeminiGenerationDraft] = []
    var editPendingPreflight: GeminiGenerationDraft? = nil
    var editErrorMessage: String? = nil

    // Memoized record set (rebuilt only when the path signature changes).
    var cachedAllRecords: [ProjectImageRecord] = []
    var lastBuildSignature: Int = -1

    // MARK: - Aggregation

    /// Lightweight hash of every path collection's `.count`. Used as `.task(id:)`
    /// so we only rebuild `cachedAllRecords` — which does per-record FileManager
    /// syscalls — when the set of paths actually changed. Typing in the search
    /// field does NOT change this, so no rebuild, no beachball.
    func recordsSignature(store: AnimateStore) -> Int {
        var h = 1469598103934665603 & Int.max
        func mix(_ v: Int) { h = (h ^ v) &* 1099511628211 }
        for p in store.backgrounds {
            mix(p.imagePaths.count)
            mix(p.animatedImagePaths.count &<< 3)
        }
        mix(store.canvasGenerations.count &<< 7)
        mix(store.placesWorkflowLibrary.generatedImageRecords.count &<< 11)
        for c in store.characters {
            mix(c.inspirationImagePaths.count)
            mix(c.referenceImagePaths.count &<< 2)
            mix(c.animatedImagePaths.count &<< 4)
        }
        for (_, galleries) in store.imagineSceneGalleries {
            for g in galleries {
                mix(g.beginningImagePaths.count)
                mix(g.middleImagePaths.count &<< 2)
                mix(g.endImagePaths.count &<< 4)
            }
        }
        return h
    }

    func rebuildIfNeeded(store: AnimateStore) {
        let sig = recordsSignature(store: store)
        if sig == lastBuildSignature { return }
        cachedAllRecords = buildAllRecords(store: store)
        lastBuildSignature = sig
    }

    private func buildAllRecords(store: AnimateStore) -> [ProjectImageRecord] {
        var records: [ProjectImageRecord] = []

        for place in store.backgrounds {
            for path in place.imagePaths {
                records.append(makeRecord(
                    id: "place-\(place.id.uuidString)-\(path)",
                    path: path,
                    source: .places,
                    originLabel: place.name.isEmpty ? "Place" : place.name,
                    store: store
                ))
            }
            for path in place.animatedImagePaths {
                records.append(makeRecord(
                    id: "place-anim-\(place.id.uuidString)-\(path)",
                    path: path,
                    source: .places,
                    originLabel: "\(place.name) (animated)",
                    store: store
                ))
            }
        }

        for record in store.placesWorkflowLibrary.generatedImageRecords {
            let activePath = record.activePath
            guard !activePath.isEmpty else { continue }
            let isMap3D = record.keywords.contains("map3d-capture")
            let origin: String
            if isMap3D {
                origin = "3D Map Capture"
            } else if let placeID = record.linkedPlaceID,
                      let place = store.backgrounds.first(where: { $0.id == placeID }) {
                origin = place.name
            } else {
                origin = "Unattached"
            }
            records.append(makeRecord(
                id: "placelib-\(record.id.uuidString)",
                path: activePath,
                source: isMap3D ? .map3dCaptures : .places,
                originLabel: origin,
                store: store
            ))
        }

        for gen in store.canvasGenerations {
            records.append(makeRecord(
                id: "canvas-\(gen.id.uuidString)",
                path: gen.imagePath,
                source: .canvas,
                originLabel: gen.prompt.isEmpty ? "Canvas generation" : String(gen.prompt.prefix(50)),
                store: store
            ))
        }

        for character in store.characters {
            let originBase = character.name.isEmpty ? "Character" : character.name
            for path in character.inspirationImagePaths {
                records.append(makeRecord(
                    id: "char-insp-\(character.id.uuidString)-\(path)",
                    path: path,
                    source: .characters,
                    originLabel: "\(originBase) (inspiration)",
                    store: store
                ))
            }
            for path in character.referenceImagePaths {
                records.append(makeRecord(
                    id: "char-ref-\(character.id.uuidString)-\(path)",
                    path: path,
                    source: .characters,
                    originLabel: "\(originBase) (reference)",
                    store: store
                ))
            }
            for path in character.animatedImagePaths {
                records.append(makeRecord(
                    id: "char-anim-\(character.id.uuidString)-\(path)",
                    path: path,
                    source: .characters,
                    originLabel: "\(originBase) (animated)",
                    store: store
                ))
            }
        }

        for (_, galleries) in store.imagineSceneGalleries {
            for gallery in galleries {
                for (moment, paths) in [
                    (ImagineShotMoment.beginning, gallery.beginningImagePaths),
                    (ImagineShotMoment.middle, gallery.middleImagePaths),
                    (ImagineShotMoment.end, gallery.endImagePaths)
                ] {
                    for path in paths {
                        records.append(makeRecord(
                            id: "shot-\(gallery.id.uuidString)-\(moment.rawValue)-\(path)",
                            path: path,
                            source: .sceneShots,
                            originLabel: "Shot (\(moment.rawValue))",
                            store: store
                        ))
                    }
                }
            }
        }

        return records
    }

    private func makeRecord(
        id: String,
        path: String,
        source: AllProjectImagesSource,
        originLabel: String,
        store: AnimateStore
    ) -> ProjectImageRecord {
        let resolved = store.resolvedCharacterAssetURL(for: path)?.path ?? path
        var created: Date? = nil
        var size: Int64? = nil
        if FileManager.default.fileExists(atPath: resolved),
           let attrs = try? FileManager.default.attributesOfItem(atPath: resolved) {
            created = attrs[.creationDate] as? Date ?? attrs[.modificationDate] as? Date
            size = (attrs[.size] as? NSNumber)?.int64Value
        }
        return ProjectImageRecord(
            id: id,
            path: path,
            resolvedPath: resolved,
            source: source,
            originLabel: originLabel,
            createdAt: created,
            sizeBytes: size
        )
    }

    // MARK: - Filter + Sort

    var filteredRecords: [ProjectImageRecord] {
        var records = cachedAllRecords
        if let source = selectedSource {
            records = records.filter { $0.source == source }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if !query.isEmpty {
            records = records.filter {
                $0.path.lowercased().contains(query)
                    || $0.originLabel.lowercased().contains(query)
            }
        }
        switch sortMode {
        case .newest:
            records.sort { (lhs, rhs) in
                (lhs.createdAt ?? .distantPast) > (rhs.createdAt ?? .distantPast)
            }
        case .oldest:
            records.sort { (lhs, rhs) in
                (lhs.createdAt ?? .distantFuture) < (rhs.createdAt ?? .distantFuture)
            }
        case .name:
            records.sort { (lhs, rhs) in
                (lhs.path as NSString).lastPathComponent
                    .localizedCompare((rhs.path as NSString).lastPathComponent) == .orderedAscending
            }
        }
        return records
    }

    var selectedRecord: ProjectImageRecord? {
        guard let id = selectedRecordID else { return nil }
        return filteredRecords.first(where: { $0.id == id })
            ?? cachedAllRecords.first(where: { $0.id == id })
    }

    func count(for source: AllProjectImagesSource) -> Int {
        cachedAllRecords.lazy.filter { $0.source == source }.count
    }
}

// MARK: - Public Workspace (consumed by OperaShellView)

@available(macOS 26.0, *)
public struct AllProjectImagesWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            AllProjectImagesWorkspaceContent(store: controller.store)
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening All Images" : "Refreshing All Images",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

// MARK: - Three-Pane Content

@available(macOS 26.0, *)
private struct AllProjectImagesWorkspaceContent: View {
    @Bindable var store: AnimateStore
    @State private var state = AllProjectImagesState()

    @AppStorage("novotro.allImages.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.allImages.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.allImages.showInspector") private var inspectorVisible = true
    @AppStorage("novotro.allImages.inspector.width") private var inspectorWidth: Double = 340

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "photo.on.rectangle.angled",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
            }
        }
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            // MARK: Left Sidebar
            if sidebarVisible {
                OperaChromeFlatPane(
                    headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                    OperaChromePaneHeader(
                        eyebrow: "ALL IMAGES",
                        title: "Sources",
                        subtitle: state.cachedAllRecords.isEmpty
                            ? "No images yet"
                            : "\(state.cachedAllRecords.count) total"
                    ) {
                        OperaChromeActionButton(systemImage: "sidebar.left") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible = false
                            }
                        }
                    }
                } content: {
                    AllProjectImagesSidebarView(store: store, state: state)
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            // MARK: Center Pane (header + grid)
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
                        Text("ALL IMAGES")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(centerPaneTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text(centerPaneSubtitle)
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
                AllProjectImagesPageView(store: store, state: state)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: Right Inspector
            if inspectorVisible {
                // Raise the split handle on top of everything so the
                // inspector's ScrollView + the picture view below it can't
                // shadow the 10px-wide gesture zone (that's how this handle
                // went invisible once a record was selected — the ScrollView
                // drawn inside the inspector pane registered hover/hit
                // regions a few pixels into the handle's strip).
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )
                .zIndex(2)

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: "All Images"
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = false
                            }
                        }
                    }
                } content: {
                    AllProjectImagesInspectorView(store: store, state: state)
                }
                .frame(width: max(inspectorWidth, 280))
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
        // Preflight + alerts attach at the workspace root so they fire whether
        // or not the inspector is visible (grid's right-click "Generate with
        // Gemini" can open the preflight sheet from the cell context menu).
        .sheet(item: $state.editPendingPreflight) { _ in
            GeminiGenerationPreflightSheet(
                store: store,
                drafts: $state.editPendingDrafts,
                title: "Edit with Gemini",
                confirmTitle: "Generate",
                onConfirm: { finalDrafts, _ in
                    let sourceRecord = state.selectedRecord
                    state.editPendingPreflight = nil
                    runEditGeneration(finalDrafts, sourceRecord: sourceRecord)
                },
                onCancel: {
                    state.editPendingPreflight = nil
                    state.editPendingDrafts = []
                }
            )
        }
        .alert(
            "Generation Error",
            isPresented: Binding(
                get: { state.editErrorMessage != nil },
                set: { if !$0 { state.editErrorMessage = nil } }
            ),
            actions: { Button("OK") { state.editErrorMessage = nil } },
            message: { Text(state.editErrorMessage ?? "") }
        )
    }

    private var centerPaneTitle: String {
        state.selectedSource?.displayName ?? "All Images"
    }

    private var centerPaneSubtitle: String {
        let shown = state.filteredRecords.count
        let total = state.cachedAllRecords.count
        if total == 0 { return "No images indexed" }
        if shown == total { return "\(total) image\(total == 1 ? "" : "s")" }
        return "\(shown) of \(total)"
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        // Anchor off the larger of the persisted value or the clamp floor
        // before subtracting the delta. Without this, a previously saved
        // width below 280 would stay stuck at 280 visually but drift under
        // the hood, making drags feel unresponsive until you pulled enough
        // pixels to overcome the accumulated offset.
        let anchor = max(inspectorWidth, 280.0)
        inspectorWidth = min(max(anchor - Double(delta), 280.0), 600.0)
    }

    // MARK: - Generate pipeline (lives at workspace root so both the grid's
    // context-menu "Generate with Gemini" and the inspector's "Edit with
    // Gemini" surface flow through the same sheet + activity tracker).

    private func runEditGeneration(
        _ drafts: [GeminiGenerationDraft],
        sourceRecord: ProjectImageRecord?
    ) {
        guard store.isGeminiAllowed() else {
            state.editErrorMessage = "Gemini API calls are blocked. Enable Gemini API Calls in Inspector > Tools."
            return
        }
        Task { @MainActor in
            let service = GeminiImageService()
            var finishedCount = 0
            for draft in drafts {
                let activityID = store.registerGeminiActivity(
                    kind: .immediate,
                    title: draft.title,
                    source: "All Images • Edit with Gemini"
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
                    source: "AllProjectImagesWorkspace.runEditGeneration()"
                )
                do {
                    let result = try await service.generate(request: request, apiKey: store.geminiAPIKey)
                    let storedPath = try store.storeUnattachedGeneratedImage(
                        imageData: result.imageData,
                        prompt: draft.effectivePrompt,
                        model: draft.model,
                        aspectRatio: draft.aspectRatio,
                        imageSize: draft.imageSize
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
                    state.editErrorMessage = error.localizedDescription
                    break
                }
            }
            if finishedCount > 0 {
                store.statusMessage = "Generated \(finishedCount) edited image\(finishedCount == 1 ? "" : "s")"
                state.editAdjustments = ""
            }
            _ = sourceRecord // reserved for future routing (filing back to origin place)
            state.editPendingDrafts = []
        }
    }
}

// MARK: - Left Sidebar (source filter)

@available(macOS 26.0, *)
private struct AllProjectImagesSidebarView: View {
    @Bindable var store: AnimateStore
    @Bindable var state: AllProjectImagesState

    var body: some View {
        List {
            Section {
                sidebarRow(
                    title: "All",
                    systemImage: "photo.on.rectangle.angled",
                    count: state.cachedAllRecords.count,
                    isSelected: state.selectedSource == nil
                ) {
                    state.selectedSource = nil
                }
            }

            Section("Sources") {
                ForEach(AllProjectImagesSource.allCases) { source in
                    sidebarRow(
                        title: source.displayName,
                        systemImage: source.systemImage,
                        count: state.count(for: source),
                        isSelected: state.selectedSource == source
                    ) {
                        state.selectedSource = source
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sidebarRow(
        title: String,
        systemImage: String,
        count: Int,
        isSelected: Bool,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(title)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected ? Color.accentColor.opacity(0.18) : Color.clear
        )
    }
}

// MARK: - Right Inspector (Details | Edit with Gemini)

@available(macOS 26.0, *)
private struct AllProjectImagesInspectorView: View {
    @Bindable var store: AnimateStore
    @Bindable var state: AllProjectImagesState

    var body: some View {
        Group {
            if let record = state.selectedRecord {
                VStack(spacing: 0) {
                    Picker("", selection: $state.inspectorTab) {
                        ForEach(AllProjectImagesInspectorTab.allCases) { tab in
                            Text(tab.displayName).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .padding(.bottom, 8)

                    Divider()

                    switch state.inspectorTab {
                    case .details:
                        detailsTab(for: record)
                    case .generate:
                        generateTab(for: record)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 32))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text("No image selected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text("Click a thumbnail to see details or right-click to edit with Gemini.")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            }
        }
    }

    // MARK: Details tab

    @ViewBuilder
    private func detailsTab(for record: ProjectImageRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Use a fixed 240x240 thumbnail (smaller than the 280 min
                // inspector width) so it can NEVER overflow into the split
                // handle's gesture zone when the user shrinks the inspector.
                CachedThumbnailView(path: record.resolvedPath, size: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .leading)

                detailRow(label: "Source", value: record.source.displayName)
                detailRow(label: "Origin", value: record.originLabel)
                if let date = record.createdAt {
                    detailRow(label: "Created", value: dateFormatter.string(from: date))
                }
                if let size = record.sizeBytes {
                    detailRow(label: "Size", value: byteFormatter.string(fromByteCount: size))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Path")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(record.path)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: record.resolvedPath)]
                        )
                    }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.resolvedPath, forType: .string)
                    }
                }
                .font(.system(size: 11))
            }
            .padding(14)
        }
    }

    // MARK: Generate tab

    @ViewBuilder
    private func generateTab(for record: ProjectImageRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CachedThumbnailView(path: record.resolvedPath, size: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Uses this image as the reference; output lands in Places → Unattached where you can re-file it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Adjustments")
                        .font(.system(size: 11, weight: .medium))
                    TextEditor(text: $state.editAdjustments)
                        .font(.system(size: 11))
                        .frame(minHeight: 80, maxHeight: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                        )
                }

                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Model").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $state.editModel) {
                            ForEach(GeminiModel.allCases, id: \.self) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aspect").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $state.editAspectRatio) {
                            ForEach(["1:1", "2:3", "3:4", "4:5", "4:3", "16:9", "21:9"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Size").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $state.editImageSize) {
                            ForEach(["1K", "2K", "4K"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                }

                Button {
                    openPreflight(for: record)
                } label: {
                    Label("Open Preflight…", systemImage: "sparkles")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(state.editAdjustments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(14)
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
        }
    }

    // MARK: Preflight trigger (Edit-with-Gemini tab button)

    private func openPreflight(for record: ProjectImageRecord) {
        let adjustments = state.editAdjustments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adjustments.isEmpty else { return }
        let reference = GeminiGenerationReferenceDraft(
            label: URL(fileURLWithPath: record.resolvedPath)
                .deletingPathExtension()
                .lastPathComponent,
            path: record.resolvedPath,
            isIncluded: true
        )
        let draft = GeminiGenerationDraft(
            title: "Edit: \(record.originLabel)",
            destinationDescription: "Places → Unattached library",
            prompt: "",
            model: state.editModel,
            aspectRatio: state.editAspectRatio,
            imageSize: state.editImageSize,
            referenceItems: [reference],
            editInstructions: adjustments
        )
        state.editPendingDrafts = [draft]
        state.editPendingPreflight = draft
    }

    // MARK: Formatters

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    private var byteFormatter: ByteCountFormatter {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }
}
