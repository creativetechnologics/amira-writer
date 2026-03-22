import SwiftUI
import AppKit
import NovotroProjectKit

@available(macOS 26.0, *)
struct ContentView: View {
    @Bindable var store: ScriptStore
    var appName: String = "Novotro Write"

    @Environment(\.openWindow) private var openWindow
    @AppStorage("novotro.write.showInspector") private var showInspector: Bool = true
    @AppStorage("novotro.write.showScratchpad") private var showScratchpad: Bool = true
    @AppStorage("novotro.write.showSummaries") private var showSummaries: Bool = false
    @AppStorage("novotro.write.sidebarVisible") private var showSidebar: Bool = true
    @AppStorage("novotro.write.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @State private var sidebarDragOrigin: Double?

    private var projectTitle: String {
        store.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var activeSceneTitle: String? {
        guard let path = store.activeSongPath else { return nil }
        return store.songAssets.first(where: { $0.relativePath == path })?.displayName
    }

    var body: some View {
        Group {
            if store.projectURL == nil {
                SharedProjectRequiredView(appName: appName)
            } else {
                workspaceBody
            }
        }

        .background(WindowConfigurator())
        .alert(
            "Couldn't Open Project",
            isPresented: Binding(
                get: { store.presentedLoadError != nil },
                set: { isPresented in
                    if !isPresented {
                        store.presentedLoadError = nil
                    }
                }
            )
        ) {
            Button("OK") {
                store.presentedLoadError = nil
            }
        } message: {
            Text(store.presentedLoadError ?? "The project could not be opened.")
        }
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            if showSidebar {
                OperaChromeFlatPane(
                    headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                OperaChromePaneHeader(
                        eyebrow: "WRITE",
                        title: "Scenes",
                        subtitle: "\(store.songAssets.count) loaded"
                    ) {
                        HStack(spacing: 6) {
                            OperaChromeActionButton(
                                systemImage: showSummaries ? "text.justify.left" : "text.justify",
                                isSelected: showSummaries
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showSummaries.toggle()
                                }
                            }
                            OperaChromeActionButton(systemImage: "plus") {
                                store.addScene()
                            }
                        }
                    }
                } content: {
                    ScriptSidebarView(store: store, showSummaries: showSummaries)
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { sidebarDragOrigin = nil }
                )
            }

            OperaChromeFlatPane(background: Color.black) {
                OperaChromePaneHeader(
                    eyebrow: "LIBRETTO",
                    title: projectTitle,
                    subtitle: activeSceneTitle ?? "Complete draft"
                ) {
                    HStack(spacing: 6) {
                        if let badgeLabel = store.collaborationBadgeLabel {
                            OperaChromeStatusBadge(
                                title: badgeLabel,
                                systemImage: store.collaborationBadgeSystemImage,
                                showsProgress: store.isAgentSyncInProgress
                            )
                        }
                        OperaChromeActionButton(
                            systemImage: showSidebar ? "sidebar.left" : "sidebar.right",
                            isSelected: showSidebar
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showSidebar.toggle()
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
                        OperaChromeActionButton(
                            systemImage: "square.and.pencil",
                            isSelected: showScratchpad
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showScratchpad.toggle()
                            }
                        }
                        OperaChromeActionButton(systemImage: "list.bullet.rectangle") {
                            openWindow(id: GlobalChangeLogWindowView.windowID)
                        }
                    }
                }
            } content: {
                VStack(spacing: 0) {
                    ScriptCenterView(
                        store: store,
                        showScratchpad: showScratchpad
                    )
                    OperaChromeDivider()
                    let isSaving = store.saveIndicator == .saving
                    let isSaved = store.saveIndicator == .saved
                    OperaChromeStatusBar(
                        isSaving: isSaving,
                        isSaved: isSaved,
                        statusMessage: (isSaving || isSaved) ? "" : store.statusMessage,
                        isDirty: store.isDirty,
                        itemCountText: "\(store.songAssets.count) scenes"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showInspector {
                OperaChromeDivider(.vertical)

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "TOOLS",
                        title: "Inspector",
                        subtitle: "Structure, notes, and versions"
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showInspector = false
                            }
                        }
                    }
                } content: {
                    ScriptInspectorView(store: store)
                }
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
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
private struct SharedProjectRequiredView: View {
    let appName: String

    var body: some View {
        OperaChromeEmptyState(
            systemImage: "folder",
            title: "Open A Project In \(appName)",
            message: "Use File > Open Project to open a local project folder (with Metadata/project.json) and continue."
        )
    }
}

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

