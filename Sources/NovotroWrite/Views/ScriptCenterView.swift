import SwiftUI
import AppKit
import NovotroProjectKit

// MARK: - Center Content

@available(macOS 26.0, *)
struct ScriptCenterView: View {
    @Bindable var store: ScriptStore
    var showScratchpad: Bool = false

    var body: some View {
        if store.librettoFiles.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("No script content")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Open a project to view the combined script")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScriptScrollContent(
                store: store,
                showScratchpad: showScratchpad
            )
        }
    }
}

// MARK: - Scrollable Script Body

@available(macOS 26.0, *)
struct ScriptScrollContent: View {
    @Bindable var store: ScriptStore
    var showScratchpad: Bool
    @AppStorage("novotro.write.scratchpad.width") private var scratchpadWidth: Double = 340

    private var displayNamesByPath: [String: String] {
        Dictionary(uniqueKeysWithValues: store.songAssets.map { ($0.relativePath, $0.displayName) })
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.librettoFiles.enumerated()), id: \.element.id) { index, libretto in
                            ScriptSectionRowView(
                                index: index,
                                displayName: displayNamesByPath[libretto.relativePath] ?? libretto.displayName,
                                path: libretto.relativePath,
                                store: store,
                                showScratchpad: showScratchpad,
                                scratchpadWidth: scratchpadWidth
                            )
                            .id(libretto.relativePath)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: SectionVisibilityKey.self,
                                        value: [SectionVisibility(
                                            path: libretto.relativePath,
                                            minY: geo.frame(in: .named("scriptScroll")).minY,
                                            maxY: geo.frame(in: .named("scriptScroll")).maxY
                                        )]
                                    )
                                }
                            )
                        }

                        Spacer().frame(height: 200)
                    }
                    .padding(.horizontal, showScratchpad ? 28 : 40)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
                .coordinateSpace(name: "scriptScroll")
                .background(Color.black)
                .onPreferenceChange(SectionVisibilityKey.self) { sections in
                    self.updateActiveSection(from: sections)
                }
                .onChange(of: store.scrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        store.scrollTarget = nil
                    }
                }
            }
        }
    }

    private func updateActiveSection(from sections: [SectionVisibility]) {
        guard !sections.isEmpty else { return }
        guard sections.contains(where: { $0.maxY > 0 }) else { return }

        let scrollOffset: CGFloat = 100
        var best: String?
        var bestScore: CGFloat = .infinity

        for section in sections {
            guard section.maxY > scrollOffset else { continue }

            let sectionTop = section.minY
            let distanceFromTop = abs(sectionTop - scrollOffset)
            let score = distanceFromTop

            if score < bestScore {
                best = section.path
                bestScore = score
            }
        }

        if best == nil {
            best = sections.first { $0.maxY > scrollOffset }?.path
        }

        if let best, best != store.activeSongPath {
            store.activeSongPath = best
        }
    }
}

@available(macOS 26.0, *)
private struct ScriptSectionRowView: View {
    let index: Int
    let displayName: String
    let path: String
    @Bindable var store: ScriptStore
    let showScratchpad: Bool
    let scratchpadWidth: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if index > 0 {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 1)
                    .padding(.vertical, 16)
            }

            HStack(alignment: .top, spacing: 24) {
                ScriptSectionView(
                    index: index,
                    displayName: displayName,
                    path: path,
                    store: store
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)

                if showScratchpad {
                    ScriptScratchpadSectionView(
                        displayName: displayName,
                        path: path,
                        store: store
                    )
                    .frame(width: scratchpadWidth, alignment: .topLeading)
                }
            }
        }
    }
}

// MARK: - Script Section (Editable)

@available(macOS 26.0, *)
struct ScriptSectionView: View {
    let index: Int
    let displayName: String
    let path: String
    @Bindable var store: ScriptStore

    @State private var localText: String = ""
    @State private var hasLoaded: Bool = false
    @State private var editorHeight: CGFloat = 60
    @State private var suppressWriteBack: Bool = false
    @State private var glowOpacity: Double = 0
    
    // Track external change highlighting
    @State private var externalChangeRanges: [NSRange] = []
    @State private var externalChangeHighlightOpacity: Double = 0
    @State private var preChangeText: String = ""

    private var isPreviewingThisSection: Bool {
        store.previewingSongPath == path && store.previewingVersionID != nil
    }

    private var previewLyrics: String? {
        guard isPreviewingThisSection,
              let versionID = store.previewingVersionID,
              let asset = store.songAssets.first(where: { $0.relativePath == path }),
              let version = asset.document.versions.first(where: { $0.id == versionID })
        else { return nil }
        return version.lyrics
    }

    private var hasPendingEdit: Bool {
        store.pendingAgentEdits[path] != nil
    }

    private var editorView: some View {
        ScriptTextEditor(
            text: $localText,
            reportedHeight: $editorHeight,
            showDirections: store.showDirections,
            showStoryboarding: store.showStoryboarding,
            showAnimateDirections: store.showAnimateDirections,
            pendingHighlightRanges: pendingDiffRanges,
            externalChangeRanges: externalChangeRanges,
            externalChangeOpacity: externalChangeHighlightOpacity
        )
    }

    private var editorContainer: some View {
        ZStack(alignment: .topLeading) {
            editorView
                .frame(height: max(40, editorHeight))
                .opacity(isPreviewingThisSection ? 0.15 : 1.0)
                .disabled(isPreviewingThisSection || hasPendingEdit)

            // Version preview overlay
            if let preview = previewLyrics {
                previewOverlay(content: preview)
            }
        }
    }

