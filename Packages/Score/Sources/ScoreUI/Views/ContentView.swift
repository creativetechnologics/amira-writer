#if os(macOS)
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct ContentView: View {
    @Bindable var store: ScoreStore
    var appName: String = "Score"

    @State private var selectedSongID: UUID?
    @AppStorage("novotro.score.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("novotro.score.sidebarVisible") private var showSidebar: Bool = true

    @AppStorage("novotro.score.showInspector") private var showInspector: Bool = true
    @AppStorage("novotro.score.inspector.width") private var inspectorWidth: Double = 360

    @State private var pianoRollController: PianoRollViewController?

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

    var body: some View {
        OperaChromeSidebarList {
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
        .onChange(of: store.midiAssets.map(\.id)) { _, _ in recomputeDurations() }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }

    private func recomputeDurations() {
        var result: [UUID: Double] = [:]
        for asset in store.midiAssets {
            guard let parsed = try? MIDIParser.parse(asset.data) else { continue }
            let secs = ScoreStore.ticksToSecondsStatic(
                parsed.lengthTicks,
                ticksPerQuarter: parsed.ticksPerQuarter,
                tempoEvents: parsed.tempoEvents
            )
            result[asset.id] = secs
        }
        cachedDurations = result
    }
}

// MARK: - Inspector

@available(macOS 26.0, *)
enum InspectorSectionID: String, CaseIterable, Identifiable {
    case instruments, libretto, versions, files, export, suno

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instruments: return "Instruments"
        case .libretto: return "Libretto"
        case .versions: return "Versions"
        case .files: return "Files"
        case .export: return "Export"
        case .suno: return "Suno"
        }
    }

    var systemImage: String {
        switch self {
        case .instruments: return "pianokeys"
        case .libretto: return "text.book.closed"
        case .versions: return "clock.arrow.circlepath"
        case .files: return "folder"
        case .export: return "square.and.arrow.up"
        case .suno: return "sparkles"
        }
    }
}

@available(macOS 26.0, *)
struct ScoreInspectorView: View {
    @Bindable var store: ScoreStore

    @AppStorage("novotro.score.inspector.activeSection") private var activeSection: String = "instruments"
    private let tabOrder: [InspectorSectionID] = [.instruments, .libretto, .versions, .files, .export, .suno]

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
        case .suno:
            SunoInspectorView(store: store)
        }
    }

    private var librettoContent: some View {
        Group {
            if let file = store.selectedLibrettoFile {
                ScrollView {
                    Text(file.content)
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

    // Legacy Suno UI removed — replaced by SunoInspectorView
}

// MARK: - Status Bar


#endif
