import SwiftUI

/// Horizontal time ruler for the NLA timeline. Shows frame/time markers
/// and the current playhead position as a vertical red line.
@available(macOS 26.0, *)
struct NLATimeRulerView: View {
    let totalFrames: Int
    let fps: Int
    let currentFrame: Int
    let pixelsPerFrame: CGFloat
    let scrollOffset: CGFloat

    var onSeek: ((_ frame: Int) -> Void)?

    private var rulerWidth: CGFloat {
        CGFloat(totalFrames) * pixelsPerFrame
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))

            // Frame markers
            Canvas { context, size in
                let visibleStartFrame = max(0, Int(-scrollOffset / pixelsPerFrame) - 1)
                let visibleEndFrame = min(totalFrames, visibleStartFrame + Int(size.width / pixelsPerFrame) + 2)

                // Determine tick spacing based on zoom level
                let majorInterval = majorTickInterval
                let minorInterval = max(1, majorInterval / 5)

                for frame in stride(from: (visibleStartFrame / minorInterval) * minorInterval,
                                     through: visibleEndFrame,
                                     by: minorInterval) {
                    let x = CGFloat(frame) * pixelsPerFrame + scrollOffset
                    guard x >= 0 && x <= size.width else { continue }

                    let isMajor = frame % majorInterval == 0
                    let tickHeight: CGFloat = isMajor ? 12 : 6

                    var path = Path()
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x, y: size.height - tickHeight))
                    context.stroke(path, with: .color(.secondary.opacity(isMajor ? 0.6 : 0.3)), lineWidth: 0.5)

                    if isMajor {
                        let label = frameLabel(frame)
                        let text = Text(label).font(.system(size: 9, design: .monospaced))
                        context.draw(text, at: CGPoint(x: x, y: 4), anchor: .top)
                    }
                }
            }
            .frame(height: 24)

            // Playhead
            let playheadX = CGFloat(currentFrame) * pixelsPerFrame + scrollOffset
            if playheadX >= 0 {
                Rectangle()
                    .fill(Color.red)
                    .frame(width: 1.5, height: 24)
                    .offset(x: playheadX)

                // Playhead triangle
                Path { path in
                    path.move(to: CGPoint(x: playheadX - 5, y: 0))
                    path.addLine(to: CGPoint(x: playheadX + 5, y: 0))
                    path.addLine(to: CGPoint(x: playheadX, y: 7))
                    path.closeSubpath()
                }
                .fill(Color.red)
            }
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .onTapGesture { location in
            let frame = Int((location.x - scrollOffset) / pixelsPerFrame)
            let clamped = max(0, min(frame, totalFrames - 1))
            onSeek?(clamped)
        }
    }

    private var majorTickInterval: Int {
        // Adaptive: at ~4px/frame show every 24 frames (1sec at 24fps),
        // at wider zoom show fewer, at narrow zoom show more.
        let approxPixelsPerMajor: CGFloat = 80
        let rawInterval = Int(approxPixelsPerMajor / max(pixelsPerFrame, 0.1))
        // Snap to nice intervals
        let niceIntervals = [1, 2, 5, 10, 24, 30, 48, 60, 120, 240, 300, 600]
        return niceIntervals.first { $0 >= rawInterval } ?? rawInterval
    }

    private func frameLabel(_ frame: Int) -> String {
        guard fps > 0 else { return "\(frame)" }
        let seconds = frame / fps
        let remainingFrames = frame % fps
        if seconds >= 60 {
            let min = seconds / 60
            let sec = seconds % 60
            return String(format: "%d:%02d:%02d", min, sec, remainingFrames)
        }
        return String(format: "%d:%02d", seconds, remainingFrames)
    }
}