    private func previewOverlay(content: String) -> some View {
        Text(
            ScriptTextEditor.displayText(
                from: SynopsisEmbedding.stripForDisplay(content: content),
                showDirections: store.showDirections,
                showStoryboarding: store.showStoryboarding,
                showAnimateDirections: store.showAnimateDirections
            )
        )
        .font(.system(size: 13, weight: .regular, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.90))
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.80))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.5), lineWidth: 1.5)
        )
    }

    /// Compute NSRanges of changed lines between committed and pending text.
    private var pendingDiffRanges: [NSRange] {
        guard let pending = store.pendingAgentEdits[path] else { return [] }
        let committed = store.librettoFiles
            .first(where: { $0.relativePath == path })?.content ?? ""
        return Self.computeChangedLineRanges(original: committed, modified: pending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Scene heading
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("SCENE \(index + 1)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .tracking(2)

                Text(displayName)
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.85))

                if isPreviewingThisSection {
                    Text("PREVIEWING")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .tracking(1)
                }

                if hasPendingEdit {
                    Text("PENDING REVIEW")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.green)
                        .tracking(1)
                }
            }
            .padding(.bottom, 8)

            // Editable libretto (dimmed when previewing, read-only when pending)
            editorContainer
            .onAppear {
                if !hasLoaded {
                    let raw = store.librettoFiles
                        .first(where: { $0.relativePath == path })?.content ?? ""
                    localText = SynopsisEmbedding.stripForDisplay(content: raw)
                    hasLoaded = true
                }
            }
            .onChange(of: localText) { _, newValue in
                guard hasLoaded, !suppressWriteBack else { return }
                // Preserve the existing synopsis block when writing back editor changes
                let existingSynopsis = store.synopsis(forScenePath: path)
                let fullContent = SynopsisEmbedding.update(content: newValue, synopsis: existingSynopsis)
                let current = store.librettoFiles.first(where: { $0.relativePath == path })?.content ?? ""
                guard fullContent != current else { return }
                store.applyEditorChange(path: path, lyrics: fullContent)
            }
            .onChange(of: store.librettoFiles) { _, files in
                guard hasLoaded, !hasPendingEdit else { return }
                let raw = files.first(where: { $0.relativePath == path })?.content ?? ""
                let incoming = SynopsisEmbedding.stripForDisplay(content: raw)
                guard incoming != localText else { return }
                suppressWriteBack = true
                localText = incoming
                DispatchQueue.main.async {
                    suppressWriteBack = false
                }
            }
            .onChange(of: store.pendingAgentEdits) { _, edits in
                guard hasLoaded else { return }
                if let pending = edits[path] {
                    // Agent produced changes — show pending text with green highlights
                    let stripped = SynopsisEmbedding.stripForDisplay(content: pending)
                    guard stripped != localText else { return }
                    suppressWriteBack = true
                    localText = stripped
                    DispatchQueue.main.async {
                        suppressWriteBack = false
                    }
                } else if !edits.keys.contains(path) {
                    // Pending cleared (accept or reject) — restore committed text
                    let raw = store.librettoFiles
                        .first(where: { $0.relativePath == path })?.content ?? ""
                    let committed = SynopsisEmbedding.stripForDisplay(content: raw)
                    if localText != committed {
                        suppressWriteBack = true
                        localText = committed
                        DispatchQueue.main.async {
                            suppressWriteBack = false
                        }
                    }
                }
            }
            .onChange(of: store.externalChangeTimes) { _, times in
                guard times[path] != nil else { return }

                // Store the text before the change for diff computation
                let oldText = localText

                // Reload text from librettoFiles — onChange(of: librettoFiles) can miss
                // in-place element mutations with @Observable
                let raw = store.librettoFiles
                    .first(where: { $0.relativePath == path })?.content ?? ""
                let incoming = SynopsisEmbedding.stripForDisplay(content: raw)

                if incoming != localText {
                    suppressWriteBack = true
                    localText = incoming
                    DispatchQueue.main.async {
                        suppressWriteBack = false
                    }
                    
                    // Compute specific changed ranges
                    externalChangeRanges = ScriptTextEditor.computeChangedCharacterRanges(original: oldText, modified: incoming)
                    
                    // Apply yellow highlighting immediately
                    withAnimation(.easeIn(duration: 0.3)) {
                        externalChangeHighlightOpacity = 1.0
                    }
                    
                    // Keep highlighting visible for 10 minutes (600 seconds)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
                        withAnimation(.easeOut(duration: 1.0)) {
                            externalChangeHighlightOpacity = 0.0
                        }
                        // Clear ranges after fade out
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            externalChangeRanges = []
                        }
                    }
                }
                
                // Clean up the timestamp after a while (keep longer than highlight)
                DispatchQueue.main.asyncAfter(deadline: .now() + 630) {
                    store.externalChangeTimes.removeValue(forKey: path)
                }
            }
        }
        .onAppear {
            store.ensureSceneHydrated(path: path)
        }
    }

    // MARK: - Line-Level Diff

    /// Compute NSRanges of changed/inserted lines in the modified text.
    static func computeChangedLineRanges(original: String, modified: String) -> [NSRange] {
        let originalLines = original.components(separatedBy: "\n")
        let modifiedLines = modified.components(separatedBy: "\n")

        let diff = modifiedLines.difference(from: originalLines)

        // Collect indices of inserted/changed lines in the modified text
        var changedLineIndices = Set<Int>()
        for change in diff {
            switch change {
            case .insert(let offset, _, _):
                changedLineIndices.insert(offset)
            case .remove:
                break
            }
        }

        guard !changedLineIndices.isEmpty else { return [] }

        // Convert line indices to NSRanges in the modified string
        var ranges: [NSRange] = []
        var currentLocation = 0

        for (index, line) in modifiedLines.enumerated() {
            let lineLength = (line as NSString).length
            if changedLineIndices.contains(index) {
                let rangeLength = (index < modifiedLines.count - 1)
                    ? lineLength + 1
                    : lineLength
                if rangeLength > 0 {
                    ranges.append(NSRange(location: currentLocation, length: rangeLength))
                }
            }
            currentLocation += lineLength + 1 // +1 for newline
        }

        return ranges
    }
}

