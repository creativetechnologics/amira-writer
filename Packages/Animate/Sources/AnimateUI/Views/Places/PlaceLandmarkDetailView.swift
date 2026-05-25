import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct PlaceLandmarkDetailView: View {
    @Bindable var store: AnimateStore
    let workflowMode: PlaceWorkflowMode
    let profile: PlaceLandmarkProfile
    @Binding var thumbnailBaseSize: CGFloat
    let onPreviewPaths: ([String], Int) -> Void
    let onShowInFinder: (String) -> Void
    let onCopy: (String) -> Void
    let onOpenPlace: (UUID?) -> Void
    let onRefreshed: () -> Void

    @State private var notesDraft: String = ""
    @State private var tagsDraft: String = ""
    @State private var selectedPaths: Set<String> = []
    @State private var lastClickedPath: String?

    private var galleryPaths: [String] {
        profile.galleryImagePaths
    }

    private var primaryImagePath: String? {
        profile.primaryImagePath ?? profile.exteriorImagePath ?? galleryPaths.first
    }

    private var selectedGalleryPath: String? {
        lastClickedPath ?? selectedPaths.first
    }

    private var allRelatedPlaces: [BackgroundPlate] {
        store.backgrounds.filter { landmarkKind(for: $0.name) == profile.kind }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var exteriorPlaces: [BackgroundPlate] {
        allRelatedPlaces
            .sorted { lhs, rhs in
                exteriorScore(lhs) > exteriorScore(rhs)
            }
    }

    private var interiorPlaces: [BackgroundPlate] {
        allRelatedPlaces
            .filter { isInteriorPlace($0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerCard
            heroImageCard
            iPadSketchCard

            HStack(alignment: .top, spacing: 16) {
                linkedPlacesCard
                notesCard
            }

            galleryToolbar

            ImageGallerySection(
                store: store,
                title: "Assigned Images",
                icon: "photo.stack",
                paths: galleryPaths,
                thumbnailBaseSize: $thumbnailBaseSize,
                onImport: {
                    store.addImagesToLandmarkFromPicker(landmarkID: profile.id)
                },
                onRemove: { index in
                    let removedPath = galleryPaths.indices.contains(index) ? galleryPaths[index] : nil
                    store.removeLandmarkImage(at: index, landmarkID: profile.id)
                    clearSelectionIfNeeded(removedPaths: removedPath.map { [$0] } ?? [])
                    onRefreshed()
                },
                onRemoveMultiple: { offsets in
                    let removedPaths = offsets.compactMap { galleryPaths.indices.contains($0) ? galleryPaths[$0] : nil }
                    store.removeLandmarkImages(at: offsets, landmarkID: profile.id)
                    clearSelectionIfNeeded(removedPaths: removedPaths)
                    onRefreshed()
                },
                onPreview: { index, paths in
                    onPreviewPaths(paths, index)
                },
                onCopy: onCopy,
                onShowInFinder: onShowInFinder,
                ratingFor: { path in store.imageLibraryRating(for: path) ?? 0 },
                isRejectedFor: { path in store.imageLibraryIsRejected(for: path) },
                hasNotesFor: { path in
                    !store.imageLibraryNotes(for: path).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                },
                selectedPaths: $selectedPaths,
                lastClickedPath: $lastClickedPath,
                onDropURLs: { urls in
                    let accepted = store.attachDroppedImagesToLandmark(urls: urls, landmarkID: profile.id)
                    if accepted { onRefreshed() }
                    return accepted
                },
                onFocusPathChange: { path in
                    store.selectGeneratedBackgroundRecord(for: path)
                }
            )
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OperaChromeTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05))
        )
        .dropDestination(for: URL.self) { urls, _ in
            let accepted = store.attachDroppedImagesToLandmark(urls: urls, landmarkID: profile.id)
            if accepted { onRefreshed() }
            return accepted
        }
        .onAppear {
            notesDraft = profile.notes
            tagsDraft = profile.tags.joined(separator: ", ")
            lastClickedPath = primaryImagePath
        }
        .onChange(of: profile.notes) { _, newValue in
            if notesDraft != newValue { notesDraft = newValue }
        }
        .onChange(of: profile.tags) { _, newValue in
            let joined = newValue.joined(separator: ", ")
            if tagsDraft != joined { tagsDraft = joined }
        }
        .onChange(of: profile.primaryImagePath) { _, newValue in
            if lastClickedPath == nil { lastClickedPath = newValue }
        }
    }

    private var headerCard: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(profile.title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Curate a single hero frame for this landmark, build a supporting gallery beneath it, and drag candidates in from Show All Images.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    pill(profile.kind.displayName, systemImage: "building.columns")
                    pill(workflowMode.displayName, systemImage: workflowMode == .photorealistic ? "camera" : "paintbrush.pointed")
                    pill("\(galleryPaths.count) images", systemImage: "photo.stack")
                    if profile.mapPoint != nil {
                        pill("Anchored", systemImage: "mappin.and.ellipse")
                    }
                }
            }

            Spacer()

            Button {
                store.refreshSuggestedLandmarkProfiles()
                onRefreshed()
            } label: {
                Label("Refresh Suggestions", systemImage: "wand.and.stars")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var heroImageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Main Image", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
                Spacer()
                if let selectedGalleryPath, selectedGalleryPath != primaryImagePath {
                    Button("Set Selected as Main") {
                        store.setLandmarkProfilePrimaryImagePath(selectedGalleryPath, landmarkID: profile.id)
                        onRefreshed()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if let primaryImagePath {
                    Button("Reveal Main") {
                        onShowInFinder(primaryImagePath)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if let primaryImagePath, let url = resolvedAssetURL(for: primaryImagePath) {
                AsyncResolvedImageView(path: url.path, maxPixelSize: 1200, contentMode: .fit)
                    .frame(maxWidth: .infinity).frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text("MAIN")
                            .font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.black.opacity(0.55), in: Capsule()).padding(14)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { store.selectGeneratedBackgroundRecord(for: primaryImagePath) }
                    .onTapGesture(count: 2) {
                        if let index = galleryPaths.firstIndex(of: primaryImagePath) {
                            onPreviewPaths(galleryPaths, index)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.secondary.opacity(0.08)).frame(maxWidth: .infinity).frame(height: 280)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus").font(.system(size: 28)).foregroundStyle(.secondary)
                            Text("No main landmark image yet").font(.headline)
                            Text("Drag images here from Show All Images or import existing files to start curating this landmark.")
                                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                        }.padding(24)
                    }
            }
        }
        .padding(16).background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var linkedPlacesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Linked Places", systemImage: "point.3.connected.trianglepath.dotted").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Exterior Anchor").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Exterior Anchor", selection: Binding(
                    get: { profile.exteriorPlaceID },
                    set: { store.setLandmarkProfileExteriorPlace($0, landmarkID: profile.id); onRefreshed() }
                )) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(exteriorPlaces) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Interior Reference").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("Interior Reference", selection: Binding(
                    get: { profile.interiorPlaceID },
                    set: { store.setLandmarkProfileInteriorPlace($0, landmarkID: profile.id); onRefreshed() }
                )) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(interiorPlaces) { Text($0.name).tag(Optional($0.id)) }
                }.labelsHidden().pickerStyle(.menu)
            }

            if let mapPoint = profile.mapPoint {
                Text("Anchor: x \(String(format: "%.3f", mapPoint.x)) \u{2022} y \(String(format: "%.3f", mapPoint.y))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No confirmed map anchor yet. Pick an exterior anchor place or assign a map-placed image and refresh suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                if let exteriorPlaceID = profile.exteriorPlaceID {
                    Button("Open Exterior") { onOpenPlace(exteriorPlaceID) }.buttonStyle(.bordered)
                }
                if let interiorPlaceID = profile.interiorPlaceID {
                    Button("Open Interior") { onOpenPlace(interiorPlaceID) }.buttonStyle(.bordered)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var iPadSketchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("iPad Storyboard Sketch", systemImage: "applepencil.tip").font(.headline)
                Spacer()
                if let path = profile.storyboardSketchPath, let url = resolvedAssetURL(for: path) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }

            if let path = profile.storyboardSketchPath, let url = resolvedAssetURL(for: path), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 220).background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.quaternary, lineWidth: 1))
                    .id(landmarkSketchFingerprint(url))
            } else {
                Text("Open this landmark in the iPad storyboard PWA and draw a quick sketch \u{2014} the latest version will appear here.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func landmarkSketchFingerprint(_ url: URL) -> Double {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        let mtime = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = Double(values.fileSize ?? 0)
        return mtime + size / 1_000_000_000
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Landmark Notes + Tags", systemImage: "tag").font(.headline)
            TextField("Tags: bridge, stone bridge, upper bridge\u{2026}", text: $tagsDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...5)
            TextField("Bridge scale, roof materials, no-modernity rules, required geography cues\u{2026}", text: $notesDraft, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(4...8)
                .onSubmit {
                    store.updateLandmarkProfileNotes(notesDraft, landmarkID: profile.id)
                    store.updateLandmarkProfileTags(parseTags(tagsDraft), landmarkID: profile.id)
                }
            HStack {
                Spacer()
                Button("Save Notes") {
                    store.updateLandmarkProfileNotes(notesDraft, landmarkID: profile.id)
                    store.updateLandmarkProfileTags(parseTags(tagsDraft), landmarkID: profile.id)
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var galleryToolbar: some View {
        HStack(spacing: 10) {
            Text("Drag images in from Show All Images, or import files directly into this landmark gallery.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let selectedGalleryPath {
                Button("Reveal Selected") { onShowInFinder(selectedGalleryPath) }.buttonStyle(.bordered)
                if selectedGalleryPath != primaryImagePath {
                    Button("Set Selected as Main") {
                        store.setLandmarkProfilePrimaryImagePath(selectedGalleryPath, landmarkID: profile.id)
                        onRefreshed()
                    }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func parseTags(_ raw: String) -> [String] {
        raw.split(separator: ",").map(String.init)
    }

    private func clearSelectionIfNeeded(removedPaths: [String]) {
        if let lastClickedPath, removedPaths.contains(lastClickedPath) {
            self.lastClickedPath = nil
            store.selectGeneratedBackgroundRecord(for: nil)
        }
        selectedPaths.subtract(removedPaths)
    }

    private func resolvedAssetURL(for path: String) -> URL? {
        if let resolved = store.resolvedCharacterAssetURL(for: path) { return resolved }
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }

    private func landmarkKind(for placeName: String) -> PlaceLandmarkProfile.Kind? {
        let lower = placeName.lowercased()
        if lower.contains("amira") { return .amiraHome }
        if lower.contains("clinic") { return .clinic }
        if lower.contains("gathering") { return .gatheringSpace }
        if lower.contains("bridge") { return .bridge }
        if lower.contains("market") { return .marketplace }
        if lower.contains("grave") || lower.contains("memorial") || lower.contains("riverbank") { return .memorial }
        if lower.contains("riverside") || lower.contains("river road") { return .riverside }
        if lower.contains("ridge") || lower.contains("mountain valley") { return .ridge }
        return nil
    }

    private func verifiedApprovedPlacePath(for place: BackgroundPlate, workflow: PlaceWorkflowMode) -> String? {
        guard let path = place.approvedImagePath(for: workflow),
              !store.placeImageIsRejected(path: path),
              store.imageLibraryIsLiked(for: path) else { return nil }
        return path
    }

    private func exteriorScore(_ place: BackgroundPlate) -> Int {
        var score = 0
        if verifiedApprovedPlacePath(for: place, workflow: workflowMode) != nil { score += 100 }
        if placeNameHasExteriorCue(place.name) { score += 40 }
        if placeNameHasInteriorCue(place.name) { score -= 60 }
        return score
    }

    private func isInteriorPlace(_ place: BackgroundPlate) -> Bool {
        if placeNameHasInteriorCue(place.name) && !placeNameHasExteriorCue(place.name) { return true }
        switch profile.kind {
        case .amiraHome, .clinic: return !placeNameHasExteriorCue(place.name)
        case .gatheringSpace:
            let lower = place.name.lowercased()
            return lower.contains("evening") || lower.contains("back alleys")
        default: return false
        }
    }

    private func placeNameHasExteriorCue(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["street", "road", "bridge", "riverside", "courtyard", "doorway", "market", "overlook", "lane", "edge", "outside", "village to", "valley", "ridge"]
            .contains { lower.contains($0) }
    }

    private func placeNameHasInteriorCue(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["room", "back room", "tent", "bunk", "night", "later that same night", "quiet moment", "inside", "interior", "pre-dawn", "home", "clinic back room"]
            .contains { lower.contains($0) }
    }

    @ViewBuilder
    private func pill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.quaternary.opacity(0.18), in: Capsule())
    }
}
