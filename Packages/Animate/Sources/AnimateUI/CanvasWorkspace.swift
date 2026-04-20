import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
public struct CanvasWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            CanvasWorkspaceContent(store: controller.store)
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Canvas" : "Refreshing Canvas",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

@available(macOS 26.0, *)
private struct CanvasWorkspaceContent: View {
    @Bindable var store: AnimateStore

    @AppStorage("novotro.canvas.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.canvas.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth

    private var projectTitle: String {
        store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "paintpalette",
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
                OperaChromeFlatPane(
                    headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                    OperaChromePaneHeader(
                        eyebrow: "CANVAS",
                        title: "Canvas",
                        subtitle: "\(store.canvasGenerations.count) generations"
                    ) { EmptyView() }
                } content: {
                    CanvasSidebarView(store: store)
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CANVAS")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(projectTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text("Free-form image generation")
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    OperaChromeActionButton(
                        systemImage: sidebarVisible ? "sidebar.left" : "rectangle.split.2x1",
                        isSelected: sidebarVisible
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            sidebarVisible.toggle()
                        }
                    }
                }
            } content: {
                ImagineCanvasPageView(store: store)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }
}
