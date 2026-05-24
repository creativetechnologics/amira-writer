import SwiftUI
import AppKit
import ProjectKit

@available(macOS 26.0, *)
struct StructuredScriptTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var reportedHeight: CGFloat
    var isEditable: Bool = true
    var showInlineShotCards: Bool = true
    var showLyricCards: Bool = true
    var characterNames: [String] = []
    var directionMarkupColorHex: String = ScriptMarkupPalette.defaultDirectionHex
    var storyboardingMarkupColorHex: String = ScriptMarkupPalette.defaultStoryboardingHex
    var animateMarkupColorHex: String = ScriptMarkupPalette.defaultAnimateHex
    var expandedShotCardIDs: Binding<Set<String>> = .constant([])
    var allowsShotBoundaryEditing: Bool = false
    var allowsShotCardEditing: Bool = true

    private struct VisibleEdit {
        let affectedRange: NSRange
        let replacementString: String
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private static func nsColor(from hex: String, fallback fallbackHex: String) -> NSColor {
        let resolvedHex = ScriptMarkupPalette.normalizedHex(hex) ?? fallbackHex
        let raw = resolvedHex.hasPrefix("#") ? String(resolvedHex.dropFirst()) : resolvedHex
        guard raw.count == 6, let value = Int(raw, radix: 16) else {
            return .white
        }
        return NSColor(
            calibratedRed: CGFloat((value >> 16) & 0xFF) / 255.0,
            green: CGFloat((value >> 8) & 0xFF) / 255.0,
            blue: CGFloat(value & 0xFF) / 255.0,
            alpha: 1
        )
    }

    private static func shotFieldSuggestions(
        document: StructuredScriptDocument,
        characterNames: [String]
    ) -> StructuredShotFieldSuggestions {
        var characters = Set(characterNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        var locations = Set<String>()
        var props = Set<String>()
        var focus = Set<String>()

        func add(_ raw: String?, to set: inout Set<String>) {
            guard let raw else { return }
            for value in raw.split(separator: ",") {
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                if !cleaned.isEmpty {
                    set.insert(cleaned)
                }
            }
        }

        for shot in document.shots {
            shot.card.tags.characters.forEach { add($0, to: &characters) }
            shot.card.tags.places.forEach { add($0, to: &locations) }
            shot.card.tags.props.forEach { add($0, to: &props) }
            add(shot.card.camera.focus, to: &focus)
        }

        for markup in document.hiddenMarkup {
            guard let parsed = BracketDSLParser.parse(markup.rawMarkup) else { continue }
            let primary = parsed.primary.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            switch parsed.tag.lowercased() {
            case "scene":
                add(primary, to: &locations)
                add(parsed.parameters["bg"], to: &locations)
            case "enter", "exit", "move", "emotion", "gesture", "lipsync", "action":
                add(primary, to: &characters)
                add(parsed.parameters["target"], to: &characters)
                add(parsed.parameters["with_object"], to: &props)
            case "object", "object_move", "object_state", "object_visibility", "prop", "prop_move", "prop_state", "prop_visibility":
                add(primary, to: &props)
                add(parsed.parameters["attach_to"], to: &focus)
            default:
                break
            }
        }

        return StructuredShotFieldSuggestions(
            characters: characters.filter { !$0.isEmpty }.sorted(),
            locations: locations.filter { !$0.isEmpty }.sorted(),
            props: props.filter { !$0.isEmpty }.sorted(),
            focus: focus.filter { !$0.isEmpty }.sorted()
        )
    }

    func makeNSView(context: Context) -> StructuredScriptTimelineHostView {
        let host = StructuredScriptTimelineHostView()
        let coordinator = context.coordinator
        coordinator.hostView = host

        host.onHeightChanged = { [weak coordinator] height in
            DispatchQueue.main.async {
                coordinator?.parent.reportedHeight = height
            }
        }

        let textView = host.textView
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.84)
        textView.backgroundColor = .clear
        textView.insertionPointColor = .white
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.white.withAlphaComponent(0.20),
            .foregroundColor: NSColor.white
        ]
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = coordinator

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.84),
            .paragraphStyle: paragraphStyle
        ]

        host.timelineView.textView = textView
        host.timelineView.onToggleShot = { [weak coordinator] id in
            coordinator?.toggleShotExpansion(id: id)
        }
        host.timelineView.onMoveShotStart = { [weak coordinator] id, offset in
            coordinator?.moveShotStart(id: id, to: offset)
        }
        host.timelineView.onMoveShotEnd = { [weak coordinator] id, offset in
            coordinator?.moveShotEnd(id: id, to: offset)
        }
        host.timelineView.onRemoveShot = { [weak coordinator] id in
            coordinator?.removeShot(id: id)
        }
        host.timelineView.onChangeShotCard = { [weak coordinator] id, card in
            coordinator?.changeShotCard(id: id, card: card)
        }
        host.timelineView.onAddShotCard = { [weak coordinator] offset in
            coordinator?.addShotCard(at: offset)
        }
        host.textView.onToggleFold = { [weak coordinator] displayOffset in
            coordinator?.toggleFold(atDisplayOffset: displayOffset)
        }
        host.onAddLyricCard = { [weak coordinator] offset in
            coordinator?.addLyricCard(at: offset)
        }
        host.onAddActionCard = { [weak coordinator] offset in
            coordinator?.addActionCard(at: offset)
        }
        host.onAddShotCard = { [weak coordinator] offset in
            coordinator?.addShotCard(at: offset)
        }
        host.lyricSpeakerOverlayView.textView = textView
        host.lyricSpeakerOverlayView.onChangeSpeaker = { [weak coordinator] id, name in
            coordinator?.changeLyricSpeaker(id: id, speakerName: name)
        }
        host.lyricSpeakerOverlayView.onChangeText = { [weak coordinator] id, text in
            coordinator?.changeLyricBlockText(id: id, text: text)
        }
        host.lyricSpeakerOverlayView.onMoveBlock = { [weak coordinator] id, offset in
            coordinator?.moveLyricBlock(id: id, to: offset)
        }
        host.lyricSpeakerOverlayView.onChangeVisibleText = { [weak coordinator] range, text in
            coordinator?.changeVisibleText(range: range, text: text)
        }
        host.lyricSpeakerOverlayView.onChangeHiddenMarkup = { [weak coordinator] id, rawMarkup in
            coordinator?.changeHiddenMarkup(id: id, rawMarkup: rawMarkup)
        }

        coordinator.refreshDisplay(in: host, rawText: text, forceTextUpdate: true)
        return host
    }

    func updateNSView(_ host: StructuredScriptTimelineHostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        host.textView.isEditable = isEditable

        let lyricCardModeChanged = coordinator.lastShowLyricCards != showLyricCards
        if (coordinator.currentRawText != text || lyricCardModeChanged), !coordinator.isEditing {
            coordinator.refreshDisplay(in: host, rawText: text, forceTextUpdate: false)
        } else {
            coordinator.configureTimeline(in: host)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: StructuredScriptTextEditor
        weak var hostView: StructuredScriptTimelineHostView?
        var currentRawText = ""
        var currentDocument = StructuredScriptDocument()
        var currentFoldedProjection = FoldedScriptProjection(document: StructuredScriptDocument())
        var isEditing = false
        var lastShowLyricCards = false
        private var isApplyingProgrammaticText = false
        private var pendingEdit: VisibleEdit?
        private var cachedFieldSuggestions: StructuredShotFieldSuggestions?
        private var cachedSuggestionsHash: Int = 0
        private var isInitialParseDone = false

        init(parent: StructuredScriptTextEditor) {
            self.parent = parent
        }

        private func documentStructureSnapshot() -> Int {
            var hasher = Hasher()
            hasher.combine(currentDocument.shots.count)
            for shot in currentDocument.shots {
                hasher.combine(shot.id)
                hasher.combine(shot.card.id)
            }
            hasher.combine(currentDocument.hiddenMarkup.count)
            for hm in currentDocument.hiddenMarkup {
                hasher.combine(hm.id)
            }
            hasher.combine(currentDocument.lyricBlocks.count)
            for lb in currentDocument.lyricBlocks {
                hasher.combine(lb.id)
            }
            return hasher.finalize()
        }

        private func fieldSuggestions() -> StructuredShotFieldSuggestions {
            let snapshot = documentStructureSnapshot()
            if let cached = cachedFieldSuggestions, cachedSuggestionsHash == snapshot {
                return cached
            }
            let suggestions = StructuredScriptTextEditor.shotFieldSuggestions(
                document: currentDocument,
                characterNames: parent.characterNames
            )
            cachedFieldSuggestions = suggestions
            cachedSuggestionsHash = snapshot
            return suggestions
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            parent.text = currentRawText
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if currentFoldedProjection.visibleEdit(
                forDisplayRange: affectedRange,
                replacementString: replacementString ?? ""
            ) == nil {
                return false
            }
            pendingEdit = VisibleEdit(
                affectedRange: affectedRange,
                replacementString: replacementString ?? ""
            )
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingProgrammaticText else { return }
            guard let tv = notification.object as? NSTextView else { return }
            let edit = pendingEdit ?? VisibleEdit(
                affectedRange: NSRange(location: 0, length: currentDocument.visibleLength),
                replacementString: tv.string
            )
            pendingEdit = nil

            guard let foldedEdit = currentFoldedProjection.visibleEdit(
                forDisplayRange: edit.affectedRange,
                replacementString: edit.replacementString
            ) else {
                refreshVisibleText(in: tv)
                return
            }
            let nsVisible = currentDocument.visibleText as NSString
            guard foldedEdit.affectedVisibleRange.location >= 0,
                  NSMaxRange(foldedEdit.affectedVisibleRange) <= nsVisible.length else {
                refreshVisibleText(in: tv)
                return
            }
            let resulting = nsVisible.replacingCharacters(
                in: foldedEdit.affectedVisibleRange,
                with: foldedEdit.replacementString
            )
            let updated = StructuredScriptDocumentProjector.applyingVisibleEdit(
                to: currentDocument,
                affectedRange: foldedEdit.affectedVisibleRange,
                replacementString: foldedEdit.replacementString,
                resultingVisibleText: resulting
            )
            commitDocument(updated, updateTextView: true)
        }

        func refreshDisplay(
            in host: StructuredScriptTimelineHostView,
            rawText: String,
            forceTextUpdate: Bool
        ) {
            let preparedText = ScriptTextEditor.prepareEditableText(from: rawText)
            let lyricCardModeChanged = lastShowLyricCards != parent.showLyricCards

            if !isInitialParseDone || lyricCardModeChanged || forceTextUpdate {
                let document = StructuredScriptDocumentProjector.parse(
                    preparedText,
                    hideLyricSpeakerCues: true
                )
                currentRawText = rawText
                currentDocument = document
                isInitialParseDone = true
            } else if rawText != currentRawText {
                let oldVisible = currentDocument.visibleText as NSString
                let newVisible = preparedText as NSString
                if let (range, replacement) = incrementalDiff(old: oldVisible, new: newVisible) {
                    let updated = StructuredScriptDocumentProjector.applyingVisibleEdit(
                        to: currentDocument,
                        affectedRange: range,
                        replacementString: replacement,
                        resultingVisibleText: preparedText
                    )
                    currentDocument = updated
                } else {
                    let document = StructuredScriptDocumentProjector.parse(
                        preparedText,
                        hideLyricSpeakerCues: true
                    )
                    currentDocument = document
                }
                currentRawText = rawText
            }
            lastShowLyricCards = parent.showLyricCards
            currentFoldedProjection = FoldedScriptProjection(
                document: currentDocument,
                expandedFoldKeys: parent.expandedShotCardIDs.wrappedValue
            )

            let textView = host.textView
            let displayText = currentDisplayText
            if forceTextUpdate || textView.string != displayText {
                let selection = textView.selectedRange()
                isApplyingProgrammaticText = true
                textView.string = displayText
                applyFoldedTextAttributes(to: textView)
                isApplyingProgrammaticText = false
                let length = (textView.string as NSString).length
                textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            }
            host.textView.foldedProjection = currentFoldedProjection

            configureTimeline(in: host)
            host.recalcHeight()
        }

        private var currentDisplayText: String {
            currentFoldedProjection.displayText
        }

        private func refreshVisibleText(in textView: NSTextView) {
            isApplyingProgrammaticText = true
            textView.string = currentDisplayText
            applyFoldedTextAttributes(to: textView)
            isApplyingProgrammaticText = false
        }

        private func applyFoldedTextAttributes(to textView: NSTextView) {
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            let storage = textView.textStorage
            storage?.beginEditing()
            storage?.setAttributes([
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.white.withAlphaComponent(0.84)
            ], range: fullRange)
            for segment in currentFoldedProjection.segments where segment.kind != .visibleText {
                storage?.addAttributes([
                    .foregroundColor: NSColor.white.withAlphaComponent(0.58)
                ], range: segment.displayRange)
            }
            storage?.endEditing()
        }

        private func incrementalDiff(
            old oldVisible: NSString,
            new newVisible: NSString
        ) -> (NSRange, String)? {
            let oldLen = oldVisible.length
            let newLen = newVisible.length
            var prefix = 0
            while prefix < oldLen && prefix < newLen
                    && oldVisible.character(at: prefix) == newVisible.character(at: prefix) {
                prefix += 1
            }
            var suffix = 0
            while suffix < oldLen - prefix && suffix < newLen - prefix
                    && oldVisible.character(at: oldLen - 1 - suffix) == newVisible.character(at: newLen - 1 - suffix) {
                suffix += 1
            }
            let affectedLen = oldLen - prefix - suffix
            guard affectedLen > 0 || prefix < oldLen || prefix < newLen else { return nil }

            let range = NSRange(location: prefix, length: affectedLen)
            let replacementLength = newLen - prefix - suffix
            guard replacementLength >= 0 else { return nil }
            let replacement = newVisible.substring(
                with: NSRange(location: prefix, length: replacementLength)
            )
            return (range, replacement)
        }

        func configureTimeline(in host: StructuredScriptTimelineHostView) {
            host.showsShotColumn = parent.showInlineShotCards
            host.showsLyricCards = parent.showLyricCards
            host.textOnlyLyricMode = true
            host.timelineView.document = currentDocument
            host.timelineView.showsShotColumn = parent.showInlineShotCards
            host.timelineView.expandedShotIDs = parent.expandedShotCardIDs.wrappedValue
            host.timelineView.allowsEditing = parent.allowsShotBoundaryEditing
            host.timelineView.allowsCardEditing = parent.allowsShotCardEditing
            host.timelineView.fieldSuggestions = fieldSuggestions()
            host.timelineView.accentColor = StructuredScriptTextEditor.nsColor(
                from: parent.animateMarkupColorHex,
                fallback: ScriptMarkupPalette.defaultAnimateHex
            )
            host.timelineView.yForOffset = { [weak host] offset in
                host?.lyricSpeakerOverlayView.yForOffset(offset)
            }
            host.timelineView.yForAnchor = { [weak host] offset, sourceOrder in
                host?.lyricSpeakerOverlayView.yForAnchor(offset: offset, sourceOrder: sourceOrder)
            }
            host.timelineView.offsetForY = { [weak host] y in
                host?.lyricSpeakerOverlayView.offsetForY(y)
            }
            host.timelineView.invalidateCachedLayout()
            host.lyricSpeakerOverlayView.document = currentDocument
            host.lyricSpeakerOverlayView.showsLyricCards = parent.showLyricCards
            host.lyricSpeakerOverlayView.allowsEditing = parent.isEditable
                && parent.allowsShotBoundaryEditing
            host.lyricSpeakerOverlayView.characterNames = parent.characterNames
            host.textOnlyLyricOverlayView.document = currentDocument
            host.textOnlyLyricOverlayView.characterNames = parent.characterNames
            host.lyricSpeakerOverlayView.directionAccentColor = StructuredScriptTextEditor.nsColor(
                from: parent.directionMarkupColorHex,
                fallback: ScriptMarkupPalette.defaultDirectionHex
            )
            host.lyricSpeakerOverlayView.actionAccentColor = StructuredScriptTextEditor.nsColor(
                from: parent.storyboardingMarkupColorHex,
                fallback: ScriptMarkupPalette.defaultStoryboardingHex
            )
            host.lyricSpeakerOverlayView.reloadCards()
            host.textView.foldedProjection = currentFoldedProjection
            host.textView.alphaValue = 1.0
            host.textView.isEditable = parent.isEditable
            host.textView.isSelectable = true
            host.needsLayout = true
            host.needsDisplay = true
            host.timelineView.needsDisplay = true
            host.timelineView.needsLayout = true
            host.lyricSpeakerOverlayView.needsLayout = true
            host.timelineView.discardCursorRects()
            host.recalcHeight()
        }

        func toggleShotExpansion(id: UUID) {
            var ids = parent.expandedShotCardIDs.wrappedValue
            let key = id.uuidString
            if ids.contains(key) {
                ids.remove(key)
            } else {
                ids.insert(key)
            }
            parent.expandedShotCardIDs.wrappedValue = ids
            if let hostView {
                configureTimeline(in: hostView)
            }
        }

        func toggleFold(atDisplayOffset offset: Int) {
            guard let key = currentFoldedProjection.foldKey(atDisplayOffset: offset) else { return }
            var ids = parent.expandedShotCardIDs.wrappedValue
            if ids.contains(key) {
                ids.remove(key)
            } else {
                ids.insert(key)
            }
            parent.expandedShotCardIDs.wrappedValue = ids
            currentFoldedProjection = FoldedScriptProjection(
                document: currentDocument,
                expandedFoldKeys: ids
            )
            if let hostView {
                refreshVisibleText(in: hostView.textView)
                configureTimeline(in: hostView)
            }
        }

        func moveShotStart(id: UUID, to offset: Int) {
            guard parent.allowsShotBoundaryEditing else { return }
            let updated = StructuredScriptDocumentProjector.movingShotStart(
                in: currentDocument,
                shotID: id,
                to: offset
            )
            commitDocument(updated, updateTextView: false)
        }

        func moveShotEnd(id: UUID, to offset: Int) {
            guard parent.allowsShotBoundaryEditing else { return }
            let updated = StructuredScriptDocumentProjector.movingShotEnd(
                in: currentDocument,
                shotID: id,
                to: offset
            )
            commitDocument(updated, updateTextView: false)
        }

        func removeShot(id: UUID) {
            guard parent.allowsShotBoundaryEditing else { return }
            let updated = StructuredScriptDocumentProjector.removingShot(
                from: currentDocument,
                shotID: id
            )
            commitDocument(updated, updateTextView: false)
        }

        func changeShotCard(id: UUID, card: ScriptShotCard) {
            guard parent.allowsShotCardEditing else { return }
            let updated = StructuredScriptDocumentProjector.updatingShotCard(
                in: currentDocument,
                shotID: id,
                card: card
            )
            commitDocument(updated, updateTextView: false)
        }

        func changeVisibleText(range: NSRange, text: String) {
            guard parent.isEditable else { return }
            let nsVisible = currentDocument.visibleText as NSString
            guard range.location >= 0, NSMaxRange(range) <= nsVisible.length else { return }
            let resulting = nsVisible.replacingCharacters(in: range, with: text)
            let updated = StructuredScriptDocumentProjector.applyingVisibleEdit(
                to: currentDocument,
                affectedRange: range,
                replacementString: text,
                resultingVisibleText: resulting
            )
            commitDocument(updated, updateTextView: true)
        }

        func changeHiddenMarkup(id: UUID, rawMarkup: String) {
            guard parent.isEditable else { return }
            let updated = StructuredScriptDocumentProjector.updatingHiddenMarkup(
                in: currentDocument,
                markupID: id,
                rawMarkup: rawMarkup
            )
            commitDocument(updated, updateTextView: false)
        }

        func changeLyricSpeaker(id: UUID, speakerName: String) {
            guard parent.isEditable, parent.allowsShotBoundaryEditing else { return }
            let updated = StructuredScriptDocumentProjector.updatingLyricSpeaker(
                in: currentDocument,
                markerID: id,
                speakerName: speakerName
            )
            commitDocument(updated, updateTextView: false)
        }

        func changeLyricBlockText(id: UUID, text: String) {
            guard parent.isEditable, parent.allowsShotBoundaryEditing else { return }
            let updated = StructuredScriptDocumentProjector.updatingLyricBlockText(
                in: currentDocument,
                blockID: id,
                text: text
            )
            commitDocument(updated, updateTextView: false)
        }

        func moveLyricBlock(id: UUID, to offset: Int) {
            guard parent.isEditable, parent.allowsShotBoundaryEditing else { return }
            let updated = StructuredScriptDocumentProjector.movingLyricBlock(
                in: currentDocument,
                blockID: id,
                to: offset
            )
            commitDocument(updated, updateTextView: false)
        }

        func addLyricCard(at offset: Int) {
            guard parent.isEditable, parent.allowsShotBoundaryEditing else { return }
            let updated = StructuredScriptDocumentProjector.addingLyricBlock(
                to: currentDocument,
                at: offset,
                speakerName: parent.characterNames.first ?? "SINGER",
                text: "New lyric"
            )
            commitDocument(updated, updateTextView: false)
        }

        func addActionCard(at offset: Int) {
            guard parent.isEditable, parent.allowsShotBoundaryEditing else { return }
            let updated = StructuredScriptDocumentProjector.addingAction(
                to: currentDocument,
                at: offset,
                text: "New action"
            )
            commitDocument(updated, updateTextView: false)
        }

        func addShotCard(at offset: Int) {
            guard parent.allowsShotBoundaryEditing else { return }
            let updated = StructuredScriptDocumentProjector.addingShot(
                to: currentDocument,
                at: offset
            )
            commitDocument(updated, updateTextView: false)
        }

        private func commitDocument(
            _ document: StructuredScriptDocument,
            updateTextView: Bool
        ) {
            let raw = StructuredScriptDocumentProjector.export(document)
            currentDocument = document
            currentRawText = raw
            parent.text = raw
            currentFoldedProjection = FoldedScriptProjection(
                document: document,
                expandedFoldKeys: parent.expandedShotCardIDs.wrappedValue
            )

            guard let hostView else { return }
            let displayText = currentDisplayText
            if updateTextView, hostView.textView.string != displayText {
                isApplyingProgrammaticText = true
                hostView.textView.string = displayText
                applyFoldedTextAttributes(to: hostView.textView)
                isApplyingProgrammaticText = false
            }
            configureTimeline(in: hostView)
        }
    }
}

