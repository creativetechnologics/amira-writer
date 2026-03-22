import SwiftUI
import NovotroProjectKit

@available(macOS 26.0, *)
struct ScriptSidebarView: View {
    @Bindable var store: ScriptStore
    var showSummaries: Bool

    @State private var renamingAssetID: UUID?
    @State private var renameText: String = ""
    @State private var sortedAssets: [OWSSongAsset] = []
    @State private var summaryByPath: [String: String] = [:]

    /// Keep the expensive filename sort out of the render path.
    private var sortKey: [String] {
        store.songAssets.map { "\($0.relativePath)|\($0.displayName)" }
    }

    var body: some View {
        OperaChromeSidebarList {
            ForEach(sortedAssets, id: \.id) { asset in
                row(for: asset)
            }
        }
        .onAppear {
            refreshSortedAssets()
            refreshSummaries()
        }
        .onChange(of: sortKey) { _, _ in
            refreshSortedAssets()
        }
        .onChange(of: showSummaries) { _, _ in
            refreshSummaries()
        }
        .onChange(of: store.librettoFiles) { _, _ in
            refreshSummaries()
        }
    }

    @ViewBuilder
    private func row(for asset: OWSSongAsset) -> some View {
        let isSelected = store.activeSongPath == asset.relativePath || store.scrollTarget == asset.relativePath

        if renamingAssetID == asset.id {
            OperaChromeSidebarRow(isSelected: true) {
                TextField("Scene name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
            }
                .onSubmit { commitRename(asset: asset) }
                .onExitCommand { renamingAssetID = nil }
        } else {
            Button {
                store.scrollTarget = asset.relativePath
                store.ensureSceneHydrated(path: asset.relativePath)
            } label: {
                OperaChromeSidebarRow(
                    isSelected: isSelected,
                    isExternallyUpdated: store.externalChangeTimes[asset.relativePath] != nil
                ) {
                    VStack(alignment: .leading, spacing: showSummaries ? 3 : 0) {
                        HStack(spacing: OperaChromeSidebarMetrics.rowIconSpacing) {
                            Image(systemName: "doc.text")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                            Text(asset.displayName)
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(OperaChromeTheme.textPrimary)
                                .lineLimit(1)
                        }

                        if let summary = summaryByPath[asset.relativePath], !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 9.5))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button("Rename") {
                    renameText = asset.displayName
                    renamingAssetID = asset.id
                }
            }
            .onAppear {
                guard showSummaries else { return }
                store.ensureSceneHydrated(path: asset.relativePath)
            }
        }
    }

    private func commitRename(asset: OWSSongAsset) {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            store.renameSong(atPath: asset.relativePath, newTitle: trimmed)
        }
        renamingAssetID = nil
    }

    private func refreshSortedAssets() {
        sortedAssets = store.songAssets.sorted {
            $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    private func refreshSummaries() {
        guard showSummaries else {
            summaryByPath = [:]
            return
        }

        summaryByPath = Dictionary(
            uniqueKeysWithValues: store.librettoFiles.compactMap { file in
                guard let summary = SummaryParser.extractSummary(from: file.content),
                      !summary.isEmpty else {
                    return nil
                }
                return (file.relativePath, summary)
            }
        )
    }
}