@available(macOS 26.0, *)
private struct ScriptScratchpadSectionView: View {
    let displayName: String
    let path: String
    @Bindable var store: ScriptStore

    @State private var localText: String = ""
    @State private var hasLoaded: Bool = false
    @State private var editorHeight: CGFloat = 120
    @State private var suppressWriteBack: Bool = false

    private var marker: String {
        store.scratchpadMarker(forPath: path)
    }

    private var hasContent: Bool {
        !localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("SCRATCHPAD")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.warning.opacity(0.9))
                    .tracking(1.4)

                Text(displayName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if hasContent {
                    OperaChromeStatusBadge(
                        text: "STAGED",
                        tint: OperaChromeTheme.warning
                    )
                }
            }

            Text(marker)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(OperaChromeTheme.textTertiary)
                .textSelection(.enabled)

            ZStack(alignment: .topLeading) {
                if localText.isEmpty {
                    Text("Stage scene-specific changes here before handing them to an LLM for commit.")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }

                ScriptTextEditor(
                    text: $localText,
                    reportedHeight: $editorHeight,
                    showDirections: store.showDirections,
                    showStoryboarding: store.showStoryboarding,
                    showAnimateDirections: store.showAnimateDirections
                )
                .frame(height: max(100, editorHeight))
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OperaChromeTheme.accentMuted, lineWidth: 1)
        )
        .onAppear {
            if !hasLoaded {
                localText = store.scratchpadText(forPath: path)
                hasLoaded = true
            }
        }
        .onChange(of: localText) { _, newValue in
            guard hasLoaded, !suppressWriteBack else { return }
            store.updateScratchpadText(forPath: path, text: newValue)
        }
        .onChange(of: store.scratchpadDocumentText) { _, _ in
            guard hasLoaded else { return }
            let incoming = store.scratchpadText(forPath: path)
            guard incoming != localText else { return }
            suppressWriteBack = true
            localText = incoming
            DispatchQueue.main.async {
                suppressWriteBack = false
            }
        }
    }
}

// MARK: - Script Text Editor (NSTextView wrapper)

