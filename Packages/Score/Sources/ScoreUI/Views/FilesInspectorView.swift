import ProjectKit
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Inspector panel showing all files associated with the current project/song.
/// Files can be dragged onto the timeline (audio files) or revealed in Finder.
@available(macOS 26.0, iOS 26.0, *)
struct FilesInspectorView: View {
    @Bindable var store: ScoreStore

    @State private var expandedSections: Set<FileSection> = [.audioClips, .soundFonts]
    @State private var cachedFilesBySection: [FileSection: [ProjectFile]] = [:]

    enum FileSection: String, CaseIterable, Identifiable, Sendable {
        case songFiles = "Song Files"
        case soundFonts = "SoundFonts"
        case audioClips = "Audio Clips"
        case exports = "Exports"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .songFiles: return "doc.text"
            case .soundFonts: return "waveform"
            case .audioClips: return "waveform.circle"
            case .exports: return "square.and.arrow.up"
            }
        }
    }

    private struct FileDiscoveryContext: Hashable, Sendable {
        struct SongAssetSnapshot: Hashable, Sendable {
            let id: UUID
            let relativePath: String
        }

        struct SoundFontMappingSnapshot: Hashable, Sendable {
            let key: String
            let displayName: String
            let sf2Path: String?
        }

        struct AudioClipSnapshot: Hashable, Sendable {
            let id: UUID
            let displayName: String
            let filePath: String
            let startTick: Int
            let durationTicks: Int
        }

        let projectPath: String?
        let selectedSongID: UUID?
        let selectedSongRelativePath: String?
        let songAssets: [SongAssetSnapshot]
        let soundFontMappings: [SoundFontMappingSnapshot]
        let audioClips: [AudioClipSnapshot]
        let fullMixExportStatus: String
    }

    private enum FileTone: Sendable {
        case blue
        case secondary
        case purple
        case orange
        case red
        case cyan
        case green

        var color: Color {
            switch self {
            case .blue: return .blue
            case .secondary: return .secondary
            case .purple: return .purple
            case .orange: return .orange
            case .red: return .red
            case .cyan: return .cyan
            case .green: return .green
            }
        }
    }

    private struct DiscoveredFile: Hashable, Sendable {
        let name: String
        let path: String
        let icon: String
        let tone: FileTone
        let detail: String?
        let isDraggable: Bool
        let isRemovable: Bool
        let fileSize: Int64?
        let clipID: UUID?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Project path
            if let url = store.projectURL {
                HStack(spacing: 4) {
                    Image(systemName: "folder.badge.gearshape")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text(url.lastPathComponent)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    #if canImport(AppKit)
                    Button {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                    #endif
                }
                .padding(.horizontal, 6)
            } else {
                Label("No project open", systemImage: "questionmark.folder")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
            }

            Divider().padding(.horizontal, 4)

            // File sections
            ForEach(FileSection.allCases) { section in
                fileSectionView(section)
            }

            Spacer(minLength: 0)

            // Add audio button
            Divider().padding(.horizontal, 4)
            Button {
                importAudioFile()
            } label: {
                Label("Import Audio File...", systemImage: "plus.circle")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 4)
        .task(id: discoveryContext) {
            await refreshFileCache(for: discoveryContext)
        }
    }

    // MARK: - Section Views

    @ViewBuilder
    private func fileSectionView(_ section: FileSection) -> some View {
        let isExpanded = expandedSections.contains(section)
        let files = filesForSection(section)

        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded {
                        expandedSections.remove(section)
                    } else {
                        expandedSections.insert(section)
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Image(systemName: section.systemImage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(section.rawValue)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("\(files.count)")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                if files.isEmpty {
                    Text(emptyMessage(for: section))
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 3)
                } else {
                    VStack(spacing: 1) {
                        ForEach(files) { file in
                            fileRow(file)
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 4)
                }
            }
        }
    }

    @ViewBuilder
    private func fileRow(_ file: ProjectFile) -> some View {
        HStack(spacing: 5) {
            Image(systemName: file.icon)
                .font(.system(size: 9))
                .foregroundStyle(file.iconColor)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 0) {
                Text(file.name)
                    .font(.system(size: 10))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = file.detail {
                    Text(detail)
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let size = file.formattedSize {
                Text(size)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.quaternary)
            }

            // Context menu button
            Menu {
                #if canImport(AppKit)
                if FileManager.default.fileExists(atPath: file.path) {
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: "")
                    }
                }
                #endif
                if file.isDraggable {
                    Button("Add to Timeline") {
                        addToTimeline(file)
                    }
                }
                if file.isRemovable {
                    Divider()
                    Button("Remove", role: .destructive) {
                        removeFile(file)
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .frame(width: 16)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.02)))
        .contentShape(Rectangle())
        .onDrag {
            guard file.isDraggable else { return NSItemProvider() }
            let url = URL(fileURLWithPath: file.path) as NSURL
            return NSItemProvider(object: url)
        }
    }

    // MARK: - File Discovery

    private func filesForSection(_ section: FileSection) -> [ProjectFile] {
        cachedFilesBySection[section] ?? []
    }

    private var discoveryContext: FileDiscoveryContext {
        let projectPath = store.projectURL?.standardizedFileURL.path
        let selectedSongID = store.selectedMidiID
        let selectedSongRelativePath = selectedSongID.flatMap { id in
            store.songAssets.first(where: { $0.id == id })?.relativePath
        }
        let songAssets = store.songAssets.map {
            FileDiscoveryContext.SongAssetSnapshot(id: $0.id, relativePath: $0.relativePath)
        }
        let soundFontMappings = store.instrumentMappings
            .sorted(by: { $0.key < $1.key })
            .map { key, mapping in
                FileDiscoveryContext.SoundFontMappingSnapshot(
                    key: key,
                    displayName: mapping.displayName,
                    sf2Path: mapping.sf2Path
                )
            }
        let audioClips = store.pianoRollAudioClips.map {
            FileDiscoveryContext.AudioClipSnapshot(
                id: $0.id,
                displayName: $0.displayName,
                filePath: $0.filePath,
                startTick: $0.startTick,
                durationTicks: $0.durationTicks
            )
        }

        return FileDiscoveryContext(
            projectPath: projectPath,
            selectedSongID: selectedSongID,
            selectedSongRelativePath: selectedSongRelativePath,
            songAssets: songAssets,
            soundFontMappings: soundFontMappings,
            audioClips: audioClips,
            fullMixExportStatus: store.fullMixExportStatus
        )
    }

    private func refreshFileCache(for context: FileDiscoveryContext) async {
        let discovered = await Task.detached(priority: .utility) {
            Self.discoverFiles(for: context)
        }.value

        await MainActor.run {
            guard self.discoveryContext == context else { return }
            self.cachedFilesBySection = Self.makeProjectFiles(from: discovered)
        }
    }

    nonisolated private static func makeProjectFiles(from discovered: [FileSection: [DiscoveredFile]]) -> [FileSection: [ProjectFile]] {
        Dictionary(uniqueKeysWithValues: discovered.map { section, files in
            let projectFiles = files.map {
                ProjectFile(
                    name: $0.name,
                    path: $0.path,
                    icon: $0.icon,
                    iconColor: $0.tone.color,
                    detail: $0.detail,
                    isDraggable: $0.isDraggable,
                    isRemovable: $0.isRemovable,
                    fileSize: $0.fileSize,
                    clipID: $0.clipID
                )
            }
            return (section, projectFiles)
        })
    }

    nonisolated private static func discoverFiles(for context: FileDiscoveryContext) -> [FileSection: [DiscoveredFile]] {
        [
            .songFiles: discoverSongFiles(for: context),
            .soundFonts: discoverSoundFonts(for: context),
            .audioClips: discoverAudioClips(for: context),
            .exports: discoverExports(for: context)
        ]
    }

    nonisolated private static func discoverSongFiles(for context: FileDiscoveryContext) -> [DiscoveredFile] {
        var files: [DiscoveredFile] = []
        let projectURL = context.projectPath.map { URL(fileURLWithPath: $0) }

        // OWS song files from the project
        for asset in context.songAssets {
            let isSelected = asset.id == context.selectedSongID
            let url: URL?
            if let projectURL {
                url = projectURL.appendingPathComponent(asset.relativePath)
            } else {
                url = nil  // standalone OWS
            }
            files.append(DiscoveredFile(
                name: asset.relativePath.components(separatedBy: "/").last ?? asset.relativePath,
                path: url?.path ?? "",
                icon: isSelected ? "doc.fill" : "doc",
                tone: isSelected ? .blue : .secondary,
                detail: isSelected ? "Active" : nil,
                isDraggable: false,
                isRemovable: false,
                fileSize: url.flatMap { Self.fileSize(at: $0) },
                clipID: nil
            ))
        }
        return files
    }

    nonisolated private static func discoverSoundFonts(for context: FileDiscoveryContext) -> [DiscoveredFile] {
        var files: [DiscoveredFile] = []
        var seen = Set<String>()
        let fileManager = FileManager.default

        // Embedded SoundFonts from OWP bundle
        if let projectPath = context.projectPath {
            let projectURL = URL(fileURLWithPath: projectPath)
            let sfDir = ProjectPaths(root: projectURL).soundFonts
            if let contents = try? fileManager.contentsOfDirectory(
                at: sfDir, includingPropertiesForKeys: [.fileSizeKey]
            ) {
                for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let ext = url.pathExtension.lowercased()
                    guard ["sf2", "sf3", "dls"].contains(ext) else { continue }
                    guard seen.insert(url.path).inserted else { continue }
                    files.append(DiscoveredFile(
                        name: url.lastPathComponent,
                        path: url.path,
                        icon: "waveform",
                        tone: .purple,
                        detail: "Embedded",
                        isDraggable: false,
                        isRemovable: false,
                        fileSize: Self.fileSize(at: url),
                        clipID: nil
                    ))
                }
            }
        }

        // Referenced SoundFonts from instrument mappings (external)
        for mapping in context.soundFontMappings {
            if let sf2Path = mapping.sf2Path, !sf2Path.isEmpty, seen.insert(sf2Path).inserted {
                let url = URL(fileURLWithPath: sf2Path)
                let exists = fileManager.fileExists(atPath: sf2Path)
                files.append(DiscoveredFile(
                    name: url.lastPathComponent,
                    path: sf2Path,
                    icon: exists ? "waveform" : "exclamationmark.triangle",
                    tone: exists ? .orange : .red,
                    detail: exists ? "External (\(mapping.displayName))" : "Missing!",
                    isDraggable: false,
                    isRemovable: false,
                    fileSize: exists ? Self.fileSize(at: url) : nil,
                    clipID: nil
                ))
            }
        }
        return files
    }

    nonisolated private static func discoverAudioClips(for context: FileDiscoveryContext) -> [DiscoveredFile] {
        context.audioClips.map { clip in
            let url = URL(fileURLWithPath: clip.filePath)
            let exists = FileManager.default.fileExists(atPath: clip.filePath)
            let tickInfo = "Tick \(clip.startTick)–\(clip.startTick + clip.durationTicks)"
            return DiscoveredFile(
                name: clip.displayName,
                path: clip.filePath,
                icon: exists ? "waveform.circle.fill" : "exclamationmark.triangle",
                tone: exists ? .cyan : .red,
                detail: exists ? tickInfo : "File missing!",
                isDraggable: true,
                isRemovable: true,
                fileSize: exists ? Self.fileSize(at: url) : nil,
                clipID: clip.id
            )
        }
    }

    nonisolated private static func discoverExports(for context: FileDiscoveryContext) -> [DiscoveredFile] {
        var files: [DiscoveredFile] = []
        let songName = context.selectedSongRelativePath.flatMap { relativePath -> String? in
            let name = relativePath.components(separatedBy: "/").last ?? ""
            return name.replacingOccurrences(of: ".ows", with: "")
        } ?? ""

        // Check Desktop export directory
        let desktopExportDir = preferredExportDirectory(projectPath: context.projectPath)

        if !songName.isEmpty {
            let songExportDir = desktopExportDir.appendingPathComponent(songName)
            if let contents = try? FileManager.default.contentsOfDirectory(
                at: songExportDir, includingPropertiesForKeys: [.fileSizeKey]
            ) {
                for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let ext = url.pathExtension.lowercased()
                    guard ["wav", "mp3", "aiff", "m4a"].contains(ext) else { continue }
                    files.append(DiscoveredFile(
                        name: url.lastPathComponent,
                        path: url.path,
                        icon: "square.and.arrow.up",
                        tone: .green,
                        detail: "Exported",
                        isDraggable: true,
                        isRemovable: false,
                        fileSize: Self.fileSize(at: url),
                        clipID: nil
                    ))
                }
            }
        }

        // Check Suno Downloads
        let sunoDir = desktopExportDir.appendingPathComponent("Suno Downloads")
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: sunoDir, includingPropertiesForKeys: [.fileSizeKey]
        ) {
            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let ext = url.pathExtension.lowercased()
                guard ["wav", "mp3"].contains(ext) else { continue }
                files.append(DiscoveredFile(
                    name: url.lastPathComponent,
                    path: url.path,
                    icon: "sparkles",
                    tone: .purple,
                    detail: "Suno render",
                    isDraggable: true,
                    isRemovable: false,
                    fileSize: Self.fileSize(at: url),
                    clipID: nil
                ))
            }
        }

        return files
    }

    nonisolated private static func preferredExportDirectory(projectPath: String?) -> URL {
        if let projectPath {
            return URL(fileURLWithPath: projectPath)
                .appendingPathComponent("Exports", isDirectory: true)
        }
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("Amira Writer", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
    }

    // MARK: - Helpers

    private func emptyMessage(for section: FileSection) -> String {
        switch section {
        case .songFiles: return "No project open"
        case .soundFonts: return "No soundfonts in project"
        case .audioClips: return "No audio clips in arrangement"
        case .exports: return "No exported files found"
        }
    }

    nonisolated private static func fileSize(at url: URL) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else { return nil }
        return size
    }

    private func addToTimeline(_ file: ProjectFile) {
        let url = URL(fileURLWithPath: file.path)
        _ = store.importAudioClipFromDrop(url: url, atTick: store.livePlayheadTick)
    }

    private func removeFile(_ file: ProjectFile) {
        if let clipID = file.clipID {
            store.removeAudioClip(id: clipID)
        }
    }

    private func importAudioFile() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = "Import Audio File"
        panel.allowedContentTypes = [.wav, .mp3, .aiff, .audio]
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            Task { @MainActor in
                for url in panel.urls {
                    _ = store.importAudioClipFromDrop(url: url, atTick: store.livePlayheadTick)
                }
            }
        }
        #endif
    }
}

// MARK: - Project File Model

@available(macOS 26.0, iOS 26.0, *)
struct ProjectFile: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let icon: String
    let iconColor: Color
    var detail: String?
    var isDraggable: Bool = false
    var isRemovable: Bool = false
    var fileSize: Int64?
    var clipID: UUID?

    var formattedSize: String? {
        guard let size = fileSize else { return nil }
        if size < 1024 { return "\(size) B" }
        if size < 1024 * 1024 { return "\(size / 1024) KB" }
        return String(format: "%.1f MB", Double(size) / (1024 * 1024))
    }
}
