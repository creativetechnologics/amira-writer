import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct TimelinePageView: View {
    @Bindable var store: AnimateStore

    private var shotSegmentationService: AnimateShotSegmentationService {
        AnimateShotSegmentationService(store: store, previewPlan: nil)
    }

    var body: some View {
        VStack(spacing: 0) {
            timelineHeader

            Divider()

            continuousSceneTimeline

            Divider()

            selectedSceneShotStrip

            Divider()

            TransportBar(store: store)

            Divider()

            TimelineRepresentable(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var timelineHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Production Timeline")
                    .font(.headline)
                Text("Continuous scene strip across the show, with shot segmentation for the selected scene.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
                Text("\(sceneSegments.count) scenes")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(OperaChromeTheme.headerBackground.opacity(0.55))
    }

    private var continuousSceneTimeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("All scenes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(totalEstimatedFrames) frames total")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(sceneSegments) { segment in
                        Button {
                            store.selectedSceneID = segment.id
                            store.currentFrame = 0
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(segment.name)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(segment.frameLabel)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Text("\(segment.characterCount) cast · \(segment.shotCount) shots")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .frame(width: max(170, CGFloat(segment.estimatedFrames) * 1.3), alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(segment.isSelected ? Color.accentColor.opacity(0.18) : OperaChromeTheme.raisedBackground.opacity(0.72))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(segment.isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var selectedSceneShotStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Selected scene shots")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selectedSceneShots.count) shots")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if selectedSceneShots.isEmpty {
                Text("No shot segments detected yet for this scene. Add shot cues, beat labels, or shot preset applications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(selectedSceneShots) { shot in
                            shotSegmentButton(shot)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func shotSegmentButton(_ shot: AnimateShotSegment) -> some View {
        Button {
            store.currentFrame = shot.startFrame
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(shot.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(shot.provenance.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(shot.containsCurrentFrame ? Color.accentColor : .secondary)
                Text(shot.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(shot.frameRangeLabel)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(10)
            .frame(width: max(160, CGFloat(shot.durationFrames) * 1.8), alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(shot.containsCurrentFrame ? Color.accentColor.opacity(0.18) : OperaChromeTheme.raisedBackground.opacity(0.72))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(shot.containsCurrentFrame ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var sceneSegments: [AnimateProjectSceneSegment] {
        shotSegmentationService.projectSceneSegments()
    }

    private var selectedSceneShots: [AnimateShotSegment] {
        guard let scene = store.selectedScene else { return [] }
        return shotSegmentationService.shotSegments(for: scene)
    }

    private var totalEstimatedFrames: Int {
        sceneSegments.reduce(0) { $0 + $1.estimatedFrames }
    }

}
