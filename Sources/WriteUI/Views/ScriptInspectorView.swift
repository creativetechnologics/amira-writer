import SwiftUI
import ProjectKit
import Foundation
#if canImport(AppKit)
import AppKit
#endif

// MARK: - Inspector Section ID

enum InspectorSectionID: String, CaseIterable, Identifiable, Sendable {
    case tools
    case notes
    case versionHistory
    case sunoLyrics
    case synopsis
    case llm

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools: return "Tools"
        case .notes: return "Notes"
        case .versionHistory: return "Version History"
        case .sunoLyrics: return "Suno Lyrics"
        case .synopsis: return "Synopsis"
        case .llm: return "LLM"
        }
    }

    var systemImage: String {
        switch self {
        case .tools: return "wrench.and.screwdriver"
        case .notes: return "note.text"
        case .versionHistory: return "clock.arrow.counterclockwise"
        case .sunoLyrics: return "music.note"
        case .synopsis: return "doc.plaintext"
        case .llm: return "bubble.left.and.text.bubble.right"
        }
    }
}

// MARK: - Inspector View

@available(macOS 26.0, *)
struct ScriptInspectorView: View {
    @Bindable var store: ScriptStore
    @AppStorage("novotro.write.inspector.activeTab") private var activeTab: String = InspectorSectionID.synopsis.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private let tabOrder: [InspectorSectionID] = [.synopsis, .llm, .tools, .notes, .versionHistory, .sunoLyrics]

    private var selectedTab: Binding<InspectorSectionID> {
        Binding(
            get: { InspectorSectionID(rawValue: activeTab) ?? .synopsis },
            set: { activeTab = $0.rawValue }
        )
    }

    var body: some View {
        OperaChromeInspectorTabs(
            selection: selectedTab,
            tabs: tabOrder.map {
                OperaChromeTabItem(id: $0, title: $0.title, systemImage: $0.systemImage)
            }
        ) { sectionID in
            sectionContent(for: sectionID)
        } 
        .onAppear {
            if InspectorSectionID(rawValue: activeTab) == nil {
                activeTab = InspectorSectionID.synopsis.rawValue
            }

            if activeTab == InspectorSectionID.synopsis.rawValue {
                store.refreshSynopsisFromProjectFile()
            }
        }
        .onChange(of: activeTab) { _, newValue in
            if newValue == InspectorSectionID.synopsis.rawValue {
                store.refreshSynopsisFromProjectFile()
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                store.refreshSynopsisFromProjectFile()
            }
        }
    }

    @ViewBuilder
    private func sectionContent(for sectionID: InspectorSectionID) -> some View {
        switch sectionID {
        case .tools:
            ScrollView {
                ToolsSectionContent(store: store)
                    .padding(12)
            }
            .scrollIndicators(.never)
        case .notes:
            NotesSectionContent(store: store)
                .padding(12)
        case .versionHistory:
            VersionHistorySectionContent(store: store)
        case .sunoLyrics:
            SunoLyricsSectionContent(store: store)
        case .synopsis:
            SynopsisSectionView(store: store)
        case .llm:
            LLMInspectorView(store: store)
        }
    }
}

// MARK: - Tools Section

@available(macOS 26.0, *)
struct ToolsSectionContent: View {
    @Bindable var store: ScriptStore

    // Apple Notes state
    @State private var notesExportInProgress = false
    @State private var notesImportInProgress = false
    @State private var notesAlertMessage: String?
    @State private var showNotesAlert = false
    @State private var showImportConfirmation = false
    @State private var pendingImportNotes: [AppleNotesService.SceneNote] = []
    @State private var importMatchResults: [ImportMatchResult] = []

    private var directionColorBinding: Binding<Color> {
        Binding(
            get: { store.directionMarkupColor },
            set: { store.directionMarkupColorHex = ScriptMarkupPalette.hex(from: $0, fallback: ScriptMarkupPalette.defaultDirectionHex) }
        )
    }

    private var storyboardingColorBinding: Binding<Color> {
        Binding(
            get: { store.storyboardingMarkupColor },
            set: { store.storyboardingMarkupColorHex = ScriptMarkupPalette.hex(from: $0, fallback: ScriptMarkupPalette.defaultStoryboardingHex) }
        )
    }

