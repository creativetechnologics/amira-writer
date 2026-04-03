import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct MixWorkspaceContentView: View {
    @Bindable var store: MixStore
    var appName: String = "Mix"
    var isLoadingProject: Bool = false
    var loadStatusMessage: String = "Loading Mix workspace from disk..."
    var isInteractionLocked: Bool = false

    @AppStorage("novotro.mix.sidebarVisible") private var showSidebar = true
    @AppStorage("novotro.mix.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.mix.inspector.visible") private var inspectorVisible = true
    @AppStorage("novotro.mix.inspector.width") private var inspectorWidth: Double = 360
    @AppStorage("novotro.mix.mixer.visible") private var showMixerDock = true
    // pixelsPerSecond is driven by AppStorage so the slider position is immediately
    // correct on first render — no 1-frame flicker from a mismatched @State initial value.
    @AppStorage("novotro.mix.timeline.pixelsPerSecond") private var pixelsPerSecond: Double = 26

    var body: some View {
        Group {
            if isLoadingProject && store.projectURL == nil {
                MixLoadingPlaceholderView(
                    title: "Opening Mix",
                    message: loadStatusMessage
                )
            } else if store.projectURL == nil || isInteractionLocked {
                OperaChromeEmptyState(
                    systemImage: "slider.horizontal.below.rectangle",
                    title: "Open A Project In \(appName)",
                    message: "Use File > Open Project to load a local opera folder, then start arranging Suno renders in Mix."
                )
            } else {
                workspaceBody
            }
        }
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            if showSidebar {
                OperaChromeFlatPane(
                    headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                    OperaChromePaneHeader(
                        eyebrow: "MIX",
                        title: "Songs",
                        subtitle: "\(store.scenes.count) scene sessions"
                    ) { EmptyView() }
                } content: {
                    MixSceneSidebarView(store: store)
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            VStack(spacing: 0) {
                MixTransportBar(
                    store: store,
                    pixelsPerSecond: $pixelsPerSecond,
                    showMixerDock: $showMixerDock
                )
                OperaChromeDivider()
                MixArrangementView(
                    store: store,
                    pixelsPerSecond: CGFloat(pixelsPerSecond),
                    showMixerDock: $showMixerDock
                )
                OperaChromeDivider()
                OperaChromeStatusBar(
                    isSaving: store.saveIndicator == .saving,
                    isSaved: store.saveIndicator == .saved,
                    statusMessage: store.statusMessage,
                    itemCountText: "\(store.currentTrackCountText) | \(store.currentClipCountText)"
                )
            }
            .background(MixPalette.arrangeBackdrop)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.showInspector {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: "Browser, FX, inputs, and scene notes"
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                setInspectorVisible(false)
                            }
                        }
                    }
                } content: {
                    MixInspectorView(store: store)
                }
                .frame(width: inspectorWidth)
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
        .overlay {
            // Keyboard shortcut interceptors (invisible).
            // Delete and Space are guarded against text-field focus: when a text field
            // (track name, notes, browser search) is focused, AppKit is the first
            // responder and these shortcuts must not fire to avoid clip deletion or
            // transport toggle while the user is typing.
            Group {
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.togglePlayback()
                }
                .keyboardShortcut(.space, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                Button("") { store.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!store.canUndo)
                    .opacity(0).frame(width: 0, height: 0)
                Button("") { store.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!store.canRedo)
                    .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.deleteSelectedClip()
                }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(store.currentSelectedClipID == nil)
                .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    if let clipID = store.currentSelectedClipID {
                        store.duplicateClip(clipID)
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(store.currentSelectedClipID == nil)
                .opacity(0).frame(width: 0, height: 0)

                // Escape: stop transport if playing, otherwise deselect clip
                Button("") {
                    if store.isPlaying || store.isRecording {
                        store.stopTransport()
                    } else if store.currentSelectedClipID != nil {
                        store.deselectClip()
                    }
                }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                // Nudge selected clip left/right with arrow keys
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    if let clipID = store.currentSelectedClipID {
                        store.nudgeClip(clipID, by: -store.nudgeAmount)
                    } else {
                        store.movePlayhead(by: -1)
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    guard !isTextFieldFocused() else { return }
                    if let clipID = store.currentSelectedClipID {
                        store.nudgeClip(clipID, by: store.nudgeAmount)
                    } else {
                        store.movePlayhead(by: 1)
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                // Cmd+Left/Right: large nudge (5× normal or move playhead 5s)
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    if let clipID = store.currentSelectedClipID {
                        store.nudgeClip(clipID, by: -store.nudgeAmount * 5)
                    } else {
                        store.movePlayhead(by: -5)
                    }
                }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    guard !isTextFieldFocused() else { return }
                    if let clipID = store.currentSelectedClipID {
                        store.nudgeClip(clipID, by: store.nudgeAmount * 5)
                    } else {
                        store.movePlayhead(by: 5)
                    }
                }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)

                // Up/Down arrows: navigate track selection
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.selectPreviousTrack()
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.selectNextTrack()
                }
                .keyboardShortcut(.downArrow, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                // Tab / Shift+Tab: cycle clips on current track
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.selectNextClip()
                }
                .keyboardShortcut(.tab, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.selectPreviousClip()
                }
                .keyboardShortcut(.tab, modifiers: .shift)
                .opacity(0).frame(width: 0, height: 0)

                // +/- keys: adjust selected clip gain by ±1 dB
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.adjustSelectedClipGain(by: 1)
                }
                .keyboardShortcut("=", modifiers: [])
                .disabled(store.currentSelectedClipID == nil)
                .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.adjustSelectedClipGain(by: -1)
                }
                .keyboardShortcut("-", modifiers: [])
                .disabled(store.currentSelectedClipID == nil)
                .opacity(0).frame(width: 0, height: 0)

                // Tool switching: 1=Pointer, 2=Split, 3=Automation, 4=Fade
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.selectedTool = .pointer
                }
                .keyboardShortcut("1", modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.selectedTool = .split
                }
                .keyboardShortcut("2", modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.selectedTool = .automation
                }
                .keyboardShortcut("3", modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.selectedTool = .fade
                }
                .keyboardShortcut("4", modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                // Return: seek to start of timeline
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.seekPlayhead(to: 0)
                }
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                // Shift+Return: seek to end of last clip on the timeline
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    let lastEnd = store.currentClips.map { $0.startSeconds + $0.durationSeconds }.max() ?? 0
                    store.seekPlayhead(to: lastEnd)
                }
                .keyboardShortcut(.return, modifiers: .shift)
                .opacity(0).frame(width: 0, height: 0)

                // G: go to selected clip (seek playhead to its start)
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    if let clipID = store.currentSelectedClipID {
                        store.seekToClip(clipID)
                    }
                }
                .keyboardShortcut("g", modifiers: [])
                .disabled(store.currentSelectedClipID == nil)
                .opacity(0).frame(width: 0, height: 0)

                // Preview selected clip (P)
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.previewSelectedClip()
                }
                .keyboardShortcut("p", modifiers: [])
                .disabled(store.currentSelectedClipID == nil)
                .opacity(0).frame(width: 0, height: 0)

                // Toggle inspector (I)
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        setInspectorVisible(!inspectorVisible)
                    }
                }
                .keyboardShortcut("i", modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                // Split selected clip at playhead (S)
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.splitSelectedClipAtPlayhead()
                }
                .keyboardShortcut("s", modifiers: [])
                .disabled(store.currentSelectedClipID == nil)
                .opacity(0).frame(width: 0, height: 0)

                // Mute selected track (M)
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    if let trackID = store.selectedTrack?.id {
                        store.toggleTrackMute(trackID)
                    }
                }
                .keyboardShortcut("m", modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                // Solo selected track (O for solo — avoids S conflict with split)
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    if let trackID = store.selectedTrack?.id {
                        store.toggleTrackSolo(trackID)
                    }
                }
                .keyboardShortcut("o", modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                // Zoom in/out with Cmd+= / Cmd+-
                Button("") {
                    pixelsPerSecond = min(pixelsPerSecond + 4, 48)
                }
                .keyboardShortcut("=", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)

                Button("") {
                    pixelsPerSecond = max(pixelsPerSecond - 4, 12)
                }
                .keyboardShortcut("-", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)

                // Reset zoom to default (Cmd+0)
                Button("") {
                    pixelsPerSecond = 26
                }
                .keyboardShortcut("0", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0)

                // Join selected clip to previous (J)
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.joinSelectedClipToPrevious()
                }
                .keyboardShortcut("j", modifiers: [])
                .disabled(store.currentSelectedClipID == nil)
                .opacity(0).frame(width: 0, height: 0)

                // Preview transition at playhead (T)
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    store.previewTransitionAtPlayhead()
                }
                .keyboardShortcut("t", modifiers: [])
                .opacity(0).frame(width: 0, height: 0)

                // Auto-sequence all clips on selected track (Cmd+Shift+S)
                Button("") {
                    guard !isTextFieldFocused() else { return }
                    if let trackID = store.selectedTrack?.id {
                        store.autoSequenceClips(on: trackID, overlapSeconds: 0)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .opacity(0).frame(width: 0, height: 0)
            }
        }
        .onAppear {
            if store.showInspector != inspectorVisible {
                store.showInspector = inspectorVisible
            }
            pixelsPerSecond = resolvedTimelinePixelsPerSecond()
        }
        .onChange(of: store.showInspector) { _, newValue in
            if inspectorVisible != newValue {
                inspectorVisible = newValue
            }
        }
        .onChange(of: inspectorVisible) { _, newValue in
            if store.showInspector != newValue {
                store.showInspector = newValue
            }
        }
        .onChange(of: store.selectedSceneID) { _, _ in
            pixelsPerSecond = resolvedTimelinePixelsPerSecond()
        }
        .onChange(of: pixelsPerSecond) { _, newValue in
            store.updateTimelinePixelsPerSecond(newValue)
        }
    }

    /// Returns true when a text-entry control (TextField, TextEditor, NSTextField/NSTextView
    /// backed SwiftUI controls) is the first responder.  Used to prevent Space and Delete
    /// shortcuts from firing while the user is typing in a track name or search field.
    private func isTextFieldFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        inspectorWidth = min(
            max(inspectorWidth - Double(delta), 290),
            620
        )
    }

    private func setInspectorVisible(_ isVisible: Bool) {
        inspectorVisible = isVisible
        store.showInspector = isVisible
    }

    private func resolvedTimelinePixelsPerSecond() -> Double {
        if store.currentSession != nil {
            return store.currentTimelinePixelsPerSecond
        }
        return pixelsPerSecond
    }
}

@available(macOS 26.0, *)
struct MixLoadingPlaceholderView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(OperaChromeTheme.textPrimary)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .background(OperaChromeTheme.workspaceBackground)
    }
}
