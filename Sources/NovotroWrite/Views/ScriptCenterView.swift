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
                    updateActiveSection(from: sections)
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
        let viewportTop: CGFloat = 60

        var best: String?
        var bestDistance: CGFloat = .infinity

        for section in sections {
            if section.maxY > 0 && section.minY < 600 {
                let distance = abs(section.minY - viewportTop)
                if section.minY <= viewportTop + 40 && distance < bestDistance {
                    best = section.path
                    bestDistance = distance
                }
            }
        }

        if best == nil {
            best = sections
                .filter { $0.maxY > 0 }
                .min(by: { abs($0.minY) < abs($1.minY) })?
                .path
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
            ZStack(alignment: .topLeading) {
                ScriptTextEditor(
                    text: $localText,
                    reportedHeight: $editorHeight,
                    showDirections: store.showDirections,
                    showStoryboarding: store.showStoryboarding,
                    showAnimateDirections: store.showAnimateDirections,
                    pendingHighlightRanges: pendingDiffRanges
                )
                .frame(height: max(40, editorHeight))
                .opacity(isPreviewingThisSection ? 0.15 : 1.0)
                .disabled(isPreviewingThisSection || hasPendingEdit)

                // Version preview overlay
                if let preview = previewLyrics {
                    Text(
                        ScriptTextEditor.displayText(
                            from: preview,
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
            }
            .onAppear {
                if !hasLoaded {
                    localText = store.librettoFiles
                        .first(where: { $0.relativePath == path })?.content ?? ""
                    hasLoaded = true
                }
            }
            .onChange(of: localText) { _, newValue in
                guard hasLoaded, !suppressWriteBack else { return }
                store.applyEditorChange(path: path, lyrics: newValue)
            }
            .onChange(of: store.librettoFiles) { _, files in
                guard hasLoaded, !hasPendingEdit else { return }
                let incoming = files.first(where: { $0.relativePath == path })?.content ?? ""
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
                    guard pending != localText else { return }
                    suppressWriteBack = true
                    localText = pending
                    DispatchQueue.main.async {
                        suppressWriteBack = false
                    }
                } else if !edits.keys.contains(path) {
                    // Pending cleared (accept or reject) — restore committed text
                    let committed = store.librettoFiles
                        .first(where: { $0.relativePath == path })?.content ?? ""
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
                // Reload text from librettoFiles — onChange(of: librettoFiles) can miss
                // in-place element mutations with @Observable
                let incoming = store.librettoFiles
                    .first(where: { $0.relativePath == path })?.content ?? ""
                if incoming != localText {
                    suppressWriteBack = true
                    localText = incoming
                    DispatchQueue.main.async {
                        suppressWriteBack = false
                    }
                }
                // Visual glow to indicate external change
                withAnimation(.easeIn(duration: 0.5)) {
                    glowOpacity = 1.0
                }
                // Fade out gradually over 3 minutes
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    withAnimation(.easeOut(duration: 150)) {
                        glowOpacity = 0.0
                    }
                }
                // Clean up the timestamp after glow expires
                DispatchQueue.main.asyncAfter(deadline: .now() + 180) {
                    store.externalChangeTimes.removeValue(forKey: path)
                }
            }
            // External change glow overlay
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: 1.0, green: 0.85, blue: 0.4).opacity(glowOpacity * 0.06))
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color(red: 1.0, green: 0.85, blue: 0.4).opacity(glowOpacity * 0.5))
                    .frame(width: 3)
                    .shadow(color: Color(red: 1.0, green: 0.85, blue: 0.4).opacity(glowOpacity * 0.3), radius: 8, x: 2)
                    .allowsHitTesting(false)
                    .opacity(glowOpacity > 0.01 ? 1 : 0)
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
        textView.string = text

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 5
        textView.defaultParagraphStyle = paragraphStyle
        textView.typingAttributes = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: paragraphStyle,
        ]

        context.coordinator.hostView = host
        context.coordinator.lastShowDirections = showDirections
        context.coordinator.lastShowStoryboarding = showStoryboarding
        context.coordinator.lastShowAnimateDirections = showAnimateDirections
        Self.applyDirectionStyling(to: textView, showDirections: showDirections, showStoryboarding: showStoryboarding, showAnimateDirections: showAnimateDirections)
        host.recalcHeight()

        return host
    }

    func updateNSView(_ host: ScriptTextHostView, context: Context) {
        let coordinator = context.coordinator
        let textChanged = host.textView.string != text && !coordinator.isEditing
        let toggleChanged = coordinator.lastShowDirections != showDirections
            || coordinator.lastShowStoryboarding != showStoryboarding
            || coordinator.lastShowAnimateDirections != showAnimateDirections
        let highlightChanged = coordinator.lastHighlightRanges != pendingHighlightRanges

        if textChanged {
            host.textView.string = text
        }

        if textChanged || toggleChanged {
            coordinator.lastShowDirections = showDirections
            coordinator.lastShowStoryboarding = showStoryboarding
            coordinator.lastShowAnimateDirections = showAnimateDirections
            Self.applyDirectionStyling(to: host.textView, showDirections: showDirections, showStoryboarding: showStoryboarding, showAnimateDirections: showAnimateDirections)
            host.recalcHeight()
        }

        if textChanged || highlightChanged {
            coordinator.lastHighlightRanges = pendingHighlightRanges
            Self.applyPendingHighlighting(to: host.textView, ranges: pendingHighlightRanges)
        }
    }

    /// Apply direction markup styling. Hidden content is removed from glyph
    /// layout so it does not render or appear when selected.
    static func applyDirectionStyling(to textView: NSTextView, showDirections show: Bool, showStoryboarding: Bool = true, showAnimateDirections: Bool = true) {
        guard let layoutManager = textView.layoutManager,
              let textStorage = textView.textStorage else { return }
        let nsString = textView.string as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        guard fullRange.length > 0 else { return }

        // Clear temporary attributes
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.font, forCharacterRange: fullRange)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

        // Reset all paragraph styles to default
        let defaultStyle = NSMutableParagraphStyle()
        defaultStyle.lineSpacing = 5

        let collapsedStyle = NSMutableParagraphStyle()
        collapsedStyle.maximumLineHeight = 0.01
        collapsedStyle.minimumLineHeight = 0.01
        collapsedStyle.lineSpacing = 0
        collapsedStyle.paragraphSpacing = 0
        collapsedStyle.paragraphSpacingBefore = 0
        let hiddenFont = NSFont.monospacedSystemFont(ofSize: 0.1, weight: .regular)
        let hiddenColor = NSColor.clear

        textView.undoManager?.disableUndoRegistration()
        textStorage.beginEditing()
        textStorage.addAttribute(.paragraphStyle, value: defaultStyle, range: fullRange)

        var hiddenRanges: [NSRange] = []

        /// Collapse lines that contain nothing but hidden content so they do
        /// not leave empty vertical gaps behind.
        func collapseRanges(_ ranges: [NSRange]) {
            for range in ranges {
                let fullLineRange = nsString.lineRange(for: range)
                var lineStart = fullLineRange.location
                while lineStart < NSMaxRange(fullLineRange) {
                    let singleLineRange = nsString.lineRange(
                        for: NSRange(location: lineStart, length: 0)
                    )
                    let lineText = nsString.substring(with: singleLineRange)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let intersection = NSIntersectionRange(singleLineRange, range)
                    let overlapText = intersection.length > 0
                        ? nsString.substring(with: intersection)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        : ""
                    if !lineText.isEmpty && lineText == overlapText {
                        textStorage.addAttribute(
                            .paragraphStyle, value: collapsedStyle, range: singleLineRange
                        )
                    }
                    lineStart = NSMaxRange(singleLineRange)
                }
            }
        }

        // Style direction markup [[...]]
        let directionRanges = DirectionParser.directionRanges(in: textView.string)
        if !directionRanges.isEmpty {
            if show {
                let tealColor = NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.80, alpha: 0.70)
                for range in directionRanges {
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor, value: tealColor, forCharacterRange: range
                    )
                }
            } else {
                hiddenRanges.append(contentsOf: directionRanges)
                collapseRanges(directionRanges)
            }
        }

        // Style storyboarding prompts [single bracket text]
        let storyboardRanges = StoryboardPromptParser.promptRanges(in: textView.string)
        if !storyboardRanges.isEmpty {
            if showStoryboarding {
                let orangeColor = NSColor(calibratedRed: 0.95, green: 0.65, blue: 0.25, alpha: 0.80)
                for range in storyboardRanges {
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor, value: orangeColor, forCharacterRange: range
                    )
                }
            } else {
                hiddenRanges.append(contentsOf: storyboardRanges)
                collapseRanges(storyboardRanges)
            }
        }

        // Style animate prompts {keyword: ...}
        let animateRanges = AnimatePromptParser.promptRanges(in: textView.string)
        if !animateRanges.isEmpty {
            if showAnimateDirections {
                let pinkColor = NSColor(calibratedRed: 0.85, green: 0.45, blue: 0.70, alpha: 0.80)
                for range in animateRanges {
                    layoutManager.addTemporaryAttribute(
                        .foregroundColor, value: pinkColor, forCharacterRange: range
                    )
                }
            } else {
                hiddenRanges.append(contentsOf: animateRanges)
                collapseRanges(animateRanges)
            }
        }

        // Always collapse summary blocks — displayed in the sidebar
        if let summaryRange = SummaryParser.summaryRange(in: textView.string) {
            hiddenRanges.append(summaryRange)
            collapseRanges([summaryRange])
        }

        textStorage.endEditing()
        textView.undoManager?.enableUndoRegistration()

        // Syllable counts are always hidden from the script body.
        let syllableRanges = syllableAnnotationRanges(in: textView.string)
        hiddenRanges.append(contentsOf: syllableRanges)
        let mergedHiddenRanges = mergedRanges(hiddenRanges)

        for range in mergedHiddenRanges {
            layoutManager.addTemporaryAttribute(
                .foregroundColor, value: hiddenColor, forCharacterRange: range
            )
            layoutManager.addTemporaryAttribute(
                .font, value: hiddenFont, forCharacterRange: range
            )
        }

        applyHiddenGlyphLayout(
            to: layoutManager,
            fullCharacterRange: fullRange,
            hiddenRanges: mergedHiddenRanges
        )
        layoutManager.invalidateLayout(forCharacterRange: fullRange, actualCharacterRange: nil)
        layoutManager.invalidateDisplay(forCharacterRange: fullRange)
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

    static func displayText(
        from text: String,
        showDirections: Bool,
        showStoryboarding: Bool,
        showAnimateDirections: Bool
    ) -> String {
        let hidden = hiddenRanges(
            in: text,
            showDirections: showDirections,
            showStoryboarding: showStoryboarding,
            showAnimateDirections: showAnimateDirections
        )
        guard !hidden.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for range in hidden.reversed() {
            mutable.replaceCharacters(in: range, with: "")
        }

        return mutable as String
    }

    static func hiddenRanges(
        in text: String,
        showDirections: Bool,
        showStoryboarding: Bool,
        showAnimateDirections: Bool
    ) -> [NSRange] {
        var ranges: [NSRange] = syllableAnnotationRanges(in: text)

        if !showDirections {
            ranges.append(contentsOf: DirectionParser.directionRanges(in: text))
        }
        if !showStoryboarding {
            ranges.append(contentsOf: StoryboardPromptParser.promptRanges(in: text))
        }
        if !showAnimateDirections {
            ranges.append(contentsOf: AnimatePromptParser.promptRanges(in: text))
        }
        if let summaryRange = SummaryParser.summaryRange(in: text) {
            ranges.append(summaryRange)
        }

        return mergedRanges(ranges)
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

    private static func applyHiddenGlyphLayout(
        to layoutManager: NSLayoutManager,
        fullCharacterRange: NSRange,
        hiddenRanges: [NSRange]
    ) {
        let fullGlyphRange = layoutManager.glyphRange(
            forCharacterRange: fullCharacterRange,
            actualCharacterRange: nil
        )

        if fullGlyphRange.length > 0 {
            for glyphIndex in fullGlyphRange.location..<NSMaxRange(fullGlyphRange) {
                layoutManager.setNotShownAttribute(false, forGlyphAt: glyphIndex)
            }
        }

        for range in hiddenRanges {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { continue }
            for glyphIndex in glyphRange.location..<NSMaxRange(glyphRange) {
                layoutManager.setNotShownAttribute(true, forGlyphAt: glyphIndex)
            }
        }
    }

    /// Apply green background highlighting to pending agent edit ranges.
    static func applyPendingHighlighting(to textView: NSTextView, ranges: [NSRange]) {
        guard let layoutManager = textView.layoutManager else { return }
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)

        // Clear previous pending highlights
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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScriptTextEditor
        weak var hostView: ScriptTextHostView?
        var isEditing = false
        var isStyling = false
        var lastShowDirections = true
        var lastShowStoryboarding = true
        var lastShowAnimateDirections = true
        var lastHighlightRanges: [NSRange] = []
        private var stylingWorkItem: DispatchWorkItem?

        init(parent: ScriptTextEditor) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            if let tv = notification.object as? NSTextView {
                parent.text = tv.string
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isStyling else { return }
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = hostView?.textView.string ?? ""

            // Debounce styling to avoid running 5 regex scans on every keystroke
            stylingWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self, weak tv] in
                guard let self, let tv else { return }
                self.applyStylingGuarded(to: tv)
            }
            stylingWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: item)
        }

        /// Apply styling with re-entrancy guard.
        func applyStylingGuarded(to tv: NSTextView) {
            guard !isStyling else { return }
            isStyling = true
            ScriptTextEditor.applyDirectionStyling(
                to: tv,
                showDirections: parent.showDirections,
                showStoryboarding: parent.showStoryboarding,
                showAnimateDirections: parent.showAnimateDirections
            )
            hostView?.recalcHeight()
            isStyling = false
        }

        /// Block edits that would land inside a collapsed (hidden) range.
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedRange: NSRange, replacementString: String?) -> Bool {
            let hiddenRanges = ScriptTextEditor.hiddenRanges(
                in: textView.string,
                showDirections: parent.showDirections,
                showStoryboarding: parent.showStoryboarding,
                showAnimateDirections: parent.showAnimateDirections
            )

            if affectedRange.length == 0 {
                return !hiddenRanges.contains { hiddenRange in
                    NSLocationInRange(affectedRange.location, hiddenRange)
                }
            }

            return !hiddenRanges.contains { hiddenRange in
                NSIntersectionRange(hiddenRange, affectedRange).length > 0
            }
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