    private var animateColorBinding: Binding<Color> {
        Binding(
            get: { store.animateMarkupColor },
            set: { store.animateMarkupColorHex = ScriptMarkupPalette.hex(from: $0, fallback: ScriptMarkupPalette.defaultAnimateHex) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: store.isLibrettoEditMode ? "pencil" : "eye")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(store.isLibrettoEditMode ? .orange : .secondary)
                Text(store.isLibrettoEditMode ? "Edit mode enables typing and the category toggles can reveal or hide markup." : "View mode is read-only and hides bracketed markup.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            markupToggleRow(
                title: "Show Directions",
                systemImage: "camera.metering.spot",
                isOn: $store.showDirections,
                color: directionColorBinding
            )

            markupToggleRow(
                title: "Show Storyboarding",
                systemImage: "film",
                isOn: $store.showStoryboarding,
                color: storyboardingColorBinding
            )

            markupToggleRow(
                title: "Show Animate",
                systemImage: "video",
                isOn: $store.showAnimateDirections,
                color: animateColorBinding
            )

            Divider()

            // Active scene stats
            if let path = store.activeSongPath,
               let libretto = store.librettoFiles.first(where: { $0.relativePath == path }) {
                let asset = store.songAssets.first(where: { $0.relativePath == path })

                VStack(alignment: .leading, spacing: 6) {
                    if let asset {
                        Text(asset.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                    }

                    HStack(spacing: 16) {
                        statItem(label: "Words", value: "\(wordCount(libretto.content))")
                        statItem(label: "Chars", value: "\(libretto.content.count)")
                    }

                    HStack(spacing: 16) {
                        statItem(label: "Lines", value: "\(lineCount(libretto.content))")
                        statItem(label: "Dirs", value: "\(DirectionParser.directionRanges(in: libretto.content).count)")
                        statItem(label: "Anim", value: "\(AnimatePromptParser.promptRanges(in: libretto.content).count)")
                    }
                }
            } else {
                Text("No active scene")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Renumber Directions button
            Button {
                renumberActiveDirections()
            } label: {
                Label("Renumber Directions", systemImage: "arrow.up.arrow.down")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(store.activeSongPath == nil)

            Divider()

            // Apple Notes Export / Import
            VStack(alignment: .leading, spacing: 6) {
                Text("Apple Notes")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text("Send scenes to Notes for mobile editing, then import changes back.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    Button {
                        exportToAppleNotes()
                    } label: {
                        Label(
                            notesExportInProgress ? "Exporting..." : "Export to Notes",
                            systemImage: "square.and.arrow.up"
                        )
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(store.songAssets.isEmpty || notesExportInProgress || notesImportInProgress)

                    Button {
                        importFromAppleNotes()
                    } label: {
                        Label(
                            notesImportInProgress ? "Importing..." : "Import from Notes",
                            systemImage: "square.and.arrow.down"
                        )
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(store.songAssets.isEmpty || notesExportInProgress || notesImportInProgress)
                }
            }
        }
        .alert("Apple Notes", isPresented: $showNotesAlert) {
            Button("OK") {}
        } message: {
            Text(notesAlertMessage ?? "")
        }
        .sheet(isPresented: $showImportConfirmation) {
            AppleNotesImportConfirmationView(
                matchResults: importMatchResults,
                onConfirm: { applyImportedNotes() },
                onCancel: {
                    pendingImportNotes = []
                    importMatchResults = []
                }
            )
        }
    }

    private func statItem(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func markupToggleRow(
        title: String,
        systemImage: String,
        isOn: Binding<Bool>,
        color: Binding<Color>
    ) -> some View {
        HStack(spacing: 10) {
            Toggle(isOn: isOn) {
                Label(title, systemImage: systemImage)
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            ColorPicker("", selection: color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 28)
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    private func lineCount(_ text: String) -> Int {
        text.components(separatedBy: "\n").count
    }

    private func renumberActiveDirections() {
        guard let path = store.activeSongPath,
              let idx = store.librettoFiles.firstIndex(where: { $0.relativePath == path }) else { return }

        let sceneIndex = store.librettoFiles.prefix(idx).count + 1
        let updated = DirectionParser.renumberDirections(
            in: store.librettoFiles[idx].content,
            act: 1,
            scene: sceneIndex,
            subsection: 0
        )
        store.updateLyricsForSong(atPath: path, lyrics: updated)
    }

    // MARK: - Apple Notes Export

    private func exportToAppleNotes() {
        notesExportInProgress = true
        let scenes = store.songAssets.map { asset in
            let lyrics = asset.document.activeVersion()?.lyrics ?? ""
            return AppleNotesService.SceneNote(
                title: asset.displayName,
                body: lyrics
            )
        }

        Task {
            defer { notesExportInProgress = false }
            do {
                let count = try await AppleNotesService.exportScenes(scenes)
                notesAlertMessage = "Exported \(count) scene\(count == 1 ? "" : "s") to Apple Notes."
                showNotesAlert = true
            } catch {
                notesAlertMessage = "Export failed: \(error.localizedDescription)"
                showNotesAlert = true
            }
        }
    }

    // MARK: - Apple Notes Import

    private func importFromAppleNotes() {
        notesImportInProgress = true

        Task {
            defer { notesImportInProgress = false }
            do {
                let notes = try await AppleNotesService.importNotes()
                guard !notes.isEmpty else {
                    notesAlertMessage = "No notes found in the \"\(AppleNotesService.folderName)\" folder."
                    showNotesAlert = true
                    return
                }

                // Match each note to a scene by title
                let matches = matchNotesToScenes(notes)
                let matchedCount = matches.filter { $0.matchedAssetPath != nil }.count

                guard matchedCount > 0 else {
                    notesAlertMessage = "Found \(notes.count) note\(notes.count == 1 ? "" : "s") but none matched existing scenes by title."
                    showNotesAlert = true
                    return
                }

                pendingImportNotes = notes
                importMatchResults = matches
                showImportConfirmation = true
            } catch {
                notesAlertMessage = "Import failed: \(error.localizedDescription)"
                showNotesAlert = true
            }
        }
    }

    private func matchNotesToScenes(_ notes: [AppleNotesService.SceneNote]) -> [ImportMatchResult] {
        notes.map { note in
            // Try exact title match first
            if let asset = store.songAssets.first(where: { $0.displayName == note.title }) {
                let currentLyrics = asset.document.activeVersion()?.lyrics ?? ""
                let changed = currentLyrics != note.body
                return ImportMatchResult(
                    noteTitle: note.title,
                    matchedAssetPath: asset.relativePath,
                    matchedDisplayName: asset.displayName,
                    hasChanges: changed
                )
            }

            // Try case-insensitive match
            if let asset = store.songAssets.first(where: {
                $0.displayName.lowercased() == note.title.lowercased()
            }) {
                let currentLyrics = asset.document.activeVersion()?.lyrics ?? ""
                let changed = currentLyrics != note.body
                return ImportMatchResult(
                    noteTitle: note.title,
                    matchedAssetPath: asset.relativePath,
                    matchedDisplayName: asset.displayName,
                    hasChanges: changed
                )
            }

            return ImportMatchResult(
                noteTitle: note.title,
                matchedAssetPath: nil,
                matchedDisplayName: nil,
                hasChanges: false
            )
        }
    }

    private func applyImportedNotes() {
        var updatedCount = 0
        for (index, match) in importMatchResults.enumerated() {
            guard let path = match.matchedAssetPath, match.hasChanges else { continue }
            guard index < pendingImportNotes.count else { continue }
            let newLyrics = pendingImportNotes[index].body
            store.updateLyricsForSong(atPath: path, lyrics: newLyrics)
            updatedCount += 1
        }

        pendingImportNotes = []
        importMatchResults = []
        notesAlertMessage = "Updated \(updatedCount) scene\(updatedCount == 1 ? "" : "s") from Apple Notes."
        showNotesAlert = true
    }
}

// MARK: - Import Match Result

struct ImportMatchResult: Identifiable {
    let id = UUID()
    let noteTitle: String
    let matchedAssetPath: String?
    let matchedDisplayName: String?
    let hasChanges: Bool
}

// MARK: - Import Confirmation Sheet

@available(macOS 26.0, *)
private struct AppleNotesImportConfirmationView: View {
    let matchResults: [ImportMatchResult]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var matchedWithChanges: [ImportMatchResult] {
        matchResults.filter { $0.matchedAssetPath != nil && $0.hasChanges }
    }

    private var matchedNoChanges: [ImportMatchResult] {
        matchResults.filter { $0.matchedAssetPath != nil && !$0.hasChanges }
    }

    private var unmatched: [ImportMatchResult] {
        matchResults.filter { $0.matchedAssetPath == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import from Apple Notes")
                .font(.headline)

            Text("Found \(matchResults.count) note\(matchResults.count == 1 ? "" : "s") in the \"Amira\" folder.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if !matchedWithChanges.isEmpty {
                        sectionHeader(
                            "Will Update (\(matchedWithChanges.count))",
                            systemImage: "arrow.triangle.2.circlepath",
                            color: .orange
                        )
                        ForEach(matchedWithChanges) { result in
                            matchRow(result)
                        }
                    }

                    if !matchedNoChanges.isEmpty {
                        sectionHeader(
                            "No Changes (\(matchedNoChanges.count))",
                            systemImage: "checkmark.circle",
                            color: .green
                        )
                        ForEach(matchedNoChanges) { result in
                            matchRow(result)
                        }
                    }

                    if !unmatched.isEmpty {
                        sectionHeader(
                            "Unmatched (\(unmatched.count))",
                            systemImage: "questionmark.circle",
                            color: .secondary
                        )
                        ForEach(unmatched) { result in
                            HStack(spacing: 6) {
                                Image(systemName: "xmark.circle")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                                Text(result.noteTitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 300)

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Apply \(matchedWithChanges.count) Update\(matchedWithChanges.count == 1 ? "" : "s")") {
                    onConfirm()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(matchedWithChanges.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 420, maxWidth: 420, minHeight: 200)
    }

    private func sectionHeader(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
    }

    private func matchRow(_ result: ImportMatchResult) -> some View {
        HStack(spacing: 6) {
            Image(systemName: result.hasChanges ? "pencil.circle.fill" : "checkmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(result.hasChanges ? .orange : .green)
            Text(result.noteTitle)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - Notes Section

@available(macOS 26.0, *)
struct NotesSectionContent: View {
    @Bindable var store: ScriptStore

    @State private var editedNotes: String = ""
    @State private var lastLoadedPath: String?

    private var activeAsset: OWSSongAsset? {
        guard let path = store.activeSongPath else { return nil }
        return store.songAssets.first(where: { $0.relativePath == path })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let asset = activeAsset, let path = store.activeSongPath {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(asset.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }

                TextEditor(text: $editedNotes)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.black.opacity(0.20))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .onChange(of: editedNotes) { _, newValue in
                        store.updateSongNotes(forPath: path, notes: newValue)
                    }
                    .onChange(of: store.activeSongPath) { _, newPath in
                        loadNotes(for: newPath)
                    }
                    .onAppear {
                        loadNotes(for: path)
                    }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("Scroll to see notes\nfor each scene")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
    }

    private func loadNotes(for path: String?) {
        guard let path, path != lastLoadedPath else { return }
        lastLoadedPath = path
        editedNotes = store.songNotes(forPath: path)
    }
}

// MARK: - Version History Section

@available(macOS 26.0, *)
struct VersionHistorySectionContent: View {
    @Bindable var store: ScriptStore

    private var activeAsset: OWSSongAsset? {
        guard let path = store.activeSongPath else { return nil }
        return store.songAssets.first(where: { $0.relativePath == path })
    }

    private var sortedVersions: [OWSVersionPayload] {
        let activeVersionID = activeAsset?.document.activeVersionID
        return (activeAsset?.document.versions ?? [])
            .filter { $0.saveType != .autosave || $0.id == activeVersionID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var sortedProjectHistory: [ProjectHistoryEntry] {
        store.projectHistoryEntries
            .filter { $0.kind != .autosave }
            .sorted { $0.recordedAt > $1.recordedAt }
    }

    private var sortedGitHistory: [GitCommitEntry] {
        store.gitHistoryEntries.sorted { $0.committedAt > $1.committedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InspectorTabLead(
                    title: "Version History",
                    systemImage: InspectorSectionID.versionHistory.systemImage,
                    subtitle: "Local scene revisions, project changes, and git commits for the current scene."
                )

                sceneVersionsSection

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Recent Changes", systemImage: "waveform.path.ecg")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if sortedProjectHistory.isEmpty {
                        Text("Revisions, synced AI edits, and external reloads will appear here.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(sortedProjectHistory) { entry in
                                ProjectHistoryRowView(entry: entry)
                            }
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Label("Git Commits", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    if sortedGitHistory.isEmpty {
                        Text("No git commits found for this project or its enclosing repo.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(sortedGitHistory) { commit in
                                GitCommitRowView(commit: commit)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var sceneVersionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Scene Versions", systemImage: "clock.arrow.counterclockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if let asset = activeAsset, let path = store.activeSongPath {
                HStack(spacing: 6) {
                    Text(asset.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        store.createManualVersion(forPath: path)
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Create manual save point")
                }

                if store.previewingVersionID != nil && store.previewingSongPath == path {
                    HStack(spacing: 6) {
                        Text("Previewing version")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Restore") {
                            if let vid = store.previewingVersionID {
                                store.rollbackToVersion(id: vid, forPath: path)
                            }
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button("Cancel") {
                            store.cancelVersionPreview()
                        }
                        .font(.system(size: 10))
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.1))
                    )
                }

                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(sortedVersions) { version in
                        VersionRowView(
                            version: version,
                            isActive: version.id == asset.document.activeVersionID,
                            isPreviewing: version.id == store.previewingVersionID,
                            onPreview: {
                                store.previewVersion(id: version.id, forPath: path)
                            },
                            onRestore: {
                                store.rollbackToVersion(id: version.id, forPath: path)
                            }
                        )
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.counterclockwise")
                        .font(.system(size: 20))
                        .foregroundStyle(.tertiary)
                    Text("Scroll to see version\nhistory for each scene")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
        }
    }
}

@available(macOS 26.0, *)
private struct SunoLyricsSectionContent: View {
    @Bindable var store: ScriptStore

    private var activeAsset: OWSSongAsset? {
        guard let path = store.activeSongPath else { return nil }
        return store.songAssets.first(where: { $0.relativePath == path })
    }

    private var formattedResult: SunoLyricsFormatter.Result {
        let librettoText = store.librettoFiles.first(where: { $0.relativePath == store.activeSongPath })?.content
        return SunoLyricsFormatter.format(
            librettoText: librettoText,
            speakerGenderHints: SunoLyricsFormatter.speakerGenderHints(from: store.characters)
        )
    }

    private var hasFormattedSunoLyrics: Bool {
        !formattedResult.formattedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                InspectorTabLead(
                    title: "Suno Lyrics",
                    systemImage: InspectorSectionID.sunoLyrics.systemImage,
                    subtitle: "Current scene only. Deterministic parsing removes staging, preserves explicit tags, and auto-labels sung blocks for Suno."
                )

                if let asset = activeAsset {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(asset.displayName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                            Text("Shows only the scene currently in view.")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }

                        Spacer(minLength: 12)

                        Button {
                            copyLyricsToPasteboard(formattedResult.formattedText)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .font(.system(size: 11, weight: .medium))
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(!hasFormattedSunoLyrics)
                    }

                    if formattedResult.speakerLabels.count > 1 {
                        Text(
                            formattedResult.speakerLabels
                                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                                .map { "\($0.key) -> \($0.value)" }
                                .joined(separator: "  |  ")
                        )
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    }

                    if hasFormattedSunoLyrics {
                        TextEditor(text: .constant(formattedResult.formattedText))
                            .font(.system(size: 11, design: .monospaced))
                            .frame(minHeight: 320)
                            .textSelection(.enabled)
                            .scrollContentBackground(.hidden)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.white.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                            )
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "music.note")
                                .font(.system(size: 20))
                                .foregroundStyle(.tertiary)
                            Text("No sung lines were detected\nin this scene yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "music.note")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text("Scroll to a scene to see\nSuno-ready lyrics")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                }
            }
            .padding(12)
        }
        .scrollIndicators(.never)
    }

    private func copyLyricsToPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

@available(macOS 26.0, *)
private struct InspectorTabLead: View {
    let title: String
    let systemImage: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

@available(macOS 26.0, *)
private struct ProjectHistoryRowView: View {
    let entry: ProjectHistoryEntry

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(badgeColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.primary)

                Text(entry.message)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)

                Text(Self.dateFormatter.string(from: entry.recordedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }

    private var badgeColor: Color {
        switch entry.kind {
        case .autosave:
            return .gray
        case .manualSave:
            return .blue
        case .externalReload:
            return .orange
        case .openedWithExternalChanges:
            return .yellow
        case .agentSync:
            return .green
        }
    }
}

@available(macOS 26.0, *)
private struct GitCommitRowView: View {
    let commit: GitCommitEntry

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(commit.shortHash)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.06))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(commit.subject)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                Text(Self.dateFormatter.string(from: commit.committedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Version Row

@available(macOS 26.0, *)
private struct VersionRowView: View {
    let version: OWSVersionPayload
    let isActive: Bool
    let isPreviewing: Bool
    let onPreview: () -> Void
    let onRestore: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(version.displayName)
                    .font(.system(size: 10, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)

                Text(Self.dateFormatter.string(from: version.updatedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if isActive {
                Text("Active")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.green.opacity(0.8))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isPreviewing ? Color.orange.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onPreview()
        }
        .contextMenu {
            if !isActive {
                Button("Restore This Version") { onRestore() }
            }
        }
    }

    private var badgeColor: Color {
        switch version.saveType {
        case .manual: return .blue
        case .autosave: return .gray
        case .snapshot: return .purple
        case .imported: return .orange
        }
    }
}