@available(macOS 26.0, *)
struct ScriptTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var reportedHeight: CGFloat
    var showDirections: Bool
    var showStoryboarding: Bool
    var showAnimateDirections: Bool
    var pendingHighlightRanges: [NSRange] = []
    var externalChangeRanges: [NSRange] = []
    var externalChangeOpacity: Double = 0

    struct VisibleChunk: Equatable {
        let rawRange: NSRange
        let displayRange: NSRange
    }

    struct DisplayProjection: Equatable {
        let rawText: String
        let displayText: String
        let hiddenRanges: [NSRange]
        let visibleChunks: [VisibleChunk]
    }

    private struct DisplayEdit {
        let affectedRange: NSRange
        let replacementString: String
    }

    private enum BoundaryBias {
        case previous
        case next
    }

    private struct ChunkBoundary {
        let chunkIndex: Int
        let offset: Int
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ScriptTextHostView {
        let host = ScriptTextHostView()
        let coordinator = context.coordinator
        host.onHeightChanged = { [weak coordinator] newHeight in
            guard let coordinator else { return }
            DispatchQueue.main.async {
                coordinator.parent.reportedHeight = newHeight
            }
        }

        let textView = host.textView

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor.white.withAlphaComponent(0.85)
        textView.backgroundColor = .clear
        textView.insertionPointColor = .white
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor.white.withAlphaComponent(0.2),
            .foregroundColor: NSColor.white,
        ]
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: paragraphStyle,
        ]

        context.coordinator.hostView = host
        context.coordinator.currentRawText = text
        context.coordinator.lastShowDirections = showDirections
        context.coordinator.lastShowStoryboarding = showStoryboarding
        context.coordinator.lastShowAnimateDirections = showAnimateDirections
        context.coordinator.lastHighlightRanges = pendingHighlightRanges
        context.coordinator.lastExternalRanges = externalChangeRanges
        context.coordinator.lastExternalOpacity = externalChangeOpacity
        context.coordinator.refreshDisplay(to: textView, rawText: text)

        return host
    }

    func updateNSView(_ host: ScriptTextHostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        let textChanged = coordinator.currentRawText != text && !coordinator.isEditing
        let toggleChanged = coordinator.lastShowDirections != showDirections
            || coordinator.lastShowStoryboarding != showStoryboarding
            || coordinator.lastShowAnimateDirections != showAnimateDirections
        let highlightChanged = coordinator.lastHighlightRanges != pendingHighlightRanges
        let externalChanged = coordinator.lastExternalRanges != externalChangeRanges
            || coordinator.lastExternalOpacity != externalChangeOpacity

        if textChanged || toggleChanged || externalChanged {
            coordinator.lastShowDirections = showDirections
            coordinator.lastShowStoryboarding = showStoryboarding
            coordinator.lastShowAnimateDirections = showAnimateDirections
            coordinator.lastHighlightRanges = pendingHighlightRanges
            coordinator.lastExternalRanges = externalChangeRanges
            coordinator.lastExternalOpacity = externalChangeOpacity
            coordinator.refreshDisplay(to: host.textView, rawText: text)
        } else if highlightChanged {
            coordinator.lastHighlightRanges = pendingHighlightRanges
            coordinator.lastExternalRanges = externalChangeRanges
            coordinator.lastExternalOpacity = externalChangeOpacity
            coordinator.applyProjectedHighlights(to: host.textView)
        }
    }

    /// Apply direction markup styling to the visible display text only.
    /// Hidden content is fully omitted from the text view string.
    @discardableResult
    static func applyDirectionStyling(
        to textView: NSTextView,
        rawText: String? = nil,
        showDirections show: Bool,
        showStoryboarding: Bool = true,
        showAnimateDirections: Bool = true
    ) -> DisplayProjection {
        let sourceText = rawText ?? textView.string
        let projection = displayProjection(
            from: sourceText,
            showDirections: show,
            showStoryboarding: showStoryboarding,
            showAnimateDirections: showAnimateDirections
        )

        textView.undoManager?.disableUndoRegistration()
        defer { textView.undoManager?.enableUndoRegistration() }

        if textView.string != projection.displayText {
            textView.string = projection.displayText
        }

        guard let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage else { return projection }

        let nsString = textView.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

        let defaultStyle = NSMutableParagraphStyle()
        defaultStyle.lineSpacing = 5

        textStorage.beginEditing()
        if fullRange.length > 0 {
            textStorage.addAttribute(.paragraphStyle, value: defaultStyle, range: fullRange)
        }
        textStorage.endEditing()

        let directionRanges = Self.directionMarkupRanges(in: textView.string)
        if !directionRanges.isEmpty {
            let tealColor = NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.80, alpha: 0.70)
            for range in directionRanges {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: tealColor, forCharacterRange: range
                )
            }
        }

        let storyboardRanges = Self.mergedRanges(
            StoryboardPromptParser.promptRanges(in: textView.string)
                + Self.parentheticalStageDirectionRanges(in: textView.string)
        )
        if !storyboardRanges.isEmpty {
            let orangeColor = NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.25, alpha: 0.80)
            for range in storyboardRanges {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: orangeColor, forCharacterRange: range
                )
            }
        }

        let animateRanges = AnimatePromptParser.promptRanges(in: textView.string)
        if !animateRanges.isEmpty {
            let pinkColor = NSColor(calibratedRed: 0.85, green: 0.45, blue: 0.70, alpha: 0.80)
            for range in animateRanges {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: pinkColor, forCharacterRange: range
                )
            }
        }

        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.invalidateDisplay(forCharacterRange: fullRange)
        return projection
    }

    /// Find NSRanges of syllable count annotations like " (8)" at end of lines.
    private static let syllablePattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\s*\(\d+\)\s*$"#, options: .anchorsMatchLines)
    }()

    private static func syllableAnnotationRanges(in text: String) -> [NSRange] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        return syllablePattern.matches(in: text, range: fullRange).map(\.range)
    }

    /// Completely removes syllable annotations from text so they don't take up space.
    static func stripSyllableAnnotations(from text: String) -> String {
        let ranges = syllableAnnotationRanges(in: text)
        guard !ranges.isEmpty else { return text }
        
        let mutable = NSMutableString(string: text)
        for range in ranges.reversed() {
            mutable.replaceCharacters(in: range, with: "")
        }
        return mutable as String
    }

    static func displayText(
        from text: String,
        showDirections: Bool,
        showStoryboarding: Bool,
        showAnimateDirections: Bool
    ) -> String {
        displayProjection(
            from: text,
            showDirections: showDirections,
            showStoryboarding: showStoryboarding,
            showAnimateDirections: showAnimateDirections
        ).displayText
    }

    static func displayProjection(
        from text: String,
        showDirections: Bool,
        showStoryboarding: Bool,
        showAnimateDirections: Bool
    ) -> DisplayProjection {
        let nsString = text as NSString
        let elidedRanges = renderHiddenRanges(
            in: text,
            showDirections: showDirections,
            showStoryboarding: showStoryboarding,
            showAnimateDirections: showAnimateDirections
        )

        guard !elidedRanges.isEmpty else {
            let fullRange = NSRange(location: 0, length: nsString.length)
            let visibleChunks = fullRange.length > 0 ? [VisibleChunk(rawRange: fullRange, displayRange: fullRange)] : []
            return DisplayProjection(
                rawText: text,
                displayText: text,
                hiddenRanges: [],
                visibleChunks: visibleChunks
            )
        }

        var displayPieces: [String] = []
        var visibleChunks: [VisibleChunk] = []
        var rawCursor = 0
        var displayCursor = 0

        for hiddenRange in elidedRanges {
            if rawCursor < hiddenRange.location {
                let visibleRange = NSRange(location: rawCursor, length: hiddenRange.location - rawCursor)
                let visibleText = nsString.substring(with: visibleRange)
                displayPieces.append(visibleText)
                visibleChunks.append(
                    VisibleChunk(
                        rawRange: visibleRange,
                        displayRange: NSRange(location: displayCursor, length: visibleRange.length)
                    )
                )
                displayCursor += visibleRange.length
            }
            rawCursor = NSMaxRange(hiddenRange)
        }

        if rawCursor < nsString.length {
            let visibleRange = NSRange(location: rawCursor, length: nsString.length - rawCursor)
            let visibleText = nsString.substring(with: visibleRange)
            displayPieces.append(visibleText)
            visibleChunks.append(
                VisibleChunk(
                    rawRange: visibleRange,
                    displayRange: NSRange(location: displayCursor, length: visibleRange.length)
                )
            )
        }

        return DisplayProjection(
            rawText: text,
            displayText: displayPieces.joined(),
            hiddenRanges: elidedRanges,
            visibleChunks: visibleChunks
        )
    }

    static func hiddenRanges(
        in text: String,
        showDirections: Bool,
        showStoryboarding: Bool,
        showAnimateDirections: Bool
    ) -> [NSRange] {
        var ranges: [NSRange] = syllableAnnotationRanges(in: text)

        if !showDirections {
            ranges.append(contentsOf: directionMarkupRanges(in: text))
        }
        if !showStoryboarding {
            ranges.append(contentsOf: StoryboardPromptParser.promptRanges(in: text))
            ranges.append(contentsOf: parentheticalStageDirectionRanges(in: text))
        }
        if !showAnimateDirections {
            ranges.append(contentsOf: AnimatePromptParser.promptRanges(in: text))
        }
        ranges.append(contentsOf: SummaryParser.summaryRanges(in: text))

        return mergedRanges(ranges)
    }

    static func renderHiddenRanges(
        in text: String,
        showDirections: Bool,
        showStoryboarding: Bool,
        showAnimateDirections: Bool
    ) -> [NSRange] {
        let baseRanges = hiddenRanges(
            in: text,
            showDirections: showDirections,
            showStoryboarding: showStoryboarding,
            showAnimateDirections: showAnimateDirections
        )
        guard !baseRanges.isEmpty else { return [] }

        let lines = lineDescriptors(in: text, hiddenRanges: baseRanges)
        let standaloneHiddenIndices = lines.indices.filter { lines[$0].isStandaloneHidden }
        guard !standaloneHiddenIndices.isEmpty else { return baseRanges }

        var ranges = baseRanges
        for index in standaloneHiddenIndices {
            ranges.append(lines[index].range)
        }

        var index = 0
        while index < lines.count {
            guard lines[index].isStandaloneHidden else {
                index += 1
                continue
            }

            let blockStart = index
            var blockEnd = index
            while blockEnd + 1 < lines.count, lines[blockEnd + 1].isStandaloneHidden {
                blockEnd += 1
            }

            var trailing = blockEnd + 1
            while trailing < lines.count, lines[trailing].isBlank {
                ranges.append(lines[trailing].range)
                trailing += 1
            }

            var leadingBlankIndices: [Int] = []
            var cursor = blockStart - 1
            while cursor >= 0, lines[cursor].isBlank {
                leadingBlankIndices.append(cursor)
                cursor -= 1
            }

            let keepNearestBlank = cursor >= 0 ? 1 : 0
            for blankIndex in leadingBlankIndices.dropFirst(keepNearestBlank) {
                ranges.append(lines[blankIndex].range)
            }

            index = trailing
        }

        return mergedRanges(ranges)
    }

    private static let genericDoubleBracketPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"\[\[[\s\S]*?\]\]"#, options: [])
    }()

    private struct LineDescriptor {
        let range: NSRange
        let isBlank: Bool
        let isStandaloneHidden: Bool
    }

    private static func directionMarkupRanges(in text: String) -> [NSRange] {
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        var ranges = DirectionParser.directionRanges(in: text)
        ranges.append(contentsOf: genericDoubleBracketPattern.matches(in: text, range: fullRange).map(\.range))
        return mergedRanges(ranges)
    }

    private static func parentheticalStageDirectionRanges(in text: String) -> [NSRange] {
        let nsString = text as NSString
        let lineRanges = allLineRanges(in: nsString)
        var ranges: [NSRange] = []
        var openBlockLocation: Int?

        for lineRange in lineRanges {
            let lineText = nsString.substring(with: lineRange)
            let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let isSyllableCount = trimmed.range(of: #"^\(\d+\)$"#, options: .regularExpression) != nil
            if openBlockLocation != nil {
                if trimmed.hasSuffix(")") {
                    ranges.append(NSRange(location: openBlockLocation!, length: NSMaxRange(lineRange) - openBlockLocation!))
                    openBlockLocation = nil
                }
                continue
            }

            guard trimmed.hasPrefix("("), !isSyllableCount else { continue }
            if trimmed.hasSuffix(")") {
                ranges.append(lineRange)
            } else {
                openBlockLocation = lineRange.location
            }
        }

        return mergedRanges(ranges)
    }

    private static func lineDescriptors(in text: String, hiddenRanges: [NSRange]) -> [LineDescriptor] {
        let nsString = text as NSString
        let lineRanges = allLineRanges(in: nsString)

        return lineRanges.map { lineRange in
            let lineText = nsString.substring(with: lineRange)
            let trimmedLine = lineText.trimmingCharacters(in: .whitespacesAndNewlines)
            let isBlank = trimmedLine.isEmpty

            guard !isBlank else {
                return LineDescriptor(range: lineRange, isBlank: true, isStandaloneHidden: false)
            }

            let coveredText = hiddenRanges.compactMap { hiddenRange -> String? in
                let overlap = NSIntersectionRange(hiddenRange, lineRange)
                guard overlap.length > 0 else { return nil }
                return nsString.substring(with: overlap)
            }.joined()

            let isStandaloneHidden = !coveredText.isEmpty
                && trimmedLine == coveredText.trimmingCharacters(in: .whitespacesAndNewlines)

            return LineDescriptor(range: lineRange, isBlank: false, isStandaloneHidden: isStandaloneHidden)
        }
    }

    private static func allLineRanges(in nsString: NSString) -> [NSRange] {
        guard nsString.length > 0 else { return [] }

        var ranges: [NSRange] = []
        var location = 0
        while location < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
            ranges.append(lineRange)
            location = NSMaxRange(lineRange)
        }
        return ranges
    }

    static func project(rawRanges: [NSRange], through projection: DisplayProjection) -> [NSRange] {
        guard !rawRanges.isEmpty, !projection.visibleChunks.isEmpty else { return [] }

        var displayRanges: [NSRange] = []
        for rawRange in rawRanges where rawRange.length > 0 {
            for chunk in projection.visibleChunks {
                let overlap = NSIntersectionRange(rawRange, chunk.rawRange)
                guard overlap.length > 0 else { continue }
                let displayLocation = chunk.displayRange.location + (overlap.location - chunk.rawRange.location)
                displayRanges.append(NSRange(location: displayLocation, length: overlap.length))
            }
        }

        return mergedRanges(displayRanges)
    }

    /// Map an edit from display-space coordinates to raw-space coordinates and
    /// apply it, preserving all hidden content intact.
    ///
    /// Two strategies depending on edit type:
    /// - **Insertions** (zero-length affected range): use chunk-based offset mapping
    ///   via `displayToRaw`. Maps to the end of the containing chunk's raw range,
    ///   ensuring the edit lands BEFORE any hidden content that follows.
    /// - **Replacements/deletions** (non-zero affected range): rebuild the raw text
    ///   by computing the new display text, then interleaving it with the preserved
    ///   hidden ranges from the original raw text. This guarantees hidden content
    ///   is never corrupted regardless of selection boundaries.
    ///
    /// After the edit, `validateHiddenContentPreserved` checks that every piece of
    /// hidden content from the original raw text still exists in the result. If
    /// validation fails, falls back to the safe rebuild path.
    static func applyDisplayEdit(
        rawText: String,
        projection: DisplayProjection,
        affectedDisplayRange: NSRange,
        replacementString: String?
    ) -> String {
        let replacement = replacementString ?? ""
        let totalDisplayLength = (projection.displayText as NSString).length
        let displayStart = max(0, min(affectedDisplayRange.location, totalDisplayLength))
        let displayEnd = max(displayStart, min(NSMaxRange(affectedDisplayRange), totalDisplayLength))
        let displayDeleteLength = displayEnd - displayStart

        // For ALL edit types: map the display-space edit directly onto the raw
        // text using the visible chunk mapping. The edit is applied at the raw
        // position corresponding to the display start, and only the visible
        // characters within the edit range are affected — hidden content between
        // the start and end is preserved by computing raw start and end
        // independently through the chunk mapping.
        let rawStart = displayToRaw(displayStart, projection: projection)
        let rawEnd = displayDeleteLength > 0
            ? displayToRaw(displayEnd, projection: projection)
            : rawStart

        let nsRaw = rawText as NSString
        let clampedRawStart = max(0, min(rawStart, nsRaw.length))
        let clampedRawEnd = max(clampedRawStart, min(rawEnd, nsRaw.length))

        // For non-zero-length edits: we must NOT delete hidden content between
        // rawStart and rawEnd. Extract and preserve it.
        if clampedRawEnd > clampedRawStart {
            var preservedHidden = ""
            for hidden in projection.hiddenRanges {
                // Hidden range is fully within the edit range — preserve it
                if hidden.location >= clampedRawStart && NSMaxRange(hidden) <= clampedRawEnd {
                    preservedHidden += nsRaw.substring(with: hidden)
                }
            }
            let mutable = NSMutableString(string: rawText)
            mutable.replaceCharacters(
                in: NSRange(location: clampedRawStart, length: clampedRawEnd - clampedRawStart),
                with: replacement + preservedHidden
            )
            return mutable as String
        }

        // Pure insertion — simple insert at the mapped raw position
        let mutable = NSMutableString(string: rawText)
        mutable.insert(replacement, at: clampedRawStart)
        return mutable as String
    }

    /// Verify that every piece of hidden content from the original raw text
    /// exists intact somewhere in the edited text. Returns false if any hidden
    /// content was corrupted, split, or deleted by the edit.
    private static func validateHiddenContentPreserved(
        original: String,
        edited: String,
        hiddenRanges: [NSRange]
    ) -> Bool {
        let nsOriginal = original as NSString
        let nsEdited = edited as NSString
        for hidden in hiddenRanges {
            guard NSMaxRange(hidden) <= nsOriginal.length else { continue }
            let hiddenContent = nsOriginal.substring(with: hidden)
            // The hidden content must exist as a contiguous substring in the result.
            if nsEdited.range(of: hiddenContent).location == NSNotFound {
                return false
            }
        }
        return true
    }

    /// Convert a display-space offset to a raw-space offset using the visible
    /// chunk mapping. This avoids the ambiguity of the cumulative-offset approach
    /// where a display position at a chunk boundary could map to either side of
    /// a hidden range.
    ///
    /// For insertions (the primary use case): the position maps to the END of
    /// the containing chunk's raw range, which places the edit BEFORE any hidden
    /// content that follows — matching the user's visual intent.
    private static func displayToRaw(_ displayOffset: Int, projection: DisplayProjection) -> Int {
        let chunks = projection.visibleChunks
        guard !chunks.isEmpty else { return displayOffset }

        // Before the first chunk
        if displayOffset <= 0 {
            return chunks[0].rawRange.location
        }

        for chunk in chunks {
            let displayStart = chunk.displayRange.location
            let displayEnd = NSMaxRange(chunk.displayRange)

            if displayOffset <= displayEnd {
                // Position is within or at the end of this chunk.
                // Map directly: raw = chunk.rawRange.location + (display - chunk.displayRange.location)
                let offsetInChunk = min(displayOffset - displayStart, chunk.rawRange.length)
                return chunk.rawRange.location + offsetInChunk
            }
        }

        // Past the last chunk — map to end of raw text
        if let lastChunk = chunks.last {
            return NSMaxRange(lastChunk.rawRange)
        }
        return displayOffset
    }

    /// Rebuild raw text from new display text + preserved hidden ranges.
    /// Walks through the original raw text's hidden ranges and interleaves
    /// them with chunks of the new display text at the correct positions.
    private static func rebuildRawText(newDisplayText: String, rawText: String, hiddenRanges: [NSRange]) -> String {
        guard !hiddenRanges.isEmpty else { return newDisplayText }

        let nsRaw = rawText as NSString
        let nsNew = newDisplayText as NSString
        var result = ""
        var displayCursor = 0 // position in newDisplayText
        var rawCursor = 0     // position in original rawText (for extracting hidden content)

        for hidden in hiddenRanges {
            // How many visible characters precede this hidden range in the original?
            let visibleBeforeHidden = hidden.location - rawCursor
            // Copy that many characters from the new display text
            if visibleBeforeHidden > 0, displayCursor < nsNew.length {
                let takeLength = min(visibleBeforeHidden, nsNew.length - displayCursor)
                result += nsNew.substring(with: NSRange(location: displayCursor, length: takeLength))
                displayCursor += takeLength
            }
            // Copy the hidden content from the original raw text
            result += nsRaw.substring(with: hidden)
            rawCursor = NSMaxRange(hidden)
        }

        // Append remaining new display text after the last hidden range
        if displayCursor < nsNew.length {
            result += nsNew.substring(with: NSRange(location: displayCursor, length: nsNew.length - displayCursor))
        }

        return result
    }

    private static func mergedRanges(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges
            .filter { $0.length > 0 }
            .sorted { lhs, rhs in
                if lhs.location == rhs.location {
                    return lhs.length < rhs.length
                }
                return lhs.location < rhs.location
            }

        var merged: [NSRange] = []
        for range in sorted {
            guard let last = merged.last else {
                merged.append(range)
                continue
            }

            if range.location <= NSMaxRange(last) {
                let combinedEnd = max(NSMaxRange(last), NSMaxRange(range))
                merged[merged.count - 1] = NSRange(
                    location: last.location,
                    length: combinedEnd - last.location
                )
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private static func boundary(
        for displayLocation: Int,
        in projection: DisplayProjection,
        bias: BoundaryBias
    ) -> ChunkBoundary {
        guard !projection.visibleChunks.isEmpty else {
            return ChunkBoundary(chunkIndex: 0, offset: 0)
        }

        if displayLocation <= 0 {
            return ChunkBoundary(chunkIndex: 0, offset: 0)
        }

        let totalDisplayLength = (projection.displayText as NSString).length
        if displayLocation >= totalDisplayLength {
            let lastIndex = projection.visibleChunks.count - 1
            return ChunkBoundary(
                chunkIndex: lastIndex,
                offset: projection.visibleChunks[lastIndex].displayRange.length
            )
        }

        for (index, chunk) in projection.visibleChunks.enumerated() {
            let chunkStart = chunk.displayRange.location
            let chunkEnd = NSMaxRange(chunk.displayRange)

            if displayLocation < chunkStart {
                return ChunkBoundary(chunkIndex: index, offset: 0)
            }
            if displayLocation < chunkEnd {
                return ChunkBoundary(chunkIndex: index, offset: displayLocation - chunkStart)
            }
            if displayLocation == chunkEnd {
                if bias == .next, index + 1 < projection.visibleChunks.count {
                    return ChunkBoundary(chunkIndex: index + 1, offset: 0)
                }
                return ChunkBoundary(chunkIndex: index, offset: chunk.displayRange.length)
            }
        }

        let lastIndex = projection.visibleChunks.count - 1
        return ChunkBoundary(
            chunkIndex: lastIndex,
            offset: projection.visibleChunks[lastIndex].displayRange.length
        )
    }

    /// Apply green background highlighting to pending agent edit ranges.
    static func applyPendingHighlighting(to textView: NSTextView, ranges: [NSRange]) {
        guard let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)

        // Clear previous pending highlights (but preserve external change highlights)
        // We'll use a different approach - clear all and re-apply both
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

        guard !ranges.isEmpty else { return }

        let greenBG = NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.3, alpha: 0.25)
        for range in ranges {
            let clamped = NSIntersectionRange(range, fullRange)
            guard clamped.length > 0 else { continue }
            layoutManager.addTemporaryAttribute(
                .backgroundColor, value: greenBG, forCharacterRange: clamped
            )
        }
    }

    /// Apply yellow text color highlighting to external change ranges.
    static func applyExternalChangeHighlighting(to textView: NSTextView, ranges: [NSRange], opacity: Double) {
        guard let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        guard !ranges.isEmpty, opacity > 0 else { return }
        
        // Yellow text color with opacity based on the fade animation
        let yellowText = NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.2, alpha: opacity)
        for range in ranges {
            let clamped = NSIntersectionRange(range, fullRange)
            guard clamped.length > 0 else { continue }
            layoutManager.addTemporaryAttribute(
                .foregroundColor, value: yellowText, forCharacterRange: clamped
            )
        }
    }

    /// Compute NSRanges of changed characters between original and modified text.
    static func computeChangedCharacterRanges(original: String, modified: String) -> [NSRange] {
        // Use a simple line-by-line diff first, then refine to character level
        let originalLines = original.components(separatedBy: "\n")
        let modifiedLines = modified.components(separatedBy: "\n")
        
        let diff = modifiedLines.difference(from: originalLines)
        
        var ranges: [NSRange] = []
        var currentLocation = 0
        
        // Track which lines were modified
        var modifiedLineIndices = Set<Int>()
        for change in diff {
            switch change {
            case .insert(let offset, _, _):
                modifiedLineIndices.insert(offset)
            case .remove(let offset, _, _):
                modifiedLineIndices.insert(offset)
            }
        }
        
        // Build ranges from modified lines
        for (index, line) in modifiedLines.enumerated() {
            let lineLength = line.utf16.count
            if modifiedLineIndices.contains(index) {
                // Include the newline in the range
                let rangeLength = index < modifiedLines.count - 1 ? lineLength + 1 : lineLength
                ranges.append(NSRange(location: currentLocation, length: rangeLength))
            }
            currentLocation += lineLength + 1 // +1 for newline
        }
        
        return ranges
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptTextEditor
        weak var hostView: ScriptTextHostView?
        var isEditing = false
        var isStyling = false
        var currentRawText = ""
        var currentProjection = DisplayProjection(rawText: "", displayText: "", hiddenRanges: [], visibleChunks: [])
        var lastShowDirections = true
        var lastShowStoryboarding = true
        var lastShowAnimateDirections = true
        var lastHighlightRanges: [NSRange] = []
        var lastExternalRanges: [NSRange] = []
        var lastExternalOpacity: Double = 0
        private var pendingDisplayEdit: DisplayEdit?

        // MARK: - Undo/Redo Stack (raw text level)
        private var undoStack: [String] = []
        private var redoStack: [String] = []
        private static let maxUndoDepth = 100

        init(parent: ScriptTextEditor) {
            self.parent = parent
        }

        func pushUndo(_ rawText: String) {
            undoStack.append(rawText)
            if undoStack.count > Self.maxUndoDepth {
                undoStack.removeFirst()
            }
            redoStack.removeAll()
        }

        func undo(in tv: NSTextView) {
            guard let previous = undoStack.popLast() else { return }
            redoStack.append(currentRawText)
            currentRawText = previous
            parent.text = previous
            refreshDisplay(to: tv, rawText: previous)
        }

        func redo(in tv: NSTextView) {
            guard let next = redoStack.popLast() else { return }
            undoStack.append(currentRawText)
            currentRawText = next
            parent.text = next
            refreshDisplay(to: tv, rawText: next)
        }

        var canUndo: Bool { !undoStack.isEmpty }
        var canRedo: Bool { !redoStack.isEmpty }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            parent.text = currentRawText
        }

        func textDidChange(_ notification: Notification) {
            guard !isStyling else { return }
            guard let tv = notification.object as? NSTextView else { return }
            let edit = pendingDisplayEdit ?? DisplayEdit(
                affectedRange: NSRange(location: 0, length: (currentProjection.displayText as NSString).length),
                replacementString: tv.string
            )
            pendingDisplayEdit = nil

            let newRawText = ScriptTextEditor.applyDisplayEdit(
                rawText: currentRawText,
                projection: currentProjection,
                affectedDisplayRange: edit.affectedRange,
                replacementString: edit.replacementString
            )

            // SAFEGUARD: Don't apply edits that produce no change or empty results
            // when the original had content. This catches degenerate edit mappings.
            if newRawText == currentRawText {
                // Edit was a no-op in raw space — just refresh display without
                // pushing undo or updating the store.
                refreshDisplay(to: tv, rawText: currentRawText)
                return
            }
            if newRawText.isEmpty && !currentRawText.isEmpty {
                // Something went wrong — the entire text was wiped. Restore.
                NSLog("[ScriptTextEditor] Edit produced empty text from non-empty source — rejecting")
                refreshDisplay(to: tv, rawText: currentRawText)
                return
            }

            // Push undo snapshot BEFORE committing the edit
            pushUndo(currentRawText)

            currentRawText = newRawText
            parent.text = newRawText
            refreshDisplay(to: tv, rawText: newRawText)
        }

        /// Apply styling with re-entrancy guard.
        /// Saves and restores the cursor position around the display text swap
        /// to prevent the insertion point from jumping to the end.
        func refreshDisplay(to tv: NSTextView, rawText: String? = nil) {
            guard !isStyling else { return }
            isStyling = true

            // Save cursor position BEFORE swapping display text.
            let savedSelection = tv.selectedRange()

            let sourceText = rawText ?? currentRawText
            let projection = ScriptTextEditor.applyDirectionStyling(
                to: tv,
                rawText: sourceText,
                showDirections: parent.showDirections,
                showStoryboarding: parent.showStoryboarding,
                showAnimateDirections: parent.showAnimateDirections
            )
            currentRawText = sourceText
            currentProjection = projection
            applyProjectedHighlights(to: tv)

            // Restore cursor position, clamped to the new text length.
            let newLength = (tv.string as NSString).length
            let clampedLocation = min(savedSelection.location, newLength)
            let clampedEnd = min(clampedLocation + savedSelection.length, newLength)
            tv.setSelectedRange(NSRange(location: clampedLocation, length: clampedEnd - clampedLocation))

            hostView?.recalcHeight()
            isStyling = false
        }

        func applyProjectedHighlights(to tv: NSTextView) {
            let pendingRanges = ScriptTextEditor.project(
                rawRanges: parent.pendingHighlightRanges,
                through: currentProjection
            )
            ScriptTextEditor.applyPendingHighlighting(to: tv, ranges: pendingRanges)

            let externalRanges = ScriptTextEditor.project(
                rawRanges: parent.externalChangeRanges,
                through: currentProjection
            )
            ScriptTextEditor.applyExternalChangeHighlighting(
                to: tv,
                ranges: externalRanges,
                opacity: parent.externalChangeOpacity
            )
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedRange: NSRange, replacementString: String?) -> Bool {
            pendingDisplayEdit = DisplayEdit(
                affectedRange: affectedRange,
                replacementString: replacementString ?? ""
            )
            return true
        }

        /// Intercept undo/redo commands to use our raw-text-level undo stack
        /// instead of NSTextView's built-in undo (which is disabled during styling).
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == NSSelectorFromString("undo:") {
                undo(in: textView)
                return true
            }
            if commandSelector == NSSelectorFromString("redo:") {
                redo(in: textView)
                return true
            }
            return false
        }
    }
}

// MARK: - Script Text Host View

/// Custom NSView that hosts an NSTextView directly (no NSScrollView)
/// and reports layout height via a callback so SwiftUI can size the frame.
@MainActor
final class ScriptTextHostView: NSView {
    let textView = NSTextView()
    var onHeightChanged: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.autoresizingMask = [.width, .height]
        textView.backgroundColor = .clear
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        let w = bounds.width
        if w > 0 {
            textView.textContainer?.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
            recalcHeight()
        }
    }

    func recalcHeight() {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let newHeight = ceil(usedRect.height + textView.textContainerInset.height * 2 + 8)
        let clamped = max(40, newHeight)
        if abs(lastReportedHeight - clamped) > 0.5 {
            lastReportedHeight = clamped
            onHeightChanged?(clamped)
        }
    }
}

// MARK: - Preference Key for Section Visibility

struct SectionVisibility: Equatable, Sendable {
    let path: String
    let minY: CGFloat
    let maxY: CGFloat
}

struct SectionVisibilityKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [SectionVisibility] = []
    static func reduce(value: inout [SectionVisibility], nextValue: () -> [SectionVisibility]) {
        value.append(contentsOf: nextValue())
    }
}
