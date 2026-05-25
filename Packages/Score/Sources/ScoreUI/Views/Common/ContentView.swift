#if os(macOS)
import AppKit
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct ContentView: View {
    @Bindable var store: ScoreStore
    var appName: String = "Score"

    @State private var selectedSongID: UUID?
    @AppStorage("amira.score.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("amira.score.sidebarVisible") private var showSidebar: Bool = true

    @AppStorage("amira.score.showInspector") private var showInspector: Bool = true
    @AppStorage("amira.score.inspector.width") private var inspectorWidth: Double = 360

    @State private var pianoRollController: PianoRollViewController?
    @State private var spacebarMonitor: Any?

    private var projectTitle: String {
        store.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var selectedSongTitle: String {
        store.selectedMidiAsset?.displayName ?? "No song selected"
    }

    var body: some View {
        Group {
            if store.projectURL == nil {
                ScoreSharedProjectRequiredView(appName: appName)
            } else {
                workspaceBody
            }
        }

        .onChange(of: selectedSongID) { _, newValue in
            guard let id = newValue, id != store.selectedMidiID else { return }
            store.setSelectedMidi(id: id)
        }
        .onChange(of: store.selectedMidiID) { _, newValue in
            guard selectedSongID != newValue else { return }
            selectedSongID = newValue
        }
        .onChange(of: store.selectedTrackFilter) { _, _ in
            store.trackFilterDidChange()
            pianoRollController?.trackFilterDidChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: ScoreAppSignals.toggleInspectorNotification)) { _ in
            showInspector.toggle()
        }
        .onChange(of: showInspector) { _, newValue in
            if store.showInspector != newValue {
                store.showInspector = newValue
            }
        }
        .onChange(of: store.showInspector) { _, newValue in
            if showInspector != newValue {
                showInspector = newValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: ScoreAppSignals.openFileNotification)) { notification in
            guard let url = notification.userInfo?["url"] as? URL else { return }
            Task { @MainActor in
                await store.loadProject(url: url, preferService: false)
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
                        eyebrow: "SCORE",
                        title: "Songs",
                        subtitle: "\(store.midiAssets.count) MIDI assets"
                    ) { EmptyView() }
                } content: {
                    ScoreSidebarView(
                        store: store,
                        selectedSongID: $selectedSongID
                    )
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            OperaChromeFlatPane {
                OperaChromePaneHeader(
                    eyebrow: "PIANO ROLL",
                    title: projectTitle,
                    subtitle: selectedSongTitle
                ) {
                    HStack(spacing: 6) {
                        if let badgeLabel = store.collaborationBadgeLabel {
                            OperaChromeStatusBadge(
                                title: badgeLabel,
                                systemImage: store.collaborationBadgeSystemImage,
                                showsProgress: store.isAgentSyncInProgress
                            )
                        }
                    }
                }
            } content: {
                VStack(spacing: 0) {
                    PianoRollRepresentable(store: store, controller: $pianoRollController)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: "Mappings, files, and export"
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showInspector = false
                            }
                        }
                    }
                } content: {
                    ScoreInspectorView(store: store)
                }
                .frame(width: inspectorWidth)
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
        .onAppear(perform: installSpacebarMonitor)
        .onDisappear(perform: removeSpacebarMonitor)
    }



    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        // For inspector on the right, dragging left (negative delta) makes it wider
        inspectorWidth = min(
            max(inspectorWidth - Double(delta), 250),
            600
        )
    }

    private func installSpacebarMonitor() {
        guard spacebarMonitor == nil else { return }

        spacebarMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let modifierFlags = event.modifierFlags
            let windowNumber = event.windowNumber

            guard MainActor.assumeIsolated({
                Self.shouldTogglePlayback(
                    keyCode: keyCode,
                    modifierFlags: modifierFlags,
                    windowNumber: windowNumber
                )
            }) else { return event }

            NotificationCenter.default.post(
                name: ScoreAppSignals.spacebarPlayPauseNotification,
                object: nil
            )
            return nil
        }
    }

    private func removeSpacebarMonitor() {
        if let spacebarMonitor {
            NSEvent.removeMonitor(spacebarMonitor)
            self.spacebarMonitor = nil
        }
    }

    @MainActor
    private static func shouldTogglePlayback(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        windowNumber: Int
    ) -> Bool {
        guard keyCode == 49 else { return false }

        let mods = modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            return false
        }

        guard let window = NSApp.window(withWindowNumber: windowNumber),
              window === NSApp.mainWindow else { return false }

        if let responder = window.firstResponder,
           responder is NSText || responder is NSTextView || responder is NSTextField {
            return false
        }

        return true
    }
}

@available(macOS 26.0, *)
private struct ScoreSharedProjectRequiredView: View {
    let appName: String

    var body: some View {
        OperaChromeEmptyState(
            systemImage: "music.note.list",
            title: "Open A Project In \(appName)",
            message: "Use File > Open Project to pick a local Amira project folder from disk."
        )
    }
}

// MARK: - NSViewControllerRepresentable Bridge

@available(macOS 26.0, *)
struct PianoRollRepresentable: NSViewControllerRepresentable {
    let store: ScoreStore
    @Binding var controller: PianoRollViewController?

    func makeNSViewController(context: Context) -> PianoRollViewController {
        let vc = PianoRollViewController(store: store)
        DispatchQueue.main.async {
            controller = vc
        }
        return vc
    }

