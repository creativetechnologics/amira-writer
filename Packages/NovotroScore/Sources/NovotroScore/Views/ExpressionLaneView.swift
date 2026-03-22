#if canImport(AppKit)
import AppKit
import SwiftUI

// MARK: - Expression Controller Lane View
// An AppKit NSView that draws CC envelope curves (similar to VelocityLaneView).
// Supports CC1 (mod wheel), CC11 (expression), CC64 (sustain), pitch bend.
// Click to add points, drag to move, right-click to delete.

@available(macOS 26.0, *)
final class ExpressionLaneView: NSView {

    var automationData: PianoRollAutomationData = PianoRollAutomationData() {
        didSet { setNeedsDisplay(bounds) }
    }
    var activeLaneType: AutomationLaneType = .cc1Modulation {
        didSet { setNeedsDisplay(bounds) }
    }
    var scrollOffset: CGFloat = 0 { didSet { guard scrollOffset != oldValue else { return }; setNeedsDisplay(bounds) } }
    var pixelsPerTick: CGFloat = 0.267 { didSet { guard pixelsPerTick != oldValue else { return }; setNeedsDisplay(bounds) } }
    var gridWidth: CGFloat = 5000 { didSet { guard gridWidth != oldValue else { return }; setNeedsDisplay(bounds) } }
    var keyboardOffset: CGFloat = 96 { didSet { guard keyboardOffset != oldValue else { return }; setNeedsDisplay(bounds) } }

    /// Called when automation points change. Returns the updated full point array for the active lane.
    var onPointsChanged: ((AutomationLaneType, [PianoRollAutoPoint]) -> Void)?

    private let pointRadius: CGFloat = 5
    private let hitRadius: CGFloat = 8
    private var draggedPointID: UUID?
    private var isDragging = false

    override var isFlipped: Bool { true }

    private var activePoints: [PianoRollAutoPoint] {
        automationData.points(for: activeLaneType)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        let bgColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95)
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(bounds)

