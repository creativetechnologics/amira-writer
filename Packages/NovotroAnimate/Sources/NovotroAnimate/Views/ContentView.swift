import SwiftUI
import NovotroProjectKit

@available(macOS 26.0, *)
struct ContentView: View {
    @Bindable var store: AnimateStore
    var appName: String = "Novotro Animate"

    @AppStorage("novotro.animate.showInspector") private var showInspector: Bool = true
    @AppStorage("novotro.animate.sidebarVisible") private var sidebarVisible: Bool = true
    @AppStorage("novotro.animate.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.animate.selectedPage") private var selectedPage: AnimatePage = .animate
    @State private var sidebarDragOrigin: Double?

    private var projectTitle: String {
        store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var activeDetailTitle: String {
        switch selectedPage {
        case .script:
            return store.selectedScene?.name ?? "Scene direction editor"
        case .characters:
            return store.selectedCharacter?.name ?? "Character packages and rigs"
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
                await store.openOWP(url: url, preferService: false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AnimateAppSignals.switchPageNotification)) { notification in
            if let page = notification.userInfo?["page"] as? AnimatePage {
                selectedPage = page
            }
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
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
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
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { sidebarDragOrigin = nil }
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
                        ForEach(AnimatePage.allCases) { page in
                            OperaChromeActionButton(
                                title: page.rawValue,
                                systemImage: page.systemImage,
                                isSelected: selectedPage == page
                            ) {
                                selectedPage = page
                            }
                        }
                    }

                    HStack(spacing: 6) {
                        OperaChromeActionButton(
                            systemImage: sidebarVisible ? "sidebar.left" : "sidebar.right",
                            isSelected: sidebarVisible
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible.toggle()
                            }
                        }
                        OperaChromeActionButton(
                            systemImage: "info.circle",
                            isSelected: showInspector
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showInspector.toggle()
                            }
                        }
                    }
                }
            } content: {
                pageContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showInspector {
                OperaChromeDivider(.vertical)

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: selectedPage.rawValue
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showInspector = false
                            }
                        }
                    }
                } content: {
                    InspectorView(store: store, currentPage: selectedPage)
                }
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .script:
            ScriptPageView(store: store)
        case .characters:
            CharactersPageView(store: store)
        case .animate:
            AnimatePageView(store: store)
        case .timeline:
            TimelinePageView(store: store)
        }
    }



    private func resizeSidebar(_ translation: CGFloat) {
        if sidebarDragOrigin == nil {
            sidebarDragOrigin = sidebarWidth
        }

        let baseWidth = sidebarDragOrigin ?? sidebarWidth
        sidebarWidth = min(
            max(baseWidth + Double(translation), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
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
