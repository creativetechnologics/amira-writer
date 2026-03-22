import SwiftUI

@available(macOS 26.0, iOS 26.0, *)
struct VersionHistoryView: View {
    @Bindable var store: ScoreStore

    @State private var editingVersionID: UUID?
    @State private var editLabel: String = ""
    @State private var confirmDeleteID: UUID?

    private var songPath: String? {
        store.selectedMidiAsset?.relativePath
    }

    private var versions: [OWSVersionPayload] {
        guard let path = songPath else { return [] }
        return store.versionHistory(for: path)
    }

    private var activeVersionID: UUID? {
        guard let path = songPath,
              let asset = store.songAssets.first(where: { $0.relativePath == path }) else { return nil }
        return asset.document.activeVersionID
    }

    // Bookmarked versions first, then the rest sorted by date
    private var sortedVersions: [OWSVersionPayload] {
        let bookmarked = versions.filter(\.isBookmarked).sorted { $0.updatedAt > $1.updatedAt }
        let rest = versions.filter { !$0.isBookmarked }.sorted { $0.updatedAt > $1.updatedAt }
        return bookmarked + rest
    }

    var body: some View {
        VStack(spacing: 0) {
            if store.selectedMidiID == nil {
                emptyState("No song selected", icon: "music.note")
            } else if versions.isEmpty {
                emptyState("No versions yet", icon: "clock.arrow.circlepath")
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(sortedVersions) { version in
                            versionRow(version)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
            }

            // Snapshot button at bottom
            if store.selectedMidiID != nil {
                Divider().padding(.horizontal, 8)
                HStack {
                    Button {
                        if let midiID = store.selectedMidiID {
                            store.snapshotSongVersion(for: midiID)
                        }
                    } label: {
                        Label("Snapshot Now", systemImage: "camera")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)

                    Spacer()

                    Text("\(versions.count) versions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func versionRow(_ version: OWSVersionPayload) -> some View {
        let isActive = version.id == activeVersionID

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                // Save type badge
                saveTypeBadge(version.saveType)

                // Label (editable or static)
                if editingVersionID == version.id {
                    TextField("Label", text: $editLabel, onCommit: {
                        if let path = songPath {
                            store.renameVersion(songPath: path, versionID: version.id, newLabel: editLabel)
                        }
                        editingVersionID = nil
                    })
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.caption)
                } else {
                    Text(version.displayName)
                        .font(.caption.weight(isActive ? .semibold : .regular))
                        .foregroundStyle(isActive ? .primary : .secondary)
                        .lineLimit(1)
                }

                Spacer()

                if version.isBookmarked {
                    Image(systemName: "bookmark.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                }
            }

            // Timestamp
            Text(version.updatedAt, style: .relative)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            // Note count info
            if let playback = version.playback {
                Text("\(playback.notes.count) notes")
                    .font(.system(size: 10))
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.blue.opacity(0.1) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isActive ? Color.blue.opacity(0.2) : Color.clear, lineWidth: 1)
        )
        .contextMenu {
            Button("Restore This Version") {
                if let path = songPath {
                    store.rollbackToVersion(songPath: path, versionID: version.id)
                }
            }
            .disabled(isActive)

            Button("Rename...") {
                editLabel = version.userLabel ?? version.label
                editingVersionID = version.id
            }

            Button(version.isBookmarked ? "Remove Bookmark" : "Bookmark") {
                if let path = songPath {
                    store.toggleVersionBookmark(songPath: path, versionID: version.id)
                }
            }

            Divider()

            Button("Delete", role: .destructive) {
                if let path = songPath {
                    store.deleteVersion(songPath: path, versionID: version.id)
                }
            }
            .disabled(versions.count <= 1)
        }
        .onTapGesture(count: 2) {
            // Double-click to restore
            if !isActive, let path = songPath {
                store.rollbackToVersion(songPath: path, versionID: version.id)
            }
        }
    }

    @ViewBuilder
    private func saveTypeBadge(_ type: VersionSaveType) -> some View {
        let (text, color): (String, Color) = {
            switch type {
            case .manual: return ("M", .blue)
            case .autosave: return ("A", .gray)
            case .snapshot: return ("S", .purple)
            case .imported: return ("I", .green)
            }
        }()

        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: 14, height: 14)
            .background(
                Circle()
                    .fill(color.opacity(0.15))
            )
    }

    @ViewBuilder
    private func emptyState(_ message: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
