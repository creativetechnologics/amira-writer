import SwiftUI
import ProjectKit

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
                                Text(scene.displayTitle)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(OperaChromeTheme.textPrimary)
                                    .lineLimit(1)
                                Spacer()
                                if let dur = sessionInfo.durationSeconds {
                                    Text(formatDuration(dur))
                                        .font(.caption.monospacedDigit())
                                        .fontWeight(.light)
                                        .foregroundStyle(Color.gray.opacity(0.6))
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
        let durationSeconds: Double?
    }

    private func sceneSessionInfo(for scene: MixSceneSummary) -> SceneSessionInfo {
        guard let session = store.sessionForScene(scene) else {
            return SceneSessionInfo(hasContent: false, summary: "", durationSeconds: nil)
        }
        let trackCount = session.tracks.count
        let clipCount = session.clips.count
        let duration = session.clips
            .map { $0.startSeconds + $0.durationSeconds }
            .max()
        if trackCount == 0 && clipCount == 0 {
            return SceneSessionInfo(hasContent: false, summary: "", durationSeconds: nil)
        }
        return SceneSessionInfo(
            hasContent: true,
            summary: "\(trackCount)T \u{00B7} \(clipCount)C",
            durationSeconds: duration
        )
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}
