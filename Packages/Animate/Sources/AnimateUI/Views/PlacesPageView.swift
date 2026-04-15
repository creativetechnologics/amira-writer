import AppKit
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
private struct PendingPlaceGenerationPlan: Identifiable {
    var id: UUID = UUID()
    var placeID: UUID
    var workflow: PlaceWorkflowMode
    var routeID: UUID? = nil
    var nodeIDs: [UUID] = []
    var count: Int
    var title: String
    var confirmTitle: String
}

@available(macOS 26.0, *)
private struct PlaceAllImagesGallerySection: View {
    @Bindable var store: AnimateStore
    let title: String
    let records: [GeneratedBackgroundLibraryRecord]
    @Binding var thumbnailBaseSize: CGFloat
    @Binding var selectedPaths: Set<String>
    @Binding var lastClickedPath: String?
    @FocusState private var galleryKeyboardFocused: Bool

    private let minThumbnailSize: CGFloat = 100
    private let maxThumbnailSize: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            if records.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(.tertiary)
                    Text("No generated images match the current filters.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 8)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbnailBaseSize, maximum: thumbnailBaseSize), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(records) { record in
                        PlaceAllImagesThumbnail(
                            store: store,
                            record: record,
                            tileWidth: thumbnailBaseSize,
                            isSelected: selectedPaths.contains(record.activePath),
                            onClick: { event in handleClick(path: record.activePath, event: event) },
                            onQuickLook: { openQuickLook(path: record.activePath) },
                            onShowInFinder: { showInFinder(path: record.activePath) }
                        )
                    }
                }
                .focusable()
                .focused($galleryKeyboardFocused)
                .focusEffectDisabled()
                .onKeyPress(.space) {
                    guard let focusPath = lastClickedPath,
                          let index = records.firstIndex(where: { $0.activePath == focusPath }) else {
                        if QuickLookPreviewController.shared.isVisible {
                            QuickLookPreviewController.shared.dismiss()
                            return .handled
                        }
                        return .ignored
                    }
                    let urls = records.compactMap { store.resolvedCharacterAssetURL(for: $0.activePath) }
                    let qlIndex = min(index, max(urls.count - 1, 0))
                    QuickLookPreviewController.shared.toggle(urls: urls, startAt: qlIndex)
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    guard let focusPath = lastClickedPath,
                          let currentIndex = records.firstIndex(where: { $0.activePath == focusPath }),
                          currentIndex > 0 else {
                        return .ignored
                    }
                    let newIndex = currentIndex - 1
                    let newPath = records[newIndex].activePath
                    selectedPaths = [newPath]
                    lastClickedPath = newPath
                    store.selectGeneratedBackgroundRecord(for: newPath)
                    if QuickLookPreviewController.shared.isVisible {
                        QuickLookPreviewController.shared.navigateTo(index: newIndex)
                    }
                    return .handled
                }
                .onKeyPress(.rightArrow) {
                    guard let focusPath = lastClickedPath,
                          let currentIndex = records.firstIndex(where: { $0.activePath == focusPath }),
                          currentIndex < records.count - 1 else {
                        return .ignored
                    }
                    let newIndex = currentIndex + 1
                    let newPath = records[newIndex].activePath
                    selectedPaths = [newPath]
                    lastClickedPath = newPath
                    store.selectGeneratedBackgroundRecord(for: newPath)
                    if QuickLookPreviewController.shared.isVisible {
                        QuickLookPreviewController.shared.navigateTo(index: newIndex)
                    }
                    return .handled
                }
                .onKeyPress(phases: .down) { press in
                    handleRatingKeyPress(press)
                }
                .onKeyPress(.escape) {
                    if QuickLookPreviewController.shared.isVisible {
                        QuickLookPreviewController.shared.dismiss()
                        return .handled
                    }
                    if !selectedPaths.isEmpty {
                        selectedPaths.removeAll()
                        lastClickedPath = nil
                        store.selectGeneratedBackgroundRecord(for: nil)
                        return .handled
                    }
                    return .ignored
                }
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Label(title, systemImage: "photo.on.rectangle.angled")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(records.count) images")
                .font(.caption)
                .foregroundStyle(.tertiary)

            HStack(spacing: 4) {
                Button {
                    thumbnailBaseSize = max(minThumbnailSize, thumbnailBaseSize - 20)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(thumbnailBaseSize <= minThumbnailSize)

                Slider(value: $thumbnailBaseSize, in: minThumbnailSize...maxThumbnailSize, step: 20)
                    .frame(width: 80)

                Button {
                    thumbnailBaseSize = min(maxThumbnailSize, thumbnailBaseSize + 20)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(thumbnailBaseSize >= maxThumbnailSize)
            }
        }
    }

    private func handleClick(path: String, event: GalleryClickEvent) {
        galleryKeyboardFocused = true
        switch event.modifiers {
        case .command:
            if selectedPaths.contains(path) {
                selectedPaths.remove(path)
            } else {
                selectedPaths.insert(path)
            }
        case .shift:
            if let anchor = lastClickedPath,
               let anchorIndex = records.firstIndex(where: { $0.activePath == anchor }),
               let clickIndex = records.firstIndex(where: { $0.activePath == path }) {
                let range = min(anchorIndex, clickIndex)...max(anchorIndex, clickIndex)
                for idx in range {
                    selectedPaths.insert(records[idx].activePath)
                }
            } else {
                selectedPaths = [path]
            }
        default:
            selectedPaths = [path]
        }
        lastClickedPath = path
        store.selectGeneratedBackgroundRecord(for: path)
        if QuickLookPreviewController.shared.isVisible,
           let clickIndex = records.firstIndex(where: { $0.activePath == path }) {
            QuickLookPreviewController.shared.navigateTo(index: clickIndex)
        }
    }

    private func openQuickLook(path: String) {
        guard let index = records.firstIndex(where: { $0.activePath == path }) else { return }
        let urls = records.compactMap { store.resolvedCharacterAssetURL(for: $0.activePath) }
        guard !urls.isEmpty else { return }
        QuickLookPreviewController.shared.present(urls: urls, startAt: min(index, urls.count - 1))
    }

    private func showInFinder(path: String) {
        guard let url = store.resolvedCharacterAssetURL(for: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func applyRating(_ rating: Int?) -> KeyPress.Result {
        guard !selectedPaths.isEmpty else { return .ignored }
        let selectedIDs = selectedPaths.compactMap { store.generatedBackgroundRecord(for: $0)?.id }
        guard !selectedIDs.isEmpty else { return .ignored }
        for recordID in selectedIDs {
            store.setGeneratedBackgroundRating(rating, for: recordID)
        }
        return .handled
    }

    private func toggleRejected() -> KeyPress.Result {
        guard !selectedPaths.isEmpty else { return .ignored }
        let selectedIDs = selectedPaths.compactMap { store.generatedBackgroundRecord(for: $0)?.id }
        guard !selectedIDs.isEmpty else { return .ignored }
        for recordID in selectedIDs {
            store.toggleGeneratedBackgroundRejected(recordID)
        }
        return .handled
    }

    private func handleRatingKeyPress(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case "1":
            return applyRating(1)
        case "2":
            return applyRating(2)
        case "3":
            return applyRating(3)
        case "4":
            return applyRating(4)
        case "5", ".":
            return applyRating(5)
        case "0":
            return applyRating(nil)
        case "x", "X":
            return toggleRejected()
        default:
            return .ignored
        }
    }
}

@available(macOS 26.0, *)
private struct PlaceAllImagesThumbnail: View {
    let store: AnimateStore
    let record: GeneratedBackgroundLibraryRecord
    let tileWidth: CGFloat
    let isSelected: Bool
    let onClick: (GalleryClickEvent) -> Void
    let onQuickLook: () -> Void
    let onShowInFinder: () -> Void

    private var imageBoxHeight: CGFloat { max(90, tileWidth * 0.72) }

    var body: some View {
        let resolvedURL = store.resolvedCharacterAssetURL(for: record.activePath)
        let displayName = resolvedURL?.lastPathComponent ?? URL(fileURLWithPath: record.activePath).lastPathComponent
        let subtitle = relativeFolderLabel(for: record.activePath)
        let queueItem = store.pendingGeneratedBackgroundEditQueueItem(for: record.id)

        VStack(alignment: .leading, spacing: 6) {
            PlaceAllImagesAsyncThumbnail(
                store: store,
                record: record,
                tileWidth: tileWidth,
                imageBoxHeight: imageBoxHeight,
                isSelected: isSelected
            )
            .overlay(alignment: .topTrailing) {
                VStack(alignment: .trailing, spacing: 6) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white, Color.accentColor)
                    }
                    if let queueItem {
                        badgeLabel(
                            systemName: queueItem.state == .failed ? "exclamationmark.triangle.fill" : "tray.and.arrow.down.fill",
                            text: queueItem.state.rawValue.capitalized,
                            tint: queueItem.state == .failed ? .orange : .blue
                        )
                    }
                    if record.duplicatePaths.count > 0 {
                        badgeLabel(systemName: "square.on.square", text: "\(record.duplicatePaths.count + 1)x", tint: .secondary)
                    }
                }
                .padding(6)
            }

            Text(displayName)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(OperaChromeTheme.textPrimary))

            HStack(spacing: 6) {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let rating = record.rating {
                    Label("\(rating)", systemImage: "star.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.yellow)
                } else if record.isRejected {
                    Label("Rejected", systemImage: "xmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.06), lineWidth: isSelected ? 2 : 1)
        )
        .opacity(record.isRejected ? 0.45 : 1.0)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(count: 1) {
            let flags = NSEvent.modifierFlags
            if flags.contains(.command) {
                onClick(GalleryClickEvent(modifiers: .command))
            } else if flags.contains(.shift) {
                onClick(GalleryClickEvent(modifiers: .shift))
            } else {
                onClick(GalleryClickEvent(modifiers: .none))
            }
        }
        .contextMenu {
            Button("Quick Look", systemImage: "eye") { onQuickLook() }
            Button("Show in Finder", systemImage: "folder") { onShowInFinder() }
        }
        .help("Click to select. Press Space to Quick Look.")
        .draggable(resolvedURL ?? URL(fileURLWithPath: record.activePath))
    }

    private func relativeFolderLabel(for path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/")
        guard components.count > 1 else { return "backgrounds" }
        return components.dropLast().suffix(3).joined(separator: "/")
    }

    private func badgeLabel(systemName: String, text: String, tint: Color) -> some View {
        Label(text, systemImage: systemName)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}

@available(macOS 26.0, *)
private struct PlaceAllImagesAsyncThumbnail: View {
    let store: AnimateStore
    let record: GeneratedBackgroundLibraryRecord
    let tileWidth: CGFloat
    let imageBoxHeight: CGFloat
    let isSelected: Bool

    @State private var loadedImage: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isSelected
                        ? AnyShapeStyle(Color.accentColor.opacity(0.12))
                        : AnyShapeStyle(.quaternary.opacity(0.22))
                )
                .frame(width: tileWidth, height: imageBoxHeight)

            if let loadedImage {
                Image(nsImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: tileWidth, height: imageBoxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.tertiary)
                    .frame(width: tileWidth, height: imageBoxHeight)
            }
        }
        .frame(width: tileWidth, height: imageBoxHeight)
        .task(id: "\(record.activePath)#\(Int(tileWidth))") {
            if let cached = store.thumbnailImage(for: record.activePath, maxSize: tileWidth) {
                loadedImage = cached
                return
            }
            let image = await store.thumbnailImageAsync(for: record.activePath, maxSize: tileWidth)
            if !Task.isCancelled {
                loadedImage = image
            }
        }
    }
}

@available(macOS 26.0, *)
private struct PlaceGenerationSpec: Hashable {
    var title: String
    var focus: String
}

@available(macOS 26.0, *)
private enum PlacesWorldMapPanelMode: String, CaseIterable {
    case map = "Map"
    case coverage = "Coverage"
    case unconfirmed = "Review Unconfirmed"
}

enum PlacesViewMode: String, CaseIterable {
    case grid = "Grid"
    case detail = "Detail"
    case world = "World Map"
    case map3d = "3D Map"
    case landmarks = "Landmarks"
    case review = "Review Queue"
    case library = "All Images"
}

// MARK: - Sidebar

@available(macOS 26.0, *)
struct PlacesSidebarView: View {
    @Bindable var store: AnimateStore
    @Binding var viewMode: PlacesViewMode
    @Binding var selectedLandmarkID: UUID?
    let allImageCount: Int
    let worldSnapshot: PlacesWorldbuildingSnapshot
    @AppStorage("animate.places.workflowMode.v1") private var workflowModeRawValue = PlaceWorkflowMode.photorealistic.rawValue
    @State private var dropTargetPlaceID: UUID?
    @State private var dropTargetLandmarkID: UUID?
    @State private var landmarksExpanded = true
    @State private var placesExpanded = true

