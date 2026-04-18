import SwiftUI
import AppKit

@available(macOS 26.0, *)
enum AllProjectImagesSource: String, CaseIterable, Identifiable, Hashable {
    case places
    case canvas
    case characters
    case sceneShots
    case map3dCaptures

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .places: "Places"
        case .canvas: "Canvas"
        case .characters: "Characters"
        case .sceneShots: "Scene Shots"
        case .map3dCaptures: "Map 3D Captures"
        }
    }

    var systemImage: String {
        switch self {
        case .places: "map"
        case .canvas: "paintpalette"
        case .characters: "person.2"
        case .sceneShots: "film.stack"
        case .map3dCaptures: "camera.macro"
        }
    }
}

@available(macOS 26.0, *)
struct ProjectImageRecord: Identifiable, Hashable {
    let id: String
    let path: String
    let resolvedPath: String
    let source: AllProjectImagesSource
    let originLabel: String
    let createdAt: Date?
    let sizeBytes: Int64?
}

@available(macOS 26.0, *)
enum AllProjectImagesInspectorTab: String, CaseIterable, Identifiable, Hashable {
    case details
    case generate

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .details: "Details"
        case .generate: "Edit with Gemini"
        }
    }
}

@available(macOS 26.0, *)
enum AllProjectImagesSortMode: String, CaseIterable, Identifiable, Hashable {
    case newest
    case oldest
    case name

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .name: "Name"
        }
    }
}

@available(macOS 26.0, *)
struct AllProjectImagesPageView: View {
    @Bindable var store: AnimateStore
    /// Optional dismiss closure. When nil (the common case, since this page is
    /// now hosted as a top-level tab in the Opera shell), no close button is
    /// rendered. Pre-existing sheet callsites can still pass a dismiss handler.
    var onDismiss: (() -> Void)?

    @State private var selectedSource: AllProjectImagesSource? = nil
    @State private var selectedRecordID: String? = nil
    @State private var sortMode: AllProjectImagesSortMode = .newest
    @State private var thumbnailSize: CGFloat = 140
    @State private var searchText: String = ""
    @State private var inspectorTab: AllProjectImagesInspectorTab = .details
    @State private var editAdjustments: String = ""
    @State private var editModel: GeminiModel = .flash
    @State private var editAspectRatio: String = "1:1"
    @State private var editImageSize: String = "1K"
    @State private var editPendingDrafts: [GeminiGenerationDraft] = []
    @State private var editPendingPreflight: GeminiGenerationDraft? = nil
    @State private var editErrorMessage: String? = nil
    @State private var cachedAllRecords: [ProjectImageRecord] = []
    @State private var lastBuildSignature: Int = -1

    init(store: AnimateStore, onDismiss: (() -> Void)? = nil) {
        self.store = store
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 220)
                Divider()
                gridSection
                if selectedRecord != nil {
                    Divider()
                    inspector
                        .frame(width: 320)
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 700)
        .task(id: recordsSignature) {
            let sig = recordsSignature
            if sig == lastBuildSignature { return }
            cachedAllRecords = buildAllRecords()
            lastBuildSignature = sig
        }
        .task(id: prefetchKey) {
            let paths = filteredRecords.prefix(120).map(\.resolvedPath)
            let pixel = Int(thumbnailSize * 2)
            ImagineThumbnailCache.shared.prefetch(paths: paths, maxPixelSize: pixel)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
            }

            Text("All Project Images")
                .font(.system(size: 16, weight: .semibold))