@available(macOS 26.0, *)
@MainActor
final class FoldedScriptTextView: NSTextView {
    var foldedProjection: FoldedScriptProjection?
    var onToggleFold: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let projection = foldedProjection else {
            super.mouseDown(with: event)
            return
        }
        let pointInView = convert(event.locationInWindow, from: nil)
        guard let layoutManager,
              let textContainer else {
            super.mouseDown(with: event)
            return
        }

        var point = pointInView
        point.x -= textContainerOrigin.x
        point.y -= textContainerOrigin.y
        let index = layoutManager.characterIndex(
            for: point,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        let text = string as NSString
        guard index >= 0, index < text.length else {
            super.mouseDown(with: event)
            return
        }
        let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
        guard lineRange.length >= 2 else {
            super.mouseDown(with: event)
            return
        }
        let linePrefix = text.substring(with: NSRange(location: lineRange.location, length: min(2, lineRange.length)))
        if (linePrefix == "> " || linePrefix == "v "),
           index <= lineRange.location + 2,
           projection.foldKey(atDisplayOffset: lineRange.location) != nil {
            onToggleFold?(lineRange.location)
            return
        }
        super.mouseDown(with: event)
    }
}

@available(macOS 26.0, *)
@MainActor
final class StructuredScriptTimelineHostView: NSView {
    let textView = FoldedScriptTextView()
    fileprivate let lyricSpeakerOverlayView = StructuredLyricSpeakerOverlayView()
    fileprivate let textOnlyLyricOverlayView = StructuredTextOnlyLyricOverlayView()
    fileprivate let timelineView = StructuredShotTimelineView()
    private let connectorOverlayView = StructuredTimelineConnectorOverlayView()
    var showsShotColumn = true
    var showsLyricCards = true
    var textOnlyLyricMode = false
    var onHeightChanged: ((CGFloat) -> Void)?
    var onAddLyricCard: ((Int) -> Void)?
    var onAddActionCard: ((Int) -> Void)?
    var onAddShotCard: ((Int) -> Void)?
    private var lastReportedHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        textView.backgroundColor = .clear
        addSubview(textView)

        lyricSpeakerOverlayView.wantsLayer = true
        lyricSpeakerOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(lyricSpeakerOverlayView)

        textOnlyLyricOverlayView.wantsLayer = true
        textOnlyLyricOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        textOnlyLyricOverlayView.isHidden = true
        addSubview(textOnlyLyricOverlayView)

        timelineView.wantsLayer = true
        timelineView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(timelineView)

