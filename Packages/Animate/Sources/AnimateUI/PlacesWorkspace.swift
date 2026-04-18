import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
public struct PlacesWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            PlacesWorkspaceContent(store: controller.store)
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Places" : "Refreshing Places",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

@available(macOS 26.0, *)
private struct PlacesWorkspaceContent: View {
    @Bindable var store: AnimateStore
    @State private var animateWorkspaceState = AnimateWorkspaceState()
    @State private var placesViewMode: PlacesViewMode = .grid

    @AppStorage("novotro.places.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.places.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.places.showInspector") private var inspectorVisible = true
    @AppStorage("novotro.places.inspector.width") private var inspectorWidth: Double = 320

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "map",
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
                        eyebrow: "PLACES",
                        title: "Places",
                        subtitle: ""
                    ) {
                        Button {
                            store.importPlacesFromPicker()
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
                        .help("Import Place")
                    }
                } content: {
                    PlacesSidebarView(
                        store: store,
                        viewMode: $placesViewMode,
                        allImageCount: store.allBackgroundHierarchyImageCount()
                    )
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    Text(centerPaneTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 10)
                }
            } content: {
                PlacesPageView(store: store, viewMode: $placesViewMode, showSidebar: false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: "Places"
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
                        currentPage: .places,
                        animateWorkspaceState: animateWorkspaceState
                    )
                }
                .frame(width: inspectorWidth)
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }


    private var centerPaneTitle: String {
        switch placesViewMode {
        case .world:
            return "World Map"
        case .map3d:
            return "3D Map"
        case .landmarks:
            return "Landmarks"
        case .review:
            return "Review Queue"
        case .library:
            return "All Images"
        case .detail:
            return store.selectedPlace?.name ?? "Places"
        case .grid:
            return "Places"
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
            max(inspectorWidth - Double(delta), 280),
            900
        )
    }
}
