#if canImport(AppKit)
import AppKit
import SwiftUI

// MARK: - Articulation Lane View
// An AppKit NSView lane (matching VelocityLaneView pattern) that shows articulation
// assignments per note. Clicking a note's region shows a popup menu with available
// articulations from the active expression map.

@available(macOS 26.0, *)
final class ArticulationLaneView: NSView {

    var notes: [PianoRollNote] = [] { didSet { guard notes != oldValue else { return }; setNeedsDisplay(bounds) } }
    var selectedNoteIDs: Set<UUID> = [] { didSet { guard selectedNoteIDs != oldValue else { return }; setNeedsDisplay(bounds) } }
    var scrollOffset: CGFloat = 0 { didSet { guard scrollOffset != oldValue else { return }; setNeedsDisplay(bounds) } }
    var pixelsPerTick: CGFloat = 0.267 { didSet { guard pixelsPerTick != oldValue else { return }; setNeedsDisplay(bounds) } }
    var gridWidth: CGFloat = 5000 { didSet { guard gridWidth != oldValue else { return }; setNeedsDisplay(bounds) } }
    var keyboardOffset: CGFloat = 96 { didSet { guard keyboardOffset != oldValue else { return }; setNeedsDisplay(bounds) } }

    /// The available articulations from the active expression map.
    var articulations: [ArticulationEntry] = [] { didSet { setNeedsDisplay(bounds) } }

    /// Called when the user selects an articulation for a note. Params: (noteID, articulationID?).
    var onArticulationChanged: ((UUID, UUID?) -> Void)?

    /// Color provider matching the piano roll's track coloring. Params: (trackIndex, channel) -> SIMD4<Float>.
    var colorProvider: ((Int, Int) -> SIMD4<Float>)?

    private let laneHeight: CGFloat = 28
    private let labelPadding: CGFloat = 3

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        let bgColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95)
        ctx.setFillColor(bgColor.cgColor)
        ctx.fill(bounds)

        // Separator line at top
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.move(to: CGPoint(x: 0, y: 0))
        ctx.addLine(to: CGPoint(x: bounds.width, y: 0))
        ctx.strokePath()

        // Draw articulation labels for each note
        for note in notes {
            let x = tickToX(note.startTick)
            let endX = tickToX(note.startTick + note.duration)
            let noteWidth = max(endX - x, 12)

            // Only draw if visible
            guard endX > keyboardOffset && x < bounds.width else { continue }

            // Find articulation for this note
            let articulationEntry = articulations.first { $0.id == note.articulationID }
            let label = articulationEntry?.shortName ?? articulationEntry?.name ?? ""
            let colorHex = articulationEntry?.colorHex

            // Background rect
            let rect = CGRect(x: x, y: 2, width: noteWidth, height: bounds.height - 4)
            let bgFill: NSColor
            if let hex = colorHex {
                bgFill = ColorHex.nsColor(from: hex)?.withAlphaComponent(0.6) ?? NSColor.systemBlue.withAlphaComponent(0.3)
            } else if let provider = colorProvider {
                let c = provider(note.trackIndex, note.channel)
                bgFill = NSColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 0.4)
            } else {
                bgFill = NSColor.systemGray.withAlphaComponent(0.3)
            }

            let isSelected = selectedNoteIDs.contains(note.id)
            let roundedPath = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            bgFill.setFill()
            roundedPath.fill()

            if isSelected {
                NSColor.controlAccentColor.withAlphaComponent(0.6).setStroke()
                roundedPath.lineWidth = 1.5
                roundedPath.stroke()
            }

            // Draw label text — use CTLine to avoid CoreText crash
            if !label.isEmpty, let ctx = NSGraphicsContext.current?.cgContext {
                let font = CTFontCreateWithName("Helvetica Neue" as CFString, 9, nil)
                let color = NSColor.labelColor.cgColor
                let cfAttrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
                let cfStr = CFAttributedStringCreate(nil, label as CFString, cfAttrs as CFDictionary)!
                let line = CTLineCreateWithAttributedString(cfStr)
                let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let asc = CTFontGetAscent(font)
                let desc = CTFontGetDescent(font)
                let textHeight = asc + desc
                let textX = x + labelPadding
                let textY = (bounds.height - textHeight) / 2
                if textWidth <= noteWidth - labelPadding * 2 {
                    ctx.saveGState()
                    ctx.translateBy(x: textX, y: textY + asc)
                    ctx.scaleBy(x: 1, y: -1)
                    CTLineDraw(line, ctx)
                    ctx.restoreGState()
                }
            }
        }
    }

    // MARK: - Mouse Handling

    override func mouseDown(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard let note = noteAt(loc) else { return }

        showArticulationMenu(for: note, at: loc)
    }

    private func showArticulationMenu(for note: PianoRollNote, at point: NSPoint) {
        let menu = NSMenu(title: "Articulation")

        // "None" option
        let noneItem = NSMenuItem(title: "None", action: #selector(articulationMenuAction(_:)), keyEquivalent: "")
        noneItem.target = self
        noneItem.representedObject = ArticulationMenuPayload(noteID: note.id, articulationID: nil)
        if note.articulationID == nil {
            noneItem.state = .on
        }
        menu.addItem(noneItem)
        menu.addItem(NSMenuItem.separator())

        for artic in articulations {
            let item = NSMenuItem(title: artic.name, action: #selector(articulationMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ArticulationMenuPayload(noteID: note.id, articulationID: artic.id)
            if note.articulationID == artic.id {
                item.state = .on
            }

            // Color swatch
            if let hex = artic.colorHex, let color = ColorHex.nsColor(from: hex) {
                let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                    color.setFill()
                    NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2, yRadius: 2).fill()
                    return true
                }
                item.image = swatch
            }

            menu.addItem(item)
        }

        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func articulationMenuAction(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? ArticulationMenuPayload else { return }
        onArticulationChanged?(payload.noteID, payload.articulationID)
    }

    // MARK: - Hit Testing

    private func noteAt(_ point: NSPoint) -> PianoRollNote? {
        for note in notes {
            let x = tickToX(note.startTick)
            let endX = tickToX(note.startTick + note.duration)
            let rect = CGRect(x: x, y: 2, width: max(endX - x, 12), height: laneHeight - 4)
            if rect.contains(point) { return note }
        }
        return nil
    }

    // MARK: - Coordinate Mapping

    private func tickToX(_ tick: Int) -> CGFloat {
        keyboardOffset + CGFloat(tick) * pixelsPerTick - scrollOffset
    }
}

// MARK: - Menu Payload

private final class ArticulationMenuPayload: NSObject {
    let noteID: UUID
    let articulationID: UUID?
    init(noteID: UUID, articulationID: UUID?) {
        self.noteID = noteID
        self.articulationID = articulationID
    }
}
#endif
