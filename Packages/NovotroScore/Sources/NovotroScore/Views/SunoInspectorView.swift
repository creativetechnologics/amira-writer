import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@available(macOS 26.0, iOS 26.0, *)
struct SunoInspectorView: View {
    @Bindable var store: ScoreStore

    enum Tab: String, CaseIterable {
        case plan = "Plan"
        case render = "Render"
        case log = "Log"
        case lyrics = "Lyrics"
        case settings = "Settings"
    }

    @State private var activeTab: Tab = .plan

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
                    case .plan:
                        planTabContent
                    case .render:
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Request Mode")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Picker("Request Mode", selection: Binding(
                get: { store.sunoRequestMode },
                set: { store.sunoRequestMode = $0 }
            )) {
                ForEach(SunoRequestMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }

        if store.sunoRequestMode == .cover {
            if store.activeChunkPlan != nil {
                HStack(spacing: 8) {
                    Button {
                        Task { await store.startSunoRender() }
                    } label: {
                        Label("Start Cover Render", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.activeRenderSession?.status == .generating)

                    Button {
                        store.exportForManualSuno()
                    } label: {
                        Label("Manual Export", systemImage: "square.and.arrow.up")
                    }
                    .controlSize(.small)
                }
            } else {
                Text("Generate a chunk plan first (Plan tab)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }

            if let session = store.activeRenderSession {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Active Session")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(session.status.rawValue)
                            .font(.system(size: 9, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.2))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }

                    let totalChunks = session.plan.chunks.count
                    let completedChunks = session.plan.chunks.filter {
                        $0.status == .downloaded || $0.status == .selected || $0.status == .aligned
                    }.count
                    ProgressView(value: Double(completedChunks), total: Double(max(1, totalChunks)))
                        .controlSize(.small)
                    Text("\(completedChunks)/\(totalChunks) chunks complete")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    HStack(spacing: 8) {
                        Button {
                            store.importSunoSessionToAudioPane(session.id, selectedOnly: true)
                        } label: {
                            Label("Import Selected Takes", systemImage: "waveform.badge.plus")
                        }
                        .controlSize(.small)

                        Button {
                            store.importSunoSessionToAudioPane(session.id, selectedOnly: false)
                        } label: {
                            Label("Import All Takes", systemImage: "square.stack.3d.up")
                        }
                        .controlSize(.small)
                    }
                    .padding(.top, 2)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Session History")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if store.sunoRenderSessions.isEmpty {
                    Text("No completed sessions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(store.sunoRenderSessions) { session in
                        sessionRow(session)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("Generate an original Suno song using the style prompt and the formatted lyrics from the Lyrics tab.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Song Prompt")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("If blank, the style template is used", text: Binding(
                        get: { store.sunoSongPrompt },
                        set: { store.sunoSongPrompt = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await store.sunoGenerateOriginalSong() }
                    } label: {
                        Label("Generate Original Song", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(store.sunoIsGenerating)

                    if store.hasFormattedSunoLyrics {
                        Label("Lyrics attached", systemImage: "text.quote")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    } else {
                        Label("No lyrics attached", systemImage: "text.quote")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if !store.sunoGenerateStatus.isEmpty {
                    Text(store.sunoGenerateStatus)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Generated Songs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if store.selectedSunoGenerations.isEmpty {
                        Text("No original-song generations for this song yet")
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
                    Text(generation.createdAt, style: .time)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(generation.status.title)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if generation.canDownload {
                    Button {
                        Task { await store.sunoDownloadTrack(generation.id) }
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                    .controlSize(.mini)
                }

                if generation.isDownloaded {
                    Button {
                        store.sunoPreviewTrack(generation.id)
                    } label: {
                        Label("Preview", systemImage: "play.circle")
                    }
                    .controlSize(.mini)
                }
            }

            if generation.status == .submitted {
                Text("Submitted in Suno. Download becomes available once a real Suno track ID is captured.")
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

            // Summary status
            if let plan = store.activeChunkPlan {
                let planned = plan.chunks.filter { $0.status == .planned }.count
                let exported = plan.chunks.filter { $0.status == .exported }.count
                let generating = plan.chunks.filter { $0.status == .generating }.count
                let done = plan.chunks.filter { [.downloaded, .selected, .aligned].contains($0.status) }.count
                let failed = plan.chunks.filter { $0.status == .failed }.count

                HStack(spacing: 12) {
                    statusBadge(count: planned, label: "Planned", color: .gray)
                    statusBadge(count: exported, label: "Exported", color: .blue)
                    statusBadge(count: generating, label: "Generating", color: .yellow)
                    statusBadge(count: done, label: "Done", color: .green)
                    if failed > 0 {
                        statusBadge(count: failed, label: "Failed", color: .red)
                    }
                }
                .padding(.vertical, 4)

                // Next action hint
                if store.activeRenderSession == nil {
                    if planned == plan.chunks.count {
                        Label("Ready to render — go to Render tab to start", systemImage: "arrow.right.circle")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                } else if let session = store.activeRenderSession {
                    Label("Session: \(session.status.rawValue)", systemImage: "circle.dotted")
                        .font(.caption2)
                        .foregroundStyle(.purple)
                }

                if store.isChunkPlanStale {
                    Label("Plan is stale — score was edited since planning", systemImage: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Label("No chunk plan — go to Plan tab to generate one", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if store.sunoStatusLog.isEmpty {
                Text("No log entries yet. Generate a chunk plan or start a render to see status updates here.")
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
            // Server setup section
            serverSetupSection

            Divider()

            // Connection status
            HStack(spacing: 6) {
                Circle()
                    .fill(store.sunoClient.isConfigured ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(store.sunoClient.isConfigured ? "API configured" : "Not configured")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if store.sunoLoggedIn {
                    Spacer()
                    Label("Logged in", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            // Chunk config (unchanged — keep existing steppers)
            VStack(alignment: .leading, spacing: 6) {
                Text("Generation Config")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Max chunk duration")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Stepper(value: Binding(
                        get: { store.sunoConfig.maxChunkDurationSeconds },
                        set: { store.sunoConfig.maxChunkDurationSeconds = $0 }
                    ), in: 15...120, step: 5) {
                        Text("\(Int(store.sunoConfig.maxChunkDurationSeconds))s")
                            .font(.caption2.monospacedDigit())
                    }
                    .controlSize(.mini)
                }

                HStack {
                    Text("Min chunk duration")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Stepper(value: Binding(
                        get: { store.sunoConfig.minChunkDurationSeconds },
                        set: { store.sunoConfig.minChunkDurationSeconds = $0 }
                    ), in: 5...60, step: 5) {
                        Text("\(Int(store.sunoConfig.minChunkDurationSeconds))s")
                            .font(.caption2.monospacedDigit())
                    }
                    .controlSize(.mini)
                }

                HStack {
                    Text("Density threshold (medium)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Stepper(value: Binding(
                        get: { store.sunoConfig.densityThresholdMedium },
                        set: { store.sunoConfig.densityThresholdMedium = $0 }
                    ), in: 2...10) {
                        Text("\(store.sunoConfig.densityThresholdMedium)")
                            .font(.caption2.monospacedDigit())
                    }
                    .controlSize(.mini)
                }

                HStack {
                    Text("Density threshold (dense)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Stepper(value: Binding(
                        get: { store.sunoConfig.densityThresholdDense },
                        set: { store.sunoConfig.densityThresholdDense = $0 }
                    ), in: 3...20) {
                        Text("\(store.sunoConfig.densityThresholdDense)")
                            .font(.caption2.monospacedDigit())
                    }
                    .controlSize(.mini)
                }
            }

            Divider()

            // QC mode info
            VStack(alignment: .leading, spacing: 4) {
                Text("QC Mode")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Curated: Review each take manually before proceeding. Auto: Accept best similarity score. Iterative: Re-roll low-scoring chunks.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var serverSetupSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suno Server")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if store.sunoServerIsBootstrapping {
                // State: Bootstrapping in progress
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(store.sunoBootstrapStep?.rawValue ?? "Setting up...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if store.sunoServerState == .running {
                // State: Server running
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Server running on \(store.sunoServerManager.serverAddressDisplay)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") {
                        store.sunoServerManager.stop()
                    }
                    .font(.caption2)
                    .controlSize(.mini)
                }
            } else if store.sunoServerIsBootstrapped {
                // State: Bootstrapped, server stopped
                HStack(spacing: 6) {
                    Circle()
                        .fill(store.sunoServerState == .error ? Color.red : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(store.sunoServerState == .error
                         ? (store.sunoServerErrorMessage ?? "Server error")
                         : "Server stopped")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer()
                    Button("Start") {
                        store.sunoServerManager.start()
                    }
                    .font(.caption2)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            } else {
                // State: Not bootstrapped
                VStack(alignment: .leading, spacing: 4) {
                    Text("Downloads and configures the Suno AI server for audio generation")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task {
                            do {
                                try await store.sunoServerManager.bootstrap { step in
                                    // Progress tracked via onStateChange callback → bridging properties
                                }
                            } catch {
                                store.appendSunoLog("Bootstrap failed: \(error.localizedDescription)", level: .error)
                                store.statusMessage = "Suno setup failed: \(error.localizedDescription)"
                            }
                        }
                    } label: {
                        Label("Set Up Suno", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            // Login section — always visible
            Divider()
            sunoLoginSection
        }
    }

    @ViewBuilder
    private var sunoLoginSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Suno Account")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            switch store.sunoLoginState {
            case .loggedIn:
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("Logged in to Suno")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Re-import") {
                        store.sunoServerManager.importLoginFromChrome()
                    }
                    .font(.caption2)
                    .controlSize(.mini)
                }
            case .loggingIn:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Importing login from Chrome...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            case .notLoggedIn:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Log into suno.com in Chrome first, then import your session here")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        store.sunoServerManager.importLoginFromChrome()
                    } label: {
                        Label("Import from Chrome", systemImage: "globe")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    if let error = store.sunoServerErrorMessage, !error.isEmpty {
                        Text(error)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
