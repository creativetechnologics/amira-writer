import SwiftUI
import UniformTypeIdentifiers

/// Grid view of recorded and imported motion clips.
/// Displayed in the Motion dock tab alongside Characters, Places, etc.
@available(macOS 26.0, *)
struct MotionClipLibraryView: View {
    @Environment(AnimateStore.self) private var store

    @State private var searchText = ""
    @State private var showImportPanel = false
    @State private var clipToDelete: MotionClip?
    @State private var renamingClipID: UUID?
    @State private var renameText = ""

    private var filteredClips: [MotionClip] {
        if searchText.isEmpty {
            return store.motionClips
        }
        let query = searchText.lowercased()
        return store.motionClips.filter {
            $0.name.lowercased().contains(query) ||
            $0.tags.contains(where: { $0.lowercased().contains(query) })
        }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text("Motion Clips")
                    .font(.headline)

                Spacer()

                Text("\(store.motionClips.count) clips")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    showImportPanel = true
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import BVH file")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search
            TextField("Search clips...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            Divider()

            // Grid
            if filteredClips.isEmpty {
                ContentUnavailableView {
                    Label("No Motion Clips", systemImage: "figure.walk")
                } description: {
                    Text("Record a motion capture session or import a BVH file to get started.")
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredClips) { clip in
                            MotionClipCard(
                                clip: clip,
                                isSelected: store.selectedMotionClipID == clip.id,
                                isRenaming: renamingClipID == clip.id,
                                renameText: $renameText,
                                onSelect: {
                                    store.selectedMotionClipID = clip.id
                                },
                                onRename: {
                                    renamingClipID = clip.id
                                    renameText = clip.name
                                },
                                onCommitRename: {
                                    store.renameMotionClip(id: clip.id, newName: renameText)
                                    renamingClipID = nil
                                },
                                onDelete: {
                                    clipToDelete = clip
                                }
                            )
                        }
                    }
                    .padding(12)
                }
            }
        }
        .fileImporter(
            isPresented: $showImportPanel,
            allowedContentTypes: [UTType(filenameExtension: "bvh")].compactMap { $0 },
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                for url in urls {
                    guard url.startAccessingSecurityScopedResource() else { continue }
                    defer { url.stopAccessingSecurityScopedResource() }
                    do {
                        try store.importBVHFile(url: url)
                    } catch {
                        print("[MotionClipLibrary] Failed to import \(url.lastPathComponent): \(error)")
                    }
                }
            case .failure(let error):
                print("[MotionClipLibrary] Import failed: \(error)")
            }
        }
        .alert("Delete Clip?", isPresented: .init(
            get: { clipToDelete != nil },
            set: { if !$0 { clipToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let clip = clipToDelete {
                    store.deleteMotionClip(id: clip.id)
                }
                clipToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                clipToDelete = nil
            }
        } message: {
            if let clip = clipToDelete {
                Text("Are you sure you want to delete \"\(clip.name)\"? This cannot be undone.")
            }
        }
    }
}

// MARK: - MotionClipCard

@available(macOS 26.0, *)
private struct MotionClipCard: View {
    let clip: MotionClip
    let isSelected: Bool
    let isRenaming: Bool
    @Binding var renameText: String
    let onSelect: () -> Void
    let onRename: () -> Void
    let onCommitRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Icon based on source
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
                    .frame(height: 80)

                Image(systemName: sourceIcon)
                    .font(.largeTitle)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }

            // Name
            if isRenaming {
                TextField("Name", text: $renameText, onCommit: onCommitRename)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            } else {
                Text(clip.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Metadata
            HStack(spacing: 4) {
                Text(durationString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(clip.fps) fps")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Tags
            if !clip.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(clip.tags.prefix(3), id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.background)
                .shadow(color: .black.opacity(isSelected ? 0.15 : 0.05), radius: isSelected ? 4 : 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2)
        )
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Rename") { onRename() }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private var sourceIcon: String {
        switch clip.source {
        case .webcamCapture: return "web.camera"
        case .videoFileCapture: return "film"
        case .hunyuanMotion: return "sparkles"
        case .importedBVH: return "doc.text"
        case .importedFBX: return "cube"
        case .audioLipSync: return "waveform.and.mic"
        case .manual: return "hand.draw"
        }
    }

    private var durationString: String {
        let seconds = Int(clip.duration)
        let minutes = seconds / 60
        let remainingSeconds = seconds % 60
        if minutes > 0 {
            return "\(minutes)m \(remainingSeconds)s"
        }
        return "\(remainingSeconds)s"
    }
}
