import SwiftUI

@available(macOS 26.0, *)
struct MixTimelineRulerView: View {
    let duration: Double
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    var playheadSeconds: Double = 0
    var onSeek: ((Double) -> Void)? = nil

    var body: some View {
        // Cap rendered duration to prevent the canvas and ForEach from generating
        // hundreds-of-thousands of draw calls / views on extremely long timelines.
        // 36000 seconds (10 hours) is a safe upper bound for any opera project.
        let clampedDuration = max(min(duration, 36_000), 0)
        let width = max(CGFloat(clampedDuration) * pixelsPerSecond, 1600)
        // Limit canvas grid steps to avoid thousands of draw calls.  At 48 px/s the
        // maximum useful step count is ~1600; the canvas skips invisible steps anyway.
        let halfSecondSteps = max(0, min(Int(ceil(clampedDuration * 2)), 200_000))

        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(MixPalette.rulerBackground)

            Rectangle()
                .fill(LinearGradient(colors: [MixPalette.rulerHighlight, .clear], startPoint: .top, endPoint: .bottom))
                .frame(height: 10)

            Canvas { context, size in
                // Skip subdivision lines when they would be less than 4px apart
                // to avoid excessive draw calls on long or zoomed-out timelines.
                let halfSecondPixels = pixelsPerSecond * 0.5
                let drawSubdivisions = halfSecondPixels >= 4
                let drawMinorGrid = pixelsPerSecond >= 8

                guard halfSecondSteps > 0 else { return }
                for step in 0...halfSecondSteps {
                    let seconds = Double(step) / 2
                    // Odd steps represent half-second marks (0.5s, 1.5s, 2.5s …)
                    let isHalfSecond = !step.isMultiple(of: 2)
                    if isHalfSecond && !drawSubdivisions { continue }
                    if !isHalfSecond && !drawMinorGrid && !Int(seconds).isMultiple(of: 5) { continue }
                    let x = CGFloat(seconds) * pixelsPerSecond
                    let color = gridColor(for: seconds)
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                        with: .color(color)
                    )
                }
            }

            // Choose a label interval (in whole seconds) that keeps the label count
            // below 200 regardless of zoom level. With 200 Text views the SwiftUI
            // layout pass stays fast; beyond that (e.g. the old 7200-label cap) the
            // initial body evaluation takes visible time on long sessions.
            // The interval is always a multiple of 5 so labels land on round numbers.
            let rawInterval = max(1.0, clampedDuration / 200.0)
            let labelInterval = max(5, Int((rawInterval / 5.0).rounded(.up)) * 5)
            // Only draw labels where they would be at least 40px apart (readable).
            let minPixelSpacing: CGFloat = 40
            let resolvedInterval: Int = {
                var iv = labelInterval
                while CGFloat(iv) * pixelsPerSecond < minPixelSpacing {
                    iv += 5
                }
                return iv
            }()
            let labelCount = min(max(Int(ceil(clampedDuration / Double(resolvedInterval))), 0), 500)
            ForEach(0...max(labelCount, 0), id: \.self) { mark in
                let seconds = Double(mark * resolvedInterval)
                Text(timeLabel(for: Int(seconds)))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.72))
                    .offset(x: CGFloat(seconds) * pixelsPerSecond + 8, y: 7)
            }

            // Playhead marker
            let phX = CGFloat(playheadSeconds) * pixelsPerSecond
            Rectangle()
                .fill(Color.red.opacity(0.92))
                .frame(width: 2, height: height)
                .offset(x: phX - 1)
                .allowsHitTesting(false)

            PlayheadTriangle()
                .fill(Color.red)
                .frame(width: 10, height: 7)
                .offset(x: phX - 5, y: 0)
                .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let t = max(0, Double(value.location.x / pixelsPerSecond))
                    onSeek?(t)
                }
        )
        .accessibilityLabel("Timeline ruler")
        .accessibilityValue("Playhead at \(timeLabel(for: Int(playheadSeconds.rounded())))")
        .accessibilityHint("Drag to seek playhead.")
        .onHover { isHovering in
            if isHovering {
                NSCursor.crosshair.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func gridColor(for seconds: Double) -> Color {
        if seconds == 0 { return .white.opacity(0.24) }
        if Int(seconds).isMultiple(of: 5) && seconds.rounded() == seconds {
            return MixPalette.gridMajor
        }
        if seconds.rounded() == seconds {
            return MixPalette.gridMinor
        }
        return MixPalette.gridSubdivision
    }

    private func timeLabel(for second: Int) -> String {
        let minutes = second / 60
        let remaining = second % 60
        return String(format: "%02d:%02d", minutes, remaining)
    }
}

private struct PlayheadTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