        connectorOverlayView.wantsLayer = true
        connectorOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        lyricSpeakerOverlayView.onConnectorLayoutChanged = { [weak connectorOverlayView] in
            connectorOverlayView?.needsDisplay = true
        }
        connectorOverlayView.connectorProvider = { [weak self] in
            guard let self else { return nil }
            return StructuredTimelineConnectorOverlayView.Payload(
                connectors: self.lyricSpeakerOverlayView.timelineConnectors(),
                lyricOrigin: self.lyricSpeakerOverlayView.frame.origin,
                railX: self.timelineView.frame.minX + self.timelineView.timelineRailXInLocalCoordinates,
                visible: self.showsLyricCards && self.showsShotColumn && !self.timelineView.isHidden
            )
        }
        addSubview(connectorOverlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        let width = max(bounds.width, 1)
        let timelineWidth = (showsShotColumn && !textOnlyLyricMode) ? timelineColumnWidth(for: width) : 0
        let gap = timelineWidth > 0 ? CGFloat(18) : 0
        let textWidth = max(280, width - timelineWidth - gap)

        textView.frame = NSRect(x: 0, y: 0, width: min(textWidth, width), height: bounds.height)

        if textOnlyLyricMode {
            lyricSpeakerOverlayView.isHidden = true
            textOnlyLyricOverlayView.isHidden = true
        } else {
            lyricSpeakerOverlayView.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
            lyricSpeakerOverlayView.scriptColumnWidth = textView.frame.width
            lyricSpeakerOverlayView.isHidden = !showsLyricCards
            textOnlyLyricOverlayView.isHidden = true
        }
        timelineView.frame = NSRect(x: textView.frame.maxX + gap, y: 0, width: timelineWidth, height: bounds.height)
        timelineView.isHidden = !showsShotColumn || timelineWidth < 80
        connectorOverlayView.frame = bounds
        connectorOverlayView.needsDisplay = true

        textView.textContainer?.containerSize = NSSize(
            width: max(1, textView.frame.width),
            height: .greatestFiniteMagnitude
        )
        recalcHeight()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if textOnlyLyricMode {
            let textPoint = textView.convert(point, from: self)
            return textView.hitTest(textPoint)
        }
        if !timelineView.isHidden {
            let timelinePoint = timelineView.convert(point, from: self)
            if let hit = timelineView.hitTest(timelinePoint) {
                return hit
            }
        }
        if !lyricSpeakerOverlayView.isHidden {
            let lyricPoint = lyricSpeakerOverlayView.convert(point, from: self)
            if let hit = lyricSpeakerOverlayView.hitTest(lyricPoint) {
                return hit
            }
        }
        if showsLyricCards {
            return nil
        }
        let textPoint = textView.convert(point, from: self)
        return textView.hitTest(textPoint)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let offset = insertionOffset(at: point)
        let menu = NSMenu()
        if textOnlyLyricMode {
            let lyric = NSMenuItem(title: "Add Lyric Card", action: #selector(addLyricCardFromMenu(_:)), keyEquivalent: "")
            lyric.target = self
            lyric.representedObject = offset
            menu.addItem(lyric)
            let actionItem = NSMenuItem(title: "Add Action Card", action: #selector(addActionCardFromMenu(_:)), keyEquivalent: "")
            actionItem.target = self
            actionItem.representedObject = offset
            menu.addItem(actionItem)
        } else if !timelineView.isHidden, point.x >= timelineView.frame.minX {
            let item = NSMenuItem(
                title: "Add Shot Card",
                action: #selector(addShotCardFromMenu(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = offset
            menu.addItem(item)
        } else {
            let lyric = NSMenuItem(
                title: "Add Lyric Card",
                action: #selector(addLyricCardFromMenu(_:)),
                keyEquivalent: ""
            )
            lyric.target = self
            lyric.representedObject = offset
            menu.addItem(lyric)

            let action = NSMenuItem(
                title: "Add Action Card",
                action: #selector(addActionCardFromMenu(_:)),
                keyEquivalent: ""
            )
            action.target = self
            action.representedObject = offset
            menu.addItem(action)
        }

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func addLyricCardFromMenu(_ sender: NSMenuItem) {
        onAddLyricCard?(sender.representedObject as? Int ?? 0)
    }

    @objc private func addActionCardFromMenu(_ sender: NSMenuItem) {
        onAddActionCard?(sender.representedObject as? Int ?? 0)
    }

    @objc private func addShotCardFromMenu(_ sender: NSMenuItem) {
        onAddShotCard?(sender.representedObject as? Int ?? 0)
    }

    func recalcHeight() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let textHeight = ceil(usedRect.height + textView.textContainerInset.height * 2 + 8)
        let lyricHeight = textOnlyLyricMode ? 0 : lyricSpeakerOverlayView.requiredHeight()
        let timelineHeight = timelineView.requiredHeight()
        let clamped = showsLyricCards
            ? max(40, lyricHeight, timelineHeight)
            : max(40, textHeight, lyricHeight, timelineHeight)
        if abs(lastReportedHeight - clamped) > 0.5 {
            lastReportedHeight = clamped
            onHeightChanged?(clamped)
        }
    }

    private func timelineColumnWidth(for width: CGFloat) -> CGFloat {
        guard width >= 720 else { return min(340, max(280, width * 0.48)) }
        return min(480, max(360, width * 0.40))
    }

    private func insertionOffset(at point: NSPoint) -> Int {
        if showsLyricCards {
            let lyricPoint = lyricSpeakerOverlayView.convert(point, from: self)
            if let offset = lyricSpeakerOverlayView.offsetForY(lyricPoint.y) {
                return offset
            }
        }
        if !timelineView.isHidden {
            let timelinePoint = timelineView.convert(point, from: self)
            if let offset = timelineView.characterOffsetForInsertion(atTimelineY: timelinePoint.y) {
                return offset
            }
        }
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        var textPoint = textView.convert(point, from: self)
        textPoint.x -= textView.textContainerOrigin.x
        textPoint.y -= textView.textContainerOrigin.y
        let index = layoutManager.characterIndex(
            for: textPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return max(0, min(index, (textView.string as NSString).length))
    }
}

@available(macOS 26.0, *)
@MainActor
private struct StructuredScriptStackItem {
    enum Kind {
        case sceneHeader
        case visibleText
        case hiddenMarkup
        case lyric
    }

    var id: String
    var kind: Kind
    var anchorOffset: Int
    var sourceOrder: Int
    var visibleRange: NSRange?
    var hiddenMarkup: StructuredHiddenMarkup?
    var lyricBlock: StructuredLyricBlock?
    var text: String
}

@available(macOS 26.0, *)
@MainActor
private struct StructuredShotFieldSuggestions {
    var characters: [String] = []
    var locations: [String] = []
    var props: [String] = []
    var focus: [String] = []
}

@available(macOS 26.0, *)
@MainActor
private struct StructuredScriptTimelineConnector {
    var cardEdgeX: CGFloat
    var y: CGFloat
    var color: NSColor
}

private final class StructuredTimelineConnectorOverlayView: NSView {
    struct Payload {
        var connectors: [StructuredScriptTimelineConnector]
        var lyricOrigin: NSPoint
        var railX: CGFloat
        var visible: Bool
    }

    var connectorProvider: (() -> Payload?)?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let payload = connectorProvider?(),
              payload.visible else { return }

        for connector in payload.connectors {
            let y = payload.lyricOrigin.y + connector.y

            let cardEdgeX = payload.lyricOrigin.x + connector.cardEdgeX
            let startX = min(cardEdgeX + 1, payload.railX - 10)
            let endX = payload.railX - 3
            guard startX < endX else { continue }

            let path = NSBezierPath()
            path.move(to: NSPoint(x: startX, y: y))
            path.line(to: NSPoint(x: endX, y: y))
            connector.color.setStroke()
            path.lineWidth = 1
            path.stroke()

            let cardCap = NSBezierPath()
            cardCap.move(to: NSPoint(x: cardEdgeX, y: y - 2))
            cardCap.line(to: NSPoint(x: cardEdgeX, y: y + 2))
            connector.color.withAlphaComponent(0.72).setStroke()
            cardCap.lineWidth = 1
            cardCap.stroke()

            let dotRect = NSRect(x: payload.railX - 2.5, y: y - 2.5, width: 5, height: 5)
            connector.color.withAlphaComponent(0.72).setFill()
            NSBezierPath(ovalIn: dotRect).fill()

            NSColor(calibratedWhite: 0.04, alpha: 0.9).setStroke()
            let dotOutline = NSBezierPath(ovalIn: dotRect.insetBy(dx: -0.5, dy: -0.5))
            dotOutline.lineWidth = 1
            dotOutline.stroke()
        }
    }
}

@available(macOS 26.0, *)
@MainActor
private final class StructuredLyricSpeakerOverlayView: NSView {
    weak var textView: NSTextView?
    var document = StructuredScriptDocument() {
        didSet {
            if oldValue != document {
                invalidateStackItems()
            }
        }
    }
    var showsLyricCards = true
    var allowsEditing = false
    var characterNames: [String] = []
    var scriptColumnWidth: CGFloat = 0 {
        didSet {
            if abs(oldValue - scriptColumnWidth) > 0.5 {
                itemFrames.removeAll()
            }
        }
    }
    var directionAccentColor = NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.80, alpha: 1)
    var actionAccentColor = NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.25, alpha: 1)
    var onChangeSpeaker: ((UUID, String) -> Void)?
    var onChangeText: ((UUID, String) -> Void)?
    var onMoveBlock: ((UUID, Int) -> Void)?
    var onChangeVisibleText: ((NSRange, String) -> Void)?
    var onChangeHiddenMarkup: ((UUID, String) -> Void)?
    var onConnectorLayoutChanged: (() -> Void)?

    private var cardViews: [UUID: StructuredLyricBlockCardView] = [:]
    private var visibleCardViews: [String: StructuredVisibleTextCardView] = [:]
    private var hiddenCardViews: [UUID: StructuredHiddenMarkupCardView] = [:]
    private var itemFrames: [(item: StructuredScriptStackItem, frame: NSRect)] = []
    private var cachedStackItems: [StructuredScriptStackItem] = []
    private var stackItemsDirty = true
    private var lastPositionedWidth: CGFloat = -1
    private var lastPositionedScriptColumnWidth: CGFloat = -1

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard showsLyricCards, bounds.contains(point) else { return nil }
        for subview in subviews.reversed() {
            let converted = subview.convert(point, from: self)
            if let hit = subview.hitTest(converted) {
                return hit
            }
        }
        return nil
    }

    override func layout() {
        super.layout()
        positionCards()
    }

    func reloadCards() {
        guard showsLyricCards else {
            subviews.forEach { $0.removeFromSuperview() }
            cardViews.removeAll()
            visibleCardViews.removeAll()
            hiddenCardViews.removeAll()
            itemFrames.removeAll()
            return
        }

        let items = resolvedStackItems()
        let lyricBlocks = items.compactMap(\.lyricBlock)
        let markerIDs = Set(lyricBlocks.map(\.id))
        for (id, view) in cardViews where !markerIDs.contains(id) {
            view.removeFromSuperview()
        }
        cardViews = cardViews.filter { markerIDs.contains($0.key) }

        let visibleIDs = Set(items.filter { $0.visibleRange != nil }.map(\.id))
        for (id, view) in visibleCardViews where !visibleIDs.contains(id) {
            view.removeFromSuperview()
        }
        visibleCardViews = visibleCardViews.filter { visibleIDs.contains($0.key) }

        let hiddenMarkupItems = items.compactMap(\.hiddenMarkup)
        let hiddenIDs = Set(hiddenMarkupItems.map(\.id))
        for (id, view) in hiddenCardViews where !hiddenIDs.contains(id) {
            view.removeFromSuperview()
        }
        hiddenCardViews = hiddenCardViews.filter { hiddenIDs.contains($0.key) }

        for item in items {
            if let block = item.lyricBlock {
                configureLyricCard(block)
            } else if let range = item.visibleRange {
                configureVisibleCard(item: item, range: range)
            } else if let hidden = item.hiddenMarkup {
                configureHiddenCard(hidden)
            }
        }
        positionCards(items: items)
        superview?.needsDisplay = true
    }

    func requiredHeight() -> CGFloat {
        guard showsLyricCards else { return 0 }
        ensurePositionedCards()
        return ceil((itemFrames.map(\.frame.maxY).max() ?? 0) + 12)
    }

    func timelineConnectors() -> [StructuredScriptTimelineConnector] {
        ensurePositionedCards()
        let frames = itemFrames
        return frames.compactMap { entry in
            let color: NSColor
            switch entry.item.kind {
            case .sceneHeader:
                return nil
            case .lyric:
                color = NSColor.white.withAlphaComponent(0.18)
            case .visibleText, .hiddenMarkup:
                color = actionAccentColor.withAlphaComponent(0.28)
            }
            return StructuredScriptTimelineConnector(
                cardEdgeX: entry.frame.maxX,
                y: entry.frame.midY,
                color: color
            )
        }
    }

    func yForOffset(_ offset: Int) -> CGFloat? {
        yForAnchor(offset: offset, sourceOrder: nil)
    }

    func yForAnchor(offset: Int, sourceOrder: Int?) -> CGFloat? {
        ensurePositionedCards()
        let items = itemFrames
        guard !items.isEmpty else { return nil }
        let clampedOffset = max(0, min(offset, document.visibleLength))
        let candidate = items
            .filter { $0.item.kind != .sceneHeader }
            .min {
                let lhsDistance = abs($0.item.anchorOffset - clampedOffset)
                let rhsDistance = abs($1.item.anchorOffset - clampedOffset)
                if lhsDistance == rhsDistance {
                    if let sourceOrder {
                        let lhsOrderDistance = abs($0.item.sourceOrder - sourceOrder)
                        let rhsOrderDistance = abs($1.item.sourceOrder - sourceOrder)
                        if lhsOrderDistance != rhsOrderDistance {
                            return lhsOrderDistance < rhsOrderDistance
                        }
                    }
                    return $0.item.anchorOffset < $1.item.anchorOffset
                }
                return lhsDistance < rhsDistance
            } ?? items[0]
        if candidate.item.kind == .sceneHeader,
           let next = items.first(where: { $0.item.kind != .sceneHeader }) {
            return next.frame.minY
        }
        return candidate.frame.midY
    }

    func offsetForY(_ y: CGFloat) -> Int? {
        ensurePositionedCards()
        let items = itemFrames
        guard !items.isEmpty else { return nil }
        let closest = items.min {
            abs($0.frame.midY - y) < abs($1.frame.midY - y)
        }
        return closest?.item.anchorOffset
    }

    private func configureLyricCard(_ block: StructuredLyricBlock) {
            let view = cardViews[block.id] ?? StructuredLyricBlockCardView()
            if cardViews[block.id] == nil {
                cardViews[block.id] = view
                addSubview(view)
            }
            view.configure(
                block: block,
                characterNames: characterNames,
                allowsEditing: allowsEditing,
                onChangeSpeaker: { [weak self] id, name in
                    self?.onChangeSpeaker?(id, name)
                },
                onChangeText: { [weak self] id, text in
                    self?.onChangeText?(id, text)
                },
                onMove: { [weak self] id, translation in
                    self?.moveBlock(id: id, translation: translation)
                }
            )
    }

    private func configureVisibleCard(item: StructuredScriptStackItem, range: NSRange) {
        let view = visibleCardViews[item.id] ?? StructuredVisibleTextCardView()
        if visibleCardViews[item.id] == nil {
            visibleCardViews[item.id] = view
            addSubview(view)
        }
        view.configure(
            id: item.id,
            kind: item.kind,
            text: item.text,
            accentColor: item.kind == .sceneHeader ? directionAccentColor : actionAccentColor,
            allowsEditing: allowsEditing,
            onChangeText: { [weak self] _, text in
                self?.onChangeVisibleText?(range, text)
            }
        )
    }

    private func configureHiddenCard(_ hidden: StructuredHiddenMarkup) {
        let view = hiddenCardViews[hidden.id] ?? StructuredHiddenMarkupCardView()
        if hiddenCardViews[hidden.id] == nil {
            hiddenCardViews[hidden.id] = view
            addSubview(view)
        }
        let displayText = StructuredScriptDocumentProjector.actionDisplayText(from: hidden.rawMarkup)
        view.configure(
            markup: hidden,
            displayText: displayText,
            accentColor: actionAccentColor,
            allowsEditing: allowsEditing,
            onChangeText: { [weak self] id, text in
                let raw = StructuredScriptDocumentProjector.actionRawMarkup(
                    displayText: text,
                    preserving: hidden.rawMarkup
                )
                self?.onChangeHiddenMarkup?(id, raw)
            }
        )
    }

    private func positionCards() {
        guard showsLyricCards else { return }
        positionCards(items: resolvedStackItems())
    }

