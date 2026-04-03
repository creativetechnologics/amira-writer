import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct SidebarView: View {
    @Bindable var store: AnimateStore

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
                    Button {
                        store.selectedSceneID = scene.id
                    } label: {
                        OperaChromeSidebarRow(
                            isSelected: store.selectedSceneID == scene.id,
                            isExternallyUpdated: store.externalChangeTimes[scene.owpSongPath] != nil
                        ) {
                            HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
                                Image(systemName: "sparkles.tv")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                                Text(scene.name)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(OperaChromeTheme.textPrimary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