            Text("\(filteredRecords.count) of \(cachedAllRecords.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            TextField("Search paths or names…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Picker("Sort", selection: $sortMode) {
                ForEach(AllProjectImagesSortMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            HStack(spacing: 4) {
                Image(systemName: "photo")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Slider(value: $thumbnailSize, in: 80...260)
                    .frame(width: 110)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List(selection: $selectedSource) {
            Section {
                HStack {
                    Image(systemName: "photo.on.rectangle.angled")
                        .frame(width: 18)
                    Text("All")
                    Spacer()
                    Text("\(cachedAllRecords.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { selectedSource = nil }
                .listRowBackground(
                    selectedSource == nil
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear
                )
            }

            Section("Sources") {
                ForEach(AllProjectImagesSource.allCases) { source in
                    let count = cachedAllRecords.filter { $0.source == source }.count
                    HStack {
                        Image(systemName: source.systemImage)
                            .frame(width: 18)
                            .foregroundStyle(.secondary)
                        Text(source.displayName)
                        Spacer()
                        Text("\(count)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .tag(source)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Grid

    @ViewBuilder
    private var gridSection: some View {
        if filteredRecords.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No images in this view")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 10)],
                    spacing: 10
                ) {
                    ForEach(filteredRecords) { record in
                        thumbnailCell(for: record)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private func thumbnailCell(for record: ProjectImageRecord) -> some View {
        let isSelected = selectedRecordID == record.id
        UnifiedImageTile(
            path: record.path,
            resolvedPath: record.resolvedPath,
            thumbnailSize: thumbnailSize,
            caption: record.originLabel,
            sourceLabel: record.source.displayName,
            sourceSystemImage: record.source.systemImage,
            isSelected: isSelected,
            actions: UnifiedImageActions(
                onShowInFinder: {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: record.resolvedPath)]
                    )
                },
                onCopy: {
                    if let image = NSImage(contentsOfFile: record.resolvedPath) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    } else {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.resolvedPath, forType: .string)
                    }
                },
                onEditWithGemini: {
                    selectedRecordID = record.id
                    inspectorTab = .generate
                },
                onGenerateWithGemini: { count in
                    beginGenerate(for: record, count: count)
                }
            ),
            onTap: { selectedRecordID = record.id }
        )
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        if let record = selectedRecord {
            VStack(spacing: 0) {
                HStack {
                    Picker("", selection: $inspectorTab) {
                        ForEach(AllProjectImagesInspectorTab.allCases) { tab in
                            Text(tab.displayName).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Spacer()
                    Button(action: { selectedRecordID = nil }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

                Divider()

                switch inspectorTab {
                case .details:
                    detailsTab(for: record)
                case .generate:
                    generateTab(for: record)
                }
            }
            .alert(
                "Generation Error",
                isPresented: Binding(
                    get: { editErrorMessage != nil },
                    set: { if !$0 { editErrorMessage = nil } }
                ),
                actions: { Button("OK") { editErrorMessage = nil } },
                message: { Text(editErrorMessage ?? "") }
            )
            .sheet(item: $editPendingPreflight) { _ in
                GeminiGenerationPreflightSheet(
                    store: store,
                    drafts: $editPendingDrafts,
                    title: "Edit with Gemini",
                    confirmTitle: "Generate",
                    onConfirm: { finalDrafts, _ in
                        editPendingPreflight = nil
                        runEditGeneration(finalDrafts, sourceRecord: record)
                    },
                    onCancel: {
                        editPendingPreflight = nil
                        editPendingDrafts = []
                    }
                )
            }
        }
    }

    @ViewBuilder
    private func detailsTab(for record: ProjectImageRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CachedThumbnailView(path: record.resolvedPath, size: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

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

    @ViewBuilder
    private func generateTab(for record: ProjectImageRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CachedThumbnailView(path: record.resolvedPath, size: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Text("Uses this image as the reference; output lands in Places → Unattached where you can re-file it.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Adjustments")
                        .font(.system(size: 11, weight: .medium))
                    TextEditor(text: $editAdjustments)
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
                        Picker("", selection: $editModel) {
                            ForEach(GeminiModel.allCases, id: \.self) { model in
                                Text(model.displayName).tag(model)
                            }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aspect").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $editAspectRatio) {
                            ForEach(["1:1", "2:3", "3:4", "4:5", "4:3", "16:9", "21:9"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        .labelsHidden()
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Size").font(.system(size: 10, weight: .medium))
                        Picker("", selection: $editImageSize) {
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
                .disabled(editAdjustments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    // MARK: - Aggregation

    /// Lightweight hash of every path collection's `.count`. Used as `.task(id:)`
    /// so we only rebuild `cachedAllRecords` — which does per-record FileManager
    /// syscalls — when the set of paths actually changed. Typing in the search
    /// field does NOT change this, so no rebuild, no beachball.
    private var recordsSignature: Int {
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

    private var prefetchKey: String {
        "\(recordsSignature)|\(selectedSource?.rawValue ?? "all")|\(Int(thumbnailSize))"
    }

    private func buildAllRecords() -> [ProjectImageRecord] {
        var records: [ProjectImageRecord] = []

        for place in store.backgrounds {
            for path in place.imagePaths {
                records.append(makeRecord(
                    id: "place-\(place.id.uuidString)-\(path)",
                    path: path,
                    source: .places,
                    originLabel: place.name.isEmpty ? "Place" : place.name
                ))
            }
            for path in place.animatedImagePaths {
                records.append(makeRecord(
                    id: "place-anim-\(place.id.uuidString)-\(path)",
                    path: path,
                    source: .places,
                    originLabel: "\(place.name) (animated)"
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
                originLabel: origin
            ))
        }

        for gen in store.canvasGenerations {
            records.append(makeRecord(
                id: "canvas-\(gen.id.uuidString)",
                path: gen.imagePath,
                source: .canvas,
                originLabel: gen.prompt.isEmpty ? "Canvas generation" : String(gen.prompt.prefix(50))
            ))
        }

        for character in store.characters {
            let originBase = character.name.isEmpty ? "Character" : character.name
            for path in character.inspirationImagePaths {
                records.append(makeRecord(
                    id: "char-insp-\(character.id.uuidString)-\(path)",
                    path: path,
                    source: .characters,
                    originLabel: "\(originBase) (inspiration)"
                ))
            }
            for path in character.referenceImagePaths {
                records.append(makeRecord(
                    id: "char-ref-\(character.id.uuidString)-\(path)",
                    path: path,
                    source: .characters,
                    originLabel: "\(originBase) (reference)"
                ))
            }
            for path in character.animatedImagePaths {
                records.append(makeRecord(
                    id: "char-anim-\(character.id.uuidString)-\(path)",
                    path: path,
                    source: .characters,
                    originLabel: "\(originBase) (animated)"
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
                            originLabel: "Shot (\(moment.rawValue))"
                        ))
                    }
                }
            }
        }

        return records
    }

    private var filteredRecords: [ProjectImageRecord] {
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

    private var selectedRecord: ProjectImageRecord? {
        guard let id = selectedRecordID else { return nil }
        return filteredRecords.first(where: { $0.id == id })
            ?? cachedAllRecords.first(where: { $0.id == id })
    }

    private func makeRecord(
        id: String,
        path: String,
        source: AllProjectImagesSource,
        originLabel: String
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

    // MARK: - Edit-with-Gemini

    private func openPreflight(for record: ProjectImageRecord) {
        let adjustments = editAdjustments.trimmingCharacters(in: .whitespacesAndNewlines)
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
            model: editModel,
            aspectRatio: editAspectRatio,
            imageSize: editImageSize,
            referenceItems: [reference],
            editInstructions: adjustments
        )
        editPendingDrafts = [draft]
        editPendingPreflight = draft
    }

    private func beginGenerate(for record: ProjectImageRecord, count: Int) {
        let filename = URL(fileURLWithPath: record.resolvedPath).lastPathComponent
        let reference = GeminiGenerationReferenceDraft(
            label: "Reference: \(filename)",
            path: record.resolvedPath,
            isIncluded: true
        )
        let drafts = (0..<max(1, count)).map { i in
            GeminiGenerationDraft(
                title: count == 1
                    ? "Generate from \(filename)"
                    : "Batch \(i + 1) from \(filename)",
                destinationDescription: "Places → Unattached library",
                prompt: "",
                model: editModel,
                aspectRatio: editAspectRatio,
                imageSize: editImageSize,
                referenceItems: [reference]
            )
        }
        editPendingDrafts = drafts
        editPendingPreflight = drafts.first
    }

    private func runEditGeneration(
        _ drafts: [GeminiGenerationDraft],
        sourceRecord: ProjectImageRecord
    ) {
        guard store.isGeminiAllowed() else {
            editErrorMessage = "Gemini API calls are blocked. Enable Gemini API Calls in Inspector > Tools."
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
                    source: "AllProjectImagesPageView.runEditGeneration()"
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
                    editErrorMessage = error.localizedDescription
                    break
                }
            }
            if finishedCount > 0 {
                store.statusMessage = "Generated \(finishedCount) edited image\(finishedCount == 1 ? "" : "s")"
                editAdjustments = ""
            }
            editPendingDrafts = []
        }
    }

    // MARK: - Formatters

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
