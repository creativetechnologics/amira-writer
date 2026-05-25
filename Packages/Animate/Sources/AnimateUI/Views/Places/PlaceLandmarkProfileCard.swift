import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct PlaceLandmarkProfileCard: View {
    @Bindable var store: AnimateStore
    let workflowMode: PlaceWorkflowMode
    let profile: PlaceLandmarkProfile
    let onShowInFinder: (String) -> Void
    let onOpenPlace: (UUID) -> Void
    let onRefreshed: () -> Void

    @State private var notesDraft: String = ""

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

    private func verifiedApprovedPlacePath(for place: BackgroundPlate, workflow: PlaceWorkflowMode) -> String? {
        guard let path = place.approvedImagePath(for: workflow),
              !store.placeImageIsRejected(path: path),
              store.imageLibraryIsLiked(for: path) else { return nil }
        return path
    }

    private var exteriorImageCandidates: [String] {
        var values: [String] = []
        if let current = profile.exteriorImagePath { values.append(current) }
        if let place = exteriorPlaces.first(where: { $0.id == profile.exteriorPlaceID }) {
            values.append(contentsOf: place.imagePaths(for: workflowMode).filter { !store.placeImageIsRejected(path: $0) })
            if let approved = verifiedApprovedPlacePath(for: place, workflow: workflowMode) { values.append(approved) }
        }
        values.append(contentsOf: matchingGeneratedRecords(preferredInterior: false).map(\.activePath))
        return uniqueNormalizedPaths(values)
    }

    private var interiorImageCandidates: [String] {
        var values: [String] = []
        if let current = profile.interiorImagePath { values.append(current) }
        if let place = interiorPlaces.first(where: { $0.id == profile.interiorPlaceID }) {
            values.append(contentsOf: place.imagePaths(for: workflowMode).filter { !store.placeImageIsRejected(path: $0) })
            if let approved = verifiedApprovedPlacePath(for: place, workflow: workflowMode) { values.append(approved) }
        }
        values.append(contentsOf: matchingGeneratedRecords(preferredInterior: true).map(\.activePath))
        return uniqueNormalizedPaths(values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.title).font(.headline)
                    HStack(spacing: 8) {
                        pill(profile.kind.displayName, systemImage: "building.columns")
                        if profile.mapPoint != nil { pill("Anchored", systemImage: "mappin.and.ellipse") }
                        if profile.exteriorImagePath != nil { pill("Exterior Canon", systemImage: "camera") }
                        if profile.interiorImagePath != nil { pill("Interior Canon", systemImage: "house") }
                    }
                }
                Spacer()
                Button {
                    store.refreshSuggestedLandmarkProfiles()
                    onRefreshed()
                } label: { Label("Reinfer", systemImage: "wand.and.stars") }
                .buttonStyle(.bordered)
            }

            if let mapPoint = profile.mapPoint {
                Text("Map anchor: x \(String(format: "%.3f", mapPoint.x)), y \(String(format: "%.3f", mapPoint.y))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("No confirmed map anchor yet. Set or refine an exterior pin first, then refresh suggestions.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                landmarkImageColumn(
                    title: "Exterior Canon",
                    placeSelection: Binding(
                        get: { profile.exteriorPlaceID },
                        set: { store.setLandmarkProfileExteriorPlace($0, landmarkID: profile.id); onRefreshed() }
                    ),
                    placeOptions: exteriorPlaces,
                    imageSelection: Binding(
                        get: { profile.exteriorImagePath },
                        set: { store.setLandmarkProfileExteriorImagePath($0, landmarkID: profile.id); onRefreshed() }
                    ),
                    imageOptions: exteriorImageCandidates,
                    currentPath: profile.exteriorImagePath,
                    accent: .blue,
                    openPlaceAction: onOpenPlace
                )

                landmarkImageColumn(
                    title: "Interior Canon",
                    placeSelection: Binding(
                        get: { profile.interiorPlaceID },
                        set: { store.setLandmarkProfileInteriorPlace($0, landmarkID: profile.id); onRefreshed() }
                    ),
                    placeOptions: interiorPlaces,
                    imageSelection: Binding(
                        get: { profile.interiorImagePath },
                        set: { store.setLandmarkProfileInteriorImagePath($0, landmarkID: profile.id); onRefreshed() }
                    ),
                    imageOptions: interiorImageCandidates,
                    currentPath: profile.interiorImagePath,
                    accent: .orange,
                    openPlaceAction: onOpenPlace
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Landmark Notes").font(.subheadline.weight(.semibold))
                TextField("Bridge scale, clinic facade rules, interior constraints\u{2026}", text: $notesDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(2...4)
                    .onSubmit { store.updateLandmarkProfileNotes(notesDraft, landmarkID: profile.id) }
                HStack {
                    Spacer()
                    Button("Save Notes") { store.updateLandmarkProfileNotes(notesDraft, landmarkID: profile.id) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear { notesDraft = profile.notes }
        .onChange(of: profile.notes) { _, newValue in if notesDraft != newValue { notesDraft = newValue } }
    }

    // MARK: - Image Column

    @ViewBuilder
    private func landmarkImageColumn(
        title: String,
        placeSelection: Binding<UUID?>,
        placeOptions: [BackgroundPlate],
        imageSelection: Binding<String?>,
        imageOptions: [String],
        currentPath: String?,
        accent: Color,
        openPlaceAction: @escaping (UUID) -> Void
    ) -> some View {
        let displayPath = currentPath.flatMap { store.placeImageIsRejected(path: $0) ? nil : $0 }
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold))

            Picker(title, selection: placeSelection) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(placeOptions) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().pickerStyle(.menu)

            Picker("\(title) Image", selection: imageSelection) {
                Text("None").tag(Optional<String>.none)
                ForEach(imageOptions, id: \.self) { Text(imageLabel(for: $0)).tag(Optional($0)) }
            }.labelsHidden().pickerStyle(.menu)

            ZStack(alignment: .bottomTrailing) {
                if let displayPath,
                   let url = store.resolvedCharacterAssetURL(for: displayPath)
                    ?? (FileManager.default.fileExists(atPath: displayPath) ? URL(fileURLWithPath: displayPath) : nil) {
                    CachedThumbnailView(path: url.path, size: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(accent.opacity(0.35), lineWidth: 1))
                        .contentShape(Rectangle())
                        .onTapGesture { store.selectGeneratedBackgroundRecord(for: displayPath) }
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.08)).frame(height: 180)
                        .overlay(Label("No image selected", systemImage: "photo")
                            .font(.caption).foregroundStyle(.secondary))
                }
            }.frame(maxWidth: .infinity)

            HStack {
                if let placeID = placeSelection.wrappedValue {
                    Button("Open Place") { openPlaceAction(placeID) }.buttonStyle(.bordered)
                }
                Spacer()
                if let displayPath {
                    Button("Reveal") { onShowInFinder(displayPath) }.buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Helpers

    private func uniqueNormalizedPaths(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in values {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty, seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }

    private func imageLabel(for path: String) -> String {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        if let record = store.generatedBackgroundRecord(for: path), let rating = record.rating {
            return "\(String(repeating: "\u{2605}", count: rating)) \(filename)"
        }
        return filename
    }

    private func matchingGeneratedRecords(preferredInterior: Bool) -> [GeneratedBackgroundLibraryRecord] {
        store.placesWorkflowLibrary.generatedImageRecords.filter { record in
            guard record.workflow == workflowMode,
                  !record.isRejected,
                  !store.placeImageIsRejected(path: record.activePath) else { return false }
            return landmarkKind(for: record) == profile.kind
        }.sorted { lhs, rhs in
            recordScore(lhs, preferredInterior: preferredInterior) > recordScore(rhs, preferredInterior: preferredInterior)
        }
    }

    private func recordScore(_ record: GeneratedBackgroundLibraryRecord, preferredInterior: Bool) -> Int {
        let lower = [record.activePath, record.summary, record.sourcePrompt]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let interiorCue = ["room", "back room", "lamplight", "treatment_room", "inside", "interior", "tent", "bunk"]
            .contains { lower.contains($0) }
        var score = (record.rating ?? 0) * 20
        if record.mapPlacementStatus == .confirmed { score += 40 }
        score += preferredInterior ? (interiorCue ? 50 : -10) : (interiorCue ? -30 : 20)
        return score
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

    private func landmarkKind(for record: GeneratedBackgroundLibraryRecord) -> PlaceLandmarkProfile.Kind? {
        let lower = [record.activePath, record.summary, record.sourcePrompt]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        if lower.contains("amira") || lower.contains("home") { return .amiraHome }
        if lower.contains("clinic") { return .clinic }
        if lower.contains("gathering") { return .gatheringSpace }
        if lower.contains("bridge") { return .bridge }
        if lower.contains("market") { return .marketplace }
        if lower.contains("grave") || lower.contains("memorial") || lower.contains("riverbank") { return .memorial }
        if lower.contains("riverside") || lower.contains("river road") { return .riverside }
        if lower.contains("ridge") || lower.contains("mountain valley") { return .ridge }
        return nil
    }

    private func exteriorScore(_ place: BackgroundPlate) -> Int {
        var score = 0
        if place.approvedImagePath(for: workflowMode) != nil || place.approvedImagePath != nil { score += 100 }
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
