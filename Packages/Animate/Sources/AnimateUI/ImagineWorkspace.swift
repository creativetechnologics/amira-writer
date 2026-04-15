import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
public struct ImagineWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            ImagineWorkspaceContent(store: controller.store)
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Imagine" : "Refreshing Imagine",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

@available(macOS 26.0, *)
private struct ImagineWorkspaceContent: View {
    @Bindable var store: AnimateStore

    @AppStorage("novotro.imagine.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.imagine.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.imagine.showInspector") private var inspectorVisible = true
    @AppStorage("novotro.imagine.inspector.width") private var inspectorWidth: Double = 320

    private var projectTitle: String {
        store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var activeDetailTitle: String {
        switch store.selectedImaginePage {
        case .characters:
            store.selectedCharacter?.name ?? "Character image generation"
        case .scenes:
            store.selectedScene?.name ?? "Scene image generation"
        case .canvas:
            "Free-form image generation"
        }
    }

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "sparkles",
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
                        Text("IMAGINE")
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
                        ForEach(ImaginePage.allCases) { page in
                            OperaChromeActionButton(
                                title: page.rawValue,
                                systemImage: page.systemImage,
                                isSelected: store.selectedImaginePage == page
                            ) {
                                store.selectedImaginePage = page
                            }
                        }
                    }

                    GeminiStatusBadge(store: store)
                    GlobalSettingsGear(store: store)
                }
            } content: {
                pageContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "IMAGINE",
                        title: "Inspector",
                        subtitle: store.selectedImaginePage.rawValue
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = false
                            }
                        }
                    }
                } content: {
                    ImagineInspectorView(store: store)
                }
                .frame(width: max(inspectorWidth, 250))
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    @ViewBuilder
    private var sidebarContent: some View {
        switch store.selectedImaginePage {
        case .characters:
            OperaChromeFlatPane(
                headerPadding: OperaChromeSidebarMetrics.headerPadding
            ) {
                OperaChromePaneHeader(
                    eyebrow: "IMAGINE",
                    title: "Characters",
                    subtitle: "\(store.characters.count) characters"
                ) { EmptyView() }
            } content: {
                CharactersSidebarView(store: store)
            }
        case .scenes:
            OperaChromeFlatPane(
                headerPadding: OperaChromeSidebarMetrics.headerPadding
            ) {
                OperaChromePaneHeader(
                    eyebrow: "IMAGINE",
                    title: "Scenes",
                    subtitle: "\(store.scenes.count) scenes"
                ) { EmptyView() }
            } content: {
                SidebarView(store: store)
            }
        case .canvas:
            OperaChromeFlatPane(
                headerPadding: OperaChromeSidebarMetrics.headerPadding
            ) {
                OperaChromePaneHeader(
                    eyebrow: "IMAGINE",
                    title: "Canvas",
                    subtitle: "\(store.canvasGenerations.count) generations"
                ) { EmptyView() }
            } content: {
                CanvasSidebarView(store: store)
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch store.selectedImaginePage {
        case .characters:
            ImagineCharactersPageView(store: store)
        case .scenes:
            ImagineScenesPageView(store: store)
        case .canvas:
            ImagineCanvasPageView(store: store)
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
            max(inspectorWidth - Double(delta), 250),
            600
        )
    }
}
