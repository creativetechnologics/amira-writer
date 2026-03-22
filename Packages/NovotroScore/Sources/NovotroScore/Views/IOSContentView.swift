#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

@available(iOS 26.0, *)
struct IOSContentView: View {
    @Bindable var store: ScoreStore

    @State private var showInspector = false
    @State private var showFilePicker = false
    @State private var showMusicXMLPicker = false
    @State private var activeInspectorTab: IOSInspectorTab = .instruments

    enum IOSInspectorTab: String, CaseIterable, Identifiable {
        case instruments = "Instruments"
        case libretto = "Libretto"
        case versions = "Versions"
        case files = "Files"
        case suno = "Suno"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .instruments: return "pianokeys"
            case .libretto: return "text.book.closed"
            case .versions: return "clock.arrow.circlepath"
            case .files: return "folder"
            case .suno: return "sparkles"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            songSidebar
        } detail: {
            VStack(spacing: 0) {
                // Transport bar
                transportBar
                Divider()
                // Piano roll
                IOSPianoRollView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                // Status bar
                statusBar
            }
        }
        .inspector(isPresented: $showInspector) {
            inspectorContent
                .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }

                Menu {
                    Button("Open Project...") { showFilePicker = true }
                    Button("Import MusicXML...") { showMusicXMLPicker = true }
                    Divider()
                    Button("Save") { store.save() }
                        .disabled(store.projectURL == nil)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [
                UTType(filenameExtension: "owp") ?? .package,
                UTType(filenameExtension: "ows") ?? .data,
            ],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                Task { @MainActor in
                    await store.loadProject(url: url)
                }
            }
        }
        .fileImporter(
            isPresented: $showMusicXMLPicker,
            allowedContentTypes: [.xml, UTType(filenameExtension: "musicxml") ?? .xml],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                store.importMusicXML(url: url)
            }
        }
    }

    // MARK: - Song Sidebar

    private var songSidebar: some View {
        List(selection: Binding(
            get: { store.selectedMidiID },
            set: { id in
                if let id { store.setSelectedMidi(id: id) }
            }
        )) {
            Section("Songs") {
                ForEach(store.midiAssets) { asset in
                    Label(asset.displayName, systemImage: "music.note")
                        .tag(asset.id)
                }
            }
        }
        .navigationTitle("Novotro Score")
        .listStyle(.sidebar)
    }

    // MARK: - Transport Bar

    private var transportBar: some View {
        HStack(spacing: 16) {
            // Play/Stop
            Button {
                if store.isPlaying {
                    store.stopPlayback()
                } else {
                    store.playPianoRoll(startTick: 0)
                }
            } label: {
                Image(systemName: store.isPlaying ? "stop.fill" : "play.fill")
                    .font(.title3)
            }

            // Tempo display
            Text("\(Int(store.pianoRollTempoEvents.first?.bpm ?? 120)) BPM")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Spacer()

            // Undo/Redo
            Button { store.undo() } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!store.canUndo)

            Button { store.redo() } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!store.canRedo)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(store.pianoRollNotes.count) notes")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
    }

    // MARK: - Inspector

    private var inspectorContent: some View {
        VStack(spacing: 0) {
            // Tab picker
            Picker("Inspector", selection: $activeInspectorTab) {
                ForEach(IOSInspectorTab.allCases) { tab in
                    Image(systemName: tab.systemImage)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(8)

            Divider()

            ScrollView {
                switch activeInspectorTab {
                case .instruments:
                    IOSInstrumentPanel(store: store)
                case .libretto:
                    librettoContent
                case .versions:
                    VersionHistoryView(store: store)
                case .files:
                    FilesInspectorView(store: store)
                case .suno:
                    SunoInspectorView(store: store)
                }
            }
        }
    }

    private var librettoContent: some View {
        Group {
            if let file = store.selectedLibrettoFile {
                Text(file.content)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .textSelection(.enabled)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.book.closed")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No libretto")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
    }
}

// MARK: - iOS Instrument Panel (simplified)

@available(iOS 26.0, *)
struct IOSInstrumentPanel: View {
    @Bindable var store: ScoreStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(store.instrumentMappings.keys.sorted(), id: \.self) { key in
                if let mapping = store.instrumentMappings[key] {
                    instrumentRow(key: key, mapping: mapping)
                }
            }

            if store.instrumentMappings.isEmpty {
                Text("No instruments")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func instrumentRow(key: String, mapping: InstrumentMapping) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(mapping.displayName)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { !(mapping.muted) },
                    set: { store.instrumentMappings[key]?.muted = !$0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            // Gain slider
            HStack {
                Text("Gain")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Slider(value: Binding(
                    get: { mapping.gainDB },
                    set: { store.instrumentMappings[key]?.gainDB = $0 }
                ), in: -24...12)
                .controlSize(.small)
                Text(String(format: "%.0f dB", mapping.gainDB))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 40)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }
}
#endif
