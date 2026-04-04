import AppKit
import SwiftUI
import ProjectKit

// MARK: - Sidebar

@available(macOS 26.0, *)
struct PlacesSidebarView: View {
    @Bindable var store: AnimateStore

    var body: some View {
        OperaChromeSidebarList {
            if store.backgrounds.isEmpty {
                OperaChromeSidebarRow {
                    Text("No places yet — import a set image")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            } else {
                ForEach(store.backgrounds) { place in
                    Button {
                        store.selectedBackgroundID = place.id
                    } label: {
                        OperaChromeSidebarRow(isSelected: store.selectedBackgroundID == place.id) {
                            placeRow(place)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Delete Place", systemImage: "trash", role: .destructive) {
                            store.deletePlace(place.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func placeRow(_ place: BackgroundPlate) -> some View {
        HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
            if let path = place.resolvedApprovedImagePath,
               let url = store.resolvedCharacterAssetURL(for: path),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "building.2")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(place.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(1)
                Text("\(place.imagePaths.count) image\(place.imagePaths.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
        }
    }
}

@available(macOS 26.0, *)
private extension PlacesPageView {
    var projectURL: URL? {
        store.workingOWPURL ?? store.owpURL
    }

    // 3D registry methods archived — types moved to _archived_3d, excluded from build
    func ensure3DRegistryScaffolding() { }

    func reveal3DRegistryRoot() {
        reveal3DRelativePath(ProjectDatabaseBridge.animate3DRegistryRootPath)
    }

    func reveal3DRelativePath(_ relativePath: String) {
        guard let projectURL else { return }
        let url = projectURL.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.pathExtension.isEmpty ? url : url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Main Page View

@available(macOS 26.0, *)
struct PlacesPageView: View {
    @Bindable var store: AnimateStore
    @State private var selectedGalleryImagePaths: Set<String> = []
    @State private var lastClickedGalleryImagePath: String?
    @State private var thumbnailBaseSize: CGFloat = 140
    @State private var viewMode: PlacesViewMode = .grid
    @State private var showDrawThingsPane: Bool = false
    var showSidebar: Bool = true

    enum PlacesViewMode: String, CaseIterable {
        case grid = "Grid"
        case detail = "Detail"
    }

    private var selectedPlace: BackgroundPlate? {
        store.selectedPlace
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if showSidebar {
                    PlacesSidebarView(store: store)
                        .frame(width: min(geo.size.width * 0.3, 280))

                    Divider()
                }

                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: store.workingOWPURL?.path) {
            ensure3DRegistryScaffolding()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                mapOverviewSection
                viewModePicker
                switch viewMode {
                case .grid:
                    locationGridSection
                case .detail:
                    placeDetailSection
                }
            }
            .padding()
        }
    }

    // MARK: - Map Overview Section

    private var mapOverviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Places Overview")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("All locations used across the libretto. Import backgrounds, tag camera angles, and track coverage for scene generation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        generatePlaceholders()
                    } label: {
                        Label("Stubs", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Button {
                        store.importPlacesFromPicker()
                    } label: {
                        Label("Import Place", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 10) {
                overviewPill(title: "Total Locations", value: "\(store.backgrounds.count)", systemImage: "map")
                overviewPill(title: "With Images", value: "\(placesWithImages)", systemImage: "photo.fill")
                overviewPill(title: "Need Images", value: "\(placesNeedingImages)", systemImage: "photo.badge.plus")
                overviewPill(title: "Coverage", value: coveragePercentage, systemImage: "chart.pie")
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var placesWithImages: Int {
        store.backgrounds.filter { !$0.imagePaths.isEmpty }.count
    }

    private var placesNeedingImages: Int {
        store.backgrounds.filter { $0.imagePaths.isEmpty }.count
    }

    private var coveragePercentage: String {
        guard !store.backgrounds.isEmpty else { return "N/A" }
        let ratio = Double(placesWithImages) / Double(store.backgrounds.count)
        return "\(Int(ratio * 100))%"
    }

    private func generatePlaceholders() {
        guard let projectURL = store.workingOWPURL ?? store.owpURL else { return }
        let outputDirectory = projectURL
            .appendingPathComponent("Animate")
            .appendingPathComponent("backgrounds")
        let existingNames = Set(store.backgrounds.map { $0.filename })
        BackgroundPlaceholderService.generatePlaceholders(
            locations: BackgroundPlaceholderService.amiraLocations,
            outputDirectory: outputDirectory
        )
        for location in BackgroundPlaceholderService.amiraLocations {
            guard !existingNames.contains(location.fileName) else { continue }
            let url = outputDirectory.appendingPathComponent(location.fileName)
            if FileManager.default.fileExists(atPath: url.path) {
                store.importBackground(from: url)
            }
        }
    }

    private func overviewPill(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.16), in: Capsule())
    }

    // MARK: - View Mode Picker

    private var viewModePicker: some View {
        HStack {
            Picker("View", selection: $viewMode) {
                ForEach(PlacesViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Spacer()
        }
    }

    // MARK: - 3D World Catalog (archived — 3D pipeline removed)

    // MARK: - Location Grid

    private var locationGridSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 300), spacing: 16)], spacing: 16) {
            ForEach(store.backgrounds) { place in
                PlaceGridCard(
                    store: store,
                    place: place,
                    isSelected: store.selectedBackgroundID == place.id,
                    sceneUsageCount: sceneUsageCount(for: place.id),
                    requiredShots: store.requiredCameraShots(for: place.id)
                ) {
                    store.selectedBackgroundID = place.id
                    viewMode = .detail
                }
            }
        }
    }

    // MARK: - Detail View (existing single-place view)

    @ViewBuilder
    private var placeDetailSection: some View {
        if let place = selectedPlace {
            VStack(alignment: .leading, spacing: 16) {
                placeHeader(place)
                shotRequirementsSection(place)
                angleImagesSection(place)
                approvedPlaceSection(place)
                notesSection(place)
                placeImagesSection(place)
                drawThingsCollapsiblePane(place)
            }
        } else {
            VStack(spacing: 16) {
                OperaChromeEmptyState(
                    systemImage: "building.2",
                    title: "No Place Selected",
                    message: "Select a location from the sidebar or the grid above to see its details."
                )
                Button {
                    viewMode = .grid
                } label: {
                    Label("View All Places", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Place Header (Detail)

    private func placeHeader(_ place: BackgroundPlate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(place.name)
                            .font(.title2)
                            .fontWeight(.semibold)

                        if !place.locationCategory.isEmpty {
                            categoryBadge(place.locationCategory)
                        }
                    }
                    Text("Manage set/location imagery, approve a key background per place, and keep alternates handy for later generation or scene selection.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        viewMode = .grid
                    } label: {
                        Label("Back to Grid", systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.importPlacesFromPicker()
                    } label: {
                        Label("Import New Place", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 10) {
                placeSummaryPill(title: "Images", value: "\(place.imagePaths.count)", systemImage: "photo.stack")
                placeSummaryPill(title: "Angle Images", value: "\(place.angleImages.count)", systemImage: "camera.viewfinder")
                placeSummaryPill(title: "Scenes Using It", value: "\(sceneUsageCount(for: place.id))", systemImage: "film.stack")
                placeSummaryPill(title: "Approved", value: place.resolvedApprovedImagePath == nil ? "No" : "Yes", systemImage: "checkmark.seal")
            }

            HStack(spacing: 12) {
                TextField(
                    "Place Name",
                    text: Binding(
                        get: { place.name },
                        set: { store.updatePlaceName($0, placeID: place.id) }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.headline)

                Picker("Category", selection: Binding(
                    get: { place.locationCategory },
                    set: { store.updatePlaceCategory($0, placeID: place.id) }
                )) {
                    Text("No Category").tag("")
                    Text("Interior").tag("Interior")
                    Text("Exterior").tag("Exterior")
                    Text("Vehicle").tag("Vehicle")
                }
                .pickerStyle(.menu)
                .frame(width: 150)
            }
        }
    }

    // MARK: - Shot Requirements Correlation

    private func shotRequirementsSection(_ place: BackgroundPlate) -> some View {
        let required = store.requiredCameraShots(for: place.id)
        let covered = place.coveredCameraShots
        let coveredCount = required.filter { covered.contains($0) }.count

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Shot Requirements", systemImage: "camera.aperture")
                    .font(.headline)
                Spacer()
                if !required.isEmpty {
                    Text("\(coveredCount)/\(required.count) angles covered")
                        .font(.subheadline)
                        .foregroundStyle(coveredCount >= required.count ? .green : .orange)
                        .fontWeight(.medium)
                }
            }

            if required.isEmpty {
                Text("No scenes currently use this location, so no specific angle requirements.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))], spacing: 8) {
                    ForEach(Array(required).sorted(), id: \.self) { shotType in
                        let isCovered = covered.contains(shotType)
                        HStack(spacing: 6) {
                            Image(systemName: isCovered ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(isCovered ? .green : .orange)
                                .font(.system(size: 14))
                            Text(shotType.capitalized)
                                .font(.callout)
                                .foregroundStyle(isCovered ? .primary : .secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            (isCovered ? Color.green.opacity(0.1) : Color.orange.opacity(0.08)),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                }

                // Scene breakdown
                let scenesUsingPlace = store.scenes.filter { $0.backgroundID == place.id }
                if !scenesUsingPlace.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scenes using this location:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(scenesUsingPlace) { scene in
                            HStack(spacing: 6) {
                                Image(systemName: "film")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(scene.name)
                                    .font(.caption)
                                let shotTypes = scene.shots.compactMap { $0.cameraShot?.displayName }
                                if !shotTypes.isEmpty {
                                    Text("(\(shotTypes.joined(separator: ", ")))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Angle Images Section

    private func angleImagesSection(_ place: BackgroundPlate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Angle Images", systemImage: "camera.viewfinder")
                    .font(.headline)
                Spacer()
                Button {
                    store.addAngleImagesToPlaceFromPicker(placeID: place.id)
                } label: {
                    Label("Add Angle Image", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
            }

            if place.angleImages.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "camera.viewfinder")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                        Text("No angle images yet")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text("Add images tagged by camera shot, angle, and time of day.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Button {
                            store.addAngleImagesToPlaceFromPicker(placeID: place.id)
                        } label: {
                            Label("Import Angle Images", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                }
                .padding(.vertical, 20)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)], spacing: 12) {
                    ForEach(place.angleImages) { angleImage in
                        AngleImageCard(
                            store: store,
                            angleImage: angleImage,
                            placeID: place.id
                        )
                    }
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Approved Place Section

    private func approvedPlaceSection(_ place: BackgroundPlate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Approved Scene Image", systemImage: "photo.on.rectangle")
                    .font(.headline)
                Spacer()
                Button {
                    store.addImagesToPlaceFromPicker(placeID: place.id)
                } label: {
                    Label("Add Images", systemImage: "plus.rectangle.on.rectangle")
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    store.deletePlace(place.id)
                } label: {
                    Label("Delete Place", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }

            if let path = place.resolvedApprovedImagePath,
               let url = store.resolvedCharacterAssetURL(for: path),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture(count: 2) {
                        openQuickLook(for: [path], startingAt: 0)
                    }
                    .contextMenu {
                        Button("Copy Image", systemImage: "doc.on.doc") {
                            copyImage(at: path)
                        }
                        Button("Quick Look", systemImage: "eye") {
                            openQuickLook(for: [path], startingAt: 0)
                        }
                    }

                HStack {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if let firstSelected = selectedGalleryImagePaths.first,
                       selectedGalleryImagePaths.count == 1,
                       firstSelected != path,
                       place.imagePaths.contains(firstSelected) {
                        Button("Use Selected As Approved") {
                            store.setApprovedPlaceImage(firstSelected, placeID: place.id)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                OperaChromeEmptyState(
                    systemImage: "photo",
                    title: "No Approved Image",
                    message: "Add one or more place images, then approve the best one for scene use."
                )
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Notes Section

    private func notesSection(_ place: BackgroundPlate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Place Notes", systemImage: "text.alignleft")
                .font(.headline)

            TextEditor(text: Binding(
                get: { place.notes },
                set: { store.updatePlaceNotes($0, placeID: place.id) }
            ))
            .font(.callout)
            .frame(minHeight: 120)
            .padding(8)
            .background(.background.opacity(0.84), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.quaternary.opacity(0.4))
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Image Library Section

    private func placeImagesSection(_ place: BackgroundPlate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Image Library")
                .font(.headline)
            Text("Keep every variant here. Double-click for Quick Look, right-click to copy, and approve whichever one should represent this place in scenes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ImageGallerySection(
                store: store,
                title: "Place Images",
                icon: "photo.stack",
                paths: place.imagePaths,
                thumbnailBaseSize: $thumbnailBaseSize,
                onImport: { store.addImagesToPlaceFromPicker(placeID: place.id) },
                onRemove: { index in store.removePlaceImage(at: index, placeID: place.id) },
                onPreview: { index, paths in openQuickLook(for: paths, startingAt: index) },
                onCopy: { path in copyImage(at: path) },
                onShowInFinder: { path in showInFinder(at: path) },
                showsHeader: true,
                selectedPaths: $selectedGalleryImagePaths,
                lastClickedPath: $lastClickedGalleryImagePath
            )
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Helpers

    private func categoryBadge(_ category: String) -> some View {
        Text(category)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(categoryColor(category).opacity(0.15), in: Capsule())
            .foregroundStyle(categoryColor(category))
    }

    private func categoryColor(_ category: String) -> Color {
        switch category {
        case "Interior": .blue
        case "Exterior": .green
        case "Vehicle": .orange
        default: .secondary
        }
    }

    private func placeSummaryPill(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.16), in: Capsule())
    }

    private func sceneUsageCount(for placeID: UUID) -> Int {
        store.scenes.filter { $0.backgroundID == placeID }.count
    }

    private func openQuickLook(for paths: [String], startingAt index: Int) {
        let resolvedItems = paths.enumerated().compactMap { offset, path -> (Int, URL)? in
            guard let url = store.resolvedCharacterAssetURL(for: path) else { return nil }
            return (offset, url)
        }

        guard !resolvedItems.isEmpty else { return }
        let quickLookIndex = resolvedItems.firstIndex(where: { $0.0 == index }) ?? 0
        QuickLookPreviewController.shared.present(
            urls: resolvedItems.map(\.1),
            startAt: quickLookIndex
        )
    }

    private func copyImage(at path: String) {
        guard let url = store.resolvedCharacterAssetURL(for: path),
              ImageClipboardService.copyImage(at: url) else {
            store.statusMessage = "Could not copy image"
            return
        }
        store.statusMessage = "Copied image"
    }

    private func showInFinder(at path: String) {
        guard let url = store.resolvedCharacterAssetURL(for: path) else {
            store.statusMessage = "Could not locate image"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Draw Things Generation Pane

    @ViewBuilder
    private func drawThingsCollapsiblePane(_ place: BackgroundPlate) -> some View {
        DisclosureGroup(isExpanded: $showDrawThingsPane) {
            DrawThingsGenerationPane(store: store, place: place)
                .padding(.top, 12)
        } label: {
            HStack(spacing: 10) {
                Label("Local Generation (Draw Things)", systemImage: "cpu")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OperaChromeTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.05))
        )
    }
}

// MARK: - Place Grid Card

@available(macOS 26.0, *)
struct PlaceGridCard: View {
    let store: AnimateStore
    let place: BackgroundPlate
    let isSelected: Bool
    let sceneUsageCount: Int
    let requiredShots: Set<String>
    let onSelect: () -> Void

    private var coveredCount: Int {
        let covered = place.coveredCameraShots
        return requiredShots.filter { covered.contains($0) }.count
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                // Thumbnail
                ZStack(alignment: .topTrailing) {
                    thumbnailView
                        .frame(height: 130)
                        .frame(maxWidth: .infinity)
                        .clipped()

                    if !place.locationCategory.isEmpty {
                        categoryBadge(place.locationCategory)
                            .padding(8)
                    }
                }

                // Info area
                VStack(alignment: .leading, spacing: 6) {
                    Text(place.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    HStack(spacing: 12) {
                        Label("\(place.imagePaths.count)", systemImage: "photo")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if sceneUsageCount > 0 {
                            Label("\(sceneUsageCount)", systemImage: "film")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    // Angle coverage indicator
                    if !requiredShots.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: coveredCount >= requiredShots.count
                                  ? "checkmark.circle.fill"
                                  : "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(coveredCount >= requiredShots.count ? .green : .orange)
                            Text("\(coveredCount)/\(requiredShots.count) angles")
                                .font(.caption2)
                                .foregroundStyle(coveredCount >= requiredShots.count ? .green : .orange)
                        }
                    } else if place.angleImages.isEmpty && !place.imagePaths.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "camera.viewfinder")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text("No angles tagged")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    // Scene usage tags
                    if sceneUsageCount > 0 {
                        let scenesUsing = store.scenes.filter { $0.backgroundID == place.id }
                        HStack(spacing: 4) {
                            ForEach(scenesUsing.prefix(3)) { scene in
                                Text(scene.name)
                                    .font(.system(size: 9))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.quaternary.opacity(0.3), in: Capsule())
                                    .lineLimit(1)
                            }
                            if scenesUsing.count > 3 {
                                Text("+\(scenesUsing.count - 3)")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(10)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Place", systemImage: "trash", role: .destructive) {
                store.deletePlace(place.id)
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let path = place.resolvedApprovedImagePath,
           let url = store.resolvedCharacterAssetURL(for: path),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.gray.opacity(0.1)
                VStack(spacing: 6) {
                    Image(systemName: "building.2")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No image")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func categoryBadge(_ category: String) -> some View {
        Text(category)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

// MARK: - Angle Image Card

@available(macOS 26.0, *)
struct AngleImageCard: View {
    let store: AnimateStore
    let angleImage: PlaceAngleImage
    let placeID: UUID

    @State private var isEditing: Bool = false
    @State private var editCameraShot: String = ""
    @State private var editAngle: String = ""
    @State private var editTimeOfDay: String = ""
    @State private var editNotes: String = ""

    private static let cameraShotOptions = ["", "wide", "medium", "medium close", "close", "extreme wide", "extreme close"]
    private static let angleOptions = ["", "front", "left", "right", "overhead", "low", "behind"]
    private static let timeOfDayOptions = ["", "day", "night", "dawn", "dusk", "golden hour"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            ZStack(alignment: .topTrailing) {
                angleImageThumbnail
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .clipped()

                HStack(spacing: 4) {
                    if let shot = angleImage.cameraShot, !shot.isEmpty {
                        tagPill(shot)
                    }
                    if let tod = angleImage.timeOfDay, !tod.isEmpty {
                        tagPill(tod)
                    }
                }
                .padding(6)
            }

            // Metadata
            VStack(alignment: .leading, spacing: 4) {
                if let angle = angleImage.angle, !angle.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(angle.capitalized)
                            .font(.caption)
                    }
                }

                if !angleImage.notes.isEmpty {
                    Text(angleImage.notes)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 6) {
                    Button {
                        editCameraShot = angleImage.cameraShot ?? ""
                        editAngle = angleImage.angle ?? ""
                        editTimeOfDay = angleImage.timeOfDay ?? ""
                        editNotes = angleImage.notes
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button(role: .destructive) {
                        store.removeAngleImage(angleImage.id, placeID: placeID)
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.quaternary.opacity(0.5))
        )
        .popover(isPresented: $isEditing) {
            angleImageEditor
        }
    }

    @ViewBuilder
    private var angleImageThumbnail: some View {
        if let url = store.resolvedCharacterAssetURL(for: angleImage.imagePath),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.gray.opacity(0.1)
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func tagPill(_ text: String) -> some View {
        Text(text.capitalized)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var angleImageEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Angle Image")
                .font(.headline)

            Picker("Camera Shot", selection: $editCameraShot) {
                ForEach(Self.cameraShotOptions, id: \.self) { option in
                    Text(option.isEmpty ? "None" : option.capitalized).tag(option)
                }
            }

            Picker("Angle", selection: $editAngle) {
                ForEach(Self.angleOptions, id: \.self) { option in
                    Text(option.isEmpty ? "None" : option.capitalized).tag(option)
                }
            }

            Picker("Time of Day", selection: $editTimeOfDay) {
                ForEach(Self.timeOfDayOptions, id: \.self) { option in
                    Text(option.isEmpty ? "None" : option.capitalized).tag(option)
                }
            }

            TextField("Notes", text: $editNotes, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            HStack {
                Button("Cancel") {
                    isEditing = false
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    store.updateAngleImage(
                        angleImage.id,
                        placeID: placeID,
                        cameraShot: editCameraShot.isEmpty ? nil : editCameraShot,
                        angle: editAngle.isEmpty ? nil : editAngle,
                        timeOfDay: editTimeOfDay.isEmpty ? nil : editTimeOfDay,
                        notes: editNotes
                    )
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 280)
    }
}
