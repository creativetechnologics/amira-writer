import AppKit
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
public struct CharactersWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            CharactersWorkspaceContent(store: controller.store)
                .environment(\.unifiedImageFlipHandler) { path in
                    controller.store.flipImageHorizontallyAndAttachLikeOriginal(path: path)
                }
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Characters" : "Refreshing Characters",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

private enum CharactersDetailTab: String, CaseIterable, Identifiable {
    case imagine
    case reference

    var id: String { rawValue }
    var title: String {
        switch self {
        case .imagine: return "Imagine"
        case .reference: return "Reference"
        }
    }
    var systemImage: String {
        switch self {
        case .imagine: return "sparkles"
        case .reference: return "photo.on.rectangle"
        }
    }
}

@available(macOS 26.0, *)
private struct CharactersWorkspaceContent: View {
    @Bindable var store: AnimateStore
    @State private var animateWorkspaceState = AnimateWorkspaceState()
    @State private var selectedTab: CharactersDetailTab = .reference

    @AppStorage("novotro.characters.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.characters.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.characters.showInspector") private var inspectorVisible = true
    @AppStorage("novotro.characters.inspector.width") private var inspectorWidth: Double = 320

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "person.2",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
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
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                OperaChromeFlatPane(
                    headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                    OperaChromePaneHeader(
                        eyebrow: "CHARACTERS",
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
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    if let character = store.selectedCharacter {
                        characterHeaderThumbnail(path: character.profileImagePath, fallbackIcon: "person.crop.circle.fill")
                        characterHeaderThumbnail(path: character.inspirationReferenceImagePath, fallbackIcon: "photo")
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.selectedCharacter?.name ?? "Select a character")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text(store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera")
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 10)

                    if store.selectedCharacter != nil {
                        HStack(spacing: 6) {
                            ForEach(CharactersDetailTab.allCases) { tab in
                                OperaChromeActionButton(
                                    title: tab.title,
                                    systemImage: tab.systemImage,
                                    isSelected: selectedTab == tab
                                ) {
                                    selectedTab = tab
                                }
                            }
                        }
                    }
                }
            } content: {
                switch selectedTab {
                case .reference:
                    CharactersPageView(store: store, showSidebar: false)
                case .imagine:
                    ImagineCharactersPageView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )
                .zIndex(2)

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: "Characters"
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
                        currentPage: .characters,
                        animateWorkspaceState: animateWorkspaceState
                    )
                }
                .frame(width: max(inspectorWidth, 280))
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    @ViewBuilder
    private func characterHeaderThumbnail(path: String?, fallbackIcon: String) -> some View {
        if let resolvedPath = path.flatMap({ store.resolvedCharacterAssetURL(for: $0)?.path }) {
            CachedThumbnailView(path: resolvedPath, size: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(systemName: fallbackIcon)
                .font(.system(size: 16))
                .foregroundStyle(OperaChromeTheme.textTertiary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(OperaChromeTheme.raisedBackground.opacity(0.5))
                )
        }
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        // Anchor from the clamped visible width. If an older persisted value is
        // below the current minimum, using it directly makes the pane look
        // locked until the drag overcomes the hidden underflow.
        let anchor = max(inspectorWidth, 280.0)
        inspectorWidth = min(max(anchor - Double(delta), 280.0), 720.0)
    }
}
