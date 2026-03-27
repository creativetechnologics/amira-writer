import SwiftUI
import NovotroProjectKit

@available(macOS 26.0, *)
struct MixSceneSidebarView: View {
    @Bindable var store: MixStore

    var body: some View {
        OperaChromeSidebarList {
            if store.scenes.isEmpty {
                Text("No mix scenes are available yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(store.scenes) { scene in
                    let isSelected = store.selectedSceneID == scene.id
                    let sessionInfo = sceneSessionInfo(for: scene)
                    Button {
                        store.selectScene(scene.id)
                    } label: {
                        OperaChromeSidebarRow(isSelected: isSelected) {
                            HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
                                Image(systemName: sessionInfo.hasContent ? "waveform" : "waveform.badge.plus")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(scene.displayTitle)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(OperaChromeTheme.textPrimary)
                                        .lineLimit(1)
                                    if sessionInfo.hasContent {
                                        Text(sessionInfo.summary)
                                            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private struct SceneSessionInfo {
        let hasContent: Bool
        let summary: String
    }

    private func sceneSessionInfo(for scene: MixSceneSummary) -> SceneSessionInfo {
        guard let session = store.sessionForScene(scene) else {
            return SceneSessionInfo(hasContent: false, summary: "")
        }
        let trackCount = session.tracks.count
        let clipCount = session.clips.count
        if trackCount == 0 && clipCount == 0 {
            return SceneSessionInfo(hasContent: false, summary: "")
        }
        return SceneSessionInfo(
            hasContent: true,
            summary: "\(trackCount)T \u{00B7} \(clipCount)C"
        )
    }
}
