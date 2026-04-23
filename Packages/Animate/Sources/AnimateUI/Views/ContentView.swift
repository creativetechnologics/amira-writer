import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct ContentView: View {
    @Bindable var store: AnimateStore
    var appName: String = "Animate"

    @AppStorage("novotro.animate.showInspector") private var showInspector: Bool = true
    @AppStorage("novotro.animate.sidebarVisible") private var sidebarVisible: Bool = true
    @AppStorage("novotro.animate.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.animate.selectedPage") private var selectedPage: AnimatePage = .animate

    @AppStorage("novotro.animate.inspector.width") private var inspectorWidth: Double = 320
    @AppStorage("novotro.places.viewMode.v1") private var placesViewModeRaw: String = PlacesViewMode.grid.rawValue
    @State private var showAPISettings: Bool = false
    @State private var animateWorkspaceState = AnimateWorkspaceState()

    private var projectTitle: String {
        store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var placesViewModeBinding: Binding<PlacesViewMode> {
        Binding(
            get: { PlacesViewMode(rawValue: placesViewModeRaw) ?? .grid },
            set: { placesViewModeRaw = $0.rawValue }
        )
    }

    private var activeDetailTitle: String {
        switch effectiveSelectedPage {
        case .script:
            return store.selectedScene?.name ?? "Animate workspace"
        case .characters:
            return store.selectedCharacter?.name ?? "Character packages and rigs"
        case .places:
            return store.selectedPlace?.name ?? "Set and location imagery"
        case .props:
            return "Scene objects, vehicles, and interactive props"
        case .animate:
            return store.selectedScene?.name ?? "Canvas staging"
        case .timeline:
            return store.selectedScene?.name ?? "Timeline sequencing"
        }
    }

    var body: some View {
        Group {
            if store.owpURL == nil {
                AnimateSharedProjectRequiredView(appName: appName)
            } else {
                workspaceBody
            }
        }

        .onReceive(NotificationCenter.default.publisher(for: AnimateAppSignals.toggleInspectorNotification)) { _ in
            showInspector.toggle()
        }
        .onReceive(NotificationCenter.default.publisher(for: AnimateAppSignals.spacebarPlayPauseNotification)) { _ in
            store.togglePlayback()
        }
        .onReceive(NotificationCenter.default.publisher(for: AnimateAppSignals.openFileNotification)) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            Task { @MainActor in
                await store.openOWP(url: url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AnimateAppSignals.switchPageNotification)) { notification in
            if let page = notification.userInfo?["page"] as? AnimatePage {
                selectedPage = normalizedPage(page)
            }
        }
        .onAppear {
            selectedPage = normalizedPage(selectedPage)
        }
        .sheet(isPresented: $store.showGenerationSheet) {
            GeminiGenerationView(store: store)
        }
        .sheet(isPresented: $store.showRigEditor) {
            if let charID = store.selectedCharacterID {
                CharacterRigEditor(store: store, characterID: charID)
                    .frame(minWidth: 700, minHeight: 500)
            }
        }
        .sheet(isPresented: $store.showExportSheet) {
            ExportView(store: store)
        }
        .sheet(isPresented: $showAPISettings) {
            APISettingsSheet(
                store: store,
                onDismiss: { showAPISettings = false }
            )
        }
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebarContent
                    .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ANIMATION")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(projectTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text(activeDetailTitle)
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    HStack(spacing: 6) {
                        if let badgeLabel = store.collaborationBadgeLabel {
                            OperaChromeStatusBadge(
                                title: badgeLabel,
                                systemImage: store.collaborationBadgeSystemImage,
                                showsProgress: store.isAgentSyncInProgress
                            )
                        }
                        ForEach(AnimatePage.allCases.filter { $0 != .script && $0 != .characters && $0 != .places && $0 != .props }) { page in
                            OperaChromeActionButton(
                                title: page.rawValue,
                                systemImage: page.systemImage,
                                isSelected: effectiveSelectedPage == page
                            ) {
                                selectedPage = page
                            }
                        }
                        OperaChromeActionButton(
                            systemImage: "gearshape",
                            isSelected: showAPISettings
                        ) {
                            showAPISettings = true
                        }
                    }

                    EmptyView()
                }
            } content: {
                pageContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showInspector {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: effectiveSelectedPage.rawValue
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showInspector = false
                            }
                        }
                    }
                } content: {
                    InspectorView(
                        store: store,
                        currentPage: effectiveSelectedPage,
                        animateWorkspaceState: animateWorkspaceState
                    )
                }
                .frame(width: max(inspectorWidth, minimumInspectorWidth))
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
        .onChange(of: effectiveSelectedPage) { _, newPage in
            if newPage == .animate && inspectorWidth < minimumInspectorWidth {
                inspectorWidth = minimumInspectorWidth
            }
        }
    }

    private var effectiveSelectedPage: AnimatePage {
        normalizedPage(selectedPage)
    }

    private var minimumInspectorWidth: Double {
        effectiveSelectedPage == .animate ? 360 : 250
    }

    private func normalizedPage(_ page: AnimatePage) -> AnimatePage {
        switch page {
        case .script, .characters, .places, .props:
            .animate
        case .animate, .timeline:
            page
        }
    }

    @ViewBuilder
    private var sidebarContent: some View {
        switch effectiveSelectedPage {
        case .characters:
            // Characters page shows character list in sidebar
            OperaChromeFlatPane(
                headerPadding: OperaChromeSidebarMetrics.headerPadding
            ) {
                OperaChromePaneHeader(
                    eyebrow: "ANIMATE",
                    title: "Characters",
                    subtitle: ""
                ) {
                    Button {
                        store.addCharacter()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(OperaChromeTheme.raisedBackground.opacity(0.5))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Add Character")
                }
            } content: {
                CharactersSidebarView(store: store)
            }
        case .places:
            OperaChromeFlatPane(
                headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                    OperaChromePaneHeader(
                        eyebrow: "ANIMATE",
                        title: "Places",
                        subtitle: "\(store.backgrounds.count) sets"
                    ) { EmptyView() }
                } content: {
                    PlacesSidebarView(
                        store: store,
                        viewMode: placesViewModeBinding,
                        allImageCount: store.placesWorkflowLibrary.generatedImageRecords.count
                    )
                }
        default:
            // All other pages show scenes in sidebar
            OperaChromeFlatPane(
                headerPadding: OperaChromeSidebarMetrics.headerPadding
            ) {
                OperaChromePaneHeader(
                    eyebrow: "ANIMATE",
                    title: "Scenes",
                    subtitle: "\(store.scenes.count) staged"
                ) { EmptyView() }
            } content: {
                SidebarView(store: store)
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch effectiveSelectedPage {
        case .script:
            AnimatePageView(store: store, workspaceState: animateWorkspaceState)
        case .characters:
            CharactersPageView(store: store, showSidebar: false)
        case .places:
            PlacesPageView(store: store, viewMode: placesViewModeBinding, showSidebar: false)
        case .props:
            // Props has its own dedicated workspace; this fallback shows animate.
            AnimatePageView(store: store, workspaceState: animateWorkspaceState)
        case .animate:
            AnimatePageView(store: store, workspaceState: animateWorkspaceState)
        case .timeline:
            TimelinePageView(store: store)
        }
    }



    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        inspectorWidth = min(
            max(inspectorWidth - Double(delta), minimumInspectorWidth),
            600
        )
    }
}

@available(macOS 26.0, *)
private struct AnimateSharedProjectRequiredView: View {
    let appName: String

    var body: some View {
        OperaChromeEmptyState(
            systemImage: "sparkles.tv",
            title: "Open A Project In \(appName)",
            message: "Use File > Open Project to pick a local Amira project folder from disk."
        )
    }
}