    private func positionCards(items: [StructuredScriptStackItem]) {
        guard showsLyricCards else { return }
        lastPositionedWidth = bounds.width
        lastPositionedScriptColumnWidth = scriptColumnWidth
        let scriptWidth = scriptColumnWidth > 0 ? min(scriptColumnWidth, bounds.width) : bounds.width
        let contentMaxWidth = max(180, scriptWidth - 10)
        let cardWidth = min(contentMaxWidth, min(540, max(260, scriptWidth * 0.72)))
        var nextY: CGFloat = 0
        var frames: [(item: StructuredScriptStackItem, frame: NSRect)] = []

        for item in items {
            guard let card = view(for: item) else { continue }
            let isHeader = item.kind == .sceneHeader
            let width = isHeader ? max(280, bounds.width - 10) : cardWidth
            let height = cardHeight(for: item, width: width)
            let x: CGFloat
            switch item.kind {
            case .sceneHeader, .lyric:
                x = 0
            case .visibleText, .hiddenMarkup:
                x = max(0, scriptWidth - width)
            }
            let frame = NSRect(
                x: x,
                y: nextY,
                width: width,
                height: height
            )
            card.frame = frame
            frames.append((item: item, frame: frame))
            nextY = frame.maxY + (isHeader ? 14 : 10)
        }
        itemFrames = frames
        onConnectorLayoutChanged?()
    }

    private func ensurePositionedCards() {
        guard showsLyricCards else { return }
        if itemFrames.isEmpty
            || abs(lastPositionedWidth - bounds.width) > 0.5
            || abs(lastPositionedScriptColumnWidth - scriptColumnWidth) > 0.5 {
            positionCards(items: resolvedStackItems())
        }
    }

    private func invalidateStackItems() {
        cachedStackItems.removeAll()
        stackItemsDirty = true
        itemFrames.removeAll()
        lastPositionedWidth = -1
        lastPositionedScriptColumnWidth = -1
    }

    private func resolvedStackItems() -> [StructuredScriptStackItem] {
        if stackItemsDirty {
            cachedStackItems = stackItems()
            stackItemsDirty = false
        }
        return cachedStackItems
    }

    private func view(for item: StructuredScriptStackItem) -> NSView? {
        if let block = item.lyricBlock {
            return cardViews[block.id]
        }
        if let hidden = item.hiddenMarkup {
            return hiddenCardViews[hidden.id]
        }
        return visibleCardViews[item.id]
    }

    private func cardHeight(for item: StructuredScriptStackItem, width: CGFloat) -> CGFloat {
        switch item.kind {
        case .sceneHeader:
            return max(58, textHeight(for: item.text, width: width - 28, fontSize: 13) + 30)
        case .visibleText:
            return max(66, textHeight(for: item.text, width: width - 42, fontSize: 13) + 38)
        case .hiddenMarkup:
            return max(62, textHeight(for: item.text, width: width - 42, fontSize: 13) + 36)
        case .lyric:
            return cardHeight(forLyricText: item.text, width: width)
        }
    }

