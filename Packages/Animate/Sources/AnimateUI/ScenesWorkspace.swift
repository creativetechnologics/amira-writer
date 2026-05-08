import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
public struct ScenesWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            ScenesWorkspaceContent(store: controller.store)
                .environment(\.unifiedImageFlipHandler) { path in
                    controller.store.flipImageHorizontallyAndAttachLikeOriginal(path: path)
                }
                .environment(\.unifiedImageRecategorizeHandler) { path, category in
                    controller.store.recategorizeImageReviewScope(path: path, semanticRole: category.semanticRole)
                }
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Scenes" : "Refreshing Scenes",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

@available(macOS 26.0, *)
private struct ScenesWorkspaceContent: View {
    @Bindable var store: AnimateStore

    @AppStorage("amira.imagine.sidebarVisible") private var sidebarVisible = true
    @AppStorage("amira.imagine.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("amira.imagine.showInspector") private var inspectorVisible = true
    @AppStorage("amira.imagine.inspector.width") private var inspectorWidth: Double = 320

    @State private var animateWorkspaceState = AnimateWorkspaceState()
    @State private var activeTab: ScenesWorkspaceTab = .imagine

    private enum ScenesWorkspaceTab: String, CaseIterable {
        case imagine = "Imagine"
        case previs3D = "Previs 3D"
    }

    private var projectTitle: String {
        store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var activeDetailTitle: String {
        store.selectedScene?.name ?? "Scene image generation"
    }

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "film.stack",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
            }
        }
    }

    private var workspaceBody: some View {
        GeometryReader { proxy in
            let handleWidth: CGFloat = 10
            let centerMinimumWidth = min(640, max(420, proxy.size.width * 0.42))
            let sidebarHandleWidth = sidebarVisible ? handleWidth : 0
            let inspectorHandleWidth = inspectorVisible ? handleWidth : 0
            let maxSidebarWidth = max(
                OperaChromeSidebarMetrics.minWidth,
                min(
                    OperaChromeSidebarMetrics.maxWidth,
                    proxy.size.width - sidebarHandleWidth - inspectorHandleWidth - 280 - centerMinimumWidth
                )
            )
            let effectiveSidebarWidth = sidebarVisible
                ? min(max(CGFloat(sidebarWidth), OperaChromeSidebarMetrics.minWidth), maxSidebarWidth)
                : 0
            let availableAfterSidebar = proxy.size.width - effectiveSidebarWidth - sidebarHandleWidth - inspectorHandleWidth
            let maxInspectorWidth = inspectorVisible
                ? max(280, min(640, availableAfterSidebar - centerMinimumWidth))
                : 0
            let effectiveInspectorWidth = inspectorVisible
                ? min(max(CGFloat(inspectorWidth), 280), maxInspectorWidth)
                : 0

            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebarContent
                        .frame(width: effectiveSidebarWidth)

                    OperaChromeSplitHandle(
                        onDragChanged: resizeSidebar,
                        onDragEnded: { }
                    )
                    .frame(width: handleWidth)
                }

                OperaChromeFlatPane {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SCENES")
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
                    }
                } content: {
                    VStack(spacing: 0) {
                        Picker("", selection: $activeTab) {
                            ForEach(ScenesWorkspaceTab.allCases, id: \.self) { tab in
                                Text(tab.rawValue).tag(tab)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        switch activeTab {
                        case .imagine:
                            ImagineScenesPageView(store: store)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .previs3D:
                            previsContent
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                if inspectorVisible {
                    OperaChromeSplitHandle(
                        onDragChanged: { delta in
                            resizeInspector(delta, maxWidth: maxInspectorWidth)
                        },
                        onDragEnded: { }
                    )
                    .frame(width: handleWidth)
                    .zIndex(2)

                    OperaChromeFlatPane {
                        OperaChromePaneHeader(
                            eyebrow: "SCENES",
                            title: "Inspector",
                            subtitle: "Scenes"
                        ) {
                            OperaChromeActionButton(systemImage: "xmark") {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    inspectorVisible = false
                                }
                            }
                        }
                    } content: {
                        InspectorView(
                            store: store,
                            currentPage: .scenes,
                            animateWorkspaceState: animateWorkspaceState
                        )
                    }
                    .frame(width: effectiveInspectorWidth)
                    .clipped()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .background(OperaChromeTheme.workspaceBackground)
        }
    }

    private var sidebarContent: some View {
        OperaChromeFlatPane(
            headerPadding: OperaChromeSidebarMetrics.headerPadding
        ) {
            OperaChromePaneHeader(
                eyebrow: "SCENES",
                title: "Scenes",
                subtitle: "\(store.scenes.count) scenes"
            ) { EmptyView() }
        } content: {
            SidebarView(store: store)
        }
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat, maxWidth: CGFloat) {
        let visibleAnchor = min(
            max(CGFloat(inspectorWidth), 280),
            maxWidth
        )
        inspectorWidth = Double(
            min(
                max(visibleAnchor - delta, 280),
                maxWidth
            )
        )
    }

    @ViewBuilder
    private var previsContent: some View {
        if let scene = store.selectedScene {
            if let shotID = store.selectedShotID,
               scene.shots.contains(where: { $0.id == shotID }) {
                Previs3DContainerView(store: store, sceneID: scene.id, shotID: shotID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                OperaChromeEmptyState(
                    systemImage: "cube",
                    title: "Select a Shot",
                    message: "Choose a shot from the sidebar to start pre-visualizing in 3D."
                )
            }
        } else {
            OperaChromeEmptyState(
                systemImage: "film.stack",
                title: "Select a Scene",
                message: "Choose a scene from the sidebar to view its shots and pre-visualization."
            )
        }
    }
}
