import SwiftUI

@available(macOS 26.0, *)
struct MixAutomationEnvelopeView: View {
    @Bindable var store: MixStore
    let track: MixTrack
    let duration: Double
    let pixelsPerSecond: CGFloat
    let laneHeight: CGFloat

    // Automation points are kept sorted at mutation time (addVolumeAutomationPoint and
    // updateVolumeAutomationPoint both sort after every change), so we read them directly
    // without re-sorting on every render frame.
    private var points: [MixAutomationPoint] {
        track.volumeAutomation
    }

    var body: some View {
        // Capture safe denominator once — guards all per-point calculations below.
        let safePixelsPerSecond: CGFloat = pixelsPerSecond > 0 ? pixelsPerSecond : 1
        ZStack(alignment: .topLeading) {
            if points.isEmpty {
                Text("Automation mode: click the lane to add volume points")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(MixPalette.cyan.opacity(0.88))
                    .lineLimit(1)
                    .padding(.leading, 18)
                    .padding(.top, max(laneHeight - 28, 8))
            }

            Path { path in
                guard let first = points.first else { return }
                path.move(to: CGPoint(x: xPosition(for: first, pps: safePixelsPerSecond), y: yPosition(for: first)))
                for point in points.dropFirst() {
                    path.addLine(to: CGPoint(x: xPosition(for: point, pps: safePixelsPerSecond), y: yPosition(for: point)))
                }
            }
            .stroke(MixPalette.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            ForEach(points) { point in
                Circle()
                    .fill(MixPalette.cyan)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.black.opacity(0.34), lineWidth: 1))
                    .position(x: xPosition(for: point, pps: safePixelsPerSecond), y: yPosition(for: point))
                    .contentShape(Circle().inset(by: -4))
                    // Tap on a point: consume the tap so the lane doesn't add
                    // a duplicate point on top.  A future enhancement could
                    // toggle "selected" state or show a popover for fine editing.
                    .onTapGesture {
                        // Intentionally empty — prevents fall-through to lane tap.
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                // Use shouldAutosave:false during live drag to avoid scheduling
                                // a debounced save on every frame — onEnded commits the final
                                // value and triggers the save.
                                let time = Double(max(value.location.x, 0) / safePixelsPerSecond)
                                let level = 1 - min(max(value.location.y / laneHeight, 0), 1)
                                store.updateVolumeAutomationPoint(
                                    trackID: track.id, pointID: point.id,
                                    timeSeconds: time, value: level,
                                    shouldAutosave: false
                                )
                            }
                            .onEnded { value in
                                // Commit the final position and trigger the deferred save.
                                let time = Double(max(value.location.x, 0) / safePixelsPerSecond)
                                let level = 1 - min(max(value.location.y / laneHeight, 0), 1)
                                store.updateVolumeAutomationPoint(
                                    trackID: track.id, pointID: point.id,
                                    timeSeconds: time, value: level,
                                    shouldAutosave: true
                                )
                            }
                    )
                    .accessibilityLabel("Volume automation point at \(String(format: "%.1f", point.timeSeconds))s, \(Int(point.value * 100))%")
            }
        }
    }

    private func xPosition(for point: MixAutomationPoint, pps: CGFloat) -> CGFloat {
        CGFloat(point.timeSeconds) * pps
    }

    private func yPosition(for point: MixAutomationPoint) -> CGFloat {
        let normalized = 1 - min(max(point.value, 0), 1)
        return CGFloat(normalized) * (laneHeight - 22) + 11
    }
}