        // Top separator
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 0, y: 0))
        ctx.addLine(to: CGPoint(x: bounds.width, y: 0))
        ctx.strokePath()

        // Lane type label — use CTLine to avoid ARC/CoreText crash
        let labelFont = CTFontCreateWithName("Helvetica Neue" as CFString, 9, nil)
        let labelColor = NSColor.secondaryLabelColor.cgColor
        let labelCFAttrs: [CFString: Any] = [kCTFontAttributeName: labelFont, kCTForegroundColorAttributeName: labelColor]
        let labelCFStr = CFAttributedStringCreate(nil, activeLaneType.rawValue as CFString, labelCFAttrs as CFDictionary)!
        let labelLine = CTLineCreateWithAttributedString(labelCFStr)
        let labelAsc = CTFontGetAscent(labelFont)
        ctx.saveGState()
        ctx.translateBy(x: 4, y: 3 + labelAsc)
        ctx.scaleBy(x: 1, y: -1)
        CTLineDraw(labelLine, ctx)
        ctx.restoreGState()

        // Draw grid lines (0%, 25%, 50%, 75%, 100%)
        ctx.setStrokeColor(NSColor.separatorColor.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(0.5)
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let y = valueToY(fraction)
            ctx.move(to: CGPoint(x: keyboardOffset, y: y))
            ctx.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        ctx.strokePath()

        let points = activePoints
        guard !points.isEmpty else { return }

        // Draw envelope curve
        let laneColor = colorForLaneType(activeLaneType)

        // Filled area under curve
        ctx.saveGState()
        let fillPath = CGMutablePath()
        let firstX = tickToX(points[0].tick)
        fillPath.move(to: CGPoint(x: firstX, y: valueToY(0)))
        for pt in points {
            fillPath.addLine(to: CGPoint(x: tickToX(pt.tick), y: valueToY(pt.value)))
        }
        let lastX = tickToX(points.last!.tick)
        fillPath.addLine(to: CGPoint(x: lastX, y: valueToY(0)))
        fillPath.closeSubpath()
        ctx.setFillColor(laneColor.withAlphaComponent(0.15).cgColor)
        ctx.addPath(fillPath)
        ctx.fillPath()
        ctx.restoreGState()

        // Stroke the curve
        ctx.setStrokeColor(laneColor.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.5)
        ctx.move(to: CGPoint(x: tickToX(points[0].tick), y: valueToY(points[0].value)))
        for i in 1..<points.count {
            ctx.addLine(to: CGPoint(x: tickToX(points[i].tick), y: valueToY(points[i].value)))
        }
        ctx.strokePath()

        // Draw control points
        for pt in points {
            let center = CGPoint(x: tickToX(pt.tick), y: valueToY(pt.value))
            let rect = CGRect(x: center.x - pointRadius, y: center.y - pointRadius,
                              width: pointRadius * 2, height: pointRadius * 2)

            let isActive = pt.id == draggedPointID
            ctx.setFillColor((isActive ? NSColor.white : laneColor).cgColor)
            ctx.fillEllipse(in: rect)
            ctx.setStrokeColor(laneColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.strokeEllipse(in: rect)
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)

        // Check if clicking an existing point
        if let hit = pointAt(loc) {
            draggedPointID = hit.id
            isDragging = true
            setNeedsDisplay(bounds)
            return
        }

        // Add a new point
        let tick = xToTick(loc.x)
        let value = yToValue(loc.y)
        guard tick >= 0 else { return }

        var points = activePoints
        let newPoint = PianoRollAutoPoint(tick: tick, value: value)
        points.append(newPoint)
        points.sort { $0.tick < $1.tick }
        onPointsChanged?(activeLaneType, points)

        draggedPointID = newPoint.id
        isDragging = true
        setNeedsDisplay(bounds)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let dragID = draggedPointID else { return }
        let loc = convert(event.locationInWindow, from: nil)

        var points = activePoints
        guard let idx = points.firstIndex(where: { $0.id == dragID }) else { return }

        let newTick = max(0, xToTick(loc.x))
        let newValue = yToValue(loc.y)
        points[idx] = PianoRollAutoPoint(id: dragID, tick: newTick, value: newValue)
        points.sort { $0.tick < $1.tick }
        onPointsChanged?(activeLaneType, points)
        setNeedsDisplay(bounds)
    }

    override func mouseUp(with event: NSEvent) {
        isDragging = false
        draggedPointID = nil
        setNeedsDisplay(bounds)
    }

    override func rightMouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard let hit = pointAt(loc) else { return }

        // Delete the point
        var points = activePoints
        points.removeAll { $0.id == hit.id }
        onPointsChanged?(activeLaneType, points)
    }

    // MARK: - Hit Testing

    private func pointAt(_ location: NSPoint) -> PianoRollAutoPoint? {
        for pt in activePoints {
            let center = CGPoint(x: tickToX(pt.tick), y: valueToY(pt.value))
            let dx = location.x - center.x
            let dy = location.y - center.y
            if dx * dx + dy * dy <= hitRadius * hitRadius {
                return pt
            }
        }
        return nil
    }

    // MARK: - Coordinate Mapping

    private func tickToX(_ tick: Int) -> CGFloat {
        keyboardOffset + CGFloat(tick) * pixelsPerTick - scrollOffset
    }

    private func xToTick(_ x: CGFloat) -> Int {
        let tick = (x - keyboardOffset + scrollOffset) / pixelsPerTick
        return max(0, Int(tick))
    }

    /// Value 0.0 maps to bottom, 1.0 maps to top. View is flipped.
    private func valueToY(_ value: Double) -> CGFloat {
        let margin: CGFloat = 4
        let drawableHeight = bounds.height - margin * 2
        return margin + drawableHeight * CGFloat(1.0 - value)
    }

    private func yToValue(_ y: CGFloat) -> Double {
        let margin: CGFloat = 4
        let drawableHeight = bounds.height - margin * 2
        let clamped = min(max(y - margin, 0), drawableHeight)
        return Double(1.0 - clamped / drawableHeight)
    }

    // MARK: - Colors

    private func colorForLaneType(_ type: AutomationLaneType) -> NSColor {
        switch type {
        case .cc1Modulation: return .systemBlue
        case .cc11Expression: return .systemGreen
        case .cc64Sustain: return .systemOrange
        case .pitchBend: return .systemPurple
        case .cc7Volume: return .systemYellow
        case .cc10Pan: return .systemPink
        case .aftertouch: return .systemTeal
        }
    }
}
#endif