    private var workflowMode: PlaceWorkflowMode {
        PlaceWorkflowMode(rawValue: workflowModeRawValue) ?? .photorealistic
    }

    private var sortedLandmarkProfiles: [PlaceLandmarkProfile] {
        store.placesWorkflowLibrary.landmarkProfiles.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind.displayName.localizedCaseInsensitiveCompare(rhs.kind.displayName) == .orderedAscending
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    init(
        store: AnimateStore,
        viewMode: Binding<PlacesViewMode>,
        selectedLandmarkID: Binding<UUID?> = .constant(nil),
        allImageCount: Int,
        worldSnapshot: PlacesWorldbuildingSnapshot = .empty
    ) {
        _store = Bindable(store)
        _viewMode = viewMode
        _selectedLandmarkID = selectedLandmarkID
        self.allImageCount = allImageCount
        self.worldSnapshot = worldSnapshot
    }

    var body: some View {
        OperaChromeSidebarList {
            sidebarButton(
                title: "Review Queue",
                subtitle: "\(worldSnapshot.totalFlaggedReviews) flagged item\(worldSnapshot.totalFlaggedReviews == 1 ? "" : "s")",
                systemImage: "checklist.unchecked",
                isSelected: viewMode == .review
            ) {
                viewMode = .review
            }

            sidebarButton(
                title: "World Map",
                subtitle: "\(worldSnapshot.routes.count) routes • \(worldSnapshot.unconfirmedCaptureCount) unconfirmed",
                systemImage: "map",
                isSelected: viewMode == .world
            ) {
                viewMode = .world
            }

            sidebarButton(
                title: "3D Map",
                subtitle: "terrain + buildings preview",
                systemImage: "mountain.2",
                isSelected: viewMode == .map3d
            ) {
                viewMode = .map3d
            }

            sidebarButton(
                title: "Show All Images",
                subtitle: "\(allImageCount) generated images",
                systemImage: "square.grid.2x2",
                isSelected: viewMode == .library
            ) {
                viewMode = .library
            }

            DisclosureGroup(isExpanded: $landmarksExpanded) {
                VStack(spacing: 2) {
                    if sortedLandmarkProfiles.isEmpty {
                        sidebarEmptyState("No landmark profiles yet.")
                    } else {
                        ForEach(sortedLandmarkProfiles) { profile in
                            Button {
                                selectedLandmarkID = profile.id
                                viewMode = .landmarks
                            } label: {
                                OperaChromeSidebarRow(
                                    isSelected: (viewMode == .landmarks && selectedLandmarkID == profile.id) || dropTargetLandmarkID == profile.id
                                ) {
                                    landmarkRow(profile)
                                        .padding(.leading, 18)
                                }
                            }
                            .buttonStyle(.plain)
                            .dropDestination(for: URL.self) { urls, _ in
                                let accepted = store.attachDroppedImagesToLandmark(urls: urls, landmarkID: profile.id)
                                if accepted {
                                    selectedLandmarkID = profile.id
                                    viewMode = .landmarks
                                }
                                return accepted
                            } isTargeted: { isTargeted in
                                if isTargeted {
                                    dropTargetLandmarkID = profile.id
                                } else if dropTargetLandmarkID == profile.id {
                                    dropTargetLandmarkID = nil
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                sidebarDisclosureLabel(
                    title: "Landmarks",
                    subtitle: "\(store.placesWorkflowLibrary.landmarkProfiles.count) profiles",
                    systemImage: "building.columns"
                )
            }

            DisclosureGroup(isExpanded: $placesExpanded) {
                VStack(spacing: 2) {
                    if store.backgrounds.isEmpty {
                        sidebarEmptyState("No places yet — import a place or sync the place list.")
                    } else {
                        ForEach(store.backgrounds) { place in
                            Button {
                                store.selectedBackgroundID = place.id
                                viewMode = .detail
                            } label: {
                                OperaChromeSidebarRow(
                                    isSelected: (viewMode == .detail && store.selectedBackgroundID == place.id) || dropTargetPlaceID == place.id
                                ) {
                                    placeRow(place)
                                        .padding(.leading, 18)
                                }
                            }
                            .buttonStyle(.plain)
                            .dropDestination(for: URL.self) { urls, _ in
                                store.selectedBackgroundID = place.id
                                let accepted = store.attachDroppedImagesToPlace(urls: urls, placeID: place.id, workflow: workflowMode)
                                if accepted {
                                    viewMode = .detail
                                }
                                return accepted
                            } isTargeted: { isTargeted in
                                if isTargeted {
                                    dropTargetPlaceID = place.id
                                } else if dropTargetPlaceID == place.id {
                                    dropTargetPlaceID = nil
                                }
                            }
                            .contextMenu {
                                Button("Delete Place", systemImage: "trash", role: .destructive) {
                                    store.deletePlace(place.id)
                                }
                            }
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                sidebarDisclosureLabel(
                    title: "Places",
                    subtitle: "\(store.backgrounds.count) total",
                    systemImage: "square.stack.3d.up"
                )
            }
        }
    }

    @ViewBuilder
    private func sidebarButton(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            OperaChromeSidebarRow(isSelected: isSelected) {
                HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? OperaChromeTheme.textPrimary : OperaChromeTheme.textSecondary)
                        .frame(width: 24, height: 24)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sidebarDisclosureLabel(
        title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func sidebarEmptyState(_ text: String) -> some View {
        OperaChromeSidebarRow {
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .padding(.leading, 18)
        }
    }

    @ViewBuilder
    private func placeRow(_ place: BackgroundPlate) -> some View {
        HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
            if let path = place.approvedImagePath(for: workflowMode),
               let url = store.resolvedCharacterAssetURL(for: path) {
                CachedThumbnailView(path: url.path, size: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: workflowMode == .photorealistic ? "camera" : "paintbrush.pointed")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(place.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(1)
                Text(placeMetricsSubtitle(for: place))
                    .font(.system(size: 10))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func landmarkRow(_ profile: PlaceLandmarkProfile) -> some View {
        HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
            if let url = resolvedLandmarkImageURL(for: profile.primaryImagePath ?? profile.exteriorImagePath ?? profile.galleryImagePaths.first) {
                CachedThumbnailView(path: url.path, size: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "building.columns")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(profile.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(1)
                Text(landmarkMetricsSubtitle(for: profile))
                    .font(.system(size: 10))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
        }
    }

    private func placeMetricsSubtitle(for place: BackgroundPlate) -> String {
        let nodeCount = worldSnapshot.placeNodeCounts[place.id] ?? 0
        let flaggedCount = worldSnapshot.placeFlaggedCounts[place.id] ?? 0
        if nodeCount > 0 || flaggedCount > 0 {
            return "\(nodeCount) node\(nodeCount == 1 ? "" : "s") • \(flaggedCount) flag\(flaggedCount == 1 ? "" : "s")"
        }
        let imageCount = place.imagePaths(for: workflowMode).count
        return "\(imageCount) \(workflowMode.shortLabel.lowercased()) image\(imageCount == 1 ? "" : "s")"
    }

    private func landmarkMetricsSubtitle(for profile: PlaceLandmarkProfile) -> String {
        let imageCount = profile.galleryImagePaths.count
        let anchorText = profile.mapPoint == nil ? "needs anchor" : "anchored"
        return "\(imageCount) image\(imageCount == 1 ? "" : "s") • \(anchorText)"
    }

    private func resolvedLandmarkImageURL(for path: String?) -> URL? {
        guard let path else { return nil }
        if let resolved = store.resolvedCharacterAssetURL(for: path) {
            return resolved
        }
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

@available(macOS 26.0, *)
private extension PlacesPageView {
    var projectURL: URL? {
        store.workingOWPURL ?? store.owpURL
    }

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
    @Binding var viewMode: PlacesViewMode
    @State private var selectedLandmarkID: UUID?
    @State private var workflowSelectedPaths: Set<String> = []
    @State private var workflowLastClickedPath: String?
    @State private var allLibrarySelectedPaths: Set<String> = []
    @State private var allLibraryLastClickedPath: String?
    @State private var thumbnailBaseSize: CGFloat = 140
    @State private var libraryFlagFilter: GeneratedBackgroundFlagFilterMode = .all
    @State private var libraryMinimumRating: Int? = nil
    @State private var libraryWorkflowFilter: GeneratedBackgroundWorkflowFilterMode = .all
    @State private var librarySearchText = ""
    @State private var showEditBatchManager = false
    @State private var placePendingPlan: PendingPlaceGenerationPlan?
    @State private var placeGenerationDrafts: [GeminiGenerationDraft] = []
    @State private var placeGenerationErrorMessage: String?
    @State private var selectedWorldRouteID: String?
    @State private var selectedWorldNodeID: String?
    @State private var selectedWorldReviewID: String?
    @State private var selectedWorldCaptureRecordID: UUID?
    @State private var worldMapViewportHeight: CGFloat = 520
    @State private var worldMapViewportDragOrigin: CGFloat = 520
    @State private var isWorldMapViewportResizing = false
    @State private var worldMapPanelMode: PlacesWorldMapPanelMode = .map
    @State private var cachedWorldbuildingSnapshot: PlacesWorldbuildingSnapshot = .empty
    @State private var worldNodeDrafts: [String: PlacesWorldNodeDraft] = [:]
    @AppStorage("animate.places.workflowMode.v1") private var workflowModeRawValue = PlaceWorkflowMode.photorealistic.rawValue
    var showSidebar: Bool = true

    private var selectedPlace: BackgroundPlate? {
        store.selectedPlace
    }

    private var sortedLandmarkProfiles: [PlaceLandmarkProfile] {
        store.placesWorkflowLibrary.landmarkProfiles.sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return lhs.kind.displayName.localizedCaseInsensitiveCompare(rhs.kind.displayName) == .orderedAscending
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private var selectedLandmarkProfile: PlaceLandmarkProfile? {
        if let selectedLandmarkID,
           let profile = store.placesWorkflowLibrary.landmarkProfiles.first(where: { $0.id == selectedLandmarkID }) {
            return profile
        }
        return sortedLandmarkProfiles.first
    }

    private var workflowMode: PlaceWorkflowMode {
        get { PlaceWorkflowMode(rawValue: workflowModeRawValue) ?? .photorealistic }
        nonmutating set { workflowModeRawValue = newValue.rawValue }
    }

    private var workflowConfig: PlaceWorkflowRenderConfig {
        store.workflowConfig(for: workflowMode)
    }

    private var worldbuildingSnapshot: PlacesWorldbuildingSnapshot {
        cachedWorldbuildingSnapshot.applying(nodeDrafts: worldNodeDrafts)
    }

    private var worldbuildingSnapshotRefreshToken: String {
        let generatedCount = store.placesWorkflowLibrary.generatedImageRecords.count
        let generatedUpdated = store.placesWorkflowLibrary.generatedImageRecords
            .map(\.updatedAt)
            .max()?
            .timeIntervalSinceReferenceDate ?? 0
        let routeCount = store.placesWorkflowLibrary.worldGraph.routes.count
        let nodeCount = store.placesWorkflowLibrary.worldGraph.nodes.count
        let reviewCount = store.placesWorkflowLibrary.continuityReviews.count
        let backgroundCount = store.backgrounds.count
        return [
            workflowMode.rawValue,
            store.placesWorkflowLibrary.masterMapImagePath ?? "",
            String(backgroundCount),
            String(generatedCount),
            String(Int(generatedUpdated)),
            String(routeCount),
            String(nodeCount),
            String(reviewCount)
        ].joined(separator: "|")
    }

    private var selectedWorldRoute: PlacesWorldbuildingSnapshot.Route? {
        worldbuildingSnapshot.route(withID: selectedWorldRouteID)
            ?? selectedPlace.flatMap { place in
                worldbuildingSnapshot.routes.first(where: { $0.placeID == place.id })
            }
            ?? worldbuildingSnapshot.routes.first
    }

    private var selectedWorldNode: PlacesWorldbuildingSnapshot.Node? {
        worldbuildingSnapshot.node(withID: selectedWorldNodeID)
            ?? selectedWorldRoute.flatMap { route in
                route.nodeIDs.compactMap { worldbuildingSnapshot.node(withID: $0) }.first
            }
            ?? worldbuildingSnapshot.nodes.first
    }

    private var selectedWorldCapture: PlacesWorldbuildingSnapshot.Capture? {
        worldbuildingSnapshot.capture(withRecordID: selectedWorldCaptureRecordID)
            ?? worldbuildingSnapshot.capture(withRecordID: store.selectedGeneratedBackgroundRecordID)
            ?? worldbuildingSnapshot.captures.first
    }

    private func refreshWorldbuildingSnapshot() {
        cachedWorldbuildingSnapshot = PlacesWorldbuildingSnapshot.make(store: store, workflowMode: workflowMode)
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if showSidebar {
                    PlacesSidebarView(
                        store: store,
                        viewMode: $viewMode,
                        selectedLandmarkID: $selectedLandmarkID,
                        allImageCount: allBackgroundImagePaths.count,
                        worldSnapshot: worldbuildingSnapshot
                    )
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
        .sheet(item: $placePendingPlan) { plan in
            GeminiGenerationPreflightSheet(
                store: store,
                drafts: $placeGenerationDrafts,
                title: plan.title,
                confirmTitle: plan.confirmTitle,
                onConfirm: { drafts, mode in
                    guard let place = store.backgrounds.first(where: { $0.id == plan.placeID }) else {
                        placePendingPlan = nil
                        return
                    }
                    placePendingPlan = nil
                    switch mode {
                    case .standard:
                        runPlaceGeneration(drafts, for: place, workflow: plan.workflow)
                    case .batch:
                        submitPlaceBatch(drafts, for: place, workflow: plan.workflow)
                    }
                },
                onCancel: {
                    placePendingPlan = nil
                }
            )
        }
        .sheet(isPresented: $showEditBatchManager) {
            NavigationStack {
                ScrollView {
                    PlaceGeminiBatchInspectorSection(store: store, showsHeading: false)
                        .padding()
                }
                .frame(minWidth: 640, minHeight: 520)
                .navigationTitle("Manage Gemini Edit Batch")
            }
        }
        .onAppear {
            store.syncGeneratedBackgroundLibrary()
            store.refreshSuggestedLandmarkProfiles()
            if selectedLandmarkID == nil {
                selectedLandmarkID = sortedLandmarkProfiles.first?.id
            }
            refreshWorldbuildingSnapshot()
        }
        .onChange(of: worldbuildingSnapshotRefreshToken) { _, _ in
            refreshWorldbuildingSnapshot()
        }
        .onChange(of: store.selectedGeneratedBackgroundRecordID) { _, newValue in
            selectedWorldCaptureRecordID = newValue
            guard let newValue,
                  let record = store.placesWorkflowLibrary.generatedImageRecords.first(where: { $0.id == newValue }) else {
                return
            }
            allLibrarySelectedPaths = [record.activePath]
            allLibraryLastClickedPath = record.activePath
        }
        .onChange(of: store.placesWorkflowLibrary.landmarkProfiles.map(\.id)) { _, newValue in
            if let selectedLandmarkID, newValue.contains(selectedLandmarkID) {
                return
            }
            self.selectedLandmarkID = sortedLandmarkProfiles.first?.id
        }
        .alert("Place Generation", isPresented: placeGenerationAlertBinding) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(placeGenerationErrorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                switch viewMode {
                case .grid:
                    overviewSection
                    workflowModePicker
                    locationGridSection
                case .detail:
                    placeDetailSection
                case .world:
                    worldMapSection
                case .map3d:
                    map3DSection
                case .landmarks:
                    landmarksSection
                case .review:
                    reviewQueueSection
                case .library:
                    allImagesLibrarySection
                }
            }
            .padding()
        }
    }

    // MARK: - Overview

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Places")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Gemini-native place workflow with a master map, landmark references, photoreal vs animated variants, and prompt-preview generation before anything is sent.")
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
                        store.setMasterPlaceMapFromPicker()
                    } label: {
                        Label(store.effectivePlacesMasterMapPath() == nil ? "Import Map" : "Replace Map", systemImage: "map")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.addGlobalPlaceReferenceImagesFromPicker(category: .bridge)
                    } label: {
                        Label("Add Landmark Refs", systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.importPlacesFromPicker()
                    } label: {
                        Label("Import Place", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 10) {
                overviewPill(title: "Total Places", value: "\(store.backgrounds.count)", systemImage: "map")
                overviewPill(title: "Photo Outputs", value: "\(store.backgrounds.reduce(0) { $0 + $1.imagePaths.count })", systemImage: "camera")
                overviewPill(title: "Animated Outputs", value: "\(store.backgrounds.reduce(0) { $0 + $1.animatedImagePaths.count })", systemImage: "paintpalette")
                overviewPill(title: "Landmark Refs", value: "\(store.placesWorkflowLibrary.landmarkReferences.count)", systemImage: "square.stack.3d.up")
            }

            HStack(alignment: .top, spacing: 16) {
                masterMapOverviewCard
                landmarkReferenceOverviewCard
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var masterMapOverviewCard: some View {
        let explicitPath = store.placesWorkflowLibrary.masterMapImagePath
        let effectivePath = store.effectivePlacesMasterMapPath()
        let inferredPath = store.inferredPlacesMasterMapRecord()?.activePath
        let isInferredMap = explicitPath == nil && effectivePath != nil && effectivePath == inferredPath

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Master Map", systemImage: "map")
                    .font(.headline)
                if isInferredMap {
                    Text("Using inferred map reference")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.18), in: Capsule())
                }
                Spacer()
                if let effectivePath {
                    Button("Open World Map") {
                        viewMode = .world
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Reveal") {
                        showInFinder(at: effectivePath)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if isInferredMap {
                        Button("Use as Master Map") {
                            store.useGeneratedImageAsMasterPlaceMap(effectivePath)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            if let path = effectivePath,
               let url = resolvedAssetURL(for: path),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                emptyCard("No master map yet", systemImage: "map", message: "Import the approved valley map here so outdoor prompts can inherit the same geography.")
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var landmarkReferenceOverviewCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Landmark References", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
                Text("\(store.placesWorkflowLibrary.landmarkReferences.count) items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.placesWorkflowLibrary.landmarkReferences.isEmpty {
                emptyCard("No landmark refs yet", systemImage: "square.stack.3d.up", message: "Add bridge or landmark reference photos here so prompts can reuse them across multiple places.")
                    .frame(maxWidth: .infinity)
                    .frame(height: 220)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(store.placesWorkflowLibrary.landmarkReferences) { reference in
                            PlaceReferenceThumbnailCard(
                                store: store,
                                reference: reference,
                                onRemove: { store.removeGlobalPlaceReference(reference.id) },
                                onShowInFinder: { showInFinder(at: reference.imagePath) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: 220)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    // MARK: - Pickers / Grid

    private var workflowModePicker: some View {
        HStack(spacing: 12) {
            Picker("", selection: Binding(
                get: { workflowMode },
                set: { workflowMode = $0 }
            )) {
                ForEach(PlaceWorkflowMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)

            Picker("", selection: $viewMode) {
                ForEach(PlacesViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
            .labelsHidden()
            .fixedSize(horizontal: true, vertical: false)

            Spacer()

            Text(viewModeHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var allBackgroundImagePaths: [String] {
        store.allBackgroundHierarchyImagePaths()
    }

    private var viewModeHelpText: String {
        switch viewMode {
        case .library:
            return "Drag images from the library onto a place in the sidebar to attach them to the current \(workflowMode.displayName.lowercased()) workflow."
        case .world:
            switch worldMapPanelMode {
            case .map:
                return "Map mode anchors generated images, camera direction, and canon decisions to the master map."
            case .coverage:
                return "Coverage mode surfaces missing or weak exterior and interior coverage so you can spot worldbuilding gaps without opening terminal tools."
            case .unconfirmed:
                return "Review provisional placements, homeless images, and interior-building links before confirming them onto the world map."
            }
        case .landmarks:
            return "Landmarks canonize key structures like the bridge, clinic, gathering space, and Amira’s home, and infer interior anchors from the pins you’ve already set."
        case .review:
            return "Review Queue highlights worldbuilding mismatches that still need a canon decision."
        case .map3d:
            return "3D Map previews the valley from the Scripts/3d-map-pipeline outputs (heightmap + water + building bumps). Live while the dev server is running; otherwise falls back to the static viewer."
        default:
            return "Current workflow: \(workflowMode.displayName)"
        }
    }

    @ViewBuilder
    private func worldLibraryFilterButton(
        systemImage: String,
        tint: Color = .accentColor,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
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

    private var filteredGeneratedBackgroundRecords: [GeneratedBackgroundLibraryRecord] {
        store.generatedBackgroundRecords(
            flagFilter: libraryFlagFilter,
            minimumRating: libraryMinimumRating,
            workflowFilter: libraryWorkflowFilter,
            searchText: librarySearchText
        )
    }

    private func focusWorldContext(for placeID: UUID) {
        if let route = worldbuildingSnapshot.routes.first(where: { $0.placeID == placeID }) {
            selectedWorldRouteID = route.id
            selectedWorldNodeID = route.nodeIDs.first
        } else {
            selectedWorldRouteID = nil
            selectedWorldNodeID = worldbuildingSnapshot.nodes.first(where: { $0.placeID == placeID })?.id
        }
    }

    private func openPlaceDetail(_ placeID: UUID?) {
        guard let placeID else { return }
        store.selectedBackgroundID = placeID
        focusWorldContext(for: placeID)
        viewMode = .detail
    }

    private func prepareRouteGeneration(for route: PlacesWorldbuildingSnapshot.Route) {
        guard let placeID = route.placeID,
              let place = store.backgrounds.first(where: { $0.id == placeID }) else {
            store.statusMessage = "Select a place-backed route before preparing generation."
            return
        }

        let orderedNodes = route.nodeIDs
            .compactMap { nodeID in worldbuildingSnapshot.node(withID: nodeID) }
            .sorted { $0.sequenceIndex < $1.sequenceIndex }
        guard !orderedNodes.isEmpty else {
            store.statusMessage = "This route needs at least one world node before generation."
            return
        }

        let config = store.workflowConfig(for: workflowMode)
        let routeTitle = route.title
        let drafts = Array(orderedNodes.prefix(8)).map { node in
            GeminiGenerationDraft(
                title: "Route \(node.sequenceIndex + 1) • \(node.title)",
                destinationDescription: "\(place.name) • \(routeTitle) • \(workflowMode.displayName)",
                prompt: routePrompt(
                    for: node,
                    route: route,
                    place: place,
                    workflow: workflowMode,
                    config: config
                ),
                contextNote: routeGenerationContextNote(
                    for: node,
                    route: route,
                    place: place,
                    workflow: workflowMode
                ),
                model: config.model,
                aspectRatio: config.aspectRatio,
                imageSize: config.imageSize,
                referenceItems: routeGenerationReferenceDrafts(
                    for: node,
                    route: route,
                    place: place,
                    workflow: workflowMode
                ),
                linkedPlaceID: place.id,
                routeID: uuid(from: route.id),
                worldNodeID: uuid(from: node.id),
                cameraPose: WorldCameraPose(
                    yawDegrees: node.heading,
                    pitchDegrees: node.pitch,
                    rollDegrees: node.roll,
                    focalLengthMM: node.focalLength
                ),
                mapPoint: WorldMapPoint(x: Double(node.position.x), y: Double(node.position.y)),
                pricingMode: .standard
            )
        }

        guard !drafts.isEmpty else {
            store.statusMessage = "This route could not produce any generation drafts."
            return
        }

        store.selectedBackgroundID = placeID
        selectedWorldRouteID = route.id
        selectedWorldNodeID = drafts.first?.worldNodeID?.uuidString.lowercased() ?? route.nodeIDs.first
        placeGenerationDrafts = drafts
        placePendingPlan = PendingPlaceGenerationPlan(
            placeID: place.id,
            workflow: workflowMode,
            routeID: uuid(from: route.id),
            nodeIDs: drafts.compactMap(\.worldNodeID),
            count: drafts.count,
            title: "\(place.name) • \(routeTitle) • \(drafts.count) route draft\(drafts.count == 1 ? "" : "s")",
            confirmTitle: drafts.count == 1 ? "Generate Route Draft" : "Generate Route Drafts"
        )
    }

    private func setCanonForNode(_ node: PlacesWorldbuildingSnapshot.Node) {
        let candidatePath = node.canonImagePath ?? node.sourceImagePath
        guard let candidatePath else {
            store.statusMessage = "This node does not have a canon candidate yet."
            return
        }
        if let nodeID = uuid(from: node.id) {
            store.setCanonWorldNodeImage(candidatePath, nodeID: nodeID, workflow: workflowMode)
        }
        if let placeID = node.placeID {
            store.setApprovedPlaceImage(candidatePath, placeID: placeID, workflow: workflowMode)
        }
        store.selectGeneratedBackgroundRecord(for: candidatePath)
        store.statusMessage = "Updated canon image for \(node.placeName)"
    }

    private func approveReview(_ review: PlacesWorldbuildingSnapshot.Review) {
        if let recordID = review.recordID {
            store.setGeneratedBackgroundRating(5, for: recordID)
        }
        if let reviewID = uuid(from: review.id) {
            store.updateContinuityReviewStatus(.approved, reviewID: reviewID)
        }
        if let nodeID = review.nodeID.flatMap(uuid(from:)),
           let candidatePath = review.candidatePath {
            store.setCanonWorldNodeImage(candidatePath, nodeID: nodeID, workflow: review.workflow)
        }
        if let placeID = review.placeID,
           let candidatePath = review.candidatePath {
            store.setApprovedPlaceImage(candidatePath, placeID: placeID, workflow: review.workflow)
            store.selectGeneratedBackgroundRecord(for: candidatePath)
        }
        selectedWorldReviewID = review.id
        if let placeID = review.placeID {
            focusWorldContext(for: placeID)
        }
        store.statusMessage = "Approved canon candidate for \(review.placeName)"
    }

    private func rejectReview(_ review: PlacesWorldbuildingSnapshot.Review) {
        if let reviewID = uuid(from: review.id) {
            store.updateContinuityReviewStatus(.rejected, reviewID: reviewID)
        }
        if let recordID = review.recordID {
            let record = store.placesWorkflowLibrary.generatedImageRecords.first(where: { $0.id == recordID })
            if record?.isRejected == false {
                store.toggleGeneratedBackgroundRejected(recordID)
            }
        }
        selectedWorldReviewID = review.id
        store.statusMessage = "Rejected candidate for \(review.placeName)"
    }

    private func jumpToReviewTarget(_ review: PlacesWorldbuildingSnapshot.Review) {
        if let placeID = review.placeID {
            store.selectedBackgroundID = placeID
        }
        selectedWorldReviewID = review.id
        selectedWorldRouteID = review.routeID ?? selectedWorldRouteID
        selectedWorldNodeID = review.nodeID ?? selectedWorldNodeID
        viewMode = .world
    }

    private var locationGridSection: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)], spacing: 16) {
            ForEach(store.backgrounds) { place in
                PlaceGridCard(
                    store: store,
                    place: place,
                    workflowMode: workflowMode,
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

    private var allImagesLibrarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            workflowModePicker

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("All Generated Background Images")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Browse Gemini-generated images from Animate/backgrounds. Raw inspiration photos are excluded. Drag any thumbnail onto a place in the sidebar to add it to that place’s current \(workflowMode.displayName.lowercased()) workflow.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        showEditBatchManager = true
                    } label: {
                        Label(
                            store.hasPendingGeneratedBackgroundEdits
                                ? "Manage Batch (\(store.placesWorkflowLibrary.pendingEditQueue.count))"
                                : "Manage Batch",
                            systemImage: "tray.full"
                        )
                    }
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)

                    Button {
                        viewMode = .review
                    } label: {
                        Label("Open Review Queue", systemImage: "checklist.unchecked")
                    }
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)

                    Button {
                        viewMode = .grid
                    } label: {
                        Label("Back to Places", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            HStack(spacing: 12) {
                Picker("", selection: $libraryWorkflowFilter) {
                    ForEach(GeneratedBackgroundWorkflowFilterMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .labelsHidden()
                .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: 8) {
                    worldLibraryFilterButton(
                        systemImage: "square.grid.2x2",
                        isSelected: libraryFlagFilter == .all
                    ) {
                        libraryFlagFilter = .all
                    }
                    .help("Show all generated backgrounds")

                    worldLibraryFilterButton(
                        systemImage: "flag.slash",
                        isSelected: libraryFlagFilter == .unflagged
                    ) {
                        libraryFlagFilter = .unflagged
                    }
                    .help("Show only unflagged images")

                    worldLibraryFilterButton(
                        systemImage: "xmark.circle.fill",
                        isSelected: libraryFlagFilter == .rejected
                    ) {
                        libraryFlagFilter = .rejected
                    }
                    .help("Show only rejected images")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.12), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)

                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { rating in
                        worldLibraryFilterButton(
                            systemImage: libraryMinimumRating != nil && rating <= (libraryMinimumRating ?? 0) ? "star.fill" : "star",
                            tint: .yellow,
                            isSelected: libraryMinimumRating == rating
                        ) {
                            libraryMinimumRating = libraryMinimumRating == rating ? nil : rating
                        }
                        .help("Show \(rating)-star and higher images")
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.12), in: Capsule())
                .fixedSize(horizontal: true, vertical: false)

                TextField("Filter by filename, summary, keyword, or prompt", text: $librarySearchText)
                    .textFieldStyle(.roundedBorder)

                if !librarySearchText.isEmpty || libraryFlagFilter != .all || libraryMinimumRating != nil || libraryWorkflowFilter != .all {
                    Button("Clear") {
                        librarySearchText = ""
                        libraryFlagFilter = .all
                        libraryMinimumRating = nil
                        libraryWorkflowFilter = .all
                    }
                    .buttonStyle(.bordered)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            PlaceAllImagesGallerySection(
                store: store,
                title: "Background Library",
                records: filteredGeneratedBackgroundRecords,
                thumbnailBaseSize: $thumbnailBaseSize,
                selectedPaths: $allLibrarySelectedPaths,
                lastClickedPath: $allLibraryLastClickedPath
            )
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var placeDetailSection: some View {
        if let place = selectedPlace {
            VStack(alignment: .leading, spacing: 16) {
                placeHeader(place)
                shotRequirementsSection(place)
                workflowOutputSection(place)
                placeReferencesSection(place)
                angleImagesSection(place)
                placeNotesSection(place)
                generationStudioSection(place)
            }
        } else {
            VStack(spacing: 16) {
                OperaChromeEmptyState(
                    systemImage: "building.2",
                    title: "No Place Selected",
                    message: "Select a place from the sidebar or grid to manage references, variants, and Gemini generations."
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

    private var map3DSection: some View {
        PlacesMap3DView()
            .frame(maxWidth: .infinity)
    }

    private var worldMapSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            workflowModePicker

            Picker("", selection: $worldMapPanelMode) {
                ForEach(PlacesWorldMapPanelMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420, alignment: .leading)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Worldbuilding Map")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Pin generated images onto the master map, inspect their inferred camera direction, and compare continuity at a glance before committing new canon.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        overviewPill(title: "Pinned Images", value: "\(worldbuildingSnapshot.totalPinnedCaptures)", systemImage: "photo.badge.location")
                        overviewPill(title: "Nodes", value: "\(worldbuildingSnapshot.nodes.count)", systemImage: "scope")
                        overviewPill(title: "Flags", value: "\(worldbuildingSnapshot.totalFlaggedReviews)", systemImage: "exclamationmark.triangle")
                        overviewPill(title: "Unplaced", value: "\(worldbuildingSnapshot.unplacedCaptureCount)", systemImage: "mappin.slash")
                        overviewPill(title: "Homeless", value: "\(worldbuildingSnapshot.homelessCaptureCount)", systemImage: "house.slash")
                    }
                    .padding(.vertical, 2)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Button {
                            worldMapPanelMode = .coverage
                        } label: {
                            Label("Coverage", systemImage: "chart.bar.xaxis")
                        }
                        .buttonStyle(.bordered)
                        .fixedSize(horizontal: true, vertical: false)

                        Button {
                            worldMapPanelMode = .unconfirmed
                        } label: {
                            Label("Review Unconfirmed", systemImage: "mappin.slash.circle")
                        }
                        .buttonStyle(.bordered)
                        .fixedSize(horizontal: true, vertical: false)

                        Button {
                            addWorldRouteForCurrentPlace()
                        } label: {
                            Label("Add Route", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .fixedSize(horizontal: true, vertical: false)

                        Button {
                            addWorldNodeForCurrentContext()
                        } label: {
                            Label("Add Node", systemImage: "scope")
                        }
                        .buttonStyle(.bordered)
                        .disabled(store.selectedBackgroundID == nil && selectedWorldRoute == nil)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            if worldMapPanelMode == .map {
                PlacesWorldMapBrowserView(
                    store: store,
                    snapshot: worldbuildingSnapshot,
                    workflowMode: workflowMode,
                    selectedPlace: selectedPlace,
                    isLiveResizing: isWorldMapViewportResizing,
                    selectedRouteID: selectedWorldRoute?.id,
                    selectedNodeID: selectedWorldNode?.id,
                    selectedCaptureID: selectedWorldCapture?.recordID,
                    onSelectRoute: { route in
                        selectedWorldRouteID = route.id
                        selectedWorldNodeID = route.nodeIDs.first
                        if let placeID = route.placeID {
                            store.selectedBackgroundID = placeID
                        }
                    },
                    onSelectNode: { node in
                        selectedWorldNodeID = node.id
                        selectedWorldRouteID = node.routeID
                        if let placeID = node.placeID {
                            store.selectedBackgroundID = placeID
                        }
                    },
                    onSelectCapture: { capture in
                        selectedWorldCaptureRecordID = capture.recordID
                        if let placeID = capture.placeID {
                            store.selectedBackgroundID = placeID
                        }
                        if let recordID = capture.recordID,
                           let record = store.placesWorkflowLibrary.generatedImageRecords.first(where: { $0.id == recordID }) {
                            store.selectGeneratedBackgroundRecord(for: record.activePath)
                        }
                        selectedWorldNodeID = capture.worldNodeID
                        selectedWorldRouteID = capture.routeID
                    }
                )
                .frame(height: worldMapViewportHeight)

                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(.quaternary.opacity(0.8))
                    .frame(width: 92, height: 8)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                isWorldMapViewportResizing = true
                                worldMapViewportHeight = min(max(420, worldMapViewportDragOrigin + value.translation.height), 1100)
                            }
                            .onEnded { value in
                                worldMapViewportHeight = min(max(420, worldMapViewportDragOrigin + value.translation.height), 1100)
                                worldMapViewportDragOrigin = worldMapViewportHeight
                                isWorldMapViewportResizing = false
                            }
                    )
                    .onAppear {
                        worldMapViewportDragOrigin = worldMapViewportHeight
                    }
                    .help("Drag to resize the World Map vertically.")

                PlacesWorldCaptureInspectorCard(
                    capture: selectedWorldCapture,
                    store: store,
                    onOpenPlace: { placeID in
                        openPlaceDetail(placeID)
                    },
                    onOpenLibrary: {
                        viewMode = .library
                    },
                    onOpenUnconfirmed: {
                        worldMapPanelMode = .unconfirmed
                    },
                    onReveal: { path in
                        showInFinder(at: path)
                    }
                )

                HStack(alignment: .top, spacing: 16) {
                    PlacesWorldRouteInspectorCard(
                        route: selectedWorldRoute,
                        flaggedReviewCount: selectedWorldRoute.map { worldbuildingSnapshot.reviews(for: $0.id).count } ?? 0,
                        onAnalyzeContinuity: { route in
                            selectedWorldRouteID = route.id
                            Task { @MainActor in
                                await analyzeContinuity(for: route)
                            }
                        },
                        onPrepareGeneration: { route in
                            prepareRouteGeneration(for: route)
                        },
                        onOpenPlace: { placeID in
                            openPlaceDetail(placeID)
                        }
                    )

                    PlacesWorldNodeInspectorCard(
                        node: selectedWorldNode,
                        store: store,
                        draft: selectedWorldNode.flatMap { worldNodeDrafts[$0.id] },
                        onApplyDraft: { node, draft in
                            worldNodeDrafts[node.id] = draft
                            applyDraft(draft, to: node)
                        },
                        onUseCanon: { node in
                            setCanonForNode(node)
                        },
                        onOpenPlace: { placeID in
                            openPlaceDetail(placeID)
                        }
                    )
                }
            } else if worldMapPanelMode == .coverage {
                coverageSection
            } else {
                unconfirmedPlacementsSection
            }

            PlacesWorldBatchMonitorSection(
                store: store,
                snapshot: worldbuildingSnapshot,
                projectURL: projectURL,
                workflowMode: workflowMode,
                selectedRouteID: selectedWorldRoute?.id,
                selectedPlaceID: store.selectedBackgroundID ?? selectedWorldRoute?.placeID ?? selectedWorldNode?.placeID,
                onOpenPlace: { placeID in
                    openPlaceDetail(placeID)
                },
                onFocusRoute: { routeID in
                    guard let routeID else { return }
                    selectedWorldRouteID = routeID
                    if let route = worldbuildingSnapshot.route(withID: routeID) {
                        selectedWorldNodeID = route.nodeIDs.first
                        if let placeID = route.placeID {
                            store.selectedBackgroundID = placeID
                        }
                    }
                }
            )

            if !worldbuildingSnapshot.routes.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(worldbuildingSnapshot.routes) { route in
                            Button {
                                selectedWorldRouteID = route.id
                                selectedWorldNodeID = route.nodeIDs.first
                                if let placeID = route.placeID {
                                    store.selectedBackgroundID = placeID
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(route.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        if route.flaggedCount > 0 {
                                            Label("\(route.flaggedCount)", systemImage: "exclamationmark.triangle.fill")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text(route.lengthLabel)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(route.generationSummary)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .padding(14)
                                .frame(width: 220, alignment: .leading)
                                .background(
                                    (route.id == selectedWorldRoute?.id ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08)),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var reviewQueueSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            workflowModePicker
            PlacesWorldReviewQueueSection(
                store: store,
                snapshot: worldbuildingSnapshot,
                selectedReviewID: selectedWorldReviewID,
                onSelectReview: { review in
                    selectedWorldReviewID = review.id
                },
                onApproveReview: { review in
                    approveReview(review)
                },
                onRejectReview: { review in
                    rejectReview(review)
                },
                onJumpToNode: { review in
                    jumpToReviewTarget(review)
                }
            )
        }
    }

    private var unconfirmedPlacementsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            PlacesWorldUnconfirmedPlacementSection(
                store: store,
                snapshot: worldbuildingSnapshot,
                workflowMode: workflowMode,
                selectedCaptureRecordID: selectedWorldCaptureRecordID,
                onSelectCapture: { capture in
                    selectedWorldCaptureRecordID = capture.recordID
                    if let placeID = capture.placeID {
                        store.selectedBackgroundID = placeID
                    }
                    if let recordID = capture.recordID,
                       let record = store.placesWorkflowLibrary.generatedImageRecords.first(where: { $0.id == recordID }) {
                        store.selectGeneratedBackgroundRecord(for: record.activePath)
                    }
                },
                onOpenPlace: { placeID in
                    openPlaceDetail(placeID)
                },
                onOpenLibrary: {
                    viewMode = .library
                },
                onFocusMap: { capture in
                    selectedWorldCaptureRecordID = capture.recordID
                    selectedWorldNodeID = capture.worldNodeID
                    selectedWorldRouteID = capture.routeID
                    if let placeID = capture.placeID {
                        store.selectedBackgroundID = placeID
                    }
                    viewMode = .world
                }
            )
        }
    }

    private var coverageSection: some View {
        PlacesWorldCoverageDashboardView(
            store: store,
            snapshot: worldbuildingSnapshot,
            workflowMode: workflowMode,
            onOpenPlace: { placeID in
                openPlaceDetail(placeID)
            },
            onOpenReviewUnconfirmed: {
                worldMapPanelMode = .unconfirmed
            }
        )
    }

    private func placeHeader(_ place: BackgroundPlate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.title2)
                        .fontWeight(.semibold)

                    HStack(spacing: 8) {
                        if !place.locationCategory.isEmpty {
                            categoryBadge(place.locationCategory)
                        }
                        Text(workflowMode.displayName)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background((workflowMode == .photorealistic ? Color.blue : Color.purple).opacity(0.15), in: Capsule())
                            .foregroundStyle(workflowMode == .photorealistic ? .blue : .purple)
                    }
                    Text("Manage map-driven continuity, landmark references, and separate photoreal vs animated output libraries for this place.")
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
                        focusWorldContext(for: place.id)
                        viewMode = .world
                    } label: {
                        Label("Open on Map", systemImage: "map")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        store.importPlacesFromPicker()
                    } label: {
                        Label("Import Place", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack(spacing: 10) {
                placeSummaryPill(title: "\(workflowMode.shortLabel) Images", value: "\(place.imagePaths(for: workflowMode).count)", systemImage: workflowMode == .photorealistic ? "camera" : "paintbrush.pointed")
                placeSummaryPill(title: "Refs", value: "\(place.referenceImages.count)", systemImage: "photo.stack")
                placeSummaryPill(title: "Scenes", value: "\(sceneUsageCount(for: place.id))", systemImage: "film.stack")
                placeSummaryPill(title: "Approved", value: place.approvedImagePath(for: workflowMode) == nil ? "No" : "Yes", systemImage: "checkmark.seal")
                placeSummaryPill(title: "Nodes", value: "\(worldbuildingSnapshot.placeNodeCounts[place.id] ?? 0)", systemImage: "scope")
                placeSummaryPill(title: "Flags", value: "\(worldbuildingSnapshot.placeFlaggedCounts[place.id] ?? 0)", systemImage: "exclamationmark.triangle")
            }

            HStack {
                Picker("Workflow", selection: Binding(
                    get: { workflowMode },
                    set: { workflowMode = $0 }
                )) {
                    ForEach(PlaceWorkflowMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Spacer()
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

    private var landmarksSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            workflowModePicker

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Landmarks")
                        .font(.title2.weight(.semibold))
                    Text("Canonically define the bridge, clinic, gathering space, Amira’s home, and other landmark families. Exterior pins drive anchor placement; interior places inherit those anchors.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    store.refreshSuggestedLandmarkProfiles()
                    if selectedLandmarkID == nil {
                        selectedLandmarkID = sortedLandmarkProfiles.first?.id
                    }
                    refreshWorldbuildingSnapshot()
                } label: {
                    Label("Refresh Suggestions", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
            }

            if store.placesWorkflowLibrary.landmarkProfiles.isEmpty {
                emptyCard(
                    "No landmark profiles yet",
                    systemImage: "building.columns",
                    message: "Use Refresh Suggestions to seed bridge, clinic, gathering space, home, memorial, and ridge landmark profiles from your current pin placements and canon images."
                )
            } else if let selectedLandmarkProfile {
                PlaceLandmarkDetailView(
                    store: store,
                    workflowMode: workflowMode,
                    profile: selectedLandmarkProfile,
                    thumbnailBaseSize: $thumbnailBaseSize,
                    onPreviewPaths: { paths, index in
                        openQuickLook(for: paths, startingAt: index)
                    },
                    onShowInFinder: { path in
                        showInFinder(at: path)
                    },
                    onCopy: { path in
                        copyImage(at: path)
                    },
                    onOpenPlace: { placeID in
                        openPlaceDetail(placeID)
                    },
                    onRefreshed: {
                        refreshWorldbuildingSnapshot()
                    }
                )
                .id(selectedLandmarkProfile.id)
            } else {
                emptyCard(
                    "Select a landmark",
                    systemImage: "building.columns",
                    message: "Choose a landmark from the sidebar to curate its main image, supporting gallery, and notes."
                )
            }
        }
    }

    private func workflowOutputSection(_ place: BackgroundPlate) -> some View {
        let galleryPaths = place.imagePaths(for: workflowMode)
        let approvedPath = place.approvedImagePath(for: workflowMode)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("\(workflowMode.displayName) Output Library", systemImage: workflowMode == .photorealistic ? "camera" : "paintpalette")
                    .font(.headline)
                Spacer()
                if let status = store.placeGenerationStatus(for: place.id), !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button {
                    store.addImagesToPlaceFromPicker(placeID: place.id, workflow: workflowMode)
                } label: {
                    Label("Import Existing", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }

            if let approvedPath,
               let url = resolvedAssetURL(for: approvedPath),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture(count: 2) {
                        openQuickLook(for: galleryPaths, startingAt: galleryPaths.firstIndex(of: approvedPath) ?? 0)
                    }
            } else {
                emptyCard(
                    "No approved \(workflowMode.displayName.lowercased()) image",
                    systemImage: workflowMode == .photorealistic ? "camera" : "paintpalette",
                    message: workflowMode == .photorealistic
                        ? "Import or generate a place image, then approve the strongest one for continuity."
                        : "Import or generate an animated variant of this place once the photoreal geography is in good shape."
                )
                .frame(height: 220)
            }

            ImageGallerySection(
                store: store,
                title: "\(workflowMode.displayName) Images",
                icon: workflowMode == .photorealistic ? "camera" : "paintpalette",
                paths: galleryPaths,
                thumbnailBaseSize: $thumbnailBaseSize,
                onImport: { store.addImagesToPlaceFromPicker(placeID: place.id, workflow: workflowMode) },
                onRemove: { index in store.removePlaceImage(at: index, placeID: place.id, workflow: workflowMode) },
                onPreview: { index, paths in openQuickLook(for: paths, startingAt: index) },
                onCopy: { path in copyImage(at: path) },
                onShowInFinder: { path in showInFinder(at: path) },
                showsHeader: true,
                selectedPaths: $workflowSelectedPaths,
                lastClickedPath: $workflowLastClickedPath
            )

            if let firstSelected = workflowSelectedPaths.first,
               workflowSelectedPaths.count == 1,
               galleryPaths.contains(firstSelected),
               firstSelected != approvedPath {
                HStack {
                    if worldbuildingSnapshot.placeFlaggedCounts[place.id, default: 0] > 0 {
                        Button {
                            focusWorldContext(for: place.id)
                            viewMode = .review
                        } label: {
                            Label(
                                "Review \(worldbuildingSnapshot.placeFlaggedCounts[place.id, default: 0]) Flagged Item\(worldbuildingSnapshot.placeFlaggedCounts[place.id, default: 0] == 1 ? "" : "s")",
                                systemImage: "checklist.unchecked"
                            )
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()
                    Button("Use Selected As Approved") {
                        store.setApprovedPlaceImage(firstSelected, placeID: place.id, workflow: workflowMode)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func placeReferencesSection(_ place: BackgroundPlate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Place-Specific References", systemImage: "photo.stack")
                    .font(.headline)
                Spacer()
                Menu {
                    ForEach(PlaceReferenceImage.Category.allCases, id: \.self) { category in
                        Button(category.displayName) {
                            store.addPlaceReferenceImagesFromPicker(placeID: place.id, category: category)
                        }
                    }
                } label: {
                    Label("Add Ref", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            if place.referenceImages.isEmpty {
                emptyCard("No place-specific refs", systemImage: "photo.stack", message: "Add reference photos here for this location only — bridge details, market materials, clinic facade, and so on.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 12)], spacing: 12) {
                    ForEach(place.referenceImages) { reference in
                        PlaceReferenceThumbnailCard(
                            store: store,
                            reference: reference,
                            onRemove: { store.removePlaceReferenceImage(reference.id, placeID: place.id) },
                            onShowInFinder: { showInFinder(at: reference.imagePath) }
                        )
                    }
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

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
                Text("No scenes currently use this location, so no specific shot requirements are inferred yet.")
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

                let scenesUsingPlace = store.sceneReferences(for: place.id)
                if !scenesUsingPlace.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Scenes using this place:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(scenesUsingPlace) { scene in
                            HStack(spacing: 6) {
                                Image(systemName: "film")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(scene.sceneName)
                                    .font(.caption)
                                Text(scene.songPath)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func angleImagesSection(_ place: BackgroundPlate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Angle / Coverage Images", systemImage: "camera.viewfinder")
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
                emptyCard("No angle images yet", systemImage: "camera.viewfinder", message: "Add coverage images tagged by shot type, angle, and time of day to help the place stay consistent from shot to shot.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: 12)], spacing: 12) {
                    ForEach(place.angleImages) { angleImage in
                        AngleImageCard(store: store, angleImage: angleImage, placeID: place.id)
                    }
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func placeNotesSection(_ place: BackgroundPlate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Story Notes + Prompt Notes", systemImage: "text.alignleft")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Story / location notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Workflow-specific prompt notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: Binding(
                    get: { place.workflowPromptNotes },
                    set: { store.updatePlaceWorkflowPromptNotes($0, placeID: place.id) }
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
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func generationStudioSection(_ place: BackgroundPlate) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Gemini Generation Studio", systemImage: "sparkles")
                        .font(.headline)
                    Text("Build drafts from the continuity workflow, preview the exact prompts and reference stack, then send them immediate or as a watchdog-backed batch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isGeneratingPlaceImage(place.id) {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                generationConfigPill(title: "Model", value: workflowConfig.model.displayName, systemImage: "cpu")
                generationConfigPill(title: "Aspect", value: workflowConfig.aspectRatio, systemImage: "aspectratio")
                generationConfigPill(title: "Size", value: workflowConfig.imageSize, systemImage: "arrow.up.left.and.arrow.down.right")
                generationConfigPill(title: "Lens", value: workflowConfig.lensDescription.isEmpty ? "Default" : workflowConfig.lensDescription, systemImage: "camera.metering.matrix")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Draft sets")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("1 Hero Draft") {
                        prepareGenerationPlan(for: place, count: 1)
                    }
                    .buttonStyle(.borderedProminent)

                    Button("4 Coverage Drafts") {
                        prepareGenerationPlan(for: place, count: 4)
                    }
                    .buttonStyle(.bordered)

                    Button("8 Batch-Ready Drafts") {
                        prepareGenerationPlan(for: place, count: 8)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if workflowMode == .animated {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.purple)
                    Text("Animated workflow can use the photoreal approved image as a continuity anchor, then reinterpret it into the animated style instead of copying the frame 1:1.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(.quaternary.opacity(0.12), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    // MARK: - Generation Logic

    private func prepareGenerationPlan(for place: BackgroundPlate, count: Int) {
        let specs = Array(generationSpecs(for: place).prefix(max(1, count)))
        let refs = generationReferenceDrafts(for: place, workflow: workflowMode)
        let config = store.workflowConfig(for: workflowMode)

        placeGenerationDrafts = specs.map { spec in
            GeminiGenerationDraft(
                title: spec.title,
                destinationDescription: "\(place.name) • \(workflowMode.displayName)",
                prompt: prompt(for: spec, place: place, workflow: workflowMode, config: config),
                contextNote: generationContextNote(for: place, workflow: workflowMode),
                model: config.model,
                aspectRatio: config.aspectRatio,
                imageSize: config.imageSize,
                referenceItems: refs,
                pricingMode: .standard
            )
        }

        let confirm = count == 1 ? "Generate Draft" : "Generate Drafts"
        placePendingPlan = PendingPlaceGenerationPlan(
            placeID: place.id,
            workflow: workflowMode,
            routeID: nil,
            nodeIDs: [],
            count: specs.count,
            title: "\(place.name) • \(workflowMode.displayName) • \(specs.count) draft\(specs.count == 1 ? "" : "s")",
            confirmTitle: confirm
        )
    }

    private func generationSpecs(for place: BackgroundPlate) -> [PlaceGenerationSpec] {
        if place.isExteriorLike {
            return [
                .init(title: "Hero Establishing", focus: "a broad establishing view of the place that clearly reads as inhabited and functional"),
                .init(title: "Approach / Entry", focus: "an approach shot entering the place from the main access route"),
                .init(title: "Main Street Life", focus: "a lived-in main street or lane with daily-life detail and activity cues"),
                .init(title: "Landmark Context", focus: "the place with its most identifiable landmark or structural feature integrated naturally into the frame"),
                .init(title: "Wide Whole Settlement", focus: "a wider, farther-back view that still reads as a living settlement rather than ancient ruins"),
                .init(title: "Civic / Market Area", focus: "a central market, plaza, or civic area with signs of active use"),
                .init(title: "Alternate Wide Angle", focus: "an alternate wide view from a different vantage while preserving the same geography"),
                .init(title: "Blue-Hour Continuity", focus: "the same place at dusk or blue hour, still inhabited and believable"),
            ]
        }

        return [
            .init(title: "Hero Interior", focus: "a cinematic hero view of the interior space"),
            .init(title: "Entry Perspective", focus: "a view from the entry or threshold into the interior"),
            .init(title: "Working Area", focus: "the most actively used portion of the room or interior"),
            .init(title: "Reverse Angle", focus: "a reverse angle of the same space preserving layout continuity"),
            .init(title: "Wide Layout", focus: "a wider view that clarifies the usable layout of the interior"),
            .init(title: "Practical Detail", focus: "practical details and lived-in function without turning into a prop close-up"),
            .init(title: "Atmosphere Variant", focus: "the same interior with stronger mood and cinematic lighting while remaining believable"),
            .init(title: "Secondary Coverage", focus: "a secondary coverage frame that could cut with the hero interior"),
        ]
    }

    private func prompt(
        for spec: PlaceGenerationSpec,
        place: BackgroundPlate,
        workflow: PlaceWorkflowMode,
        config: PlaceWorkflowRenderConfig
    ) -> String {
        let sceneNames = store.sceneReferences(for: place.id).map(\.sceneName)
        let sourceLines = store.sourceLines(for: place.id)
        let locationNotes = place.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let workflowNotes = place.workflowPromptNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        let sceneNote = sceneNames.isEmpty ? "" : "This place appears in scenes: \(sceneNames.joined(separator: ", "))."
        let sourceLineNote = sourceLines.isEmpty ? "" : "Script/place clues: \(sourceLines.prefix(3).joined(separator: " • "))."
        let lens = config.lensDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = config.promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = config.promptSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let bridgeConstraint = bridgeConstraintNote(for: place)

        let workflowLead: String
        switch workflow {
        case .photorealistic:
            workflowLead = "Create a photoreal cinematic still image of \(place.name). The image should look like a real production still or location photograph, not a matte painting or fantasy concept painting."
        case .animated:
            workflowLead = "Create a cinematic animated background frame of \(place.name). Preserve the geography and staging from the references, but reinterpret the result into the animated Amira look instead of copying the source frame 1:1."
        }

        let exteriorCanon = place.isExteriorLike
            ? "Respect the master map and reference geography. If the river is visible, settlement should only appear on the correct side indicated by the references, not on both sides. The town should read as inhabited and maintained, with a mix of worn stone, repaired structures, textiles, awnings, and daily-life detail."
            : "Respect the established architecture and continuity of the place. The room should feel in use and alive, not abandoned or in total ruin."

        return [
            prefix,
            workflowLead,
            "Focus: \(spec.focus).",
            lens.isEmpty ? "" : lens,
            exteriorCanon,
            sceneNote,
            sourceLineNote,
            bridgeConstraint,
            locationNotes.isEmpty ? "" : "Location notes: \(locationNotes)",
            workflowNotes.isEmpty ? "" : "Workflow notes: \(workflowNotes)",
            suffix,
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: " ")
    }

    private func generationReferenceDrafts(for place: BackgroundPlate, workflow: PlaceWorkflowMode) -> [GeminiGenerationReferenceDraft] {
        var drafts: [GeminiGenerationReferenceDraft] = []
        var seen: Set<String> = []

        func append(label: String, path: String?, included: Bool = true) {
            guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard !seen.contains(path) else { return }
            seen.insert(path)
            drafts.append(GeminiGenerationReferenceDraft(label: label, path: path, isIncluded: included))
        }

        if place.isExteriorLike {
            append(label: "Master Map", path: store.effectivePlacesMasterMapPath(), included: true)
        }

        switch workflow {
        case .photorealistic:
            let continuity = store.preferredPlaceContinuityImagePath(for: place, workflow: .photorealistic)
            append(label: "Photoreal Continuity", path: continuity, included: continuity != nil)
        case .animated:
            let photorealContinuity = store.preferredPlaceContinuityImagePath(for: place, workflow: .photorealistic)
            let animatedContinuity = store.preferredPlaceContinuityImagePath(for: place, workflow: .animated)
            append(label: "Photoreal Continuity", path: photorealContinuity, included: photorealContinuity != nil)
            append(label: "Animated Continuity", path: animatedContinuity, included: false)
        }

        for reference in place.referenceImages {
            append(label: "\(reference.category.displayName): \(reference.title)", path: reference.imagePath, included: true)
        }

        let emphasis = "\(place.name) \(place.notes) \(place.workflowPromptNotes)".lowercased()
        for reference in store.placesWorkflowLibrary.landmarkReferences {
            let shouldInclude: Bool
            switch reference.category {
            case .bridge:
                shouldInclude = emphasis.contains("bridge") || emphasis.contains(reference.title.lowercased())
            case .map:
                shouldInclude = false
            default:
                shouldInclude = false
            }
            append(label: "Global \(reference.category.displayName): \(reference.title)", path: reference.imagePath, included: shouldInclude)
        }

        return drafts
    }

    private func generationContextNote(for place: BackgroundPlate, workflow: PlaceWorkflowMode) -> String {
        let scenes = store.sceneReferences(for: place.id).map(\.sceneName)
        let refs = place.referenceImages.map { $0.category.displayName }.joined(separator: ", ")
        return [
            "Workflow: \(workflow.displayName)",
            scenes.isEmpty ? "" : "Scenes: \(scenes.joined(separator: ", "))",
            refs.isEmpty ? "" : "Local refs: \(refs)"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " • ")
    }

    private func bridgeConstraintNote(for place: BackgroundPlate) -> String {
        let emphasis = [
            place.name,
            place.notes,
            place.workflowPromptNotes,
            place.referenceImages.map(\.title).joined(separator: " "),
            place.referenceImages.map(\.notes).joined(separator: " "),
            store.placesWorkflowLibrary.landmarkReferences.map(\.title).joined(separator: " ")
        ]
        .joined(separator: " ")
        .lowercased()

        guard emphasis.contains("bridge") else { return "" }
        return "Bridge continuity requirement: the entire top of the bridge must stay completely flat and open. No raised side stones, parapets, railings, curbs, guard edges, or protective walls should appear on either side of the bridge deck."
    }

    private func routePrompt(
        for node: PlacesWorldbuildingSnapshot.Node,
        route: PlacesWorldbuildingSnapshot.Route,
        place: BackgroundPlate,
        workflow: PlaceWorkflowMode,
        config: PlaceWorkflowRenderConfig
    ) -> String {
        let scenes = store.sceneReferences(for: place.id).map(\.sceneName)
        let sourceLines = store.sourceLines(for: place.id)
        let workflowLead: String
        switch workflow {
        case .photorealistic:
            workflowLead = "Create a photoreal cinematic background plate for \(place.name)."
        case .animated:
            workflowLead = "Create a cinematic animated background frame for \(place.name) that preserves the approved world geography."
        }

        let landmarkLine = node.expectedLandmarks.isEmpty
            ? ""
            : "Expected landmarks in or near frame: \(node.expectedLandmarks.joined(separator: ", "))."
        let routeLine = "This frame is route \(route.title), node \(node.sequenceIndex + 1). Treat it as one stop in a Street-View-like traversal through the world."
        let cameraLine = String(
            format: "Camera pose: heading %.0f°, pitch %.0f°, roll %.0f°, focal length %.0fmm.",
            node.heading,
            node.pitch,
            node.roll,
            node.focalLength
        )
        let mapLine = String(
            format: "Map anchor: normalized x %.3f, y %.3f on the master map.",
            Double(node.position.x),
            Double(node.position.y)
        )
        let continuityLine = "Honor continuity with the neighboring route frames and the master map. Do not invent or remove buildings, trees, terraces, roads, or skyline elements that would break adjacency."
        let sceneNote = scenes.isEmpty ? "" : "Relevant scenes: \(scenes.joined(separator: ", "))."
        let sourceLineNote = sourceLines.isEmpty ? "" : "Script/place clues: \(sourceLines.prefix(3).joined(separator: " • "))."
        let locationNotes = place.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let lens = config.lensDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let bridgeConstraint = node.expectedLandmarks.joined(separator: " ").lowercased().contains("bridge")
            ? "Bridge continuity requirement: whenever the bridge is visible, the entire top of the bridge must stay completely flat and open. No raised side stones, parapets, railings, curbs, guard edges, or protective walls should appear on either side of the bridge deck."
            : bridgeConstraintNote(for: place)

        return [
            config.promptPrefix.trimmingCharacters(in: .whitespacesAndNewlines),
            workflowLead,
            routeLine,
            cameraLine,
            mapLine,
            landmarkLine,
            continuityLine,
            lens,
            sceneNote,
            sourceLineNote,
            bridgeConstraint,
            locationNotes.isEmpty ? "" : "Location notes: \(locationNotes)",
            config.promptSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .joined(separator: " ")
    }

    private func routeGenerationContextNote(
        for node: PlacesWorldbuildingSnapshot.Node,
        route: PlacesWorldbuildingSnapshot.Route,
        place: BackgroundPlate,
        workflow: PlaceWorkflowMode
    ) -> String {
        [
            "Workflow: \(workflow.displayName)",
            "Route: \(route.title)",
            "Node: \(node.sequenceIndex + 1) • \(node.title)",
            node.poseLabel,
            node.focalLabel,
            node.expectedLandmarks.isEmpty ? "" : "Landmarks: \(node.expectedLandmarks.joined(separator: ", "))",
            "Place: \(place.name)"
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " • ")
    }

    private func routeGenerationReferenceDrafts(
        for node: PlacesWorldbuildingSnapshot.Node,
        route: PlacesWorldbuildingSnapshot.Route,
        place: BackgroundPlate,
        workflow: PlaceWorkflowMode
    ) -> [GeminiGenerationReferenceDraft] {
        var drafts = generationReferenceDrafts(for: place, workflow: workflow)
        var seen = Set(drafts.map(\.path))

        func append(label: String, path: String?) {
            guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard !seen.contains(path) else { return }
            seen.insert(path)
            drafts.append(
                GeminiGenerationReferenceDraft(
                    label: label,
                    path: path,
                    isIncluded: true
                )
            )
        }

        let orderedNodes = route.nodeIDs
            .compactMap { nodeID in worldbuildingSnapshot.node(withID: nodeID) }
            .sorted { $0.sequenceIndex < $1.sequenceIndex }
        if let currentIndex = orderedNodes.firstIndex(where: { $0.id == node.id }) {
            if currentIndex > 0 {
                let previousNode = orderedNodes[currentIndex - 1]
                append(label: "Previous Route Node", path: previousNode.canonImagePath ?? previousNode.sourceImagePath)
            }
            append(label: "Current Node Canon", path: node.canonImagePath ?? node.sourceImagePath)
            if currentIndex + 1 < orderedNodes.count {
                let nextNode = orderedNodes[currentIndex + 1]
                append(label: "Next Route Node", path: nextNode.canonImagePath ?? nextNode.sourceImagePath)
            }
        } else {
            append(label: "Current Node Canon", path: node.canonImagePath ?? node.sourceImagePath)
        }

        if node.expectedLandmarks.joined(separator: " ").lowercased().contains("bridge") {
            for reference in store.placesWorkflowLibrary.landmarkReferences where reference.category == .bridge {
                append(label: "Global Bridge Ref: \(reference.title)", path: reference.imagePath)
            }
        }

        return drafts
    }

    private func runPlaceGeneration(
        _ drafts: [GeminiGenerationDraft],
        for place: BackgroundPlate,
        workflow: PlaceWorkflowMode
    ) {
        guard store.isGeminiAllowed() else {
            placeGenerationErrorMessage = "Gemini API calls are blocked. Enable Gemini API Calls in Inspector > Tools."
            return
        }

        store.generatingPlaceIDs.insert(place.id)
        store.placeGenerationStatusByID[place.id] = "Generating…"

        Task { @MainActor in
            defer { store.generatingPlaceIDs.remove(place.id) }
            let service = GeminiImageService()
            do {
                for (index, draft) in drafts.enumerated() {
                    store.placeGenerationStatusByID[place.id] = "Generating \(index + 1) of \(drafts.count)…"
                    let request = GeminiImageService.GenerationRequest(
                        prompt: draft.prompt,
                        referenceImages: buildReferenceImages(from: draft.referenceItems),
                        model: draft.model,
                        aspectRatio: draft.aspectRatio,
                        imageSize: draft.imageSize
                    )
                    store.logGeminiAPICall(endpoint: "image-generation", source: "PlacesPageView.runPlaceGeneration()")
                    let result = try await service.generate(request: request, apiKey: store.geminiAPIKey)
                    _ = try store.storeGeneratedPlaceImage(
                        result.imageData,
                        prompt: draft.prompt,
                        model: draft.model,
                        filenameStem: sanitizedFilenameStem(for: draft.title),
                        for: draft.linkedPlaceID ?? place.id,
                        workflow: workflow,
                        aspectRatio: draft.aspectRatio,
                        imageSize: draft.imageSize,
                        routeID: draft.routeID,
                        worldNodeID: draft.worldNodeID,
                        mapPoint: draft.mapPoint,
                        cameraPose: draft.cameraPose
                    )
                }
                store.placeGenerationStatusByID[place.id] = "Finished \(drafts.count) \(workflow.displayName.lowercased()) draft\(drafts.count == 1 ? "" : "s")."
                store.statusMessage = "Generated \(drafts.count) \(workflow.displayName.lowercased()) place image\(drafts.count == 1 ? "" : "s") for \(place.name)"
            } catch {
                store.placeGenerationStatusByID[place.id] = error.localizedDescription
                placeGenerationErrorMessage = error.localizedDescription
            }
        }
    }

    private func submitPlaceBatch(
        _ drafts: [GeminiGenerationDraft],
        for place: BackgroundPlate,
        workflow: PlaceWorkflowMode
    ) {
        guard let animateURL = store.animateURL else { return }
        guard store.isGeminiAllowed() else {
            placeGenerationErrorMessage = "Gemini API calls are blocked. Enable Gemini API Calls in Inspector > Tools."
            return
        }

        Task { @MainActor in
            do {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
                let stamp = formatter.string(from: Date())
                let placeSlug = PlacesScriptIndexService.fileStem(for: place.name)
                let outputRoot = animateURL
                    .appendingPathComponent("backgrounds")
                    .appendingPathComponent("place-batches")
                    .appendingPathComponent(placeSlug)
                    .appendingPathComponent(workflow.rawValue)
                    .appendingPathComponent(stamp)

                let promptRequests = try drafts.map { draft in
                    GeminiBatchSubmissionPlan.PromptRequest(
                        id: sanitizedFilenameStem(for: draft.title),
                        title: draft.title,
                        prompt: draft.prompt,
                        referencePaths: try resolvedBatchReferencePaths(from: draft.includedReferenceItems)
                    )
                }

                let plan = GeminiBatchSubmissionPlan(
                    characterName: place.name,
                    characterSlug: placeSlug,
                    displayName: "\(placeSlug)-\(workflow.rawValue)-\(stamp.lowercased())",
                    model: drafts.first?.model ?? workflowConfig.model,
                    aspectRatio: drafts.first?.aspectRatio ?? workflowConfig.aspectRatio,
                    imageSize: drafts.first?.imageSize ?? workflowConfig.imageSize,
                    outputRoot: outputRoot,
                    prompts: promptRequests
                )

                let service = GeminiBatchService()
                let submission = try await service.submit(plan: plan, apiKey: store.geminiAPIKey)
                try service.launchWatchdog(metadataPath: submission.metadataPath, apiKey: store.geminiAPIKey)
                let selectedDrafts = drafts.filter(\.isSelected)
                store.registerWorldGenerationBatch(
                    PlaceWorldGenerationBatch(
                        routeID: selectedDrafts.compactMap(\.routeID).first,
                        workflow: workflow,
                        title: plan.displayName,
                        state: "submitted",
                        nodeIDs: selectedDrafts.compactMap(\.worldNodeID),
                        promptCount: submission.promptCount,
                        imageSize: drafts.first?.imageSize ?? workflowConfig.imageSize,
                        model: drafts.first?.model ?? workflowConfig.model,
                        submittedAt: Date(),
                        metadataPath: submission.metadataPath.path,
                        outputRootPath: outputRoot.path,
                        generatedImagePaths: []
                    )
                )
                store.placeGenerationStatusByID[place.id] = "Submitted \(submission.promptCount)-image batch. Watchdog is active."
                store.statusMessage = "Submitted place batch for \(place.name)"
            } catch {
                placeGenerationErrorMessage = error.localizedDescription
            }
        }
    }

    private static let maxPlaceGenerationReferenceImages = 4

    private func buildReferenceImages(from references: [GeminiGenerationReferenceDraft]) -> [GeminiImageService.ReferenceImage] {
        references
            .filter(\.isIncluded)
            .prefix(Self.maxPlaceGenerationReferenceImages)
            .compactMap { reference in
                guard let url = resolvedAssetURL(for: reference.path) else { return nil }
                return GeminiImageService.referenceImage(from: url)
            }
    }

    private func resolvedBatchReferencePaths(from references: [GeminiGenerationReferenceDraft]) throws -> [String] {
        let included = Array(references.filter(\.isIncluded).prefix(Self.maxPlaceGenerationReferenceImages))
        return try included.map { reference in
            if let resolvedURL = resolvedAssetURL(for: reference.path) {
                return resolvedURL.path
            }
            throw NSError(
                domain: "PlacesBatch",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Reference image could not be resolved: \(reference.path)"]
            )
        }
    }

    // MARK: - Helpers

    private func resolvedAssetURL(for path: String) -> URL? {
        if let resolved = store.resolvedCharacterAssetURL(for: path) {
            return resolved
        }
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private var placeGenerationAlertBinding: Binding<Bool> {
        Binding(
            get: { placeGenerationErrorMessage != nil },
            set: { if !$0 { placeGenerationErrorMessage = nil } }
        )
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
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.16), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private func uuid(from rawValue: String) -> UUID? {
        UUID(uuidString: rawValue)
    }

    private func applyDraft(_ draft: PlacesWorldNodeDraft, to node: PlacesWorldbuildingSnapshot.Node) {
        guard let nodeID = uuid(from: node.id) else {
            store.statusMessage = "This preview node is not backed by a persistent world-graph node yet."
            return
        }

        store.updateWorldNodeTitle(draft.title, nodeID: nodeID)
        store.updateWorldNodeCameraPose(
            WorldCameraPose(
                yawDegrees: draft.heading,
                pitchDegrees: draft.pitch,
                rollDegrees: draft.roll,
                focalLengthMM: draft.focalLength
            ),
            nodeID: nodeID
        )
        store.updateWorldNodeLandmarkExpectations(
            expectedTitles: draft.expectedLandmarks,
            forbiddenTitles: [],
            nodeID: nodeID
        )
        store.statusMessage = "Updated world node \(draft.title)"
    }

    private func analyzeContinuity(for route: PlacesWorldbuildingSnapshot.Route) async {
        guard let routeID = uuid(from: route.id) else {
            store.statusMessage = "This route is still a fallback preview and cannot run continuity analysis yet."
            return
        }

        await store.analyzeWorldContinuity(routeID: routeID, workflow: workflowMode)
        selectedWorldReviewID = store.placesWorkflowLibrary.continuityReviews
            .filter { $0.routeID == routeID && $0.workflow == workflowMode }
            .sorted { $0.analyzedAt > $1.analyzedAt }
            .first?
            .id
            .uuidString
            .lowercased()
        viewMode = .review
        store.statusMessage = "Analyzed continuity for \(route.title)"
    }

    private func addWorldRouteForCurrentPlace() {
        let placeID = store.selectedBackgroundID ?? selectedWorldRoute?.placeID ?? selectedWorldNode?.placeID
        let routeID = store.addWorldRoute(name: nil, placeID: placeID)
        selectedWorldRouteID = routeID.uuidString.lowercased()
        if let placeID {
            store.selectedBackgroundID = placeID
        }
        store.statusMessage = "Added world route"
    }

    private func addWorldNodeForCurrentContext() {
        let routeID = selectedWorldRoute.flatMap { uuid(from: $0.id) }
        let placeID = store.selectedBackgroundID ?? selectedWorldRoute?.placeID ?? selectedWorldNode?.placeID
        let nodeID = store.addWorldNode(
            routeID: routeID,
            placeID: placeID,
            title: placeID.flatMap { id in
                store.backgrounds.first(where: { $0.id == id })?.name
            } ?? "View Node"
        )
        selectedWorldNodeID = nodeID.uuidString.lowercased()
        if selectedWorldRouteID == nil {
            selectedWorldRouteID = routeID?.uuidString.lowercased()
        }
        store.statusMessage = "Added world node"
    }

    private func generationConfigPill(title: String, value: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.caption)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func emptyCard(_ title: String, systemImage: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

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
        store.sceneReferences(for: placeID).count
    }

    private func openQuickLook(for paths: [String], startingAt index: Int) {
        let resolvedItems = paths.enumerated().compactMap { offset, path -> (Int, URL)? in
            guard let url = resolvedAssetURL(for: path) else { return nil }
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
        guard let url = resolvedAssetURL(for: path),
              ImageClipboardService.copyImage(at: url) else {
            store.statusMessage = "Could not copy image"
            return
        }
        store.statusMessage = "Copied image"
    }

    private func showInFinder(at path: String) {
        guard let url = resolvedAssetURL(for: path) else {
            store.statusMessage = "Could not locate image"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func sanitizedFilenameStem(for value: String) -> String {
        let slug = value
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: "--", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "place" : slug
    }
}

// MARK: - Place Grid Card

@available(macOS 26.0, *)
struct PlaceGridCard: View {
    let store: AnimateStore
    let place: BackgroundPlate
    let workflowMode: PlaceWorkflowMode
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
                ZStack(alignment: .topTrailing) {
                    thumbnailView
                        .frame(height: 130)
                        .frame(maxWidth: .infinity)
                        .clipped()

                    VStack(alignment: .trailing, spacing: 4) {
                        if !place.locationCategory.isEmpty {
                            categoryBadge(place.locationCategory)
                        }
                        Text(workflowMode.shortLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(8)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(place.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    HStack(spacing: 12) {
                        Label("\(place.imagePaths(for: workflowMode).count)", systemImage: workflowMode == .photorealistic ? "photo" : "paintpalette")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if sceneUsageCount > 0 {
                            Label("\(sceneUsageCount)", systemImage: "film")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !requiredShots.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: coveredCount >= requiredShots.count ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(coveredCount >= requiredShots.count ? .green : .orange)
                            Text("\(coveredCount)/\(requiredShots.count) angles")
                                .font(.caption2)
                                .foregroundStyle(coveredCount >= requiredShots.count ? .green : .orange)
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
        if let path = place.approvedImagePath(for: workflowMode),
           let url = store.resolvedCharacterAssetURL(for: path),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.gray.opacity(0.1)
                VStack(spacing: 6) {
                    Image(systemName: workflowMode == .photorealistic ? "camera" : "paintpalette")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No \(workflowMode.shortLabel.lowercased()) image")
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

// MARK: - Landmark Detail

@available(macOS 26.0, *)
private struct PlaceLandmarkDetailView: View {
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
                selectedPaths: $selectedPaths,
                lastClickedPath: $lastClickedPath,
                onDropURLs: { urls in
                    let accepted = store.attachDroppedImagesToLandmark(urls: urls, landmarkID: profile.id)
                    if accepted {
                        onRefreshed()
                    }
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
            if accepted {
                onRefreshed()
            }
            return accepted
        }
        .onAppear {
            notesDraft = profile.notes
            lastClickedPath = primaryImagePath
        }
        .onChange(of: profile.notes) { _, newValue in
            if notesDraft != newValue {
                notesDraft = newValue
            }
        }
        .onChange(of: profile.primaryImagePath) { _, newValue in
            if lastClickedPath == nil {
                lastClickedPath = newValue
            }
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
                if let selectedGalleryPath,
                   selectedGalleryPath != primaryImagePath {
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

            if let primaryImagePath,
               let url = resolvedAssetURL(for: primaryImagePath),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        Text("MAIN")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(14)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        store.selectGeneratedBackgroundRecord(for: primaryImagePath)
                    }
                    .onTapGesture(count: 2) {
                        if let index = galleryPaths.firstIndex(of: primaryImagePath) {
                            onPreviewPaths(galleryPaths, index)
                        }
                    }
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "photo.badge.plus")
                                .font(.system(size: 28))
                                .foregroundStyle(.secondary)
                            Text("No main landmark image yet")
                                .font(.headline)
                            Text("Drag images here from Show All Images or import existing files to start curating this landmark.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                        }
                        .padding(24)
                    }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var linkedPlacesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Linked Places", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("Exterior Anchor")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Exterior Anchor", selection: Binding(
                    get: { profile.exteriorPlaceID },
                    set: { newValue in
                        store.setLandmarkProfileExteriorPlace(newValue, landmarkID: profile.id)
                        onRefreshed()
                    }
                )) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(exteriorPlaces) { place in
                        Text(place.name).tag(Optional(place.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Interior Reference")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Interior Reference", selection: Binding(
                    get: { profile.interiorPlaceID },
                    set: { newValue in
                        store.setLandmarkProfileInteriorPlace(newValue, landmarkID: profile.id)
                        onRefreshed()
                    }
                )) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(interiorPlaces) { place in
                        Text(place.name).tag(Optional(place.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            if let mapPoint = profile.mapPoint {
                Text("Anchor: x \(String(format: "%.3f", mapPoint.x)) • y \(String(format: "%.3f", mapPoint.y))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No confirmed map anchor yet. Pick an exterior anchor place or assign a map-placed image and refresh suggestions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if let exteriorPlaceID = profile.exteriorPlaceID {
                    Button("Open Exterior") {
                        onOpenPlace(exteriorPlaceID)
                    }
                    .buttonStyle(.bordered)
                }
                if let interiorPlaceID = profile.interiorPlaceID {
                    Button("Open Interior") {
                        onOpenPlace(interiorPlaceID)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Landmark Notes", systemImage: "note.text")
                .font(.headline)
            TextField(
                "Bridge scale, roof materials, no-modernity rules, required geography cues…",
                text: $notesDraft,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(4...8)
            .onSubmit {
                store.updateLandmarkProfileNotes(notesDraft, landmarkID: profile.id)
            }

            HStack {
                Spacer()
                Button("Save Notes") {
                    store.updateLandmarkProfileNotes(notesDraft, landmarkID: profile.id)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var galleryToolbar: some View {
        HStack(spacing: 10) {
            Text("Drag images in from Show All Images, or import files directly into this landmark gallery.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if let selectedGalleryPath {
                Button("Reveal Selected") {
                    onShowInFinder(selectedGalleryPath)
                }
                .buttonStyle(.bordered)
                if selectedGalleryPath != primaryImagePath {
                    Button("Set Selected as Main") {
                        store.setLandmarkProfilePrimaryImagePath(selectedGalleryPath, landmarkID: profile.id)
                        onRefreshed()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func clearSelectionIfNeeded(removedPaths: [String]) {
        if let lastClickedPath, removedPaths.contains(lastClickedPath) {
            self.lastClickedPath = nil
            store.selectGeneratedBackgroundRecord(for: nil)
        }
        selectedPaths.subtract(removedPaths)
    }

    private func resolvedAssetURL(for path: String) -> URL? {
        if let resolved = store.resolvedCharacterAssetURL(for: path) {
            return resolved
        }
        if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
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

    private func exteriorScore(_ place: BackgroundPlate) -> Int {
        var score = 0
        if place.approvedImagePath(for: workflowMode) != nil || place.approvedImagePath != nil { score += 100 }
        if placeNameHasExteriorCue(place.name) { score += 40 }
        if placeNameHasInteriorCue(place.name) { score -= 60 }
        return score
    }

    private func isInteriorPlace(_ place: BackgroundPlate) -> Bool {
        if placeNameHasInteriorCue(place.name) && !placeNameHasExteriorCue(place.name) {
            return true
        }
        switch profile.kind {
        case .amiraHome, .clinic:
            return !placeNameHasExteriorCue(place.name)
        case .gatheringSpace:
            let lower = place.name.lowercased()
            return lower.contains("evening") || lower.contains("back alleys")
        default:
            return false
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.18), in: Capsule())
    }
}

// MARK: - Reference Card

@available(macOS 26.0, *)
private struct PlaceLandmarkProfileCard: View {
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

    private var exteriorImageCandidates: [String] {
        var values: [String] = []
        if let current = profile.exteriorImagePath { values.append(current) }
        if let place = exteriorPlaces.first(where: { $0.id == profile.exteriorPlaceID }) {
            values.append(contentsOf: place.imagePaths(for: workflowMode))
            if let approved = place.approvedImagePath(for: workflowMode) ?? place.approvedImagePath {
                values.append(approved)
            }
        }
        values.append(contentsOf: matchingGeneratedRecords(preferredInterior: false).map(\.activePath))
        return uniqueNormalizedPaths(values)
    }

    private var interiorImageCandidates: [String] {
        var values: [String] = []
        if let current = profile.interiorImagePath { values.append(current) }
        if let place = interiorPlaces.first(where: { $0.id == profile.interiorPlaceID }) {
            values.append(contentsOf: place.imagePaths(for: workflowMode))
            if let approved = place.approvedImagePath(for: workflowMode) ?? place.approvedImagePath {
                values.append(approved)
            }
        }
        values.append(contentsOf: matchingGeneratedRecords(preferredInterior: true).map(\.activePath))
        return uniqueNormalizedPaths(values)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.title)
                        .font(.headline)
                    HStack(spacing: 8) {
                        pill(profile.kind.displayName, systemImage: "building.columns")
                        if profile.mapPoint != nil {
                            pill("Anchored", systemImage: "mappin.and.ellipse")
                        }
                        if profile.exteriorImagePath != nil {
                            pill("Exterior Canon", systemImage: "camera")
                        }
                        if profile.interiorImagePath != nil {
                            pill("Interior Canon", systemImage: "house")
                        }
                    }
                }

                Spacer()

                Button {
                    store.refreshSuggestedLandmarkProfiles()
                    onRefreshed()
                } label: {
                    Label("Reinfer", systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
            }

            if let mapPoint = profile.mapPoint {
                Text("Map anchor: x \(String(format: "%.3f", mapPoint.x)), y \(String(format: "%.3f", mapPoint.y))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No confirmed map anchor yet. Set or refine an exterior pin first, then refresh suggestions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 18) {
                landmarkImageColumn(
                    title: "Exterior Canon",
                    placeSelection: Binding(
                        get: { profile.exteriorPlaceID },
                        set: { newValue in
                            store.setLandmarkProfileExteriorPlace(newValue, landmarkID: profile.id)
                            onRefreshed()
                        }
                    ),
                    placeOptions: exteriorPlaces,
                    imageSelection: Binding(
                        get: { profile.exteriorImagePath },
                        set: { newValue in
                            store.setLandmarkProfileExteriorImagePath(newValue, landmarkID: profile.id)
                            onRefreshed()
                        }
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
                        set: { newValue in
                            store.setLandmarkProfileInteriorPlace(newValue, landmarkID: profile.id)
                            onRefreshed()
                        }
                    ),
                    placeOptions: interiorPlaces,
                    imageSelection: Binding(
                        get: { profile.interiorImagePath },
                        set: { newValue in
                            store.setLandmarkProfileInteriorImagePath(newValue, landmarkID: profile.id)
                            onRefreshed()
                        }
                    ),
                    imageOptions: interiorImageCandidates,
                    currentPath: profile.interiorImagePath,
                    accent: .orange,
                    openPlaceAction: onOpenPlace
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Landmark Notes")
                    .font(.subheadline.weight(.semibold))
                TextField("Bridge scale, clinic facade rules, interior constraints…", text: $notesDraft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
                    .onSubmit {
                        store.updateLandmarkProfileNotes(notesDraft, landmarkID: profile.id)
                    }
                HStack {
                    Spacer()
                    Button("Save Notes") {
                        store.updateLandmarkProfileNotes(notesDraft, landmarkID: profile.id)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onAppear {
            notesDraft = profile.notes
        }
        .onChange(of: profile.notes) { _, newValue in
            if notesDraft != newValue {
                notesDraft = newValue
            }
        }
    }

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
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Picker(title, selection: placeSelection) {
                Text("None").tag(Optional<UUID>.none)
                ForEach(placeOptions) { place in
                    Text(place.name).tag(Optional(place.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            Picker("\(title) Image", selection: imageSelection) {
                Text("None").tag(Optional<String>.none)
                ForEach(imageOptions, id: \.self) { path in
                    Text(imageLabel(for: path)).tag(Optional(path))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            ZStack(alignment: .bottomTrailing) {
                if let currentPath,
                   let url = store.resolvedCharacterAssetURL(for: currentPath) ?? (FileManager.default.fileExists(atPath: currentPath) ? URL(fileURLWithPath: currentPath) : nil) {
                    CachedThumbnailView(path: url.path, size: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(accent.opacity(0.35), lineWidth: 1)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                        .frame(height: 180)
                        .overlay(
                            Label("No image selected", systemImage: "photo")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(maxWidth: .infinity)

            HStack {
                if let placeID = placeSelection.wrappedValue {
                    Button("Open Place") {
                        openPlaceAction(placeID)
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                if let currentPath {
                    Button("Reveal") {
                        onShowInFinder(currentPath)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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
            return "\(String(repeating: "★", count: rating)) \(filename)"
        }
        return filename
    }

    private func matchingGeneratedRecords(preferredInterior: Bool) -> [GeneratedBackgroundLibraryRecord] {
        store.placesWorkflowLibrary.generatedImageRecords
            .filter { record in
                guard record.workflow == workflowMode, !record.isRejected else { return false }
                return landmarkKind(for: record) == profile.kind
            }
            .sorted { lhs, rhs in
                recordScore(lhs, preferredInterior: preferredInterior) > recordScore(rhs, preferredInterior: preferredInterior)
            }
    }

    private func recordScore(_ record: GeneratedBackgroundLibraryRecord, preferredInterior: Bool) -> Int {
        let lower = [record.activePath, record.summary, record.sourcePrompt]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
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
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
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
        if placeNameHasInteriorCue(place.name) && !placeNameHasExteriorCue(place.name) {
            return true
        }
        switch profile.kind {
        case .amiraHome, .clinic:
            return !placeNameHasExteriorCue(place.name)
        case .gatheringSpace:
            let lower = place.name.lowercased()
            return lower.contains("evening") || lower.contains("back alleys")
        default:
            return false
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
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.18), in: Capsule())
    }
}

// MARK: - Reference Card

@available(macOS 26.0, *)
private struct PlaceReferenceThumbnailCard: View {
    let store: AnimateStore
    let reference: PlaceReferenceImage
    let onRemove: () -> Void
    let onShowInFinder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                if let url = store.resolvedCharacterAssetURL(for: reference.imagePath) ?? (FileManager.default.fileExists(atPath: reference.imagePath) ? URL(fileURLWithPath: reference.imagePath) : nil) {
                    CachedThumbnailView(path: url.path, size: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.1))
                        .frame(width: 150, height: 150)
                }

                Menu {
                    Button("Show in Finder") { onShowInFinder() }
                    Button("Remove", systemImage: "trash", role: .destructive) { onRemove() }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .padding(6)
                }
                .menuStyle(.borderlessButton)
            }

            Text(reference.title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(reference.category.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.quaternary.opacity(0.2), in: Capsule())
        }
        .frame(width: 150, alignment: .leading)
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
        .frame(width: 300)
    }
}