    func updateNSViewController(_ nsViewController: PianoRollViewController, context: Context) {
        // The controller observes store changes via its own mechanisms
    }
}

// MARK: - Sidebar

@available(macOS 26.0, *)
struct ScoreSidebarView: View {
    var store: ScoreStore
    @Binding var selectedSongID: UUID?

    @State private var cachedDurations: [UUID: Double] = [:]

    private var totalSeconds: Double {
        cachedDurations.values.reduce(0, +)
    }

    var body: some View {
        OperaChromeSidebarList {
            if !cachedDurations.isEmpty {
                OperaChromeSidebarRow {
                    HStack {
                        Text("Total")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                        Spacer()
                        Text(formatTotalDuration(totalSeconds))
                            .font(.caption.monospacedDigit())
                            .fontWeight(.medium)
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }
                }
            }
            ForEach(store.midiAssets) { asset in
                Button {
                    selectedSongID = asset.id
                } label: {
                    OperaChromeSidebarRow(
                        isSelected: selectedSongID == asset.id,
                        isExternallyUpdated: store.externalChangeTimes[asset.relativePath] != nil
                    ) {
                        HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
                            Image(systemName: "music.note")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                            Text(asset.displayName)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(OperaChromeTheme.textPrimary)
                                .lineLimit(1)
                            Spacer()
                            if let seconds = cachedDurations[asset.id] {
                                Text(formatDuration(seconds))
                                    .font(.caption.monospacedDigit())
                                    .fontWeight(.light)
                                    .foregroundStyle(Color.gray.opacity(0.6))
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear { recomputeDurations() }
        .onChange(of: store.songAssets.map(\.id)) { _, _ in recomputeDurations() }
        .onChange(of: store.songAssets.map { $0.document.activeVersion()?.playback?.lengthTicks }) { _, _ in recomputeDurations() }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }

    private func formatTotalDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return "\(h):\(String(format: "%02d", m)):\(String(format: "%02d", s))"
    }

    private func recomputeDurations() {
        var result: [UUID: Double] = [:]
        for asset in store.songAssets {
            guard let playback = asset.document.activeVersion()?.playback else {
                // The sidebar must never hydrate every scene just to show durations.
                // Hydrating all 50 scene packages here recursively fanned out detached
                // playback loads, pegged CPU, and made the Score/Mix switch look frozen.
                // Durations appear opportunistically after a song is selected/loaded.
                continue
            }
            let secs = ScoreStore.ticksToSecondsStatic(
                playback.lengthTicks,
                ticksPerQuarter: playback.ticksPerQuarter,
                tempoEvents: playback.tempoEvents
            )
            result[asset.id] = secs
        }
        cachedDurations = result
    }
}

// MARK: - Inspector

@available(macOS 26.0, *)
enum InspectorSectionID: String, CaseIterable, Identifiable {
    case instruments, export, libretto, versions, files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instruments: return "Instruments"
        case .libretto: return "Libretto"
        case .versions: return "Versions"
        case .files: return "Files"
        case .export: return "Export"
        }
    }

    var systemImage: String {
        switch self {
        case .instruments: return "pianokeys"
        case .libretto: return "text.book.closed"
        case .versions: return "clock.arrow.circlepath"
        case .files: return "folder"
        case .export: return "square.and.arrow.up"
        }
    }
}

@available(macOS 26.0, *)
struct ScoreInspectorView: View {
    @Bindable var store: ScoreStore

    @AppStorage("amira.score.inspector.activeSection") private var activeSection: String = "instruments"
    private let tabOrder: [InspectorSectionID] = [.instruments, .export, .libretto, .versions, .files]

    private var selectedSection: Binding<InspectorSectionID> {
        Binding(
            get: { InspectorSectionID(rawValue: activeSection) ?? .instruments },
            set: { activeSection = $0.rawValue }
        )
    }

    var body: some View {
        OperaChromeInspectorTabs(
            selection: selectedSection,
            tabs: tabOrder.map {
                OperaChromeTabItem(id: $0, title: $0.title, systemImage: $0.systemImage)
            }
        ) { sectionID in
            sectionContent(for: sectionID)
        }
        .onAppear {
            if InspectorSectionID(rawValue: activeSection) == nil {
                activeSection = InspectorSectionID.instruments.rawValue
            }
        }
    }

    @ViewBuilder
    private func sectionContent(for sectionID: InspectorSectionID) -> some View {
        switch sectionID {
        case .instruments:
            InstrumentMappingPanel(store: store, selectedTrackFilter: Binding(
                get: { store.selectedTrackFilter },
                set: { store.selectedTrackFilter = $0 }
            ))
        case .libretto:
            librettoContent
        case .versions:
            VersionHistoryView(store: store)
        case .files:
            FilesInspectorView(store: store)
        case .export:
            ExportInspectorView(store: store)
        }
    }

    private var librettoContent: some View {
        Group {
            if let file = store.selectedLibrettoFile {
                ScrollView {
                    Text(SyllabificationService.extractLyrics(from: file.content))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .textSelection(.enabled)
                }
            } else {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "text.book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text(store.selectedMidiID == nil ? "No song selected" : "No lyrics")
                        .font(.caption)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Spacer()
                }
            }
        }
    }

}

// MARK: - Status Bar


#endif
