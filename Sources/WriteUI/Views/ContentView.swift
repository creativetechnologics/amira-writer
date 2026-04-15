import SwiftUI
import AppKit
import ProjectKit

fileprivate let lyricIterationSlotRange = 1...10

@available(macOS 26.0, *)
struct ContentView: View {
    @Bindable var store: ScriptStore
    var appName: String = "Write"

    @Environment(\.openWindow) private var openWindow
    @AppStorage("novotro.write.showInspector") private var showInspector: Bool = true
    @AppStorage("novotro.write.showScratchpad") private var showScratchpad: Bool = true
    @AppStorage("novotro.write.showLyricIterations") private var showLyricIterations: Bool = true
    @AppStorage("novotro.write.lyricIterationSlot") private var selectedLyricIterationSlot: Int = 1
    @AppStorage("novotro.write.showSummaries") private var showSummaries: Bool = false
    @AppStorage("novotro.write.sidebarVisible") private var showSidebar: Bool = true
    @AppStorage("novotro.write.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth

    @AppStorage("novotro.write.inspector.width") private var inspectorWidth: Double = 360

    private var projectTitle: String {
        store.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var lyricIterationSelection: Binding<Int> {
        Binding(
            get: {
                min(
                    max(selectedLyricIterationSlot, lyricIterationSlotRange.lowerBound),
                    lyricIterationSlotRange.upperBound
                )
            },
            set: {
                selectedLyricIterationSlot = min(
                    max($0, lyricIterationSlotRange.lowerBound),
                    lyricIterationSlotRange.upperBound
                )
            }
        )
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
                    onDragEnded: { }
                )
            }

            OperaChromeFlatPane(background: Color.black) {
                OperaChromePaneHeader(
                    eyebrow: "LIBRETTO",
                    title: projectTitle,
                    subtitle: activeSceneTitle ?? "Complete draft"
                ) {
                    HStack(spacing: 6) {
                        ScriptEditorModeButton(isEditing: store.isLibrettoEditMode) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                store.isLibrettoEditMode.toggle()
                            }
                        }
                        ScriptSaveToolbarButton(
                            saveIndicator: store.saveIndicator,
                            canSave: store.canSave
                        ) {
                            store.save()
                        }
                        if store.saveIndicator != .idle {
                            OperaChromeCompactSaveIndicator(state: store.saveIndicator)
                        }
                        ScriptMarkupToolbarButton(
                            systemImage: "camera.metering.spot",
                            color: store.directionMarkupColor,
                            isSelected: store.showDirections,
                            isEnabled: store.isLibrettoEditMode
                        ) {
                            store.showDirections.toggle()
                        }
                        ScriptMarkupToolbarButton(
                            systemImage: "film",
                            color: store.storyboardingMarkupColor,
                            isSelected: store.showStoryboarding,
                            isEnabled: store.isLibrettoEditMode
                        ) {
                            store.showStoryboarding.toggle()
                        }
                        ScriptMarkupToolbarButton(
                            systemImage: "video",
                            color: store.animateMarkupColor,
                            isSelected: store.showAnimateDirections,
                            isEnabled: store.isLibrettoEditMode
                        ) {
                            store.showAnimateDirections.toggle()
                        }
                        if let badgeLabel = store.collaborationBadgeLabel {
                            OperaChromeStatusBadge(
                                title: badgeLabel,
                                systemImage: store.collaborationBadgeSystemImage,
                                showsProgress: store.isAgentSyncInProgress
                            )
                        }
                        if showLyricIterations {
                            LyricIterationSlotPicker(selection: lyricIterationSelection)
                        }
                        OperaChromeActionButton(
                            systemImage: "text.quote",
                            isSelected: showLyricIterations
                        ) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showLyricIterations.toggle()
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
                        showScratchpad: showScratchpad,
                        showLyricIterations: showLyricIterations,
                        selectedLyricIterationSlot: lyricIterationSelection.wrappedValue
                    )
                    OperaChromeDivider()
                    OperaChromeStatusBar(
                        statusMessage: store.statusMessage,
                        isDirty: appName == "Amira Writer" ? nil : store.isDirty,
                        itemCountText: "\(store.songAssets.count) scenes"
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showInspector {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )

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
                .frame(width: inspectorWidth)
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
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

@available(macOS 26.0, *)
private struct ScriptEditorModeButton: View {
    let isEditing: Bool
    let action: () -> Void

    var body: some View {
        OperaChromeActionButton(
            title: isEditing ? "Edit" : "View",
            systemImage: isEditing ? "pencil" : "eye",
            isSelected: isEditing,
            action: action
        )
    }
}

@available(macOS 26.0, *)
private struct LyricIterationSlotPicker: View {
    @Binding var selection: Int

    private let slotRange = lyricIterationSlotRange

    var body: some View {
        HStack(spacing: 8) {
            Text("Draft")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(OperaChromeTheme.textTertiary)
                .tracking(1)

            HStack(spacing: 6) {
                toolbarStepperButton(systemImage: "chevron.down") {
                    selection -= 1
                }
                .disabled(selection <= slotRange.lowerBound)

                Text("\(selection)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .frame(minWidth: 26)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(OperaChromeTheme.selection)
                    )

                toolbarStepperButton(systemImage: "chevron.up") {
                    selection += 1
                }
                .disabled(selection >= slotRange.upperBound)
            }
            .help("Preview lyric iteration \(selection) of \(slotRange.upperBound)")
        }
    }

    private func toolbarStepperButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(OperaChromeTheme.raisedBackground.opacity(0.9))
                )
        }
        .buttonStyle(.plain)
    }
}

@available(macOS 26.0, *)
private struct ScriptSaveToolbarButton: View {
    let saveIndicator: SaveIndicatorState
    let canSave: Bool
    let action: () -> Void

    var body: some View {
        OperaChromeActionButton(
            title: "Save",
            systemImage: "square.and.arrow.down",
            isProminent: canSave,
            action: action
        )
        .disabled(!canSave)
        .opacity(buttonOpacity)
        .help(helpText)
    }

    private var buttonOpacity: Double {
        if saveIndicator == .saving {
            return 0.8
        }
        return canSave ? 1.0 : 0.58
    }

    private var helpText: String {
        if saveIndicator == .saving {
            return "Saving the current project"
        }
        if canSave {
            return "Save the current project (Command-S)"
        }
        return "No unsaved changes"
    }
}

@available(macOS 26.0, *)
private struct ScriptMarkupToolbarButton: View {
    let systemImage: String
    let color: Color
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                Circle()
                    .fill(isSelected ? color : OperaChromeTheme.textTertiary.opacity(0.35))
                    .frame(width: 6, height: 6)
            }
            .foregroundStyle(
                isEnabled
                    ? (isSelected ? OperaChromeTheme.textPrimary : OperaChromeTheme.textSecondary)
                    : OperaChromeTheme.textTertiary
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(minHeight: 28)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? OperaChromeTheme.selection : Color.clear)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(
                        isSelected ? color.opacity(0.38) : Color.clear,
                        lineWidth: 1
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
