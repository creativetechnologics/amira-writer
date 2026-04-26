import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct SidebarView: View {
    @Bindable var store: AnimateStore
    @AppStorage("animate.sidebar.expandedSceneIDs") private var expandedIDsCSV: String = ""

    var body: some View {
        OperaChromeSidebarList {
            if store.scenes.isEmpty {
                OperaChromeSidebarRow {
                    Text("No scenes are available for the current project.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            } else {
                ForEach(store.scenes) { scene in
                    sceneEntry(scene)
                }
            }
        }
    }

    @ViewBuilder
    private func sceneEntry(_ scene: AnimationScene) -> some View {
        let expanded = isExpanded(scene.id)
        SceneSidebarRow(
            scene: scene,
            isSelected: store.selectedSceneID == scene.id && store.selectedShotID == nil,
            isExternallyUpdated: store.externalChangeTimes[scene.owpSongPath] != nil,
            isExpanded: expanded,
            onToggleExpand: { toggleExpansion(scene.id) },
            onSelect: {
                store.selectedSceneID = scene.id
                store.selectedShotID = nil
            }
        )

        if expanded {
            ForEach(Array(scene.shots.enumerated()), id: \.element.id) { _, shot in
                ShotSidebarRow(
                    sceneID: scene.id,
                    shot: shot,
                    isSelected: store.selectedShotID == shot.id,
                    projectRoot: store.fileOWPURL,
                    onSelect: {
                        store.selectedSceneID = scene.id
                        store.selectedShotID = shot.id
                    }
                )
            }
        }
    }

    // MARK: - Expansion persistence

    private func isExpanded(_ id: UUID) -> Bool {
        expandedSet.contains(id)
    }

    private func toggleExpansion(_ id: UUID) {
        var set = expandedSet
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        expandedIDsCSV = set.map(\.uuidString).joined(separator: ",")
    }

    private var expandedSet: Set<UUID> {
        Set(expandedIDsCSV
            .split(separator: ",")
            .compactMap { UUID(uuidString: String($0)) })
    }
}

// MARK: - Scene row (with chevron)

@available(macOS 26.0, *)
private struct SceneSidebarRow: View {
    let scene: AnimationScene
    let isSelected: Bool
    let isExternallyUpdated: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onSelect: () -> Void

    var body: some View {
        OperaChromeSidebarRow(
            isSelected: isSelected,
            isExternallyUpdated: isExternallyUpdated
        ) {
            HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
                Button(action: onToggleExpand) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.15), value: isExpanded)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Text(scene.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onSelect)
            }
        }
    }
}

// MARK: - Shot row (indented, with begin/middle/end indicators)

@available(macOS 26.0, *)
private struct ShotSidebarRow: View {
    let sceneID: UUID
    let shot: AnimationSceneShot
    let isSelected: Bool
    let projectRoot: URL?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            OperaChromeSidebarRow(isSelected: isSelected) {
                HStack(spacing: 6) {
                    // Indent under the chevron
                    Spacer().frame(width: 14)

                    Text(shot.name.isEmpty ? "Shot" : shot.name)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isSelected
                            ? OperaChromeTheme.textPrimary
                            : OperaChromeTheme.textSecondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    StoryboardFrameDots(
                        projectRoot: projectRoot,
                        sceneID: sceneID,
                        shotID: shot.id
                    )
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Begin/middle/end fill dots (mirrors iPad shot list)

@available(macOS 26.0, *)
private struct StoryboardFrameDots: View {
    let projectRoot: URL?
    let sceneID: UUID
    let shotID: UUID

    var body: some View {
        HStack(spacing: 2) {
            ForEach(StoryboardFrame.allCases, id: \.self) { frame in
                Circle()
                    .fill(filled(frame) ? OperaChromeTheme.accent : Color.clear)
                    .overlay(
                        Circle()
                            .stroke(filled(frame)
                                ? Color.clear
                                : OperaChromeTheme.textTertiary.opacity(0.6),
                                lineWidth: 1)
                    )
                    .frame(width: 6, height: 6)
            }
        }
    }

    private func filled(_ frame: StoryboardFrame) -> Bool {
        guard let projectRoot else { return false }
        let url = ProjectPaths(root: projectRoot)
            .shotStoryboardImage(sceneID: sceneID, shotID: shotID, frame: frame)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
