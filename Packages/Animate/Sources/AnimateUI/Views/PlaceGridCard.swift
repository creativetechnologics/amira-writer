import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct PlaceGridCard: View {
    let store: AnimateStore
    let place: BackgroundPlate
    let workflowMode: PlaceWorkflowMode
    let isSelected: Bool
    let sceneUsageCount: Int
    let requiredShots: Set<String>
    let showsThumbnail: Bool
    let onSelect: () -> Void

    private var coveredCount: Int {
        let covered = place.coveredCameraShots
        return requiredShots.filter { covered.contains($0) }.count
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    thumbnailView
                        .frame(height: 130)
                        .frame(maxWidth: .infinity)
                        .clipped()

                    VStack(alignment: .trailing, spacing: 4) {
                        if !place.locationCategory.isEmpty {
                            categoryBadge(place.locationCategory)
                        }
                        Text(workflowMode.shortLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(8)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(place.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)

                    HStack(spacing: 12) {
                        Label("\(place.imagePaths(for: workflowMode).count)", systemImage: workflowMode == .photorealistic ? "photo" : "paintpalette")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if sceneUsageCount > 0 {
                            Label("\(sceneUsageCount)", systemImage: "film")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !requiredShots.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: coveredCount >= requiredShots.count ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(coveredCount >= requiredShots.count ? .green : .orange)
                            Text("\(coveredCount)/\(requiredShots.count) angles")
                                .font(.caption2)
                                .foregroundStyle(coveredCount >= requiredShots.count ? .green : .orange)
                        }
                    }
                }
                .padding(10)
            }
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete Place", systemImage: "trash", role: .destructive) {
                store.deletePlace(place.id)
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if showsThumbnail,
           let path = place.approvedImagePath(for: workflowMode),
           let url = store.resolvedCharacterAssetURL(for: path) {
            AsyncResolvedImageView(path: url.path, maxPixelSize: 256, contentMode: .fill)
        } else {
            ZStack {
                Color.gray.opacity(0.1)
                VStack(spacing: 6) {
                    Image(systemName: workflowMode == .photorealistic ? "camera" : "paintpalette")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No \(workflowMode.shortLabel.lowercased()) image")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func categoryBadge(_ category: String) -> some View {
        Text(category)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
    }
}
