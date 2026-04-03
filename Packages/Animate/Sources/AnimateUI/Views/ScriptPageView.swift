import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct ScriptPageView: View {
    @Bindable var store: AnimateStore

    @State private var scriptText: String = ""
    @State private var parseResult: SceneDirectionParser.ParseResult?
    @State private var compiledScene: CompiledScene?
    @State private var bpm: Double = 120
    @State private var beatsPerBar: Int = 4
    @State private var showErrors = false
    @State private var lyricsText: String = ""
    @State private var isLoadingLyrics = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            GeometryReader { geo in
                HStack(spacing: 0) {
                    lyricsPanel
                        .frame(width: geo.size.width * 0.35)

                    Divider()

                    scriptEditor
                        .frame(width: geo.size.width * 0.35)

                    Divider()

                    directionsPanel
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: scriptText) { _, _ in
            parseScript()
        }
        .onChange(of: store.selectedSceneID) { _, _ in
            loadLyricsForSelectedScene()
        }
        .task {
            loadLyricsForSelectedScene()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(.blue)
            Text("Scene Direction Editor")
                .font(.headline)

            if let scene = store.selectedScene {
                Text("—")
                    .foregroundStyle(.tertiary)
                Text(scene.name)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 12) {
                LabeledContent("BPM") {
                    TextField("BPM", value: $bpm, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 60)
                }

                LabeledContent("Beats/Bar") {
                    HStack(spacing: 6) {
                        ForEach([3, 4, 6], id: \.self) { value in
                            OperaChromeActionButton(
                                title: "\(value)",
                                systemImage: "metronome",
                                isSelected: beatsPerBar == value
                            ) {
                                beatsPerBar = value
                            }
                        }
                    }
                }
            }

            Spacer()

            if let compiled = compiledScene {
                Text("\(compiled.characterSetups.count) characters, \(compiled.totalFrames) frames")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            OperaChromeActionButton(
                title: "Compile To Timeline",
                systemImage: "timeline.selection",
                isProminent: true
            ) {
                compileAndApply()
            }
            .disabled(parseResult?.directions.isEmpty ?? true)
        }
        .padding()
    }

    // MARK: - Lyrics Panel (read-only, from OWP)

    @ViewBuilder
    private var lyricsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Lyrics", systemImage: "music.note.list")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLoadingLyrics {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if store.selectedScene == nil {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Select a scene to view lyrics")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lyricsText.isEmpty && !isLoadingLyrics {
                VStack(spacing: 8) {
                    Image(systemName: "text.page")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("No lyrics found in this song")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(lyricsText)
                        .font(.system(.body, design: .serif))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
    }

    // MARK: - Script Editor (scene directions)

    @ViewBuilder
    private var scriptEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Scene Directions", systemImage: "film")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                OperaChromeActionButton(
                    title: "Paste Example",
                    systemImage: "doc.on.clipboard"
                ) {
                    scriptText = exampleScript
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            TextEditor(text: $scriptText)
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(4)
        }
    }

    // MARK: - Directions Panel

    @ViewBuilder
    private var directionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Parsed Directions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let result = parseResult {
                    Text("\(result.directions.count) directions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !result.errors.isEmpty {
                        Button("\(result.errors.count) errors") {
                            showErrors.toggle()
                        }
                        .foregroundStyle(.red)
                        .font(.caption)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let result = parseResult {
                List {
                    ForEach(result.directions) { direction in
                        directionRow(direction)
                    }
                }
                .listStyle(.plain)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 32))
                        .foregroundStyle(.tertiary)
                    Text("Enter scene directions with\n[bracketed tags] to parse")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if showErrors, let errors = parseResult?.errors, !errors.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parse Errors")
                        .font(.caption)
                        .foregroundStyle(.red)
                    ForEach(errors.indices, id: \.self) { i in
                        Text("Line \(errors[i].lineNumber): \(errors[i].message)")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(8)
                .frame(maxHeight: 120)
            }
        }
    }

    @ViewBuilder
    private func directionRow(_ direction: SceneDirection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: iconForTag(direction.tag))
                .foregroundStyle(colorForTag(direction.tag))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(direction.tag.rawValue.uppercased())
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundStyle(colorForTag(direction.tag))
                    if !direction.primaryValue.isEmpty {
                        Text(direction.primaryValue)
                            .font(.caption)
                    }
                }

                if !direction.parameters.isEmpty {
                    Text(direction.parameters.map { "\($0.key)=\($0.value)" }.joined(separator: " | "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Text("L\(direction.sourceLineNumber)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Actions

    private func loadLyricsForSelectedScene() {
        guard let scene = store.selectedScene else {
            lyricsText = ""
            return
        }

        isLoadingLyrics = true
        Task {
            await store.loadSongData(for: scene)
            if let songData = store.currentSongData {
                lyricsText = songData.extractLyrics()
            } else {
                lyricsText = ""
            }
            isLoadingLyrics = false
        }
    }

    private func parseScript() {
        guard !scriptText.isEmpty else {
            parseResult = nil
            compiledScene = nil
            return
        }
        parseResult = SceneDirectionParser.parse(scriptText)
    }

    private func compileAndApply() {
        guard let result = parseResult else { return }

        let compiled = SceneDirectionParser.compile(
            directions: result.directions,
            fps: store.fps,
            bpm: bpm,
            beatsPerBar: beatsPerBar
        )
        compiledScene = compiled

        store.applyCompiledScene(compiled)
        store.statusMessage = "Applied \(result.directions.count) directions (\(compiled.totalFrames) frames)"
    }

    // MARK: - Helpers

    private func iconForTag(_ tag: DirectionTag) -> String {
        switch tag {
        case .scene: "film"
        case .enter: "arrow.right.to.line"
        case .exit: "arrow.left.to.line"
        case .move: "arrow.right"
        case .emotion: "face.smiling"
        case .action: "figure.walk"
        case .gesture: "hand.raised"
        case .object: "shippingbox"
        case .objectMove: "shippingbox.and.arrow.backward"
        case .objectState: "shippingbox.circle"
        case .objectVisibility: "eye"
        case .camera: "video"
        case .lipsync: "mouth"
        case .pause: "pause"
        case .sfx: "speaker.wave.2"
        case .transition: "rectangle.2.swap"
        }
    }

    private func colorForTag(_ tag: DirectionTag) -> Color {
        switch tag {
        case .scene: .blue
        case .enter: .green
        case .exit: .red
        case .move: .orange
        case .emotion: .pink
        case .action: .purple
        case .gesture: .mint
        case .object: .brown
        case .objectMove: .orange
        case .objectState: .yellow
        case .objectVisibility: .gray
        case .camera: .cyan
        case .lipsync: .yellow
        case .pause: .gray
        case .sfx: .indigo
        case .transition: .teal
        }
    }

    // MARK: - Example Script

    private var exampleScript: String {
        """
        [scene: "Ballroom" | bg=ballroom_night | lighting=dim]
        [enter: "Amira" | position=stage_left | facing=right | emotion=neutral]
        [enter: "Luke" | position=stage_right | facing=left | emotion=confident]

        AMIRA: (singing) I never thought I'd see the day...
        [lipsync: "Amira" | mode=singing | song=duet | bars=1-4]
        [move: "Amira" | from=stage_left | to=center | bars=1-4 | easing=ease_in_out]
        [emotion: "Amira" | expression=hopeful | bar=3]

        LUKE: (singing) And here we stand together now...
        [lipsync: "Luke" | mode=singing | song=duet | bars=5-8]
        [gesture: "Luke" | type=extend_hand | hand=right | bars=5-6]
        [move: "Luke" | from=stage_right | to=center_right | bars=5-8 | easing=ease_out]

        [camera: zoom_in | from=wide | to=medium | bars=1-8 | easing=ease_in_out]

        [emotion: "Amira" | expression=happy | bar=7]
        [action: "Amira" | takes Luke's hand | bars=7-8]
        [pause: bars=1]
        [transition: crossfade | duration=bars:1]
        """
    }
}
