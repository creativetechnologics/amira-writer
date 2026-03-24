import SwiftUI
import NovotroProjectKit
import Foundation

// MARK: - Inspector Section ID

enum InspectorSectionID: String, CaseIterable, Identifiable, Sendable {
    case tools
    case notes
    case versionHistory
    case synopsis

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tools: return "Tools"
        case .notes: return "Notes"
        case .versionHistory: return "Version History"
        case .synopsis: return "Synopsis"
        }
    }

    var systemImage: String {
        switch self {
        case .tools: return "wrench.and.screwdriver"
        case .notes: return "note.text"
        case .versionHistory: return "clock.arrow.counterclockwise"
        case .synopsis: return "doc.plaintext"
        }
    }
}

// MARK: - Inspector View

@available(macOS 26.0, *)
struct ScriptInspectorView: View {
    @Bindable var store: ScriptStore
    @AppStorage("novotro.write.inspector.activeTab") private var activeTab: String = InspectorSectionID.synopsis.rawValue
    @Environment(\.scenePhase) private var scenePhase

    private let tabOrder: [InspectorSectionID] = [.synopsis, .tools, .notes, .versionHistory]

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
        case .synopsis:
            SynopsisSectionView(store: store)
        }
    }
}

// MARK: - Tools Section

@available(macOS 26.0, *)
struct ToolsSectionContent: View {
    @Bindable var store: ScriptStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Direction toggle
            Toggle(isOn: $store.showDirections) {
                Label("Show Directions", systemImage: "camera.metering.spot")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Toggle(isOn: $store.showStoryboarding) {
                Label("Show Storyboarding", systemImage: "film")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            Toggle(isOn: $store.showAnimateDirections) {
                Label("Show Animate", systemImage: "video")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

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
        (activeAsset?.document.versions ?? [])
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var sortedProjectHistory: [ProjectHistoryEntry] {
        store.projectHistoryEntries.sorted { $0.recordedAt > $1.recordedAt }
    }

    private var sortedGitHistory: [GitCommitEntry] {
        store.gitHistoryEntries.sorted { $0.committedAt > $1.committedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
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
