import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@available(macOS 26.0, iOS 26.0, *)
struct SunoInspectorView: View {
    @Bindable var store: ScoreStore

    enum Tab: String, CaseIterable {
        case cover = "Cover"
        case log = "Log"
        case lyrics = "Lyrics"
        case settings = "Settings"
    }

    @State private var activeTab: Tab = .cover
    @State private var newPresetName: String = ""

    private struct SunoSongSelectionItem: Identifiable {
        let relativePath: String
        let displayName: String
        let hasPlaybackData: Bool
        let playbackSummary: String

        var id: String { relativePath }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Button {
                        activeTab = tab
                    } label: {
                        Text(tab.rawValue)
                            .font(.caption2.weight(activeTab == tab ? .semibold : .regular))
                            .foregroundStyle(activeTab == tab ? .primary : .secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity)
                            .background(
                                activeTab == tab
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.clear
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.white.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 8)
            .padding(.top, 4)

            Divider().padding(.vertical, 4)

            // Tab content
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch activeTab {
                    case .cover:
                        renderTabContent
                    case .log:
                        logTabContent
                    case .lyrics:
                        lyricsTabContent
                    case .settings:
                        settingsTabContent
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Plan Tab

    @ViewBuilder
    private var planTabContent: some View {
        // Style template
        VStack(alignment: .leading, spacing: 4) {
            Text("Style Template")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("Style Preset", selection: Binding(
                get: { store.sunoStylePreset },
                set: { store.applySunoStylePreset($0) }
            )) {
                ForEach(SunoStylePreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            TextField("e.g. orchestral, cinematic, epic", text: Binding(
                get: { store.sunoStyleTemplate },
                set: { store.sunoStyleTemplate = $0 }
            ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Split Strategy")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("Split Strategy", selection: Binding(
                get: { store.sunoSplitMode },
                set: { store.sunoSplitMode = $0 }
            )) {
                ForEach(SunoSplitMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)

            Text(splitModeHelpText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }

        VStack(alignment: .leading, spacing: 4) {
            Text("Exclude Styles")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("e.g. drums, percussion, cymbals", text: Binding(
                get: { store.sunoExcludeStyles },
                set: { store.sunoExcludeStyles = $0 }
            ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
        }

        VStack(alignment: .leading, spacing: 6) {
            Text("Cover Defaults")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            HStack {
                Text("Weirdness")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Stepper(value: Binding(
                    get: { store.sunoCoverWeirdness },
                    set: { store.sunoCoverWeirdness = min(100, max(0, $0)) }
                ), in: 0...100, step: 5) {
                    Text("\(store.sunoCoverWeirdness)%")
                        .font(.caption2.monospacedDigit())
                }
                .controlSize(.mini)
            }

            HStack {
                Text("Style Influence")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Stepper(value: Binding(
                    get: { store.sunoCoverStyleInfluence },
                    set: { store.sunoCoverStyleInfluence = min(100, max(0, $0)) }
                ), in: 0...100, step: 5) {
                    Text("\(store.sunoCoverStyleInfluence)%")
                        .font(.caption2.monospacedDigit())
                }
                .controlSize(.mini)
            }

            HStack {
                Text("Audio Influence")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Stepper(value: Binding(
                    get: { store.sunoCoverAudioInfluence },
                    set: { store.sunoCoverAudioInfluence = min(100, max(0, $0)) }
                ), in: 0...100, step: 5) {
                    Text("\(store.sunoCoverAudioInfluence)%")
                        .font(.caption2.monospacedDigit())
                }
                .controlSize(.mini)
            }
        }

        // Config summary
        VStack(alignment: .leading, spacing: 4) {
            Text("Chunk Config")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

            HStack {
                Text("Chunk duration")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(Int(store.sunoConfig.minChunkDurationSeconds))–\(Int(store.sunoConfig.maxChunkDurationSeconds))s")
                    .font(.caption2.monospacedDigit())
            }
            if store.sunoSplitMode == .manualSplits {
                HStack {
                    Text("Manual split points")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Text("\(store.sunoSplitTicks.count)")
                        .font(.caption2.monospacedDigit())
                }
            }
            HStack {
                Text("Takes per chunk")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Stepper(value: Binding(
                    get: { store.sunoConfig.takesPerChunk },
                    set: { store.sunoConfig.takesPerChunk = $0 }
                ), in: 1...10) {
                    Text("\(store.sunoConfig.takesPerChunk)")
                        .font(.caption2.monospacedDigit())
                }
                .controlSize(.mini)
            }
        }

        Divider()

        // Generate plan button
        Button {
            store.generateSunoChunkPlan()
        } label: {
            Label("Generate Chunk Plan", systemImage: "wand.and.stars")
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(store.selectedMidiID == nil || store.pianoRollNotes.isEmpty)

        // Stale warning
        if store.isChunkPlanStale {
            Label("Plan is stale — score was edited since planning", systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(.orange)
        }

        // Chunk list
        if let plan = store.activeChunkPlan {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(plan.chunks.count) Chunks")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(plan.createdAt, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                ForEach(plan.chunks) { chunk in
                    chunkRow(chunk)
                }
            }
        } else {
            Text("No chunk plan generated yet")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func chunkRow(_ chunk: SunoChunkSpec) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(chunkStatusColor(chunk.status))
                    .frame(width: 6, height: 6)
                Text(chunk.groupLabel)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                Spacer()
                Text(chunk.status.rawValue)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("\(String(format: "%.1f", chunk.timeStart))s – \(String(format: "%.1f", chunk.timeEnd))s")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(chunk.density.rawValue)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            if !chunk.instrumentGroup.isEmpty {
                Text(chunk.instrumentGroup.joined(separator: ", "))
                    .font(.system(size: 9))
                    .foregroundStyle(.quaternary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.03)))
    }

    private func chunkStatusColor(_ status: SunoChunkStatus) -> Color {
        switch status {
        case .planned: return .gray
        case .exporting, .generating: return .yellow
        case .exported, .downloaded: return .blue
        case .aligning, .aligned: return .cyan
        case .selected: return .green
        case .failed: return .red
        }
    }

    private var splitModeHelpText: String {
        switch store.sunoSplitMode {
        case .noSplit:
            return "Send the whole song to Suno as one file."
        case .structural:
            return "Use detected sections and markers when available."
        case .manualSplits:
            return "Use the manual Suno split markers you place in the score."
        case .evenDuration:
            return "Split into large even chunks using the chunk-duration settings."
        }
    }

    // MARK: - Render Tab

    @ViewBuilder
    private var renderTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("This follows the current Suno workflow: rebuild the CLI with `Scripts/setup-suno-cli.sh`, fresh export, `suno_create_cover`, dual song IDs, polling, and both WAV downloads into the project's `Suno/` folder.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // MARK: Source selector
            VStack(alignment: .leading, spacing: 4) {
                Text("Source")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Source", selection: Binding(
                    get: { store.sunoCoverSourceMode },
                    set: { store.sunoCoverSourceMode = $0 }
                )) {
                    ForEach(SunoCoverSourceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)

                if store.sunoCoverSourceMode == .currentSong {
                    if let asset = store.selectedMidiAsset {
                        Text(asset.displayName)
                            .font(.caption2)
                            .foregroundStyle(.primary)
                        let exportInfo = store.sunoMixExportInfo(for: asset.relativePath)
                        if let info = exportInfo {
                            Text("Mix WAV: \(info.modifiedAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute()))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No mix export — use Export to Mix first")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    } else {
                        Text("No song selected")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    let available = sunoSongSelectionItems
                    if available.isEmpty {
                        Text("No songs in project")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    } else {
                        HStack(spacing: 8) {
                            Button("Select All") {
                                store.sunoCoverSelectedSongPaths = Set(sunoSelectableSongPaths)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(sunoSelectableSongPaths.isEmpty)

                            Button("Clear") {
                                store.sunoCoverSelectedSongPaths.removeAll()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(store.sunoCoverSelectedSongPaths.isEmpty)

                            Spacer()

                            Text("\(sunoSelectableSongPaths.count) ready / \(available.count) total")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }

                        ScrollView {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(available) { song in
                                    sunoSongSelectionRow(for: song)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                    }
                }
            }

            // MARK: Canonical Cover Preset
            VStack(alignment: .leading, spacing: 4) {
                Text("Canonical Cover Preset")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Picker("Cover Preset", selection: Binding(
                    get: { store.sunoCoverPreset },
                    set: { store.sunoCoverPreset = $0 }
                )) {
                    ForEach(SunoCoverPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
            }

            // MARK: Saved Preset
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved Preset")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Picker("Preset", selection: Binding(
                        get: { store.sunoSelectedPromptPresetID },
                        set: { newID in
                            store.sunoSelectedPromptPresetID = newID
                            if let id = newID {
                                store.sunoApplyPromptPreset(id: id)
                            }
                        }
                    )) {
                        Text("— None —").tag(UUID?.none)
                        ForEach(store.sunoCoverPromptPresets) { preset in
                            Text(preset.name).tag(Optional(preset.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    TextField("new preset name", text: $newPresetName)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button("Save") {
                        store.sunoSavePromptPreset(name: newPresetName)
                        newPresetName = ""
                    }
                    .controlSize(.small)
                    .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button {
                        if let id = store.sunoSelectedPromptPresetID {
                            store.sunoDeletePromptPreset(id: id)
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .controlSize(.small)
                    .disabled(store.sunoSelectedPromptPresetID == nil)
                }
            }

            // MARK: Prompt override (replaces read-only Resolved Prompt)
            VStack(alignment: .leading, spacing: 4) {
                Text("Prompt")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("(leave blank to use preset prompt)", text: Binding(
                    get: { store.sunoCoverPromptOverride },
                    set: { store.sunoCoverPromptOverride = $0 }
                ), axis: .vertical)
                .lineLimit(3...8)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                if store.sunoCoverPromptOverride.isEmpty {
                    Text("Effective: \(store.sunoResolvedCoverPrompt)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // MARK: Lyrics diagnostic (unchanged)
            VStack(alignment: .leading, spacing: 4) {
                Text("Lyrics")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if store.sunoCoverRequiresLyrics {
                    if store.hasFormattedSunoLyrics {
                        Label("Real lyrics will be submitted from the Lyrics tab.", systemImage: "text.quote")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Label("This preset needs real lyrics before Suno can run.", systemImage: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Label("This preset submits `[Instrumental]`.", systemImage: "music.note")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if store.sunoCoverPreset.isVocal {
                    Text(store.sunoResolvedVocalGenderArgument.isEmpty
                         ? "Vocal gender argument: automatic/unspecified"
                         : "Vocal gender argument: \(store.sunoResolvedVocalGenderArgument)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // MARK: Lyrics override
            VStack(alignment: .leading, spacing: 4) {
                Text("Lyrics Override")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("(leave blank to use Lyrics tab)", text: Binding(
                    get: { store.sunoCoverLyricsOverride },
                    set: { store.sunoCoverLyricsOverride = $0 }
                ), axis: .vertical)
                .lineLimit(3...12)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                Text("When blank, the Lyrics tab's formatted libretto is used.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // MARK: Negative Prompt
            VStack(alignment: .leading, spacing: 4) {
                Text("Negative Prompt")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("drums, percussion, cymbals, snare, kick", text: Binding(
                    get: { store.sunoExcludeStyles },
                    set: { store.sunoExcludeStyles = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Canonical Sliders")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Weirdness")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Stepper(value: Binding(
                        get: { store.sunoCoverWeirdness },
                        set: { store.sunoCoverWeirdness = min(100, max(0, $0)) }
                    ), in: 0...100, step: 5) {
                        Text("\(store.sunoCoverWeirdness)%")
                            .font(.caption2.monospacedDigit())
                    }
                    .controlSize(.mini)
                }

                HStack {
                    Text("Style Influence")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Stepper(value: Binding(
                        get: { store.sunoCoverStyleInfluence },
                        set: { store.sunoCoverStyleInfluence = min(100, max(0, $0)) }
                    ), in: 0...100, step: 5) {
                        Text("\(store.sunoCoverStyleInfluence)%")
                            .font(.caption2.monospacedDigit())
                    }
                    .controlSize(.mini)
                }

                HStack {
                    Text("Audio Influence")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Stepper(value: Binding(
                        get: { store.sunoCoverAudioInfluence },
                        set: { store.sunoCoverAudioInfluence = min(100, max(0, $0)) }
                    ), in: 0...100, step: 5) {
                        Text("\(store.sunoCoverAudioInfluence)%")
                            .font(.caption2.monospacedDigit())
                    }
                    .controlSize(.mini)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Cover Queue")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Iterations")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Stepper(value: Binding(
                        get: { store.sunoCoverIterations },
                        set: { store.sunoCoverIterations = min(12, max(1, $0)) }
                    ), in: 1...12, step: 1) {
                        Text("\(max(1, store.sunoCoverIterations))×")
                            .font(.caption2.monospacedDigit())
                    }
                    .controlSize(.mini)
                }

                Text(store.sunoCoverQueueSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(store.sunoCoverQueueDelaySummary)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    Task { await store.sunoRunCanonicalCover() }
                } label: {
                    Label(store.sunoRunCanonicalCoverButtonTitle, systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.sunoIsGenerating || !store.sunoCanRunCanonicalCover)

                if store.sunoIsGenerating {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if !store.sunoGenerateStatus.isEmpty {
                Text(store.sunoGenerateStatus)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Generated Covers")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if store.selectedSunoGenerations.isEmpty {
                    Text("No Suno cover runs for this song yet")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(store.selectedSunoGenerations) { generation in
                        generationRow(generation)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: SunoRenderSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Render \(session.id.uuidString.prefix(8))")
                        .font(.caption2.weight(.medium))
                    Text(session.createdAt, style: .date)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(session.status.rawValue)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    store.importSunoSessionToAudioPane(session.id, selectedOnly: true)
                } label: {
                    Label("Selected", systemImage: "checkmark.circle")
                }
                .controlSize(.mini)

                Button {
                    store.importSunoSessionToAudioPane(session.id, selectedOnly: false)
                } label: {
                    Label("All Takes", systemImage: "square.stack.3d.up")
                }
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.03)))
    }

    @ViewBuilder
    private func generationRow(_ generation: SunoGeneration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(generation.displayTitle)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                    if let baseTitle = generation.baseTitle, let version = generation.version {
                        Text(String(format: "%@ v%03d", baseTitle, version))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    if let submissionIndex = generation.submissionIndex, let submissionCount = generation.submissionCount {
                        Text("Submission \(submissionIndex)/\(submissionCount)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text(generation.createdAt, style: .time)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(generation.status.title)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if !generation.resolvedSongIDs.isEmpty {
                Text("Captured IDs: \(generation.resolvedSongIDs.joined(separator: ", "))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if generation.resolvedDownloadedFilePaths.isEmpty {
                    if generation.status == .polling || generation.status == .downloading {
                        Label("Waiting for generated WAVs", systemImage: "hourglass")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(Array(generation.resolvedDownloadedFilePaths.enumerated()), id: \.offset) { index, path in
                        let previewLabel = index == 0 ? "Preview A" : index == 1 ? "Preview B" : "Preview \(index + 1)"
                        Button {
                            store.sunoPreviewDownloadedFile(path, generationID: generation.id)
                        } label: {
                            Label(previewLabel, systemImage: "play.circle")
                        }
                        .controlSize(.mini)
                    }

                    Button {
                        store.sunoRevealGenerationDownloads(generation.id)
                    } label: {
                        Label("Reveal", systemImage: "folder")
                    }
                    .controlSize(.mini)
                }
            }

            if generation.status == .submitted || generation.status == .submitting {
                Text("Cover request submitted to Suno.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if generation.status == .polling {
                Text("Waiting for both Suno song IDs to reach `status=complete`.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            if let error = generation.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.03)))
    }

    // MARK: - Log Tab

    @ViewBuilder
    private var logTabContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pipeline Status Log")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if !store.sunoStatusLog.isEmpty {
                    Button("Clear") {
                        store.sunoStatusLog.removeAll()
                    }
                    .font(.caption2)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if store.selectedSunoGenerations.isEmpty {
                Label("No canonical Suno cover runs for the selected song yet", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                let downloaded = store.selectedSunoGenerations.filter { $0.isDownloaded }.count
                let processing = store.selectedSunoGenerations.filter { $0.isProcessing }.count
                let failed = store.selectedSunoGenerations.filter { $0.isFailed }.count

                HStack(spacing: 12) {
                    statusBadge(count: downloaded, label: "Downloaded", color: .green)
                    statusBadge(count: processing, label: "Running", color: .yellow)
                    if failed > 0 {
                        statusBadge(count: failed, label: "Failed", color: .red)
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()

            if store.sunoStatusLog.isEmpty {
                Text("No log entries yet. Run the canonical cover flow to see status updates here.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                ForEach(store.sunoStatusLog) { entry in
                    HStack(alignment: .top, spacing: 6) {
                        Circle()
                            .fill(logLevelColor(entry.level))
                            .frame(width: 5, height: 5)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.message)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                            Text(entry.timestamp, style: .time)
                                .font(.system(size: 8))
                                .foregroundStyle(.quaternary)
                        }
                    }
                }
            }
        }
    }

    private func statusBadge(count: Int, label: String, color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(count)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }

    private func logLevelColor(_ level: ScoreStore.SunoLogEntry.Level) -> Color {
        switch level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .success: return .green
        }
    }

    private var sunoSongSelectionItems: [SunoSongSelectionItem] {
        store.sunoAvailableSongPaths().compactMap { song in
            guard let asset = store.songAssets.first(where: { $0.relativePath == song.relativePath }) else {
                return nil
            }

            let playback = asset.document.activeVersion()?.playback
            let noteCount = playback?.notes.count ?? 0
            let audioClipCount = playback?.audioClips.count ?? 0
            return SunoSongSelectionItem(
                relativePath: song.relativePath,
                displayName: song.displayName,
                hasPlaybackData: asset.hasPlayableScoreData,
                playbackSummary: sunoPlaybackSummary(noteCount: noteCount, audioClipCount: audioClipCount)
            )
        }
    }

    private var sunoSelectableSongPaths: [String] {
        store.sunoBatchSelectableSongPaths.map(\.relativePath)
    }

    private func sunoPlaybackSummary(noteCount: Int, audioClipCount: Int) -> String {
        switch (noteCount, audioClipCount) {
        case let (notes, clips) where notes > 0 && clips > 0:
            return "\(notes) notes, \(clips) audio clips"
        case let (notes, _) where notes > 0:
            return "\(notes) playback notes"
        case let (_, clips) where clips > 0:
            return "\(clips) audio clips"
        default:
            return "No playback data — skipped by Select All"
        }
    }

    @ViewBuilder
    private func sunoSongSelectionRow(for song: SunoSongSelectionItem) -> some View {
        let selectionBinding = Binding<Bool>(
            get: { store.sunoCoverSelectedSongPaths.contains(song.relativePath) },
            set: { isOn in
                if isOn {
                    store.sunoCoverSelectedSongPaths.insert(song.relativePath)
                } else {
                    store.sunoCoverSelectedSongPaths.remove(song.relativePath)
                }
            }
        )

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Toggle(song.displayName, isOn: selectionBinding)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .disabled(!song.hasPlaybackData)
                    .opacity(song.hasPlaybackData ? 1 : 0.55)

                Spacer()

                if let info = store.sunoMixExportInfo(for: song.relativePath) {
                    Text(info.modifiedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("no mix export")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            HStack(spacing: 6) {
                if song.hasPlaybackData {
                    Label(song.playbackSummary, systemImage: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Label(song.playbackSummary, systemImage: "slash.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 4).fill(
                song.hasPlaybackData
                    ? Color.white.opacity(0.03)
                    : Color.orange.opacity(0.08)
            )
        )
        .opacity(song.hasPlaybackData ? 1 : 0.72)
    }

    // MARK: - Lyrics Tab

    @ViewBuilder
    private var lyricsTabContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Suno-Formatted Lyrics")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyLyricsToPasteboard(store.formattedSunoLyrics)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(!store.hasFormattedSunoLyrics)
            }

            Text("Formatter rules: keeps only sung lines, removes scene/stage directions, preserves recognized musical section tags, and only adds speaker labels when a real character block is immediately followed by lyrics.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if store.hasFormattedSunoLyrics {
                TextEditor(text: .constant(store.formattedSunoLyrics))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 280)
                    .textSelection(.enabled)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.03)))
            } else {
                Text("No libretto/lyrics are attached to this song yet.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            }

            Divider()

            Text("Original-song requests in the Render tab automatically use this formatted lyric text.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func copyLyricsToPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    // MARK: - Settings Tab

    @ViewBuilder
    private var settingsTabContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Suno CLI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.sunoCLIIsInstalled ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Text(store.sunoCLIIsInstalled ? "CLI installed" : "CLI not found")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(store.sunoCLI.cliPath)
                        .font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Change…") { selectSunoCLIPath() }
                        .font(.caption2).controlSize(.mini)
                }
                if !store.sunoCLIIsInstalled {
                    Text("Rebuild it with `bash Scripts/setup-suno-cli.sh` (add `--force` if Chromium also needs a refresh).")
                        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Login Check").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if let result = store.sunoCLILastSelftest {
                    HStack(spacing: 6) {
                        Image(systemName: result.loggedIn ? "checkmark.circle.fill" : "xmark.octagon")
                            .foregroundStyle(result.loggedIn ? .green : .orange)
                        Text(result.loggedIn ? "Logged in to Suno" : "Not logged in")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Run a selftest to verify the CLI can log in.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    Button {
                        Task { await store.openSunoLoginBrowser() }
                    } label: {
                        Label("Open Suno Login", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .font(.caption2)
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.sunoCLIIsInstalled)

                    Button {
                        Task { await store.runSunoSelftest() }
                    } label: {
                        Label("Run Selftest", systemImage: "stethoscope")
                    }
                    .font(.caption2)
                    .controlSize(.mini)
                    .buttonStyle(.bordered)
                    .disabled(!store.sunoCLIIsInstalled)
                }

                if let message = store.sunoCLIStatusMessage, !message.isEmpty {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let err = store.sunoCLIErrorMessage, !err.isEmpty {
                    Text(err).font(.caption2).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Browser Profile").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(store.sunoCLI.profileDir)
                    .font(.caption2.monospaced()).lineLimit(2).truncationMode(.middle)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    store.revealSunoProfileDirectory()
                } label: {
                    Label("Reveal Profile Folder", systemImage: "folder")
                }
                .font(.caption2)
                .controlSize(.mini)
                .buttonStyle(.bordered)
                Text("This folder stores the persistent cookies/session that the Suno CLI reuses. You should only need to sign in once unless Suno expires the session.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func selectSunoCLIPath() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Select the `suno` CLI executable"
        if panel.runModal() == .OK, let url = panel.url {
            store.sunoCLI.cliPath = url.path
        }
        #endif
    }
}
