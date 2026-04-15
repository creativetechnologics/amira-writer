import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 26.0, *)
struct VideoMouthSyncConfigurationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var pipeline = VideoMouthSyncPipeline()

    @State private var sourceVideoURL: URL?
    @State private var outputURL: URL?
    @State private var mixedAudioURL: URL?
    @State private var characterTracks: [CharacterSyncTrack] = []
    @State private var exportFormat: VideoExporter.ExportFormat = .mp4
    @State private var resolution: VideoExporter.ExportResolution = .hd1080
    @State private var fps: Int = 24
    @State private var smoothingStrength: Int = 2
    @State private var featherRadius: Float = 4.0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if pipeline.isRunning {
                progressView
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sourceVideoSection
                        characterTracksSection
                        exportSettingsSection
                    }
                    .padding()
                }
            }

            Divider()
            footer
        }
        .frame(width: 580, height: pipeline.isRunning ? 280 : 620)
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Image(systemName: "mouth")
                .foregroundStyle(.blue)
            Text("Video Mouth Sync")
                .font(.headline)
            Spacer()
        }
        .padding()
    }

    // MARK: - Source Video

    @ViewBuilder
    private var sourceVideoSection: some View {
        GroupBox("Source Video") {
            VStack(alignment: .leading, spacing: 8) {
                filePickerRow(
                    label: "Video File",
                    url: sourceVideoURL,
                    icon: "film",
                    placeholder: "Choose source video...",
                    contentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                    onSelect: { sourceVideoURL = $0 }
                )

                filePickerRow(
                    label: "Mixed Audio",
                    url: mixedAudioURL,
                    icon: "waveform",
                    placeholder: "Optional mixed audio stem...",
                    contentTypes: [.audio, .wav, .mp3, .aiff],
                    onSelect: { mixedAudioURL = $0 },
                    onRemove: { mixedAudioURL = nil }
                )

                HStack {
                    Text("Frame Rate")
                    Spacer()
                    Picker("", selection: $fps) {
                        Text("12 fps").tag(12)
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }
            }
        }
    }

    // MARK: - Character Tracks

    @ViewBuilder
    private var characterTracksSection: some View {
        GroupBox("Characters") {
            VStack(alignment: .leading, spacing: 12) {
                if characterTracks.isEmpty {
                    Text("No characters added.")
                        .foregroundStyle(.tertiary)
                        .font(.callout)
                }

                ForEach(characterTracks) { track in
                    characterTrackRow(track: track)
                }

                Button {
                    addCharacterTrack()
                } label: {
                    Label("Add Character", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func characterTrackRow(track: CharacterSyncTrack) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.fill")
                    .foregroundStyle(.secondary)
                TextField("Character Name", text: trackNameBinding(for: track.id))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)

                Spacer()

                Button {
                    removeCharacterTrack(track.id)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                filePickerCompact(
                    label: "Audio Stem",
                    url: track.audioStemURL,
                    icon: "music.note",
                    placeholder: "Audio stem...",
                    contentTypes: [.audio, .wav, .mp3, .aiff],
                    onSelect: { url in
                        updateTrack(track.id) { t in t.audioStemURL = url }
                    }
                )

                filePickerCompact(
                    label: "Sprites",
                    url: track.mouthSpriteFolderURL,
                    icon: "folder",
                    placeholder: "Mouth sprites folder...",
                    contentTypes: [],
                    isFolder: true,
                    onSelect: { url in
                        updateTrack(track.id) { t in t.mouthSpriteFolderURL = url }
                    }
                )
            }

            HStack(spacing: 12) {
                filePickerCompact(
                    label: "OWS Song",
                    url: nil,
                    icon: "music.note.list",
                    placeholder: track.songData != nil ? "Loaded: \(track.songData?.title ?? "")" : "Optional singing data...",
                    contentTypes: [.json],
                    onSelect: { url in
                        loadOWS(for: track.id, from: url)
                    }
                )

                TextField(
                    "Dialogue text (optional)",
                    text: trackDialogueBinding(for: track.id),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .frame(maxWidth: .infinity)
            }
        }
        .padding(8)
        .background(.background.secondary)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Export Settings

    @ViewBuilder
    private var exportSettingsSection: some View {
        GroupBox("Export Settings") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Format", selection: $exportFormat) {
                        ForEach(VideoExporter.ExportFormat.allCases, id: \.self) { fmt in
                            Text(fmt.rawValue).tag(fmt)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                HStack {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(VideoExporter.ExportResolution.allCases, id: \.self) { res in
                            Text(res.rawValue).tag(res)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                HStack {
                    Text("Smoothing")
                    Slider(value: .init(
                        get: { Double(smoothingStrength) },
                        set: { smoothingStrength = Int($0.rounded()) }
                    ), in: 0...5, step: 1)
                    Text("\(smoothingStrength)")
                        .monospacedDigit()
                        .frame(width: 20)
                }

                HStack {
                    Text("Feather")
                    Slider(value: $featherRadius, in: 0...10, step: 0.5)
                    Text(String(format: "%.1f px", featherRadius))
                        .monospacedDigit()
                        .frame(width: 50)
                }

                filePickerRow(
                    label: "Output",
                    url: outputURL,
                    icon: "arrow.down.doc",
                    placeholder: "Choose output location...",
                    contentTypes: [],
                    isSave: true,
                    onSelect: { outputURL = $0 }
                )
            }
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView(value: pipeline.progress.overallFraction) {
                Text(pipeline.progress.message)
                    .font(.callout)
            }
            .progressViewStyle(.linear)

            Text("\(Int(pipeline.progress.overallFraction * 100))%")
                .font(.title2)
                .monospacedDigit()

            if let error = pipeline.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button(pipeline.isRunning ? "Cancel" : "Close") {
                if pipeline.isRunning {
                    pipeline.cancel()
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if !pipeline.isRunning {
                Button("Start Mouth Sync") {
                    startPipeline()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canStart)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - Computed

    private var canStart: Bool {
        guard sourceVideoURL != nil,
              outputURL != nil,
              !characterTracks.isEmpty
        else { return false }
        return characterTracks.allSatisfy { !$0.characterName.isEmpty }
    }

    // MARK: - Actions

    private func startPipeline() {
        guard let sourceVideoURL, let outputURL else { return }

        let config = VideoMouthSyncConfiguration(
            sourceVideoURL: sourceVideoURL,
            outputVideoURL: outputURL,
            format: exportFormat,
            resolution: resolution,
            fps: fps,
            characterTracks: characterTracks,
            mixedAudioURL: mixedAudioURL,
            smoothingStrength: smoothingStrength,
            featherRadius: featherRadius
        )

        Task { @MainActor in
            do {
                _ = try await pipeline.process(config)
                pipeline.errorMessage = nil
                try await Task.sleep(for: .seconds(1.5))
                dismiss()
            } catch {
                pipeline.errorMessage = error.localizedDescription
            }
        }
    }

    private func addCharacterTrack() {
        let index = characterTracks.count + 1
        let slug = "character_\(index)"
        characterTracks.append(CharacterSyncTrack(
            characterName: "",
            characterSlug: slug,
            audioStemURL: URL(fileURLWithPath: "/dev/null"),
            mouthSpriteFolderURL: URL(fileURLWithPath: "/dev/null")
        ))
    }

    private func removeCharacterTrack(_ id: UUID) {
        characterTracks.removeAll { $0.id == id }
    }

    private func updateTrack(_ id: UUID, update: (inout CharacterSyncTrack) -> Void) {
        guard let idx = characterTracks.firstIndex(where: { $0.id == id }) else { return }
        update(&characterTracks[idx])
    }

    private func trackNameBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { characterTracks.first(where: { $0.id == id })?.characterName ?? "" },
            set: { newValue in
                if let idx = characterTracks.firstIndex(where: { $0.id == id }) {
                    characterTracks[idx].characterName = newValue
                    characterTracks[idx].characterSlug = newValue
                        .lowercased()
                        .replacingOccurrences(of: " ", with: "_")
                        .components(separatedBy: .alphanumerics.inverted)
                        .joined()
                }
            }
        )
    }

    private func trackDialogueBinding(for id: UUID) -> Binding<String> {
        Binding(
            get: { characterTracks.first(where: { $0.id == id })?.dialogueText ?? "" },
            set: { newValue in
                if let idx = characterTracks.firstIndex(where: { $0.id == id }) {
                    characterTracks[idx].dialogueText = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    private func loadOWS(for id: UUID, from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let songData = try JSONDecoder().decode(OWSSongData.self, from: data)
            updateTrack(id) { t in t.songData = songData }
        } catch {
            pipeline.errorMessage = "Failed to load OWS: \(error.localizedDescription)"
        }
    }

    // MARK: - File Picker Helpers

    @ViewBuilder
    private func filePickerRow(
        label: String,
        url: URL?,
        icon: String,
        placeholder: String,
        contentTypes: [UTType],
        isSave: Bool = false,
        isFolder: Bool = false,
        onSelect: @escaping (URL) -> Void,
        onRemove: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            if let url {
                Text(url.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if let onRemove {
                    Button("Remove") { onRemove() }
                        .controlSize(.small)
                }
            } else {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            Button("Choose...") {
                if isSave {
                    let panel = NSSavePanel()
                    panel.title = "Save Output"
                    panel.nameFieldStringValue = "mouth_sync_output.\(exportFormat.fileExtension)"
                    panel.begin { response in
                        if response == .OK, let selected = panel.url { onSelect(selected) }
                    }
                } else if isFolder {
                    let panel = NSOpenPanel()
                    panel.title = "Choose Folder"
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.begin { response in
                        if response == .OK, let selected = panel.url { onSelect(selected) }
                    }
                } else {
                    let panel = NSOpenPanel()
                    panel.title = "Choose File"
                    if !contentTypes.isEmpty {
                        panel.allowedContentTypes = contentTypes
                    }
                    panel.allowsMultipleSelection = false
                    panel.begin { response in
                        if response == .OK, let selected = panel.url { onSelect(selected) }
                    }
                }
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func filePickerCompact(
        label: String,
        url: URL?,
        icon: String,
        placeholder: String,
        contentTypes: [UTType],
        isFolder: Bool = false,
        onSelect: @escaping (URL) -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.caption)
            if url != nil, !isFolder {
                Text(url?.lastPathComponent ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.caption)
            } else {
                Text(placeholder)
                    .foregroundStyle(.tertiary)
                    .font(.caption)
            }
            Spacer()
            Button("...") {
                if isFolder {
                    let panel = NSOpenPanel()
                    panel.title = label
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    panel.begin { response in
                        if response == .OK, let selected = panel.url { onSelect(selected) }
                    }
                } else {
                    let panel = NSOpenPanel()
                    panel.title = label
                    if !contentTypes.isEmpty { panel.allowedContentTypes = contentTypes }
                    panel.allowsMultipleSelection = false
                    panel.begin { response in
                        if response == .OK, let selected = panel.url { onSelect(selected) }
                    }
                }
            }
            .controlSize(.mini)
        }
    }
}
