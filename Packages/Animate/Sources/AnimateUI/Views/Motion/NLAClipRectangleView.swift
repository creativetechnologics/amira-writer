import SwiftUI

/// A single clip rectangle on an NLA track lane.
/// Color is determined by the track's colorTag. Shows the motion clip name inside.
@available(macOS 26.0, *)
struct NLAClipRectangleView: View {
    let clip: NLAClip
    let clipName: String
    let colorTag: NLATrackColorTag
    let pixelsPerFrame: CGFloat
    let totalTimelineFrames: Int
    let motionClipFrameCount: Int

    var onMove: ((_ clipID: UUID, _ newStartFrame: Int) -> Void)?
    var onTrimStart: ((_ clipID: UUID, _ newTrimStart: Int) -> Void)?
    var onTrimEnd: ((_ clipID: UUID, _ newTrimEnd: Int) -> Void)?

    @State private var isDragging = false
    @State private var dragOffset: CGFloat = 0

    private var clipDuration: Int {
        clip.timelineDuration(motionClipFrameCount: motionClipFrameCount)
    }

    private var clipWidth: CGFloat {
        CGFloat(clipDuration) * pixelsPerFrame
    }

    private var clipXOffset: CGFloat {
        CGFloat(clip.startFrame) * pixelsPerFrame
    }

    var body: some View {
        ZStack {
            // Clip body
            RoundedRectangle(cornerRadius: 4)
                .fill(fillColor.opacity(isDragging ? 0.7 : 0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(fillColor.opacity(0.8), lineWidth: 1)
                )

            // Blend-in/out fade indicators
            HStack(spacing: 0) {
                if clip.blendInFrames > 0 {
                    LinearGradient(
                        colors: [.clear, fillColor.opacity(0.3)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: CGFloat(clip.blendInFrames) * pixelsPerFrame)
                }
                Spacer(minLength: 0)
                if clip.blendOutFrames > 0 {
                    LinearGradient(
                        colors: [fillColor.opacity(0.3), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: CGFloat(clip.blendOutFrames) * pixelsPerFrame)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Label
            Text(clipName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 4)
        }
        .frame(width: max(clipWidth, 4), height: 32)
        .offset(x: clipXOffset + dragOffset)
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    isDragging = true
                    dragOffset = value.translation.width
                }
                .onEnded { value in
                    isDragging = false
                    let frameDelta = Int(round(value.translation.width / pixelsPerFrame))
                    let newStart = max(0, min(clip.startFrame + frameDelta, totalTimelineFrames - clipDuration))
                    dragOffset = 0
                    onMove?(clip.id, newStart)
                }
        )
        .contextMenu {
            Button("Split at Playhead") { /* implemented in parent */ }
            Button("Duplicate") { /* implemented in parent */ }
            Divider()
            Button("Delete", role: .destructive) { /* implemented in parent */ }
        }
    }

    private var fillColor: Color {
        switch colorTag {
        case .webcam:   .orange
        case .ai:       .blue
        case .imported: .green
        case .manual:   .gray
        }
    }
}