    private func cardHeight(forLyricText text: String, width: CGFloat) -> CGFloat {
        let available = max(24, width - 38)
        let approximateCharsPerLine = max(18, Int(available / 7.2))
        let visualLineCount = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Int in
                max(1, Int(ceil(Double(max(1, line.count)) / Double(approximateCharsPerLine))))
            }
            .reduce(0, +)
        return max(72, CGFloat(visualLineCount) * 22 + 52)
    }

    private func textHeight(for text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
        let approximateCharsPerLine = max(18, Int(max(1, width) / (fontSize * 0.56)))
        let visualLineCount = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Int in
                max(1, Int(ceil(Double(max(1, line.count)) / Double(approximateCharsPerLine))))
            }
            .reduce(0, +)
        return CGFloat(max(1, visualLineCount)) * (fontSize + 5)
    }

    private func characterOffset(atY y: CGFloat) -> Int {
        offsetForY(y) ?? 0
    }

    private func moveBlock(id: UUID, translation: CGFloat) {
        guard allowsEditing,
              let card = cardViews[id] else { return }
        let targetY = max(0, card.frame.minY + translation)
        onMoveBlock?(id, characterOffset(atY: targetY))
    }

    private func stackItems() -> [StructuredScriptStackItem] {
        var items: [StructuredScriptStackItem] = []
        for block in visibleTextBlocks() where block.kind != .sceneHeader {
            items.append(block)
        }
        for hidden in document.hiddenMarkup where hidden.kind == .action
            && !StructuredScriptDocumentProjector.isShotDirectionActionMarkup(hidden.rawMarkup) {
            items.append(
                StructuredScriptStackItem(
                    id: hidden.id.uuidString,
                    kind: .hiddenMarkup,
                    anchorOffset: hidden.anchor.offset,
                    sourceOrder: hidden.sourceOrder,
                    visibleRange: nil,
                    hiddenMarkup: hidden,
                    lyricBlock: nil,
                    text: StructuredScriptDocumentProjector.actionDisplayText(from: hidden.rawMarkup)
                )
            )
        }
        for block in document.lyricBlocks {
            items.append(
                StructuredScriptStackItem(
                    id: block.id.uuidString,
                    kind: .lyric,
                    anchorOffset: block.anchor.offset,
                    sourceOrder: block.sourceOrder,
                    visibleRange: nil,
                    hiddenMarkup: nil,
                    lyricBlock: block,
                    text: block.text
                )
            )
        }
        return items.sorted {
            if $0.anchorOffset == $1.anchorOffset {
                return $0.sourceOrder < $1.sourceOrder
            }
            return $0.anchorOffset < $1.anchorOffset
        }
    }

    private func visibleTextBlocks() -> [StructuredScriptStackItem] {
        let visible = document.visibleText as NSString
        let ranges = paragraphRanges(in: document.visibleText)
        var items: [StructuredScriptStackItem] = []
        for (index, range) in ranges.enumerated() {
            let rawText = visible.substring(with: range)
            let text = rawText
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let kind: StructuredScriptStackItem.Kind = index == 0 ? .sceneHeader : .visibleText
            items.append(
                StructuredScriptStackItem(
                    id: "\(kind == .sceneHeader ? "scene" : "visible")-\(range.location)",
                    kind: kind,
                    anchorOffset: range.location,
                    sourceOrder: -10_000 + index,
                    visibleRange: range,
                    hiddenMarkup: nil,
                    lyricBlock: nil,
                    text: text
                )
            )
        }
        return items
    }

    private func paragraphRanges(in text: String) -> [NSRange] {
        StructuredScriptDocumentProjector.nonEmptyParagraphRanges(in: text)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class StructuredCardTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@available(macOS 26.0, *)
@MainActor
private final class StructuredVisibleTextCardView: NSView, NSTextViewDelegate {
    private let titleField = NSTextField(labelWithString: "")
    private let textScrollView = NSScrollView()
    private let bodyTextView = StructuredCardTextView()
    private var cardID = ""
    private var onChangeText: ((String, String) -> Void)?
    private var isUpdating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor(calibratedWhite: 0.072, alpha: 1).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        layer?.borderWidth = 1

        titleField.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        titleField.textColor = NSColor.white.withAlphaComponent(0.42)
        addSubview(titleField)

        textScrollView.drawsBackground = false
        textScrollView.hasVerticalScroller = false
        textScrollView.hasHorizontalScroller = false
        textScrollView.borderType = .noBorder
        textScrollView.documentView = bodyTextView
        addSubview(textScrollView)

        bodyTextView.delegate = self
        bodyTextView.isRichText = false
        bodyTextView.isVerticallyResizable = true
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.textContainer?.lineFragmentPadding = 0
        bodyTextView.textContainerInset = NSSize(width: 0, height: 2)
        bodyTextView.backgroundColor = .clear
        bodyTextView.drawsBackground = false
        bodyTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        bodyTextView.textColor = NSColor.white.withAlphaComponent(0.84)
        bodyTextView.insertionPointColor = .white
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if point.x <= 18 {
            return self
        }
        if textScrollView.frame.contains(point) {
            let scrollPoint = textScrollView.convert(point, from: self)
            return textScrollView.hitTest(scrollPoint) ?? bodyTextView
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if textScrollView.frame.contains(point) {
            window?.makeFirstResponder(bodyTextView)
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 18, y: 0))
        divider.line(to: NSPoint(x: 18, y: bounds.height))
        divider.lineWidth = 1
        divider.stroke()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        for index in 0..<3 {
            let y = bounds.midY - 6 + CGFloat(index * 6)
            let grip = NSBezierPath()
            grip.move(to: NSPoint(x: 7, y: y))
            grip.line(to: NSPoint(x: 12, y: y))
            grip.lineWidth = 1
            grip.stroke()
        }
    }

    override func layout() {
        super.layout()
        titleField.frame = NSRect(x: 24, y: 8, width: bounds.width - 36, height: 12)
        textScrollView.frame = NSRect(x: 24, y: 29, width: max(24, bounds.width - 36), height: max(24, bounds.height - 38))
        bodyTextView.minSize = NSSize(width: 0, height: textScrollView.contentSize.height)
        bodyTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        bodyTextView.frame = NSRect(origin: .zero, size: textScrollView.contentSize)
        bodyTextView.textContainer?.containerSize = NSSize(
            width: max(1, textScrollView.contentSize.width),
            height: .greatestFiniteMagnitude
        )
    }

    func configure(
        id: String,
        kind: StructuredScriptStackItem.Kind,
        text: String,
        accentColor: NSColor,
        allowsEditing: Bool,
        onChangeText: @escaping (String, String) -> Void
    ) {
        cardID = id
        self.onChangeText = onChangeText
        isUpdating = true
        titleField.stringValue = kind == .sceneHeader ? "SCENE" : "TEXT"
        titleField.textColor = kind == .sceneHeader
            ? NSColor.white.withAlphaComponent(0.54)
            : accentColor.withAlphaComponent(0.84)
        layer?.borderColor = (kind == .sceneHeader
            ? NSColor.white.withAlphaComponent(0.16)
            : accentColor.withAlphaComponent(0.26)
        ).cgColor
        bodyTextView.font = kind == .sceneHeader
            ? .monospacedSystemFont(ofSize: 14, weight: .semibold)
            : .monospacedSystemFont(ofSize: 13, weight: .regular)
        bodyTextView.textColor = kind == .sceneHeader
            ? NSColor.white.withAlphaComponent(0.84)
            : accentColor.withAlphaComponent(0.90)
        bodyTextView.isEditable = allowsEditing
        bodyTextView.isSelectable = true
        if bodyTextView.string != text {
            bodyTextView.string = text
        }
        isUpdating = false
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdating else { return }
        onChangeText?(cardID, bodyTextView.string)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class StructuredHiddenMarkupCardView: NSView, NSTextViewDelegate {
    private let titleField = NSTextField(labelWithString: "ACTION")
    private let textScrollView = NSScrollView()
    private let bodyTextView = StructuredCardTextView()
    private var markupID: UUID?
    private var onChangeRawMarkup: ((UUID, String) -> Void)?
    private var isUpdating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor(calibratedWhite: 0.067, alpha: 1).cgColor
        layer?.borderColor = NSColor(calibratedRed: 0.88, green: 0.74, blue: 0.24, alpha: 0.24).cgColor
        layer?.borderWidth = 1

        titleField.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        titleField.textColor = NSColor(calibratedRed: 0.92, green: 0.76, blue: 0.28, alpha: 0.78)
        addSubview(titleField)

        textScrollView.drawsBackground = false
        textScrollView.hasVerticalScroller = false
        textScrollView.hasHorizontalScroller = false
        textScrollView.borderType = .noBorder
        textScrollView.documentView = bodyTextView
        addSubview(textScrollView)

        bodyTextView.delegate = self
        bodyTextView.isRichText = false
        bodyTextView.isVerticallyResizable = true
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.textContainer?.lineFragmentPadding = 0
        bodyTextView.textContainerInset = NSSize(width: 0, height: 2)
        bodyTextView.backgroundColor = .clear
        bodyTextView.drawsBackground = false
        bodyTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        bodyTextView.textColor = NSColor(calibratedRed: 0.96, green: 0.82, blue: 0.36, alpha: 0.88)
        bodyTextView.insertionPointColor = .white
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if point.x <= 18 {
            return self
        }
        if textScrollView.frame.contains(point) {
            let scrollPoint = textScrollView.convert(point, from: self)
            return textScrollView.hitTest(scrollPoint) ?? bodyTextView
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if textScrollView.frame.contains(point) {
            window?.makeFirstResponder(bodyTextView)
        }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 18, y: 0))
        divider.line(to: NSPoint(x: 18, y: bounds.height))
        divider.lineWidth = 1
        divider.stroke()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        for index in 0..<3 {
            let y = bounds.midY - 6 + CGFloat(index * 6)
            let grip = NSBezierPath()
            grip.move(to: NSPoint(x: 7, y: y))
            grip.line(to: NSPoint(x: 12, y: y))
            grip.lineWidth = 1
            grip.stroke()
        }
    }

    override func layout() {
        super.layout()
        titleField.frame = NSRect(x: 24, y: 8, width: bounds.width - 36, height: 12)
        textScrollView.frame = NSRect(x: 24, y: 28, width: max(24, bounds.width - 36), height: max(24, bounds.height - 36))
        bodyTextView.minSize = NSSize(width: 0, height: textScrollView.contentSize.height)
        bodyTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        bodyTextView.frame = NSRect(origin: .zero, size: textScrollView.contentSize)
        bodyTextView.textContainer?.containerSize = NSSize(
            width: max(1, textScrollView.contentSize.width),
            height: .greatestFiniteMagnitude
        )
    }

    func configure(
        markup: StructuredHiddenMarkup,
        displayText: String,
        accentColor: NSColor,
        allowsEditing: Bool,
        onChangeText: @escaping (UUID, String) -> Void
    ) {
        markupID = markup.id
        self.onChangeRawMarkup = onChangeText
        isUpdating = true
        titleField.stringValue = "ACTION"
        titleField.textColor = accentColor.withAlphaComponent(0.82)
        layer?.borderColor = accentColor.withAlphaComponent(0.26).cgColor
        bodyTextView.textColor = accentColor.withAlphaComponent(0.88)
        bodyTextView.isEditable = allowsEditing
        bodyTextView.isSelectable = true
        if bodyTextView.string != displayText {
            bodyTextView.string = displayText
        }
        isUpdating = false
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdating, let markupID else { return }
        onChangeRawMarkup?(markupID, bodyTextView.string)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class StructuredLyricBlockCardView: NSView, NSTextViewDelegate {
    private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
    private let textScrollView = NSScrollView()
    private let bodyTextView = StructuredCardTextView()
    private var blockID: UUID?
    private var onChangeSpeaker: ((UUID, String) -> Void)?
    private var onChangeText: ((UUID, String) -> Void)?
    private var onMove: ((UUID, CGFloat) -> Void)?
    private var isUpdating = false
    private var dragStart: NSPoint?
    private var allowsCardEditing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.backgroundColor = NSColor(calibratedWhite: 0.075, alpha: 1).cgColor
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        layer?.borderWidth = 1

        popUp.font = .systemFont(ofSize: 12, weight: .semibold)
        popUp.isBordered = false
        popUp.target = self
        popUp.action = #selector(selectionChanged(_:))
        addSubview(popUp)

        textScrollView.drawsBackground = false
        textScrollView.hasVerticalScroller = false
        textScrollView.hasHorizontalScroller = false
        textScrollView.borderType = .noBorder
        textScrollView.documentView = bodyTextView
        addSubview(textScrollView)

        bodyTextView.delegate = self
        bodyTextView.isRichText = false
        bodyTextView.isVerticallyResizable = true
        bodyTextView.isHorizontallyResizable = false
        bodyTextView.textContainer?.widthTracksTextView = true
        bodyTextView.textContainer?.lineFragmentPadding = 0
        bodyTextView.textContainerInset = NSSize(width: 0, height: 2)
        bodyTextView.backgroundColor = .clear
        bodyTextView.drawsBackground = false
        bodyTextView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        bodyTextView.textColor = NSColor.white.withAlphaComponent(0.86)
        bodyTextView.insertionPointColor = .white
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.withAlphaComponent(0.08).setStroke()
        let divider = NSBezierPath()
        divider.move(to: NSPoint(x: 18, y: 0))
        divider.line(to: NSPoint(x: 18, y: bounds.height))
        divider.lineWidth = 1
        divider.stroke()

        NSColor.white.withAlphaComponent(0.20).setStroke()
        for index in 0..<3 {
            let y = bounds.midY - 6 + CGFloat(index * 6)
            let grip = NSBezierPath()
            grip.move(to: NSPoint(x: 7, y: y))
            grip.line(to: NSPoint(x: 12, y: y))
            grip.lineWidth = 1
            grip.stroke()
        }
    }

    override func layout() {
        super.layout()
        popUp.frame = NSRect(x: 22, y: 4, width: max(140, bounds.width - 34), height: 26)
        textScrollView.frame = NSRect(x: 22, y: 34, width: max(24, bounds.width - 34), height: max(24, bounds.height - 42))
        bodyTextView.minSize = NSSize(width: 0, height: textScrollView.contentSize.height)
        bodyTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        bodyTextView.frame = NSRect(origin: .zero, size: textScrollView.contentSize)
        bodyTextView.textContainer?.containerSize = NSSize(
            width: max(1, textScrollView.contentSize.width),
            height: .greatestFiniteMagnitude
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if point.x <= 18 {
            return self
        }
        if popUp.frame.contains(point) {
            let popUpPoint = popUp.convert(point, from: self)
            return popUp.hitTest(popUpPoint) ?? popUp
        }
        if textScrollView.frame.contains(point) {
            let scrollPoint = textScrollView.convert(point, from: self)
            return textScrollView.hitTest(scrollPoint) ?? bodyTextView
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if textScrollView.frame.contains(point) {
            window?.makeFirstResponder(bodyTextView)
            super.mouseDown(with: event)
            return
        }
        guard point.x <= 18, allowsCardEditing else {
            super.mouseDown(with: event)
            return
        }
        dragStart = point
        NSCursor.openHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil, allowsCardEditing else { return }
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart, allowsCardEditing else {
            super.mouseUp(with: event)
            return
        }
        defer { self.dragStart = nil }
        let point = convert(event.locationInWindow, from: nil)
        let translation = point.y - dragStart.y
        guard abs(translation) >= 4, let blockID else { return }
        onMove?(blockID, translation)
    }

    func configure(
        block: StructuredLyricBlock,
        characterNames: [String],
        allowsEditing: Bool,
        onChangeSpeaker: @escaping (UUID, String) -> Void,
        onChangeText: @escaping (UUID, String) -> Void,
        onMove: @escaping (UUID, CGFloat) -> Void
    ) {
        blockID = block.id
        self.onChangeSpeaker = onChangeSpeaker
        self.onChangeText = onChangeText
        self.onMove = onMove
        allowsCardEditing = allowsEditing

        let speaker = block.speakerName
        let options = characterOptions(current: speaker, characterNames: characterNames)

        isUpdating = true
        popUp.removeAllItems()
        popUp.addItems(withTitles: options)
        popUp.selectItem(withTitle: options.first(where: {
            $0.caseInsensitiveCompare(speaker) == .orderedSame
        }) ?? speaker)
        popUp.isEnabled = allowsEditing
        popUp.alphaValue = allowsEditing ? 1.0 : 0.72
        bodyTextView.isEditable = allowsEditing
        bodyTextView.isSelectable = true
        if bodyTextView.string != block.text {
            bodyTextView.string = block.text
        }
        isUpdating = false
    }

    @objc private func selectionChanged(_ sender: NSPopUpButton) {
        guard !isUpdating,
              let blockID,
              let title = sender.selectedItem?.title else { return }
        onChangeSpeaker?(blockID, title)
    }

    func textDidChange(_ notification: Notification) {
        guard !isUpdating, let blockID else { return }
        onChangeText?(blockID, bodyTextView.string)
    }

    private func characterOptions(current: String, characterNames: [String]) -> [String] {
        var seen = Set<String>()
        var options: [String] = []
        func add(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            options.append(trimmed)
        }
        let defaults = ["SINGER", "NARRATOR", "CHORUS"]
        add(current)
        for name in characterNames.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            add(name)
        }
        for d in defaults where options.count < 4 || !seen.contains(d.lowercased()) {
            add(d)
        }
        if options.isEmpty {
            options.append("SINGER")
        }
        return options
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ShotEditorTextField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ShotEditorComboBox: NSComboBox {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ShotEditorTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ShotEditorPopUpButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@available(macOS 26.0, *)
@MainActor
private final class ShotEditorMenuButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@available(macOS 26.0, *)
@MainActor
private final class StructuredShotCardEditorView: NSView, NSTextFieldDelegate, NSTextViewDelegate, NSComboBoxDelegate {
    private enum SuggestionKind {
        case location
        case characters
        case props
        case focus
    }

    private final class SuggestionMenuItem: NSMenuItem {
        let kind: SuggestionKind
        let suggestionValue: String

        init(title: String, kind: SuggestionKind, value: String) {
            self.kind = kind
            self.suggestionValue = value
            super.init(title: title, action: #selector(StructuredShotCardEditorView.suggestionMenuItemSelected(_:)), keyEquivalent: "")
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    private let directionScrollView = NSScrollView()
    private let directionTextView = ShotEditorTextView()
    private let labelField = ShotEditorTextField()
    private let locationField = ShotEditorComboBox()
    private let locationMenuButton = ShotEditorMenuButton()
    private let timeOfDayPopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let interiorExteriorPopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let weatherAtmospherePopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let lightSourcePopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let characterLeftField = ShotEditorComboBox()
    private let characterMiddleField = ShotEditorComboBox()
    private let characterRightField = ShotEditorComboBox()
    private let characterLeftFacingPopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let characterMiddleFacingPopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let characterRightFacingPopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let characterPositionLabels: [NSTextField] = [
        NSTextField(labelWithString: "Character Left"),
        NSTextField(labelWithString: "Character Middle"),
        NSTextField(labelWithString: "Character Right")
    ]
    private let propsField = ShotEditorComboBox()
    private let propsMenuButton = ShotEditorMenuButton()
    private let shotSizePopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let lensPopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let cameraAnglePopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let depthOfFieldPopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let movementPopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let focusField = ShotEditorComboBox()
    private let focusMenuButton = ShotEditorMenuButton()
    private let intentPopup = ShotEditorPopUpButton(frame: .zero, pullsDown: false)
    private let barsField = ShotEditorTextField()
    private let continuityField = ShotEditorTextField()
    private let notesScrollView = NSScrollView()
    private let notesTextView = ShotEditorTextView()
    private let rowLabels: [NSTextField] = [
        NSTextField(labelWithString: "Shot Name"),
        NSTextField(labelWithString: "Direction"),
        NSTextField(labelWithString: "Location"),
        NSTextField(labelWithString: "Setting"),
        NSTextField(labelWithString: "Environment"),
        NSTextField(labelWithString: "Characters"),
        NSTextField(labelWithString: "Props"),
        NSTextField(labelWithString: "Framing"),
        NSTextField(labelWithString: "Optics"),
        NSTextField(labelWithString: "Movement"),
        NSTextField(labelWithString: "Focus"),
        NSTextField(labelWithString: "Intent"),
        NSTextField(labelWithString: "Timing"),
        NSTextField(labelWithString: "Continuity"),
        NSTextField(labelWithString: "Notes")
    ]

    private var shotID: UUID?
    private var currentCard = ScriptShotCard()
    private var onCommit: ((UUID, ScriptShotCard) -> Void)?
    private var isUpdating = false
    private var locationSuggestions: [String] = []
    private var characterSuggestions: [String] = []
    private var propSuggestions: [String] = []
    private var focusSuggestions: [String] = []

    private let shotSizeOptions = [
        "",
        "extreme_wide",
        "wide",
        "medium_wide",
        "medium",
        "medium_close",
        "close",
        "extreme_close"
    ]
    private let movementOptions = [
        "",
        "hold",
        "zoom_in",
        "zoom_out",
        "pan_left",
        "pan_right",
        "pan_up",
        "pan_down",
        "track",
        "dolly_in",
        "dolly_out",
        "push_in",
        "pull_back"
    ]
    private let intentOptions = [
        "",
        "establishing",
        "reveal",
        "reaction",
        "dialogue",
        "handoff",
        "movement",
        "insert",
        "transition",
        "emotional"
    ]
    private let timeOfDayOptions = [
        "",
        "pre_dawn",
        "dawn",
        "morning",
        "midday",
        "afternoon",
        "golden_hour",
        "sunset",
        "dusk",
        "night",
        "late_night"
    ]
    private let interiorExteriorOptions = [
        "",
        "interior",
        "exterior",
        "interior_to_exterior",
        "exterior_to_interior"
    ]
    private let weatherAtmosphereOptions = [
        "",
        "clear",
        "haze",
        "dust",
        "smoke",
        "rain",
        "storm",
        "fog",
        "snow",
        "wind",
        "heat_shimmer"
    ]
    private let lightSourceOptions = [
        "",
        "natural_window",
        "sunlight",
        "moonlight",
        "firelight",
        "practical_lamp",
        "fluorescent",
        "neon",
        "vehicle_headlights",
        "candlelight",
        "stage_light"
    ]
    private let lensOptions = [
        "",
        "wide",
        "normal",
        "telephoto",
        "macro",
        "anamorphic"
    ]
    private let cameraAngleOptions = [
        "",
        "eye_level",
        "low_angle",
        "high_angle",
        "overhead",
        "dutch_angle",
        "ground_level",
        "shoulder_level"
    ]
    private let depthOfFieldOptions = [
        "",
        "deep_focus",
        "medium_depth",
        "shallow_focus",
        "background_blur",
        "foreground_blur"
    ]
    private let facingOptions = [
        "",
        "towards_camera",
        "away_from_camera",
        "left",
        "right",
        "three_quarter_left",
        "three_quarter_right",
        "profile_left",
        "profile_right",
        "up",
        "down"
    ]

    static func preferredHeight(for width: CGFloat) -> CGFloat {
        CGFloat(12) * 24 + 68 + 78 + 82 + CGFloat(14) * 6
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        for label in rowLabels {
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.textColor = NSColor.white.withAlphaComponent(0.46)
            label.alignment = .right
            addSubview(label)
        }
        for label in characterPositionLabels {
            label.font = .systemFont(ofSize: 8, weight: .semibold)
            label.textColor = NSColor.white.withAlphaComponent(0.44)
            addSubview(label)
        }

        textFields.forEach(configureTextField(_:))
        comboFields.forEach(configureComboBox(_:))
        suggestionMenuButtons.forEach(configureSuggestionMenuButton(_:))
        configureMultilineTextView(directionTextView, in: directionScrollView)
        configureMultilineTextView(notesTextView, in: notesScrollView)

        configurePopup(shotSizePopup, options: shotSizeOptions)
        configurePopup(movementPopup, options: movementOptions)
        configurePopup(intentPopup, options: intentOptions)
        configurePopup(timeOfDayPopup, options: timeOfDayOptions)
        configurePopup(interiorExteriorPopup, options: interiorExteriorOptions)
        configurePopup(weatherAtmospherePopup, options: weatherAtmosphereOptions)
        configurePopup(lightSourcePopup, options: lightSourceOptions)
        configurePopup(lensPopup, options: lensOptions)
        configurePopup(cameraAnglePopup, options: cameraAngleOptions)
        configurePopup(depthOfFieldPopup, options: depthOfFieldOptions)
        framingFacingPopups.forEach { configurePopup($0, options: facingOptions) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        if let control = controlHit(at: point) {
            let converted = control.convert(point, from: self)
            return control.hitTest(converted) ?? control
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let control = controlHit(at: point) {
            window?.makeFirstResponder(control)
        }
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 6
        let rowHeight: CGFloat = 24
        let characterRowHeight: CGFloat = 68
        let directionHeight: CGFloat = 78
        let notesHeight: CGFloat = 82
        let labelWidth = min(max(64, bounds.width * 0.30), 104)
        let controlX = labelWidth + 8
        let controlWidth = max(54, bounds.width - controlX)
        let rows: [(NSView, CGFloat)] = [
            (labelField, rowHeight),
            (directionScrollView, directionHeight),
            (locationField, rowHeight),
            (timeOfDayPopup, rowHeight),
            (weatherAtmospherePopup, rowHeight),
            (characterLeftField, characterRowHeight),
            (propsField, rowHeight),
            (shotSizePopup, rowHeight),
            (lensPopup, rowHeight),
            (movementPopup, rowHeight),
            (focusField, rowHeight),
            (intentPopup, rowHeight),
            (barsField, rowHeight),
            (continuityField, rowHeight),
            (notesScrollView, notesHeight)
        ]
        var y: CGFloat = 0
        for (index, row) in rows.enumerated() {
            rowLabels[index].frame = NSRect(x: 0, y: y + 4, width: labelWidth, height: rowHeight - 4)
            let frame = NSRect(x: controlX, y: y, width: controlWidth, height: row.1)
            if row.0 === locationField {
                layoutSuggestionCombo(locationField, menuButton: locationMenuButton, frame: frame)
            } else if row.0 === timeOfDayPopup {
                layoutSettingRow(frame)
            } else if row.0 === weatherAtmospherePopup {
                layoutEnvironmentRow(frame)
            } else if row.0 === characterLeftField {
                layoutCharacterFramingRow(frame)
            } else if row.0 === propsField {
                layoutSuggestionCombo(propsField, menuButton: propsMenuButton, frame: frame)
            } else if row.0 === lensPopup {
                layoutOpticsRow(frame)
            } else if row.0 === focusField {
                layoutSuggestionCombo(focusField, menuButton: focusMenuButton, frame: frame)
            } else {
                row.0.frame = frame
            }
            y += row.1 + gap
        }
        for textView in [directionTextView, notesTextView] {
            if let scrollView = textView.enclosingScrollView {
                textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
                textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
                textView.textContainer?.containerSize = NSSize(
                    width: max(1, scrollView.contentSize.width),
                    height: .greatestFiniteMagnitude
                )
            }
        }
    }

    func configure(
        shot: StructuredShotSpan,
        suggestions: StructuredShotFieldSuggestions,
        canEdit: Bool,
        onCommit: @escaping (UUID, ScriptShotCard) -> Void
    ) {
        shotID = shot.id
        currentCard = shot.card
        self.onCommit = onCommit

        isUpdating = true
        locationSuggestions = suggestions.locations
        characterSuggestions = suggestions.characters
        propSuggestions = suggestions.props
        focusSuggestions = suggestions.focus
        setComboItems(locationField, suggestions: suggestions.locations)
        setComboItems(characterLeftField, suggestions: suggestions.characters)
        setComboItems(characterMiddleField, suggestions: suggestions.characters)
        setComboItems(characterRightField, suggestions: suggestions.characters)
        setComboItems(propsField, suggestions: suggestions.props)
        setComboItems(focusField, suggestions: suggestions.focus)

        let directionText = directionText(for: shot)
        if directionTextView.string != directionText {
            directionTextView.string = directionText
        }
        let notesText = shot.card.camera.notes ?? ""
        if notesTextView.string != notesText {
            notesTextView.string = notesText
        }
        labelField.placeholderString = "short shot name"
        locationField.placeholderString = "place or set"
        characterLeftField.placeholderString = "left side"
        characterMiddleField.placeholderString = "middle"
        characterRightField.placeholderString = "right side"
        propsField.placeholderString = "comma-separated"
        focusField.placeholderString = "subject or object"
        barsField.placeholderString = "bars for now"
        continuityField.placeholderString = "wardrobe, blocking, prop continuity"

        let framing = characterFramingStrings(for: shot.card)
        labelField.stringValue = shot.card.camera.label ?? shot.card.label ?? ""
        locationField.stringValue = shot.card.tags.places.joined(separator: ", ")
        setPopupValue(timeOfDayPopup, value: shot.card.setting.timeOfDay ?? "", options: timeOfDayOptions)
        setPopupValue(interiorExteriorPopup, value: shot.card.setting.interiorExterior ?? "", options: interiorExteriorOptions)
        setPopupValue(
            weatherAtmospherePopup,
            value: shot.card.setting.weatherAtmosphere ?? "",
            options: weatherAtmosphereOptions
        )
        setPopupValue(lightSourcePopup, value: shot.card.setting.lightSource ?? "", options: lightSourceOptions)
        setPopupValue(lensPopup, value: shot.card.setting.lens ?? "", options: lensOptions)
        setPopupValue(cameraAnglePopup, value: shot.card.setting.cameraAngle ?? "", options: cameraAngleOptions)
        setPopupValue(depthOfFieldPopup, value: shot.card.setting.depthOfField ?? "", options: depthOfFieldOptions)
        characterLeftField.stringValue = framing.left
        characterMiddleField.stringValue = framing.middle
        characterRightField.stringValue = framing.right
        propsField.stringValue = shot.card.tags.props.joined(separator: ", ")
        focusField.stringValue = shot.card.camera.focus ?? ""
        barsField.stringValue = barsString(shot.card.timing)
        continuityField.stringValue = shot.card.setting.continuityNotes ?? ""
        setPopupValue(shotSizePopup, value: shot.card.camera.shotSize ?? "", options: shotSizeOptions)
        setPopupValue(movementPopup, value: shot.card.camera.movement ?? "", options: movementOptions)
        setPopupValue(intentPopup, value: shot.card.camera.intent ?? "", options: intentOptions)
        setPopupValue(characterLeftFacingPopup, value: shot.card.characterFraming.leftFacing ?? "", options: facingOptions)
        setPopupValue(characterMiddleFacingPopup, value: shot.card.characterFraming.middleFacing ?? "", options: facingOptions)
        setPopupValue(characterRightFacingPopup, value: shot.card.characterFraming.rightFacing ?? "", options: facingOptions)

        textFields.forEach {
            $0.isEditable = canEdit
            $0.isSelectable = true
            $0.alphaValue = canEdit ? 1 : 0.70
        }
        [directionTextView, notesTextView].forEach {
            $0.isEditable = canEdit
            $0.isSelectable = true
            $0.alphaValue = canEdit ? 1 : 0.70
        }
        comboFields.forEach {
            $0.isEnabled = canEdit
            $0.isEditable = canEdit
            $0.alphaValue = canEdit ? 1 : 0.70
        }
        suggestionMenuButtons.forEach {
            $0.isEnabled = canEdit
            $0.alphaValue = canEdit ? 1 : 0.70
        }
        popupControls.forEach {
            $0.isEnabled = canEdit
            $0.alphaValue = canEdit ? 1 : 0.70
        }
        isUpdating = false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commit()
    }

    func textDidEndEditing(_ notification: Notification) {
        commit()
    }

    @objc private func popupChanged(_ sender: NSPopUpButton) {
        commit()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        commit()
    }

    private var textFields: [NSTextField] {
        [
            labelField,
            barsField,
            continuityField
        ]
    }

    private var comboFields: [NSComboBox] {
        [
            locationField,
            characterLeftField,
            characterMiddleField,
            characterRightField,
            propsField,
            focusField
        ]
    }

    private var suggestionMenuButtons: [NSButton] {
        [
            locationMenuButton,
            propsMenuButton,
            focusMenuButton
        ]
    }

    private var framingFacingPopups: [NSPopUpButton] {
        [
            characterLeftFacingPopup,
            characterMiddleFacingPopup,
            characterRightFacingPopup
        ]
    }

    private var popupControls: [NSPopUpButton] {
        [
            shotSizePopup,
            movementPopup,
            intentPopup,
            timeOfDayPopup,
            interiorExteriorPopup,
            weatherAtmospherePopup,
            lightSourcePopup,
            lensPopup,
            cameraAnglePopup,
            depthOfFieldPopup,
            characterLeftFacingPopup,
            characterMiddleFacingPopup,
            characterRightFacingPopup
        ]
    }

    private func configureTextField(_ field: NSTextField) {
        field.delegate = self
        field.font = .systemFont(ofSize: 11, weight: .regular)
        field.textColor = NSColor.white.withAlphaComponent(0.88)
        field.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        field.drawsBackground = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        addSubview(field)
    }

    private func configureMultilineTextView(_ textView: NSTextView, in scrollView: NSScrollView) {
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .lineBorder
        scrollView.documentView = textView
        addSubview(scrollView)

        textView.delegate = self
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NSSize(width: 6, height: 5)
        textView.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        textView.drawsBackground = true
        textView.font = .systemFont(ofSize: 11, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.88)
        textView.insertionPointColor = .white
    }

    private func configureComboBox(_ field: NSComboBox) {
        field.delegate = self
        field.completes = true
        field.usesDataSource = false
        field.numberOfVisibleItems = 8
        field.font = .systemFont(ofSize: 11, weight: .regular)
        field.textColor = NSColor.white.withAlphaComponent(0.88)
        field.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        field.drawsBackground = true
        field.isBordered = true
        field.focusRingType = .none
        field.target = self
        field.action = #selector(comboAction(_:))
        addSubview(field)
    }

    private func configureSuggestionMenuButton(_ button: NSButton) {
        button.title = ""
        button.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Show suggestions")
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Show suggestions"
        button.font = .systemFont(ofSize: 10, weight: .semibold)
        button.bezelStyle = .rounded
        button.isBordered = true
        button.focusRingType = .none
        button.target = self
        button.action = #selector(showSuggestionMenu(_:))
        addSubview(button)
    }

    private func layoutSuggestionCombo(_ combo: NSComboBox, menuButton: NSButton, frame: NSRect) {
        let buttonWidth = min(CGFloat(28), max(CGFloat(22), frame.width * 0.28))
        let spacing: CGFloat = 4
        combo.frame = NSRect(
            x: frame.minX,
            y: frame.minY,
            width: max(36, frame.width - buttonWidth - spacing),
            height: frame.height
        )
        menuButton.frame = NSRect(
            x: combo.frame.maxX + spacing,
            y: frame.minY,
            width: buttonWidth,
            height: frame.height
        )
    }

    private func layoutCharacterFramingRow(_ frame: NSRect) {
        let spacing: CGFloat = 6
        let labelHeight: CGFloat = 12
        let fieldY = frame.minY + labelHeight + 3
        let fieldHeight = CGFloat(22)
        let facingY = fieldY + fieldHeight + 4
        let facingHeight = max(CGFloat(20), frame.maxY - facingY)
        let columnWidth = max(CGFloat(32), (frame.width - spacing * 2) / 3)
        let fields = [characterLeftField, characterMiddleField, characterRightField]
        let facings = framingFacingPopups
        for index in 0..<fields.count {
            let x = frame.minX + CGFloat(index) * (columnWidth + spacing)
            let width = index == fields.count - 1 ? frame.maxX - x : columnWidth
            characterPositionLabels[index].frame = NSRect(
                x: x,
                y: frame.minY,
                width: width,
                height: labelHeight
            )
            fields[index].frame = NSRect(
                x: x,
                y: fieldY,
                width: max(28, width),
                height: fieldHeight
            )
            facings[index].frame = NSRect(
                x: x,
                y: facingY,
                width: max(28, width),
                height: facingHeight
            )
        }
    }

    private func layoutSettingRow(_ frame: NSRect) {
        let spacing: CGFloat = 6
        let columnWidth = max(CGFloat(32), (frame.width - spacing) / 2)
        timeOfDayPopup.frame = NSRect(
            x: frame.minX,
            y: frame.minY,
            width: columnWidth,
            height: frame.height
        )
        interiorExteriorPopup.frame = NSRect(
            x: timeOfDayPopup.frame.maxX + spacing,
            y: frame.minY,
            width: max(28, frame.maxX - timeOfDayPopup.frame.maxX - spacing),
            height: frame.height
        )
    }

    private func layoutEnvironmentRow(_ frame: NSRect) {
        let spacing: CGFloat = 6
        let columnWidth = max(CGFloat(32), (frame.width - spacing) / 2)
        weatherAtmospherePopup.frame = NSRect(
            x: frame.minX,
            y: frame.minY,
            width: columnWidth,
            height: frame.height
        )
        lightSourcePopup.frame = NSRect(
            x: weatherAtmospherePopup.frame.maxX + spacing,
            y: frame.minY,
            width: max(28, frame.maxX - weatherAtmospherePopup.frame.maxX - spacing),
            height: frame.height
        )
    }

    private func layoutOpticsRow(_ frame: NSRect) {
        let spacing: CGFloat = 6
        let columnWidth = max(CGFloat(32), (frame.width - spacing * 2) / 3)
        lensPopup.frame = NSRect(
            x: frame.minX,
            y: frame.minY,
            width: columnWidth,
            height: frame.height
        )
        cameraAnglePopup.frame = NSRect(
            x: lensPopup.frame.maxX + spacing,
            y: frame.minY,
            width: columnWidth,
            height: frame.height
        )
        depthOfFieldPopup.frame = NSRect(
            x: cameraAnglePopup.frame.maxX + spacing,
            y: frame.minY,
            width: max(28, frame.maxX - cameraAnglePopup.frame.maxX - spacing),
            height: frame.height
        )
    }

    private func configurePopup(_ popup: NSPopUpButton, options: [String]) {
        popup.font = .systemFont(ofSize: 11, weight: .regular)
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        popup.addItems(withTitles: options.map { $0.isEmpty ? "Unset" : $0 })
        addSubview(popup)
    }

    private func setPopupValue(_ popup: NSPopUpButton, value: String, options: [String]) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        popup.removeAllItems()
        popup.addItems(withTitles: options.map { $0.isEmpty ? "Unset" : $0 })
        if !value.isEmpty, !options.contains(value) {
            popup.addItem(withTitle: value)
        }
        popup.selectItem(withTitle: value.isEmpty ? "Unset" : value)
    }

    private func setComboItems(_ combo: NSComboBox, suggestions: [String]) {
        combo.removeAllItems()
        combo.addItems(withObjectValues: suggestions)
    }

    @objc private func comboAction(_ sender: NSComboBox) {
        commit()
    }

    @objc private func showSuggestionMenu(_ sender: NSButton) {
        guard sender.isEnabled else { return }
        let kind: SuggestionKind
        if sender === locationMenuButton {
            kind = .location
        } else if sender === propsMenuButton {
            kind = .props
        } else {
            kind = .focus
        }

        let menu = NSMenu()
        for suggestion in suggestions(for: kind) {
            let item = SuggestionMenuItem(title: suggestion, kind: kind, value: suggestion)
            item.target = self
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let item = NSMenuItem(title: "No suggestions yet", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }

    @objc private func suggestionMenuItemSelected(_ sender: SuggestionMenuItem) {
        guard !isUpdating else { return }
        switch sender.kind {
        case .location:
            locationField.stringValue = sender.suggestionValue
        case .characters:
            characterMiddleField.stringValue = sender.suggestionValue
        case .props:
            appendSuggestion(sender.suggestionValue, to: propsField)
        case .focus:
            focusField.stringValue = sender.suggestionValue
        }
        commit()
    }

    func activateControl(at point: NSPoint) -> Bool {
        guard bounds.contains(point) else { return false }
        for button in suggestionMenuButtons where button.frame.contains(point) {
            button.performClick(nil)
            return true
        }
        for popup in popupControls where popup.frame.contains(point) {
            popup.performClick(nil)
            return true
        }
        for combo in comboFields where combo.frame.contains(point) {
            window?.makeFirstResponder(combo)
            combo.selectText(nil)
            return true
        }
        for field in textFields where field.frame.contains(point) {
            field.selectText(nil)
            return true
        }
        if directionScrollView.frame.contains(point) {
            window?.makeFirstResponder(directionTextView)
            return true
        }
        if notesScrollView.frame.contains(point) {
            window?.makeFirstResponder(notesTextView)
            return true
        }
        for (index, label) in rowLabels.enumerated() where label.frame.insetBy(dx: -8, dy: -4).contains(point) {
            activateRow(at: index)
            return true
        }
        return false
    }

    private func controlHit(at point: NSPoint) -> NSView? {
        for button in suggestionMenuButtons where button.frame.contains(point) {
            return button
        }
        for popup in popupControls where popup.frame.contains(point) {
            return popup
        }
        for combo in comboFields where combo.frame.contains(point) {
            return combo
        }
        for field in textFields where field.frame.contains(point) {
            return field
        }
        if directionScrollView.frame.contains(point) {
            return directionScrollView
        }
        if notesScrollView.frame.contains(point) {
            return notesScrollView
        }
        for (index, label) in rowLabels.enumerated() where label.frame.insetBy(dx: -8, dy: -4).contains(point) {
            return controlForRow(at: index)
        }
        return nil
    }

    private func activateRow(at index: Int) {
        guard let control = controlForRow(at: index) else { return }
        if let popup = control as? NSPopUpButton {
            popup.performClick(nil)
        } else {
            window?.makeFirstResponder(control)
        }
    }

    private func controlForRow(at index: Int) -> NSView? {
        switch index {
        case 0: return labelField
        case 1: return directionScrollView
        case 2: return locationField
        case 3: return timeOfDayPopup
        case 4: return weatherAtmospherePopup
        case 5: return characterMiddleField
        case 6: return propsField
        case 7: return shotSizePopup
        case 8: return lensPopup
        case 9: return movementPopup
        case 10: return focusField
        case 11: return intentPopup
        case 12: return barsField
        case 13: return continuityField
        case 14: return notesScrollView
        default: return nil
        }
    }

    private func suggestions(for kind: SuggestionKind) -> [String] {
        switch kind {
        case .location:
            return locationSuggestions
        case .characters:
            return characterSuggestions
        case .props:
            return propSuggestions
        case .focus:
            return focusSuggestions
        }
    }

    private func appendSuggestion(_ value: String, to combo: NSComboBox) {
        let existing = combo.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !existing.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { return }
        combo.stringValue = (existing + [value]).joined(separator: ", ")
    }

    private func commit() {
        guard !isUpdating, let shotID else { return }
        let updated = ScriptShotMarkup.replacementCard(
            from: currentCard,
            label: labelField.stringValue,
            direction: directionTextView.string,
            shotSize: selectedPopupValue(shotSizePopup),
            movement: selectedPopupValue(movementPopup),
            focus: focusField.stringValue,
            intent: selectedPopupValue(intentPopup),
            bars: barsField.stringValue,
            notes: notesTextView.string,
            timeOfDay: selectedPopupValue(timeOfDayPopup),
            interiorExterior: selectedPopupValue(interiorExteriorPopup),
            weatherAtmosphere: selectedPopupValue(weatherAtmospherePopup),
            lightSource: selectedPopupValue(lightSourcePopup),
            lens: selectedPopupValue(lensPopup),
            cameraAngle: selectedPopupValue(cameraAnglePopup),
            depthOfField: selectedPopupValue(depthOfFieldPopup),
            continuityNotes: continuityField.stringValue,
            characters: "",
            characterLeft: characterLeftField.stringValue,
            characterMiddle: characterMiddleField.stringValue,
            characterRight: characterRightField.stringValue,
            characterLeftFacing: selectedPopupValue(characterLeftFacingPopup),
            characterMiddleFacing: selectedPopupValue(characterMiddleFacingPopup),
            characterRightFacing: selectedPopupValue(characterRightFacingPopup),
            places: locationField.stringValue,
            props: propsField.stringValue,
            mood: currentCard.tags.mood.joined(separator: ", "),
            lighting: currentCard.tags.lighting.joined(separator: ", "),
            landmarks: currentCard.tags.landmarks.joined(separator: ", ")
        )
        currentCard = updated
        onCommit?(shotID, updated)
    }

    private func directionText(for shot: StructuredShotSpan) -> String {
        shot.card.direction.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func characterFramingStrings(for card: ScriptShotCard) -> (left: String, middle: String, right: String) {
        let framing = card.characterFraming
        if !framing.isEmpty {
            return (
                framing.left.joined(separator: ", "),
                framing.middle.joined(separator: ", "),
                framing.right.joined(separator: ", ")
            )
        }
        return ("", card.tags.characters.joined(separator: ", "), "")
    }

    private func selectedPopupValue(_ popup: NSPopUpButton) -> String {
        let title = popup.selectedItem?.title ?? ""
        return title == "Unset" ? "" : title
    }

    private func barsString(_ timing: TimingSpec) -> String {
        if let start = timing.startBar, let end = timing.endBar {
            return "\(start)-\(end)"
        }
        if let start = timing.startBar {
            return "\(start)"
        }
        return ""
    }
}

@available(macOS 26.0, *)
@MainActor
private final class StructuredShotTimelineView: NSView {
    enum HandleKind {
        case start
        case end
        case move
        case toggle
    }

    struct HandleRegion {
        var kind: HandleKind
        var shotID: UUID
        var frame: NSRect
    }

    private struct ShotLayout {
        var shot: StructuredShotSpan
        var cardFrame: NSRect
        var startY: CGFloat
        var endY: CGFloat
        var suspect: Bool
    }

    weak var textView: NSTextView?
    var document = StructuredScriptDocument() {
        didSet {
            if oldValue != document {
                normalizedDocument = document.recomputingShotExtents()
                invalidateCachedLayout()
            }
        }
    }
    var showsShotColumn = true {
        didSet {
            if oldValue != showsShotColumn {
                invalidateCachedLayout()
            }
        }
    }
    var expandedShotIDs: Set<String> = [] {
        didSet {
            if oldValue != expandedShotIDs {
                invalidateCachedLayout()
            }
        }
    }
    var allowsEditing = false
    var allowsCardEditing = false
    var accentColor = NSColor(calibratedRed: 0.76, green: 0.62, blue: 0.88, alpha: 1)
    var fieldSuggestions = StructuredShotFieldSuggestions()
    var onToggleShot: ((UUID) -> Void)?
    var onMoveShotStart: ((UUID, Int) -> Void)?
    var onMoveShotEnd: ((UUID, Int) -> Void)?
    var onRemoveShot: ((UUID) -> Void)?
    var onChangeShotCard: ((UUID, ScriptShotCard) -> Void)?
    var onAddShotCard: ((Int) -> Void)?
    var yForOffset: ((Int) -> CGFloat?)?
    var yForAnchor: ((Int, Int) -> CGFloat?)?
    var offsetForY: ((CGFloat) -> Int?)?

    private var editorViews: [UUID: StructuredShotCardEditorView] = [:]
    private var activeRegion: HandleRegion?
    private var mouseDownPoint: NSPoint?
    private var previewY: CGFloat?
    private var pendingRemoveShotID: UUID?
    private var normalizedDocument = StructuredScriptDocument()
    private var cachedShotLayouts: [ShotLayout] = []
    private var cachedLayoutWidth: CGFloat = -1
    private var isShotLayoutDirty = true

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard showsShotColumn, bounds.contains(point) else { return nil }
        for subview in subviews.reversed() {
            let converted = subview.convert(point, from: self)
            if let hit = subview.hitTest(converted) {
                return hit
            }
        }
        return handleRegion(at: point) == nil ? nil : self
    }

    override func layout() {
        super.layout()
        syncExpandedEditors(layouts: shotLayouts())
    }

    override func resetCursorRects() {
        guard showsShotColumn else { return }
        for region in handleRegions() {
            addCursorRect(region.frame, cursor: cursor(for: region.kind))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsShotColumn else { return }

        drawTimelineRail()
        let layouts = shotLayouts()
        for layout in layouts {
            drawConnector(for: layout)
            drawShotCard(layout)
        }
        if let previewY {
            drawPreviewLine(y: previewY)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for view in editorViews.values {
            guard view.frame.contains(point) else { continue }
            let editorPoint = view.convert(point, from: self)
            if view.activateControl(at: editorPoint) {
                activeRegion = nil
                mouseDownPoint = nil
                return
            }
        }
        activeRegion = handleRegion(at: point)
        mouseDownPoint = point
        if let activeRegion {
            cursor(for: activeRegion.kind).set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let activeRegion, activeRegion.kind != .toggle else { return }
        cursor(for: activeRegion.kind).set()
        let point = convert(event.locationInWindow, from: nil)
        previewY = min(max(point.y, 0), max(bounds.height, requiredHeight()))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        defer {
            activeRegion = nil
            mouseDownPoint = nil
            previewY = nil
            needsDisplay = true
        }

        guard let region = activeRegion else { return }
        if region.kind == .toggle {
            onToggleShot?(region.shotID)
            return
        }

        let downPoint = mouseDownPoint ?? point
        let dragged = hypot(point.x - downPoint.x, point.y - downPoint.y) >= 4
        if !dragged {
            return
        }
        guard dragged,
              allowsEditing,
              let offset = characterOffset(atTimelineY: point.y) else { return }

        switch region.kind {
        case .start, .move:
            onMoveShotStart?(region.shotID, offset)
        case .end:
            onMoveShotEnd?(region.shotID, offset)
        case .toggle:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()

        if allowsEditing,
           let region = handleRegion(at: point) {
            pendingRemoveShotID = region.shotID
            let remove = NSMenuItem(
                title: "Remove Shot",
                action: #selector(removeShotFromMenu(_:)),
                keyEquivalent: ""
            )
            remove.target = self
            menu.addItem(remove)
        }

        let add = NSMenuItem(
            title: "Add Shot Card",
            action: #selector(addShotFromMenu(_:)),
            keyEquivalent: ""
        )
        add.target = self
        add.representedObject = characterOffset(atTimelineY: point.y) ?? 0
        menu.addItem(add)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func removeShotFromMenu(_ sender: Any?) {
        if let pendingRemoveShotID {
            onRemoveShot?(pendingRemoveShotID)
        }
        pendingRemoveShotID = nil
    }

    @objc private func addShotFromMenu(_ sender: NSMenuItem) {
        onAddShotCard?(sender.representedObject as? Int ?? 0)
    }

    func requiredHeight() -> CGFloat {
        guard showsShotColumn else { return 0 }
        let maxCardY = shotLayouts().map(\.cardFrame.maxY).max() ?? 0
        return ceil(maxCardY + 12)
    }

    func characterOffsetForInsertion(atTimelineY y: CGFloat) -> Int? {
        characterOffset(atTimelineY: y)
    }

    func invalidateCachedLayout() {
        isShotLayoutDirty = true
        cachedShotLayouts.removeAll()
        cachedLayoutWidth = -1
    }

    private func handleRegion(at point: NSPoint) -> HandleRegion? {
        handleRegions().reversed().first { $0.frame.contains(point) }
    }

    private func handleRegions() -> [HandleRegion] {
        guard showsShotColumn else { return [] }
        var regions: [HandleRegion] = []
        for layout in shotLayouts() {
            let card = layout.cardFrame
            let expanded = expandedShotIDs.contains(layout.shot.id.uuidString)
            regions.append(
                HandleRegion(
                    kind: .toggle,
                    shotID: layout.shot.id,
                    frame: NSRect(
                        x: card.minX,
                        y: card.minY,
                        width: card.width,
                        height: expanded ? 76 : card.height
                    )
                )
            )
            guard allowsEditing else { continue }
            regions.append(
                HandleRegion(
                    kind: .start,
                    shotID: layout.shot.id,
                    frame: NSRect(x: card.minX, y: card.minY - 3, width: card.width, height: 12)
                )
            )
            regions.append(
                HandleRegion(
                    kind: .move,
                    shotID: layout.shot.id,
                    frame: NSRect(x: card.maxX - 44, y: card.minY + 6, width: 36, height: 34)
                )
            )
            regions.append(
                HandleRegion(
                    kind: .end,
                    shotID: layout.shot.id,
                    frame: NSRect(x: card.minX, y: card.maxY - 8, width: card.width, height: 14)
                )
            )
        }
        return regions
    }

    private func cursor(for kind: HandleKind) -> NSCursor {
        switch kind {
        case .start, .end:
            return .resizeUpDown
        case .move:
            return .openHand
        case .toggle:
            return .pointingHand
        }
    }

    private func shotLayouts() -> [ShotLayout] {
        if !isShotLayoutDirty, abs(cachedLayoutWidth - bounds.width) <= 0.5 {
            return cachedShotLayouts
        }

        let normalized = normalizedDocument
        guard !normalized.shots.isEmpty else {
            cachedShotLayouts = []
            cachedLayoutWidth = bounds.width
            isShotLayoutDirty = false
            return []
        }
        let railX = timelineRailX
        let cardX = railX + 26
        let cardWidth = max(96, bounds.width - cardX - 8)
        var nextY: CGFloat = 4
        var layouts: [ShotLayout] = []

        for shot in normalized.shots {
            let startY = lineY(for: shot.startAnchor.offset, sourceOrder: shot.sourceOrder) ?? nextY
            let endY = lineY(for: shot.endAnchor.offset, sourceOrder: shot.sourceOrder + 1) ?? startY
            let expanded = expandedShotIDs.contains(shot.id.uuidString)
            let editorHeight = StructuredShotCardEditorView.preferredHeight(
                for: max(120, cardWidth - 48)
            )
            let cardHeight = expanded ? CGFloat(82 + editorHeight + 16) : CGFloat(76)
            let naturalY = max(4, startY - 12)
            let cardY = max(naturalY, nextY)
            let suspect = shot.startAnchor.offset >= shot.endAnchor.offset
                || shot.startAnchor.offset > normalized.visibleLength
                || shot.endAnchor.offset > normalized.visibleLength

            layouts.append(
                ShotLayout(
                    shot: shot,
                    cardFrame: NSRect(x: cardX, y: cardY, width: cardWidth, height: cardHeight),
                    startY: startY,
                    endY: max(endY, startY),
                    suspect: suspect
                )
            )
            nextY = cardY + cardHeight + 8
        }
        cachedShotLayouts = layouts
        cachedLayoutWidth = bounds.width
        isShotLayoutDirty = false
        return layouts
    }

    private var timelineRailX: CGFloat {
        18
    }

    var timelineRailXInLocalCoordinates: CGFloat {
        timelineRailX
    }

    private func lineY(for offset: Int, sourceOrder: Int) -> CGFloat? {
        if let y = yForAnchor?(offset, sourceOrder) {
            return y
        }
        if let y = yForOffset?(offset) {
            return y
        }
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let length = (textView.string as NSString).length
        guard length > 0 else { return textView.textContainerOrigin.y }
        let characterIndex = max(0, min(offset, length - 1))
        let glyphIndex = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let rect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        return rect.midY + textView.textContainerOrigin.y
    }

    private func characterOffset(atTimelineY y: CGFloat) -> Int? {
        if let offset = offsetForY?(y) {
            return offset
        }
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let length = (textView.string as NSString).length
        guard length > 0 else { return 0 }

        var textPoint = NSPoint(x: textView.textContainerOrigin.x + 2, y: y)
        textPoint.x -= textView.textContainerOrigin.x
        textPoint.y -= textView.textContainerOrigin.y
        let offset = layoutManager.characterIndex(
            for: textPoint,
            in: textContainer,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        return max(0, min(offset, length))
    }

    private func drawTimelineRail() {
        let rail = NSBezierPath()
        rail.move(to: NSPoint(x: timelineRailX, y: 0))
        rail.line(to: NSPoint(x: timelineRailX, y: max(bounds.height, requiredHeight())))
        NSColor.white.withAlphaComponent(0.14).setStroke()
        rail.lineWidth = 1
        rail.stroke()
    }

    private func drawConnector(for layout: ShotLayout) {
        let y = layout.startY
        let dotRect = NSRect(x: timelineRailX - 2, y: y - 2, width: 4, height: 4)
        NSColor.white.withAlphaComponent(layout.suspect ? 0.70 : 0.42).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        let connector = NSBezierPath()
        connector.move(to: NSPoint(x: timelineRailX + 4, y: y))
        connector.line(to: NSPoint(x: layout.cardFrame.minX - 8, y: y))
        NSColor.white.withAlphaComponent(layout.suspect ? 0.48 : 0.24).setStroke()
        connector.lineWidth = 1
        connector.stroke()
    }

    private func drawShotCard(_ layout: ShotLayout) {
        let frame = layout.cardFrame
        let cardPath = NSBezierPath(roundedRect: frame, xRadius: 7, yRadius: 7)
        NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
        cardPath.fill()

        (layout.suspect
            ? NSColor(calibratedRed: 0.88, green: 0.62, blue: 0.20, alpha: 0.68)
            : accentColor.withAlphaComponent(0.28)
        ).setStroke()
        cardPath.lineWidth = 1
        cardPath.stroke()

        drawCardHandleLines(in: frame, suspect: layout.suspect)
        drawCardHeader(layout.shot, in: frame)
    }

    private func syncExpandedEditors(layouts: [ShotLayout]? = nil) {
        guard showsShotColumn else {
            subviews.forEach { $0.removeFromSuperview() }
            editorViews.removeAll()
            return
        }
        let layouts = layouts ?? shotLayouts()
        let expandedLayouts = layouts.filter {
            expandedShotIDs.contains($0.shot.id.uuidString)
        }
        let expandedIDs = Set(expandedLayouts.map { $0.shot.id })

        for (id, view) in editorViews where !expandedIDs.contains(id) {
            view.removeFromSuperview()
        }
        editorViews = editorViews.filter { expandedIDs.contains($0.key) }

        for layout in expandedLayouts {
            let view = editorViews[layout.shot.id] ?? StructuredShotCardEditorView()
            if editorViews[layout.shot.id] == nil {
                editorViews[layout.shot.id] = view
                addSubview(view)
            }
            let shot = shotForEditor(layout.shot)
            view.frame = editorFrame(in: layout.cardFrame)
            view.configure(
                shot: shot,
                suggestions: fieldSuggestions,
                canEdit: allowsCardEditing,
                onCommit: { [weak self] id, card in
                    self?.onChangeShotCard?(id, card)
                }
            )
        }
    }

    private func editorFrame(in cardFrame: NSRect) -> NSRect {
        NSRect(
            x: cardFrame.minX + 34,
            y: cardFrame.minY + 82,
            width: max(120, cardFrame.width - 48),
            height: max(120, cardFrame.height - 94)
        )
    }

    private func shotForEditor(_ shot: StructuredShotSpan) -> StructuredShotSpan {
        var copy = shot
        let existingDirection = copy.card.direction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard existingDirection.isEmpty else { return copy }
        let shotActions = actionSummaries(for: shot)
        guard !shotActions.isEmpty else { return copy }
        copy.card.direction = shotActions.joined(separator: "\n")
        return copy
    }

    private func drawCardHandleLines(in frame: NSRect, suspect: Bool) {
        let handleColor = suspect
            ? NSColor(calibratedRed: 0.88, green: 0.62, blue: 0.20, alpha: 0.40)
            : NSColor.white.withAlphaComponent(0.16)
        handleColor.setStroke()

        let top = NSBezierPath()
        top.move(to: NSPoint(x: frame.minX, y: frame.minY + 1))
        top.line(to: NSPoint(x: frame.maxX, y: frame.minY + 1))
        top.lineWidth = 1
        top.stroke()

        let bottom = NSBezierPath()
        bottom.move(to: NSPoint(x: frame.minX, y: frame.maxY - 1))
        bottom.line(to: NSPoint(x: frame.maxX, y: frame.maxY - 1))
        bottom.lineWidth = 1
        bottom.stroke()

        let gripX = frame.maxX - 27
        for index in 0..<3 {
            let grip = NSBezierPath()
            let y = frame.minY + 17 + CGFloat(index * 5)
            grip.move(to: NSPoint(x: gripX, y: y))
            grip.line(to: NSPoint(x: gripX + 13, y: y))
            grip.lineWidth = 1
            grip.stroke()
        }
    }

    private func drawCardHeader(_ shot: StructuredShotSpan, in frame: NSRect) {
        let expanded = expandedShotIDs.contains(shot.id.uuidString)
        let symbolName = expanded ? "chevron.down" : "chevron.right"
        if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
                .applying(.init(hierarchicalColor: NSColor.white.withAlphaComponent(0.62)))
            let configured = symbol.withSymbolConfiguration(config)
            configured?.draw(at: NSPoint(x: frame.minX + 12, y: frame.minY + 18),
                            from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        drawText(
            "SHOT",
            at: NSPoint(x: frame.minX + 36, y: frame.minY + 9),
            font: .monospacedSystemFont(ofSize: 9.5, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.38)
        )
        drawText(
            headline(for: shot.card),
            in: NSRect(x: frame.minX + 36, y: frame.minY + 23, width: max(24, frame.width - 72), height: 22),
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: NSColor.white.withAlphaComponent(0.86)
        )
        let subline = subline(for: shot)
        if !subline.isEmpty {
            drawText(
                subline,
                in: NSRect(x: frame.minX + 36, y: frame.minY + 50, width: max(24, frame.width - 52), height: 18),
                font: .systemFont(ofSize: 12, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.48)
            )
        }
    }

    private func drawExpandedMetadata(_ shot: StructuredShotSpan, in frame: NSRect) {
        let lines = metadataLines(for: shot)
        var y = frame.minY + 84
        for line in lines.prefix(5) {
            drawText(
                line,
                in: NSRect(x: frame.minX + 36, y: y, width: max(24, frame.width - 52), height: 18),
                font: .systemFont(ofSize: 12, weight: .regular),
                color: NSColor.white.withAlphaComponent(0.64)
            )
            y += 19
        }
    }

    private func drawPreviewLine(y: CGFloat) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: y))
        path.line(to: NSPoint(x: bounds.width, y: y))
        NSColor(calibratedRed: 0.82, green: 0.63, blue: 0.28, alpha: 0.72).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawText(
        _ string: String,
        at point: NSPoint,
        font: NSFont,
        color: NSColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        (string as NSString).draw(at: point, withAttributes: attributes)
    }

    private func drawText(
        _ string: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (string as NSString).draw(in: rect, withAttributes: attributes)
    }

    private func headline(for card: ScriptShotCard) -> String {
        if let label = nonEmpty(card.label) { return label }
        if let label = nonEmpty(card.camera.label) { return label }
        if let shotSize = nonEmpty(card.camera.shotSize) {
            return shotSize.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if let movement = nonEmpty(card.camera.movement) {
            return movement.replacingOccurrences(of: "_", with: " ").capitalized
        }
        if let notes = nonEmpty(card.camera.notes) { return notes }
        return "Direction"
    }

    private func subline(for shot: StructuredShotSpan) -> String {
        var parts = [
            nonEmpty(shot.card.camera.shotSize),
            nonEmpty(shot.card.camera.movement),
            nonEmpty(shot.card.camera.focus).map { "on \($0)" },
            nonEmpty(shot.card.camera.intent),
            barsString(shot.card.timing).map { "bars \($0)" }
        ]
        .compactMap { $0 }
        let actionCount = actionSummaries(for: shot).count
        if actionCount > 0 {
            parts.append(actionCount == 1 ? "1 action" : "\(actionCount) actions")
        }
        return parts.joined(separator: "  |  ")
    }

    private func metadataLines(for shot: StructuredShotSpan) -> [String] {
        var lines: [String] = []
        let card = shot.card
        if let notes = nonEmpty(card.camera.notes) {
            lines.append("Notes: \(notes)")
        }
        if let focus = nonEmpty(card.camera.focus) {
            lines.append("Focus: \(focus)")
        }
        for action in actionSummaries(for: shot).prefix(3) {
            lines.append("Action: \(action)")
        }
        if !card.tags.characters.isEmpty {
            lines.append("Characters: \(card.tags.characters.joined(separator: ", "))")
        }
        if !card.tags.props.isEmpty {
            lines.append("Props: \(card.tags.props.joined(separator: ", "))")
        }
        if lines.isEmpty {
            lines.append("No additional metadata")
        }
        return lines
    }

    private func actionSummaries(for shot: StructuredShotSpan) -> [String] {
        let start = shot.startAnchor.offset
        let end = max(start, shot.endAnchor.offset)
        return document.hiddenMarkup
            .filter { markup in
                markup.kind == .action
                    && StructuredScriptDocumentProjector.isShotDirectionActionMarkup(markup.rawMarkup)
                    && markup.anchor.offset >= start
                    && (markup.anchor.offset < end || end == start)
            }
            .sorted {
                if $0.anchor.offset == $1.anchor.offset {
                    return $0.sourceOrder < $1.sourceOrder
                }
                return $0.anchor.offset < $1.anchor.offset
            }
            .map { StructuredScriptDocumentProjector.actionDisplayText(from: $0.rawMarkup) }
    }

    private func actionSummary(from rawMarkup: String) -> String {
        guard let parsed = BracketDSLParser.parse(rawMarkup) else {
            return rawMarkup
                .replacingOccurrences(of: "[", with: "")
                .replacingOccurrences(of: "]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let tag = cleanToken(parsed.tag)
        let subject = cleanToken(parsed.primary)
        let description = parsed.parameters["description"].map(cleanToken)
        if let description, !description.isEmpty {
            return subject.isEmpty ? description : "\(subject): \(description)"
        }
        if tag.caseInsensitiveCompare("action") != .orderedSame, !tag.isEmpty {
            return subject.isEmpty ? tag : "\(tag): \(subject)"
        }
        return subject.isEmpty ? "Action cue" : subject
    }

    private func cleanToken(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private func barsString(_ timing: TimingSpec) -> String? {
        if let start = timing.startBar, let end = timing.endBar {
            return "\(start)-\(end)"
        }
        if let start = timing.startBar {
            return "\(start)"
        }
        return nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
