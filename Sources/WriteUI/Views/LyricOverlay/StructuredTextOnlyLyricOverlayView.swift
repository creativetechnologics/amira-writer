import SwiftUI
import AppKit
import ProjectKit

@available(macOS 26.0, *)
@MainActor
final class StructuredTextOnlyLyricOverlayView: NSView {
    var document = StructuredScriptDocument() {
        didSet {
            if oldValue != document {
                needsDisplay = true
                invalidateIntrinsicContentSize()
                cachedLayout.removeAll()
            }
        }
    }
    var characterNames: [String] = []
    var directionAccentColor = NSColor.white.withAlphaComponent(0.55)
    var actionAccentColor = NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.25, alpha: 1)

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return nil
    }

    func requiredHeight() -> CGFloat {
        let layout = computeLayout()
        return ceil((layout.map(\.frame.maxY).max() ?? 0) + 12)
    }

    private var cachedLayout: [TextOnlyLyricLine] = []

    private struct TextOnlyLyricLine {
        var text: String
        var kind: String
        var speakerName: String?
        var frame: NSRect
    }

    private func computeLayout() -> [TextOnlyLyricLine] {
        if !cachedLayout.isEmpty {
            return cachedLayout
        }

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let boldFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        let width = max(100, bounds.width - 16)
        let lineHeight: CGFloat = 19
        let sectionGap: CGFloat = 12

        var lines: [TextOnlyLyricLine] = []
        var y: CGFloat = 6

        var blockEntries: [(kind: String, text: String, sourceOrder: Int, speaker: String?)] = []

        for (index, range) in paragraphRanges(in: document.visibleText).enumerated() {
            let rawText = (document.visibleText as NSString).substring(with: range)
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            blockEntries.append((
                kind: index == 0 ? "scene" : "text",
                text: text,
                sourceOrder: -10_000 + index,
                speaker: nil
            ))
        }

        for block in document.lyricBlocks {
            blockEntries.append((
                kind: "lyric",
                text: block.text,
                sourceOrder: block.sourceOrder,
                speaker: block.speakerName
            ))
        }

        for hidden in document.hiddenMarkup where hidden.kind == .action
            && !StructuredScriptDocumentProjector.isShotDirectionActionMarkup(hidden.rawMarkup) {
            let displayText = StructuredScriptDocumentProjector.actionDisplayText(from: hidden.rawMarkup)
            blockEntries.append((
                kind: "action",
                text: displayText,
                sourceOrder: hidden.sourceOrder,
                speaker: nil
            ))
        }

        blockEntries.sort {
            if $0.sourceOrder == $1.sourceOrder {
                return $0.kind < $1.kind
            }
            return $0.sourceOrder < $1.sourceOrder
        }

        var lastKind: String?

        for entry in blockEntries {
            if let last = lastKind, last != entry.kind {
                y += sectionGap
            }
            lastKind = entry.kind

            let indentX: CGFloat
            var displayText: String

            switch entry.kind {
            case "lyric":
                indentX = 24
                let speakerLabel = entry.speaker.flatMap {
                    let t = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : t
                } ?? "SINGER"
                displayText = "\(speakerLabel): \(entry.text)"
            case "action":
                indentX = 0
                displayText = entry.text
            case "scene":
                indentX = 0
                displayText = entry.text.uppercased()
            default:
                indentX = 0
                displayText = entry.text
            }

            let maxTextWidth = max(50, width - indentX)
            let wrappedLines = wrapText(displayText, font: lineFont(for: entry.kind), maxWidth: maxTextWidth)

            for lineText in wrappedLines {
                let frame = NSRect(
                    x: indentX + 8,
                    y: y,
                    width: maxTextWidth,
                    height: lineHeight
                )
                lines.append(TextOnlyLyricLine(
                    text: lineText,
                    kind: entry.kind,
                    speakerName: entry.speaker,
                    frame: frame
                ))
                y += lineHeight
            }

            y += 3
        }

        cachedLayout = lines
        return lines
    }

    private func lineFont(for kind: String) -> NSFont {
        if kind == "scene" {
            return .monospacedSystemFont(ofSize: 13, weight: .bold)
        }
        return .monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    private func lineColor(for kind: String) -> NSColor {
        switch kind {
        case "scene":
            return directionAccentColor
        case "action":
            return actionAccentColor.withAlphaComponent(0.88)
        case "lyric":
            return NSColor.white.withAlphaComponent(0.88)
        default:
            return NSColor.white.withAlphaComponent(0.84)
        }
    }

    private func wrapText(_ text: String, font: NSFont, maxWidth: CGFloat) -> [String] {
        let words = text.split(separator: " ")
        var lines: [String] = []
        var currentLine = ""
        for word in words {
            let testLine = currentLine.isEmpty ? String(word) : "\(currentLine) \(word)"
            let size = (testLine as NSString).size(withAttributes: [.font: font])
            if size.width > maxWidth && !currentLine.isEmpty {
                lines.append(currentLine)
                currentLine = String(word)
            } else {
                currentLine = testLine
            }
        }
        if !currentLine.isEmpty {
            lines.append(currentLine)
        }
        if lines.isEmpty {
            lines.append(text)
        }
        return lines
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        for line in computeLayout() {
            let font = lineFont(for: line.kind)
            let color = lineColor(for: line.kind)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            (line.text as NSString).draw(at: line.frame.origin, withAttributes: attrs)
        }
    }

    private func paragraphRanges(in text: String) -> [NSRange] {
        StructuredScriptDocumentProjector.nonEmptyParagraphRanges(in: text)
    }

    private func clearCachedLayout() {
        cachedLayout.removeAll()
        needsDisplay = true
    }
}
