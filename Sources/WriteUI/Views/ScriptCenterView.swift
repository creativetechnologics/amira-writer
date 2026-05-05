import SwiftUI
import AppKit
import ProjectKit

// MARK: - Center Content

@available(macOS 26.0, *)
struct ScriptCenterView: View {
    @Bindable var store: ScriptStore
    var showScratchpad: Bool = false
    var showLyricIterations: Bool = false
    var showCards: Bool = false
    var selectedLyricIterationSlot: Int = 1

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
                showScratchpad: showScratchpad,
                showLyricIterations: showLyricIterations,
                showCards: showCards,
                selectedLyricIterationSlot: selectedLyricIterationSlot
            )
        }
    }
}

// MARK: - Scrollable Script Body

@available(macOS 26.0, *)
struct ScriptScrollContent: View {
    @Bindable var store: ScriptStore
    var showScratchpad: Bool
    var showLyricIterations: Bool
    var showCards: Bool
    var selectedLyricIterationSlot: Int
    @AppStorage("amira.write.lyricIterations.width") private var lyricIterationsWidth: Double = 340
    @AppStorage("amira.write.scratchpad.width") private var scratchpadWidth: Double = 340
    @State private var activeSectionUpdateWorkItem: DispatchWorkItem?

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
                                showLyricIterations: showLyricIterations,
                                selectedLyricIterationSlot: selectedLyricIterationSlot,
                                lyricIterationsWidth: lyricIterationsWidth,
                                showScratchpad: showScratchpad,
                                scratchpadWidth: scratchpadWidth,
                                showCards: showCards,
                                cardsWidth: 0
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
                    .padding(.horizontal, (showScratchpad || showLyricIterations) ? 28 : 40)
                    .padding(.top, 20)
                    .padding(.bottom, 40)
                }
                .coordinateSpace(name: "scriptScroll")
                .background(store.scriptBackgroundColor)
                .onPreferenceChange(SectionVisibilityKey.self) { sections in
                    self.scheduleActiveSectionUpdate(from: sections)
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

    private func scheduleActiveSectionUpdate(from sections: [SectionVisibility]) {
        activeSectionUpdateWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            self.updateActiveSection(from: sections)
        }
        activeSectionUpdateWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
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
    let showLyricIterations: Bool
    let selectedLyricIterationSlot: Int
    let lyricIterationsWidth: Double
    let showScratchpad: Bool
    let scratchpadWidth: Double
    let showCards: Bool
    let cardsWidth: Double

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
                    store: store,
                    showInlineShotCards: showCards
                )
                .frame(maxWidth: .infinity, alignment: .topLeading)

                if showLyricIterations {
                    ScriptLyricIterationSectionView(
                        displayName: displayName,
                        path: path,
                        slot: selectedLyricIterationSlot,
                        store: store
                    )
                    .frame(width: lyricIterationsWidth, alignment: .topLeading)
                }

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
    let showInlineShotCards: Bool

    @State private var localText: String = ""
    @State private var hasLoaded: Bool = false
    @State private var editorHeight: CGFloat = 60
    @State private var suppressWriteBack: Bool = false
    @State private var pendingWriteBackWorkItem: DispatchWorkItem?
    @State private var glowOpacity: Double = 0
    @State private var expandedShotCardIDs: Set<String> = []
    
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

    private var characterNames: [String] {
        store.characters.map(\.name)
    }

    private func editableText(from rawContent: String) -> String {
        ScriptTextEditor.prepareEditableText(
            from: SynopsisEmbedding.stripForDisplay(content: rawContent)
        )
    }

    private func readOnlyText(from rawContent: String) -> String {
        ScriptTextEditor.displayText(
            from: SynopsisEmbedding.stripForDisplay(content: rawContent),
            showDirections: store.showDirections,
            showStoryboarding: store.showStoryboarding,
            showAnimateDirections: store.showAnimateDirections
        )
    }

    private func storedContent(from editedText: String) -> String {
        let existingSynopsis = store.synopsis(forScenePath: path)
        let sanitizedText = ScriptTextEditor.prepareEditableText(from: editedText)
        return SynopsisEmbedding.update(content: sanitizedText, synopsis: existingSynopsis)
    }

    private func currentStoredContent() -> String {
        store.librettoFiles.first(where: { $0.relativePath == path })?.content ?? ""
    }

    private func scheduleWriteBack(_ newValue: String) {
        pendingWriteBackWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            let fullContent = storedContent(from: newValue)
            guard fullContent != currentStoredContent() else { return }
            store.applyEditorChange(path: path, lyrics: fullContent)
        }
        pendingWriteBackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16, execute: workItem)
    }

    private func flushPendingWriteBack() {
        pendingWriteBackWorkItem?.cancel()
        pendingWriteBackWorkItem = nil
        let fullContent = storedContent(from: localText)
        guard fullContent != currentStoredContent() else { return }
        store.applyEditorChange(path: path, lyrics: fullContent)
    }

    @ViewBuilder
    private var editorView: some View {
        StructuredScriptTextEditor(
            text: $localText,
            reportedHeight: $editorHeight,
            isEditable: store.isLibrettoEditMode,
            showInlineShotCards: showInlineShotCards,
            showLyricCards: showInlineShotCards,
            characterNames: characterNames,
            directionMarkupColorHex: store.directionMarkupColorHex,
            storyboardingMarkupColorHex: store.storyboardingMarkupColorHex,
            animateMarkupColorHex: store.animateMarkupColorHex,
            expandedShotCardIDs: $expandedShotCardIDs,
            allowsShotBoundaryEditing: store.isLibrettoEditMode && !isPreviewingThisSection && !hasPendingEdit,
            allowsShotCardEditing: !isPreviewingThisSection && !hasPendingEdit
        )
    }

    @ViewBuilder
    private var readOnlyView: some View {
        if showInlineShotCards && !isPreviewingThisSection {
            StructuredScriptTextEditor(
                text: $localText,
                reportedHeight: $editorHeight,
                isEditable: false,
                showInlineShotCards: showInlineShotCards,
                showLyricCards: showInlineShotCards,
                characterNames: characterNames,
                directionMarkupColorHex: store.directionMarkupColorHex,
                storyboardingMarkupColorHex: store.storyboardingMarkupColorHex,
                animateMarkupColorHex: store.animateMarkupColorHex,
                expandedShotCardIDs: $expandedShotCardIDs,
                allowsShotBoundaryEditing: false,
                allowsShotCardEditing: !hasPendingEdit
            )
            .frame(height: max(40, editorHeight))
        } else {
            let raw = store.librettoFiles.first(where: { $0.relativePath == path })?.content ?? ""
            let text = isPreviewingThisSection
                ? (previewLyrics.map { SynopsisEmbedding.stripForDisplay(content: $0) } ?? "")
                : SynopsisEmbedding.stripForDisplay(content: raw)

            StructuredScriptTextEditor(
                text: .constant(text),
                reportedHeight: $editorHeight,
                isEditable: false,
                showInlineShotCards: showInlineShotCards,
                showLyricCards: showInlineShotCards,
                characterNames: characterNames,
                directionMarkupColorHex: store.directionMarkupColorHex,
                storyboardingMarkupColorHex: store.storyboardingMarkupColorHex,
                animateMarkupColorHex: store.animateMarkupColorHex,
                expandedShotCardIDs: $expandedShotCardIDs,
                allowsShotBoundaryEditing: false,
                allowsShotCardEditing: false
            )
            .frame(height: max(40, editorHeight))
        }
    }

    private var editorContainer: some View {
        ZStack(alignment: .topLeading) {
            if store.isLibrettoEditMode {
                editorView
                    .frame(height: max(40, editorHeight))
                    .opacity(isPreviewingThisSection ? 0.15 : 1.0)
                    .disabled(isPreviewingThisSection || hasPendingEdit)

                // Version preview overlay
                if let preview = previewLyrics {
                    previewOverlay(content: preview)
                }
            } else {
                readOnlyView
            }
        }
    }

    private func previewOverlay(content: String) -> some View {
        Text(verbatim:
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
                .fill(store.scriptBackgroundColor.opacity(0.88))
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
                    localText = editableText(from: raw)
                    hasLoaded = true
                }
            }
            .onChange(of: localText) { _, newValue in
                let allowsStructuredCardWriteBack = showInlineShotCards && !isPreviewingThisSection && !hasPendingEdit
                guard (store.isLibrettoEditMode || allowsStructuredCardWriteBack),
                      hasLoaded,
                      !suppressWriteBack else { return }
                scheduleWriteBack(newValue)
            }
            .onChange(of: store.librettoContentRevisionByPath[path] ?? 0) { _, _ in
                guard hasLoaded, !hasPendingEdit else { return }
                let raw = currentStoredContent()
                let incoming = editableText(from: raw)
                guard incoming != localText else { return }
                pendingWriteBackWorkItem?.cancel()
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
                    let stripped = editableText(from: pending)
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
                    let committed = editableText(from: raw)
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
                let incoming = editableText(from: raw)

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
        .onDisappear {
            if pendingWriteBackWorkItem != nil {
                flushPendingWriteBack()
            }
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
                    isEditable: store.isLibrettoEditMode,
                    showDirections: store.showDirections,
                    showStoryboarding: store.showStoryboarding,
                    showAnimateDirections: store.showAnimateDirections,
                    directionMarkupColorHex: store.directionMarkupColorHex,
                    storyboardingMarkupColorHex: store.storyboardingMarkupColorHex,
                    animateMarkupColorHex: store.animateMarkupColorHex
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
            guard store.isLibrettoEditMode, hasLoaded, !suppressWriteBack else { return }
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

@available(macOS 26.0, *)
private struct ScriptLyricIterationSectionView: View {
    let displayName: String
    let path: String
    let slot: Int
    @Bindable var store: ScriptStore

    private var iterationText: String {
        store.lyricIterationText(forPath: path, slot: slot)
    }

    private var iterationRelativePath: String {
        store.lyricIterationRelativePath(forPath: path, slot: slot)
    }

    private var hasContent: Bool {
        !iterationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("LYRIC ITERATION \(slot)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.cyan.opacity(0.9))
                    .tracking(1.2)

                Text(displayName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                OperaChromeStatusBadge(
                    text: hasContent ? "READY" : "EMPTY",
                    tint: hasContent ? Color.cyan.opacity(0.85) : OperaChromeTheme.textTertiary
                )
            }

            Text(iterationRelativePath)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(OperaChromeTheme.textTertiary)
                .textSelection(.enabled)

            if hasContent {
                Text(verbatim: iterationText)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.vertical, 6)
            } else {
                Text("Place a lyrics-only draft in this file to preview it here automatically. Keep it plain lyrics with no stage directions.")
                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.cyan.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Script Text Editor (NSTextView wrapper)

@available(macOS 26.0, *)
struct ScriptTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var reportedHeight: CGFloat
    var isEditable: Bool = true
    var showDirections: Bool
    var showStoryboarding: Bool
    var showAnimateDirections: Bool
    var directionMarkupColorHex: String = ScriptMarkupPalette.defaultDirectionHex
    var storyboardingMarkupColorHex: String = ScriptMarkupPalette.defaultStoryboardingHex
    var animateMarkupColorHex: String = ScriptMarkupPalette.defaultAnimateHex
    var pendingHighlightRanges: [NSRange] = []
    var externalChangeRanges: [NSRange] = []
    var externalChangeOpacity: Double = 0
    var showInlineShotCards: Bool = false
    var expandedShotCardIDs: Binding<Set<String>> = .constant([])
    var allowsShotCardEditing: Bool = false
    var allowsShotBoundaryEditing: Bool = false

    struct VisibleChunk: Equatable {
        let rawRange: NSRange
        let displayRange: NSRange
    }

    struct ShotAttachment: Equatable, Identifiable {
        let id: String
        let rawRange: NSRange
        let displayRange: NSRange
        var extentDisplayRange: NSRange
        let rawMarkup: String
        let card: ScriptShotCard
        let isExpanded: Bool
        var canMoveEnd: Bool
    }

    struct DisplayProjection: Equatable {
        let rawText: String
        let displayText: String
        let hiddenRanges: [NSRange]
        let visibleChunks: [VisibleChunk]
        let shotAttachments: [ShotAttachment]
    }

    private struct DisplayEdit {
        let affectedRange: NSRange
        let replacementString: String
    }

    private enum BoundaryBias {
        case previous
        case next
    }

    fileprivate enum ShotBoundaryEdge: Equatable {
        case start
        case end
    }

    fileprivate enum ShotHandleKind: Equatable {
        case startBoundary
        case endBoundary
        case moveShot
        case toggleCard
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
        context.coordinator.lastIsEditable = isEditable
        context.coordinator.lastShowDirections = showDirections
        context.coordinator.lastShowStoryboarding = showStoryboarding
        context.coordinator.lastShowAnimateDirections = showAnimateDirections
        context.coordinator.lastDirectionMarkupColorHex = directionMarkupColorHex
        context.coordinator.lastStoryboardingMarkupColorHex = storyboardingMarkupColorHex
        context.coordinator.lastAnimateMarkupColorHex = animateMarkupColorHex
        context.coordinator.lastHighlightRanges = pendingHighlightRanges
        context.coordinator.lastExternalRanges = externalChangeRanges
        context.coordinator.lastExternalOpacity = externalChangeOpacity
        context.coordinator.lastShowInlineShotCards = showInlineShotCards
        context.coordinator.lastExpandedShotCardIDs = expandedShotCardIDs.wrappedValue
        context.coordinator.lastAllowsShotCardEditing = allowsShotCardEditing
        context.coordinator.lastAllowsShotBoundaryEditing = allowsShotBoundaryEditing
        context.coordinator.refreshDisplay(to: textView, rawText: text)

        return host
    }

    func updateNSView(_ host: ScriptTextHostView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        host.textView.isEditable = isEditable

        let textChanged = coordinator.currentRawText != text && !coordinator.isEditing
        let editabilityChanged = coordinator.lastIsEditable != isEditable
        let toggleChanged = coordinator.lastShowDirections != showDirections
            || coordinator.lastShowStoryboarding != showStoryboarding
            || coordinator.lastShowAnimateDirections != showAnimateDirections
            || coordinator.lastDirectionMarkupColorHex != directionMarkupColorHex
            || coordinator.lastStoryboardingMarkupColorHex != storyboardingMarkupColorHex
            || coordinator.lastAnimateMarkupColorHex != animateMarkupColorHex
        let highlightChanged = coordinator.lastHighlightRanges != pendingHighlightRanges
        let externalChanged = coordinator.lastExternalRanges != externalChangeRanges
            || coordinator.lastExternalOpacity != externalChangeOpacity
        let inlineShotChanged = coordinator.lastShowInlineShotCards != showInlineShotCards
            || coordinator.lastExpandedShotCardIDs != expandedShotCardIDs.wrappedValue
            || coordinator.lastAllowsShotCardEditing != allowsShotCardEditing
            || coordinator.lastAllowsShotBoundaryEditing != allowsShotBoundaryEditing

        if textChanged || editabilityChanged || toggleChanged || externalChanged || inlineShotChanged {
            coordinator.lastIsEditable = isEditable
            coordinator.lastShowDirections = showDirections
            coordinator.lastShowStoryboarding = showStoryboarding
            coordinator.lastShowAnimateDirections = showAnimateDirections
            coordinator.lastDirectionMarkupColorHex = directionMarkupColorHex
            coordinator.lastStoryboardingMarkupColorHex = storyboardingMarkupColorHex
            coordinator.lastAnimateMarkupColorHex = animateMarkupColorHex
            coordinator.lastHighlightRanges = pendingHighlightRanges
            coordinator.lastExternalRanges = externalChangeRanges
            coordinator.lastExternalOpacity = externalChangeOpacity
            coordinator.lastShowInlineShotCards = showInlineShotCards
            coordinator.lastExpandedShotCardIDs = expandedShotCardIDs.wrappedValue
            coordinator.lastAllowsShotCardEditing = allowsShotCardEditing
            coordinator.lastAllowsShotBoundaryEditing = allowsShotBoundaryEditing
            coordinator.refreshDisplay(to: host.textView, rawText: text)
        } else if highlightChanged {
            coordinator.lastHighlightRanges = pendingHighlightRanges
            coordinator.lastExternalRanges = externalChangeRanges
            coordinator.lastExternalOpacity = externalChangeOpacity
            coordinator.applyProjectedHighlights(to: host.textView)
        }
    }

    /// Apply syntax coloring and, when toggles are disabled, project the text
    /// into a view that hides the selected markup families while preserving the
    /// underlying raw text.
    @discardableResult
    static func applyDirectionStyling(
        to textView: NSTextView,
        rawText: String? = nil,
        showDirections show: Bool,
        showStoryboarding: Bool = true,
        showAnimateDirections: Bool = true,
        directionMarkupColorHex: String = ScriptMarkupPalette.defaultDirectionHex,
        storyboardingMarkupColorHex: String = ScriptMarkupPalette.defaultStoryboardingHex,
        animateMarkupColorHex: String = ScriptMarkupPalette.defaultAnimateHex,
        showInlineShotCards: Bool = false,
        expandedShotCardIDs: Set<String> = []
    ) -> DisplayProjection {
        let sourceText = prepareEditableText(from: rawText ?? textView.string)
        let projection = displayProjection(
            from: sourceText,
            showDirections: show,
            showStoryboarding: showStoryboarding,
            showAnimateDirections: showAnimateDirections,
            showInlineShotCards: showInlineShotCards,
            expandedShotCardIDs: expandedShotCardIDs
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
            let tealColor = show
                ? nsColor(
                    from: directionMarkupColorHex,
                    fallback: ScriptMarkupPalette.defaultDirectionHex
                ).withAlphaComponent(0.82)
                : NSColor.clear
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
            let orangeColor = showStoryboarding
                ? nsColor(
                    from: storyboardingMarkupColorHex,
                    fallback: ScriptMarkupPalette.defaultStoryboardingHex
                ).withAlphaComponent(0.86)
                : NSColor.clear
            for range in storyboardRanges {
                layoutManager.addTemporaryAttribute(
                    .foregroundColor, value: orangeColor, forCharacterRange: range
                )
            }
        }

        let animateRanges = AnimatePromptParser.promptRanges(in: textView.string)
        if !animateRanges.isEmpty {
            let pinkColor = showAnimateDirections
                ? nsColor(
                    from: animateMarkupColorHex,
                    fallback: ScriptMarkupPalette.defaultAnimateHex
                ).withAlphaComponent(0.86)
                : NSColor.clear
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

    static func readOnlyDisplayText(from text: String) -> String {
        let editable = prepareEditableText(from: text)
        var ranges: [NSRange] = []
        ranges.append(contentsOf: directionMarkupRanges(in: editable))
        ranges.append(contentsOf: StoryboardPromptParser.promptRanges(in: editable))
        ranges.append(contentsOf: parentheticalStageDirectionRanges(in: editable))
        ranges.append(contentsOf: AnimatePromptParser.promptRanges(in: editable))
        ranges.append(contentsOf: SummaryParser.summaryRanges(in: editable))

        let merged = mergedRanges(ranges)
        guard !merged.isEmpty else {
            return collapseBlankLines(in: editable)
        }

        let mutable = NSMutableString(string: editable)
        for range in merged.reversed() {
            mutable.replaceCharacters(in: range, with: "")
        }

        return collapseBlankLines(in: mutable as String)
    }

    static func prepareEditableText(from text: String) -> String {
        text.replacingOccurrences(
            of: #"(?m)\s*\(\d+\)\s*$"#,
            with: "",
            options: .regularExpression
        )
    }

    private static func collapseBlankLines(in text: String) -> String {
        text
            .replacingOccurrences(of: #"[ \t]+\n"#, with: "\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func nsColor(from hex: String, fallback fallbackHex: String) -> NSColor {
        NSColor(ScriptMarkupPalette.color(from: hex, fallback: fallbackHex))
            .usingColorSpace(.deviceRGB)
        ?? NSColor(ScriptMarkupPalette.color(from: fallbackHex, fallback: fallbackHex))
    }

    static func displayProjection(
        from text: String,
        showDirections: Bool,
        showStoryboarding: Bool,
        showAnimateDirections: Bool,
        showInlineShotCards: Bool = false,
        expandedShotCardIDs: Set<String> = []
    ) -> DisplayProjection {
        let editableText = prepareEditableText(from: text)
        let nsString = editableText as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let shotInstances = ScriptShotMarkup.cameraInstances(in: editableText)
        let shotRawRanges = shotInstances.map(\.rawRange)
        let nonShotHiddenRanges = subtractRanges(
            collectHiddenRanges(
                in: editableText,
                showDirections: showDirections,
                showStoryboarding: showStoryboarding,
                showAnimateDirections: showAnimateDirections,
                includeCameraRanges: true
            ),
            excluding: shotRawRanges
        )
        let hiddenEvents = (nonShotHiddenRanges.map { HiddenProjectionEvent(rawRange: $0, shot: nil) }
            + shotInstances.map { HiddenProjectionEvent(rawRange: $0.rawRange, shot: $0) })
            .sorted {
                if $0.rawRange.location == $1.rawRange.location { return $0.rawRange.length < $1.rawRange.length }
                return $0.rawRange.location < $1.rawRange.location
            }

        guard !hiddenEvents.isEmpty else {
            let visibleChunks = fullRange.length > 0 ? [VisibleChunk(rawRange: fullRange, displayRange: fullRange)] : []
            return DisplayProjection(
                rawText: editableText,
                displayText: editableText,
                hiddenRanges: [],
                visibleChunks: visibleChunks,
                shotAttachments: []
            )
        }

        var display = ""
        var visibleChunks: [VisibleChunk] = []
        var shotAttachments: [ShotAttachment] = []
        var rawCursor = 0
        var displayCursor = 0

        for event in hiddenEvents {
            guard event.rawRange.location >= rawCursor else { continue }
            if event.rawRange.location > rawCursor {
                let rawRange = NSRange(location: rawCursor, length: event.rawRange.location - rawCursor)
                let displayRange = NSRange(location: displayCursor, length: rawRange.length)
                display += nsString.substring(with: rawRange)
                visibleChunks.append(VisibleChunk(rawRange: rawRange, displayRange: displayRange))
                displayCursor += rawRange.length
            }

            if let shot = event.shot {
                let id = shot.card.id.uuidString
                let isExpanded = expandedShotCardIDs.contains(id)
                let placeholder = shotPlaceholder(isVisible: showInlineShotCards, isExpanded: isExpanded)
                let displayRange = NSRange(location: displayCursor, length: (placeholder as NSString).length)
                display += placeholder
                shotAttachments.append(
                    ShotAttachment(
                        id: id,
                        rawRange: shot.rawRange,
                        displayRange: displayRange,
                        extentDisplayRange: displayRange,
                        rawMarkup: shot.rawMarkup,
                        card: shot.card,
                        isExpanded: isExpanded,
                        canMoveEnd: false
                    )
                )
                displayCursor += displayRange.length
            }
            rawCursor = NSMaxRange(event.rawRange)
        }

        if rawCursor < fullRange.length {
            let rawRange = NSRange(location: rawCursor, length: fullRange.length - rawCursor)
            let displayRange = NSRange(location: displayCursor, length: rawRange.length)
            display += nsString.substring(with: rawRange)
            visibleChunks.append(VisibleChunk(rawRange: rawRange, displayRange: displayRange))
        }

        let displayLength = (display as NSString).length
        for index in shotAttachments.indices {
            let start = shotAttachments[index].displayRange.location
            let end = index + 1 < shotAttachments.count
                ? shotAttachments[index + 1].displayRange.location
                : displayLength
            let minLength = shotAttachments[index].displayRange.length
            shotAttachments[index].extentDisplayRange = NSRange(
                location: start,
                length: max(minLength, end - start)
            )
            shotAttachments[index].canMoveEnd = index + 1 < shotAttachments.count
        }

        return DisplayProjection(
            rawText: editableText,
            displayText: display,
            hiddenRanges: hiddenEvents.map(\.rawRange),
            visibleChunks: visibleChunks,
            shotAttachments: shotAttachments
        )
    }

    private struct HiddenProjectionEvent {
        let rawRange: NSRange
        let shot: ScriptCameraMarkupInstance?
    }

    private static func shotPlaceholder(isVisible: Bool, isExpanded: Bool) -> String {
        let lineCount = isVisible ? (isExpanded ? 18 : 3) : 2
        return "\n" + Array(repeating: " ", count: lineCount).joined(separator: "\n") + "\n"
    }

    private static func subtractRanges(_ ranges: [NSRange], excluding exclusions: [NSRange]) -> [NSRange] {
        guard !ranges.isEmpty, !exclusions.isEmpty else { return ranges }
        return ranges.filter { range in
            !exclusions.contains { NSIntersectionRange($0, range).length > 0 }
        }
    }

    static func hiddenRanges(
        in text: String,
        showDirections: Bool,
        showStoryboarding: Bool,
        showAnimateDirections: Bool
    ) -> [NSRange] {
        mergedRanges(
            collectHiddenRanges(
                in: text,
                showDirections: showDirections,
                showStoryboarding: showStoryboarding,
                showAnimateDirections: showAnimateDirections,
                includeCameraRanges: true
            )
        )
    }

    private static func collectHiddenRanges(
        in text: String,
        showDirections: Bool,
        showStoryboarding: Bool,
        showAnimateDirections: Bool,
        includeCameraRanges: Bool
    ) -> [NSRange] {
        let editableText = prepareEditableText(from: text)
        var ranges: [NSRange] = []
        ranges.append(contentsOf: ScriptShotMarkup.technicalDirectionRanges(in: editableText))
        if !showDirections {
            ranges.append(contentsOf: directionMarkupRanges(in: editableText))
        }
        if !showStoryboarding {
            ranges.append(contentsOf: StoryboardPromptParser.promptRanges(in: editableText))
            ranges.append(contentsOf: parentheticalStageDirectionRanges(in: editableText))
        }
        if !showAnimateDirections {
            ranges.append(contentsOf: AnimatePromptParser.promptRanges(in: editableText))
        }
        if includeCameraRanges {
            ranges.append(contentsOf: ScriptShotMarkup.cameraInstances(in: editableText).map(\.rawRange))
        }
        return ranges
    }

    static func renderHiddenRanges(
        in text: String,
        showDirections: Bool,
        showStoryboarding: Bool,
        showAnimateDirections: Bool
    ) -> [NSRange] {
        hiddenRanges(
            in: text,
            showDirections: showDirections,
            showStoryboarding: showStoryboarding,
            showAnimateDirections: showAnimateDirections
        )
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

            if openBlockLocation != nil {
                if trimmed.hasSuffix(")") {
                    ranges.append(NSRange(location: openBlockLocation!, length: NSMaxRange(lineRange) - openBlockLocation!))
                    openBlockLocation = nil
                }
                continue
            }

            guard trimmed.hasPrefix("(") else { continue }
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

    /// Apply an edit to the displayed text while preserving any hidden markup
    /// ranges in the underlying raw source.
    static func applyDisplayEdit(
        rawText: String,
        projection: DisplayProjection,
        affectedDisplayRange: NSRange,
        replacementString: String?
    ) -> String {
        guard !editTouchesShotAttachment(affectedDisplayRange, attachments: projection.shotAttachments) else {
            return prepareEditableText(from: rawText)
        }

        let replacement = replacementString ?? ""
        let sourceText = prepareEditableText(from: rawText)
        let totalDisplayLength = (projection.displayText as NSString).length
        let displayStart = max(0, min(affectedDisplayRange.location, totalDisplayLength))
        let displayEnd = max(displayStart, min(NSMaxRange(affectedDisplayRange), totalDisplayLength))
        let rawStart = displayToRaw(displayStart, projection: projection)
        let rawEnd = displayToRaw(displayEnd, projection: projection)
        let nsSource = sourceText as NSString
        guard rawStart <= rawEnd, rawStart <= nsSource.length else { return sourceText }
        let clampedRawEnd = max(rawStart, min(rawEnd, nsSource.length))
        let mutable = NSMutableString(string: sourceText)
        mutable.replaceCharacters(
            in: NSRange(location: rawStart, length: clampedRawEnd - rawStart),
            with: replacement
        )
        let rebuilt = mutable as String
        guard validateHiddenContentPreserved(
            original: sourceText,
            edited: rebuilt,
            hiddenRanges: projection.hiddenRanges
        ) else {
            return sourceText
        }
        return prepareEditableText(from: rebuilt)
    }

    private static func editTouchesShotAttachment(
        _ editRange: NSRange,
        attachments: [ShotAttachment]
    ) -> Bool {
        guard !attachments.isEmpty else { return false }
        for attachment in attachments {
            let protected = attachment.displayRange
            if editRange.length == 0 {
                if editRange.location > protected.location && editRange.location < NSMaxRange(protected) {
                    return true
                }
            } else if NSIntersectionRange(editRange, protected).length > 0 {
                return true
            }
        }
        return false
    }

    private static func removeAdjustedShotPlaceholders(
        from displayText: String,
        attachments: [ShotAttachment],
        editRange: NSRange,
        replacementLength: Int
    ) -> String {
        guard !attachments.isEmpty else { return displayText }
        let delta = replacementLength - editRange.length
        let editEnd = NSMaxRange(editRange)
        let adjustedRanges = attachments.map { attachment -> NSRange in
            var range = attachment.displayRange
            if range.location >= editEnd {
                range.location += delta
            }
            return range
        }
        let mutable = NSMutableString(string: displayText)
        let fullLength = mutable.length
        for range in adjustedRanges.sorted(by: { $0.location > $1.location }) {
            let clamped = NSIntersectionRange(range, NSRange(location: 0, length: fullLength))
            guard clamped.length > 0 else { continue }
            mutable.replaceCharacters(in: clamped, with: "")
        }
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

            if displayOffset < displayStart {
                return chunk.rawRange.location
            }
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
        var currentProjection = DisplayProjection(rawText: "", displayText: "", hiddenRanges: [], visibleChunks: [], shotAttachments: [])
        var lastIsEditable = true
        var lastShowDirections = true
        var lastShowStoryboarding = true
        var lastShowAnimateDirections = true
        var lastShowInlineShotCards = false
        var lastAllowsShotCardEditing = false
        var lastAllowsShotBoundaryEditing = false
        var lastDirectionMarkupColorHex = ScriptMarkupPalette.defaultDirectionHex
        var lastStoryboardingMarkupColorHex = ScriptMarkupPalette.defaultStoryboardingHex
        var lastAnimateMarkupColorHex = ScriptMarkupPalette.defaultAnimateHex
        var lastHighlightRanges: [NSRange] = []
        var lastExternalRanges: [NSRange] = []
        var lastExternalOpacity: Double = 0
        var lastExpandedShotCardIDs: Set<String> = []
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

            let newRawText = ScriptTextEditor.prepareEditableText(from: ScriptTextEditor.applyDisplayEdit(
                rawText: currentRawText,
                projection: currentProjection,
                affectedDisplayRange: edit.affectedRange,
                replacementString: edit.replacementString
            ))

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
                showAnimateDirections: parent.showAnimateDirections,
                directionMarkupColorHex: parent.directionMarkupColorHex,
                storyboardingMarkupColorHex: parent.storyboardingMarkupColorHex,
                animateMarkupColorHex: parent.animateMarkupColorHex,
                showInlineShotCards: parent.showInlineShotCards,
                expandedShotCardIDs: parent.expandedShotCardIDs.wrappedValue
            )
            currentRawText = sourceText
            currentProjection = projection
            applyProjectedHighlights(to: tv)
            applyShotPlaceholderStyling(to: tv)

            // Restore cursor position, clamped to the new text length.
            let newLength = (tv.string as NSString).length
            let clampedLocation = min(savedSelection.location, newLength)
            let clampedEnd = min(clampedLocation + savedSelection.length, newLength)
            tv.setSelectedRange(NSRange(location: clampedLocation, length: clampedEnd - clampedLocation))

            hostView?.recalcHeight()
            updateShotOverlays(in: tv)
            isStyling = false
        }

        func applyShotPlaceholderStyling(to tv: NSTextView) {
            guard let layoutManager = tv.layoutManager else { return }
            for attachment in currentProjection.shotAttachments {
                let fullRange = NSRange(location: 0, length: (tv.string as NSString).length)
                let range = NSIntersectionRange(attachment.displayRange, fullRange)
                guard range.length > 0 else { continue }
                layoutManager.addTemporaryAttribute(
                    .foregroundColor,
                    value: NSColor.clear,
                    forCharacterRange: range
                )
            }
        }

        func updateShotOverlays(in tv: NSTextView) {
            guard let hostView else { return }
            hostView.shotOverlayView.resetHandleRegions()
            hostView.shotOverlayView.subviews.forEach { $0.removeFromSuperview() }
            guard !currentProjection.shotAttachments.isEmpty else { return }

            guard let layoutManager = tv.layoutManager,
                  let textContainer = tv.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)

            for attachment in currentProjection.shotAttachments {
                let frame = overlayFrame(for: attachment, textView: tv)
                let host = ShotOverlayHostingView(
                    rootView: InlineShotCardOverlayView(
                        attachment: attachment,
                        showCard: parent.showInlineShotCards,
                        canEdit: parent.allowsShotCardEditing,
                        onToggleExpanded: { [weak self] id in
                            self?.toggleShotCardExpansion(id: id)
                        },
                        onCommit: { [weak self] updated in
                            self?.replaceShotCard(attachment: attachment, with: updated, in: tv)
                        },
                        onMoveBoundary: { [weak self] edge, translation in
                            self?.moveShotBoundary(attachment: attachment, edge: edge, translation: translation, in: tv)
                        }
                    )
                )
                host.topHitHeight = topHitHeight(for: attachment)
                host.topDragHeight = parent.showInlineShotCards ? 62 : 24
                host.bottomHitHeight = parent.showInlineShotCards && attachment.canMoveEnd ? 44 : 0
                host.onFallbackBoundaryDrag = { [weak self] edge, translation in
                    self?.moveShotBoundary(attachment: attachment, edge: edge, translation: translation, in: tv)
                }
                host.onFallbackClick = { [weak self] point in
                    if attachment.isExpanded {
                        if point.x < 54, point.y < 34 {
                            self?.toggleShotCardExpansion(id: attachment.id)
                        }
                    } else {
                        self?.toggleShotCardExpansion(id: attachment.id)
                    }
                }
                host.frame = frame
                host.autoresizingMask = [.width]
                hostView.shotOverlayView.addSubview(host)
                addShotHandleOverlays(
                    for: attachment,
                    frame: frame,
                    in: hostView.shotOverlayView,
                    textView: tv
                )
            }
        }

        private func addShotHandleOverlays(
            for attachment: ShotAttachment,
            frame: NSRect,
            in overlayView: ShotOverlayContainerView,
            textView tv: NSTextView
        ) {
            let canEditBoundaries = parent.allowsShotBoundaryEditing

            if canEditBoundaries {
                overlayView.addHandleRegion(
                    kind: .startBoundary,
                    frame: NSRect(
                        x: frame.minX + 2,
                        y: frame.minY,
                        width: max(40, frame.width - 4),
                        height: 18
                    ),
                    onDragEnded: { [weak self] translation in
                        self?.moveShotBoundary(attachment: attachment, edge: .start, translation: translation, in: tv)
                    },
                    onRemove: { [weak self] in
                        self?.removeShot(attachment: attachment, in: tv)
                    }
                )
            }

            overlayView.addHandleRegion(
                kind: .toggleCard,
                frame: NSRect(
                    x: frame.minX + 6,
                    y: frame.minY + 9,
                    width: 30,
                    height: 28
                ),
                onClick: { [weak self] in
                    self?.toggleShotCardExpansion(id: attachment.id)
                }
            )

            guard canEditBoundaries else { return }

            overlayView.addHandleRegion(
                kind: .moveShot,
                frame: NSRect(
                    x: frame.maxX - 54,
                    y: frame.minY + 7,
                    width: 34,
                    height: 34
                ),
                onDragEnded: { [weak self] translation in
                    self?.moveShotBoundary(attachment: attachment, edge: .start, translation: translation, in: tv)
                },
                onRemove: { [weak self] in
                    self?.removeShot(attachment: attachment, in: tv)
                }
            )

            if attachment.canMoveEnd {
                overlayView.addHandleRegion(
                    kind: .endBoundary,
                    frame: NSRect(
                        x: frame.minX + 2,
                        y: frame.maxY - 44,
                        width: max(40, frame.width - 4),
                        height: 44
                    ),
                    onDragEnded: { [weak self] translation in
                        self?.moveShotBoundary(attachment: attachment, edge: .end, translation: translation, in: tv)
                    },
                    onRemove: { [weak self] in
                        self?.removeShot(attachment: attachment, in: tv)
                    }
                )
            }
        }

        private func overlayFrame(for attachment: ShotAttachment, textView tv: NSTextView) -> NSRect {
            guard let layoutManager = tv.layoutManager,
                  let textContainer = tv.textContainer else {
                return NSRect(x: 0, y: 0, width: tv.bounds.width, height: 24)
            }
            let visualRange = parent.showInlineShotCards ? attachment.extentDisplayRange : attachment.displayRange
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: visualRange,
                actualCharacterRange: nil
            )
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += tv.textContainerOrigin.x
            rect.origin.y += tv.textContainerOrigin.y
            let minHeight = topHitHeight(for: attachment)
                + (parent.showInlineShotCards && attachment.canMoveEnd ? 24 : 0)
                + 8
            return NSRect(
                x: 0,
                y: max(0, rect.minY),
                width: max(40, tv.bounds.width),
                height: max(minHeight, rect.height)
            )
        }

        private func topHitHeight(for attachment: ShotAttachment) -> CGFloat {
            guard parent.showInlineShotCards else { return 24 }
            return attachment.isExpanded ? 370 : 62
        }

        private func toggleShotCardExpansion(id: String) {
            var ids = parent.expandedShotCardIDs.wrappedValue
            if ids.contains(id) {
                ids.remove(id)
            } else {
                ids.insert(id)
            }
            parent.expandedShotCardIDs.wrappedValue = ids
            lastExpandedShotCardIDs = ids
            if let tv = hostView?.textView {
                refreshDisplay(to: tv, rawText: currentRawText)
            }
        }

        private func replaceShotCard(
            attachment: ShotAttachment,
            with updated: ScriptShotCard,
            in tv: NSTextView
        ) {
            let raw = currentRawText as NSString
            guard NSMaxRange(attachment.rawRange) <= raw.length else { return }
            let replacement = ScriptShotMarkup.editedMarkup(for: updated)
            let mutable = NSMutableString(string: currentRawText)
            mutable.replaceCharacters(in: attachment.rawRange, with: replacement)
            let newRawText = ScriptTextEditor.prepareEditableText(from: mutable as String)
            guard newRawText != currentRawText else { return }
            pushUndo(currentRawText)
            currentRawText = newRawText
            parent.text = newRawText
            refreshDisplay(to: tv, rawText: newRawText)
        }

        private func moveShotBoundary(
            attachment: ShotAttachment,
            edge: ShotBoundaryEdge,
            translation: CGSize,
            in tv: NSTextView
        ) {
            guard parent.allowsShotBoundaryEditing else { return }
            guard abs(translation.height) > 6 || abs(translation.width) > 12 else { return }
            let movingAttachment: ShotAttachment
            switch edge {
            case .start:
                movingAttachment = attachment
            case .end:
                guard let nextAttachment = nextShotAttachment(after: attachment) else { return }
                movingAttachment = nextAttachment
            }
            let raw = currentRawText as NSString
            guard NSMaxRange(movingAttachment.rawRange) <= raw.length else { return }
            guard let targetDisplayOffset = displayOffset(
                for: attachment,
                edge: edge,
                translation: translation,
                in: tv
            ) else { return }
            var destinationRawOffset = ScriptTextEditor.displayToRaw(
                targetDisplayOffset,
                projection: currentProjection
            )
            if destinationRawOffset >= movingAttachment.rawRange.location,
               destinationRawOffset <= NSMaxRange(movingAttachment.rawRange) {
                return
            }
            destinationRawOffset = clampedShotBoundaryDestination(
                destinationRawOffset,
                movingAttachment: movingAttachment,
                rawLength: raw.length
            )
            if destinationRawOffset >= movingAttachment.rawRange.location,
               destinationRawOffset <= NSMaxRange(movingAttachment.rawRange) {
                return
            }

            let movingMarkup = raw.substring(with: movingAttachment.rawRange)
            let mutable = NSMutableString(string: currentRawText)
            mutable.replaceCharacters(in: movingAttachment.rawRange, with: "")
            if destinationRawOffset > movingAttachment.rawRange.location {
                destinationRawOffset -= movingAttachment.rawRange.length
            }
            destinationRawOffset = max(0, min(destinationRawOffset, mutable.length))
            mutable.insert(movingMarkup, at: destinationRawOffset)
            let newRawText = ScriptTextEditor.prepareEditableText(from: mutable as String)
            guard newRawText != currentRawText else { return }
            pushUndo(currentRawText)
            currentRawText = newRawText
            parent.text = newRawText
            refreshDisplay(to: tv, rawText: newRawText)
        }

        private func removeShot(
            attachment: ShotAttachment,
            in tv: NSTextView
        ) {
            guard parent.allowsShotBoundaryEditing else { return }
            let raw = currentRawText as NSString
            guard NSMaxRange(attachment.rawRange) <= raw.length else { return }
            let mutable = NSMutableString(string: currentRawText)
            mutable.replaceCharacters(in: attachment.rawRange, with: "")
            let newRawText = ScriptTextEditor.prepareEditableText(from: mutable as String)
            guard newRawText != currentRawText else { return }
            pushUndo(currentRawText)
            currentRawText = newRawText
            parent.text = newRawText
            refreshDisplay(to: tv, rawText: newRawText)
        }

        private func clampedShotBoundaryDestination(
            _ destination: Int,
            movingAttachment: ShotAttachment,
            rawLength: Int
        ) -> Int {
            guard let index = currentProjection.shotAttachments.firstIndex(where: { $0.id == movingAttachment.id }) else {
                return max(0, min(destination, rawLength))
            }
            let lowerBound = index > 0
                ? NSMaxRange(currentProjection.shotAttachments[index - 1].rawRange)
                : 0
            let upperBound = index + 1 < currentProjection.shotAttachments.count
                ? currentProjection.shotAttachments[index + 1].rawRange.location
                : rawLength
            return max(lowerBound, min(destination, upperBound))
        }

        private func nextShotAttachment(after attachment: ShotAttachment) -> ShotAttachment? {
            guard let index = currentProjection.shotAttachments.firstIndex(where: { $0.id == attachment.id }),
                  index + 1 < currentProjection.shotAttachments.count else {
                return nil
            }
            return currentProjection.shotAttachments[index + 1]
        }

        private func displayOffset(
            for attachment: ShotAttachment,
            edge: ShotBoundaryEdge,
            translation: CGSize,
            in tv: NSTextView
        ) -> Int? {
            guard let layoutManager = tv.layoutManager,
                  let textContainer = tv.textContainer else { return nil }
            let frame = overlayFrame(for: attachment, textView: tv)
            var point = NSPoint(
                x: min(max(frame.midX + translation.width, 0), max(0, tv.bounds.width - 1)),
                y: max(0, (edge == .start ? frame.minY + 10 : frame.maxY - 8) + translation.height)
            )
            point.x -= tv.textContainerOrigin.x
            point.y -= tv.textContainerOrigin.y
            return layoutManager.characterIndex(
                for: point,
                in: textContainer,
                fractionOfDistanceBetweenInsertionPoints: nil
            )
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

// MARK: - Inline Shot Cards

@available(macOS 26.0, *)
private struct InlineShotCardOverlayView: View {
    let attachment: ScriptTextEditor.ShotAttachment
    let showCard: Bool
    let canEdit: Bool
    let onToggleExpanded: (String) -> Void
    let onCommit: (ScriptShotCard) -> Void
    let onMoveBoundary: (ScriptTextEditor.ShotBoundaryEdge, CGSize) -> Void

    @State private var label: String
    @State private var shotSize: String
    @State private var movement: String
    @State private var focus: String
    @State private var intent: String
    @State private var bars: String
    @State private var notes: String
    @State private var timeOfDay: String
    @State private var interiorExterior: String
    @State private var weatherAtmosphere: String
    @State private var lightSource: String
    @State private var lens: String
    @State private var cameraAngle: String
    @State private var depthOfField: String
    @State private var continuityNotes: String
    @State private var characterLeft: String
    @State private var characterMiddle: String
    @State private var characterRight: String
    @State private var characterLeftFacing: String
    @State private var characterMiddleFacing: String
    @State private var characterRightFacing: String
    @State private var places: String
    @State private var props: String
    @State private var mood: String
    @State private var lighting: String
    @State private var landmarks: String

    init(
        attachment: ScriptTextEditor.ShotAttachment,
        showCard: Bool,
        canEdit: Bool,
        onToggleExpanded: @escaping (String) -> Void,
        onCommit: @escaping (ScriptShotCard) -> Void,
        onMoveBoundary: @escaping (ScriptTextEditor.ShotBoundaryEdge, CGSize) -> Void
    ) {
        self.attachment = attachment
        self.showCard = showCard
        self.canEdit = canEdit
        self.onToggleExpanded = onToggleExpanded
        self.onCommit = onCommit
        self.onMoveBoundary = onMoveBoundary
        _label = State(initialValue: attachment.card.label ?? attachment.card.camera.label ?? "")
        _shotSize = State(initialValue: attachment.card.camera.shotSize ?? "")
        _movement = State(initialValue: attachment.card.camera.movement ?? "")
        _focus = State(initialValue: attachment.card.camera.focus ?? "")
        _intent = State(initialValue: attachment.card.camera.intent ?? "")
        _bars = State(initialValue: Self.barsString(from: attachment.card.timing))
        _notes = State(initialValue: attachment.card.camera.notes ?? "")
        _timeOfDay = State(initialValue: attachment.card.setting.timeOfDay ?? "")
        _interiorExterior = State(initialValue: attachment.card.setting.interiorExterior ?? "")
        _weatherAtmosphere = State(initialValue: attachment.card.setting.weatherAtmosphere ?? "")
        _lightSource = State(initialValue: attachment.card.setting.lightSource ?? "")
        _lens = State(initialValue: attachment.card.setting.lens ?? "")
        _cameraAngle = State(initialValue: attachment.card.setting.cameraAngle ?? "")
        _depthOfField = State(initialValue: attachment.card.setting.depthOfField ?? "")
        _continuityNotes = State(initialValue: attachment.card.setting.continuityNotes ?? "")
        let framing = Self.characterFramingStrings(for: attachment.card)
        _characterLeft = State(initialValue: framing.left)
        _characterMiddle = State(initialValue: framing.middle)
        _characterRight = State(initialValue: framing.right)
        _characterLeftFacing = State(initialValue: attachment.card.characterFraming.leftFacing ?? "")
        _characterMiddleFacing = State(initialValue: attachment.card.characterFraming.middleFacing ?? "")
        _characterRightFacing = State(initialValue: attachment.card.characterFraming.rightFacing ?? "")
        _places = State(initialValue: attachment.card.tags.places.joined(separator: ", "))
        _props = State(initialValue: attachment.card.tags.props.joined(separator: ", "))
        _mood = State(initialValue: attachment.card.tags.mood.joined(separator: ", "))
        _lighting = State(initialValue: attachment.card.tags.lighting.joined(separator: ", "))
        _landmarks = State(initialValue: attachment.card.tags.landmarks.joined(separator: ", "))
    }

    var body: some View {
        if showCard {
            cardBody
        } else {
            shotBreakLine
        }
    }

    private var cardBody: some View {
        ZStack(alignment: .top) {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.09, green: 0.10, blue: 0.11).opacity(0.96), location: 0),
                    .init(color: Color(red: 0.07, green: 0.08, blue: 0.09).opacity(0.58), location: 0.38),
                    .init(color: Color.black.opacity(0.02), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    header
                    if attachment.isExpanded {
                        expandedControls
                    }
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)

                Spacer(minLength: 0)

                if attachment.canMoveEnd {
                    endHandle
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 0.7)
        }
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 0.7)
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.10))
                .frame(width: 0.7)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 2)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: attachment.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
            .help(attachment.isExpanded ? "Collapse Shot" : "Expand Shot")

            Image(systemName: "video")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.orange.opacity(0.85))

            VStack(alignment: .leading, spacing: 1) {
                Text("DIRECTION")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Color.orange.opacity(0.62))
                Text(headline)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .lineLimit(1)
                if !subline.isEmpty {
                    Text(subline)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.white.opacity(0.48))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.32))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .help("Move Shot")

            if canEdit {
                Button {
                    commit()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Apply Shot")
            }
        }
        .contentShape(Rectangle())
    }

    private var endHandle: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 1)
            VStack(spacing: 2) {
                Capsule()
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 34, height: 2)
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 22, height: 2)
            }
            Rectangle()
                .fill(Color.clear)
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 24)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onEnded { value in
                    onMoveBoundary(.end, value.translation)
                }
        )
        .help("Drag Shot End")
    }

    private var expandedControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            shotTextField("Direction", text: $notes)
            HStack(spacing: 8) {
                shotPicker(title: "Frame", value: $shotSize, options: framingOptions)
                shotPicker(title: "Move", value: $movement, options: movementOptions)
                shotPicker(title: "Intent", value: $intent, options: intentOptions)
            }
            HStack(spacing: 8) {
                shotTextField("Label", text: $label)
                shotTextField("Focus", text: $focus)
                shotTextField("Bars", text: $bars)
            }
            HStack(spacing: 8) {
                shotTextField("Places", text: $places)
                shotPicker(title: "Time", value: $timeOfDay, options: timeOfDayOptions)
                shotPicker(title: "Int/Ext", value: $interiorExterior, options: interiorExteriorOptions)
            }
            HStack(spacing: 8) {
                shotPicker(title: "Weather", value: $weatherAtmosphere, options: weatherAtmosphereOptions)
                shotPicker(title: "Light Source", value: $lightSource, options: lightSourceOptions)
            }
            HStack(spacing: 8) {
                characterFrameControl("Character Left", text: $characterLeft, facing: $characterLeftFacing)
                characterFrameControl("Character Middle", text: $characterMiddle, facing: $characterMiddleFacing)
                characterFrameControl("Character Right", text: $characterRight, facing: $characterRightFacing)
            }
            HStack(spacing: 8) {
                shotPicker(title: "Lens", value: $lens, options: lensOptions)
                shotPicker(title: "Angle", value: $cameraAngle, options: cameraAngleOptions)
                shotPicker(title: "DOF", value: $depthOfField, options: depthOfFieldOptions)
            }
            HStack(spacing: 8) {
                shotTextField("Props", text: $props)
                shotTextField("Mood", text: $mood)
                shotTextField("Light", text: $lighting)
            }
            HStack(spacing: 8) {
                shotTextField("Landmarks", text: $landmarks)
                shotTextField("Continuity", text: $continuityNotes)
            }
        }
        .disabled(!canEdit)
        .opacity(canEdit ? 1 : 0.72)
    }

    private var shotBreakLine: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.orange.opacity(0.32))
                .frame(height: 1)
            Image(systemName: "video")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.orange.opacity(0.46))
            Rectangle()
                .fill(Color.orange.opacity(0.32))
                .frame(height: 1)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .help("Shot Break")
    }

    private func shotPicker(title: String, value: Binding<String>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.38))
            Picker(title, selection: value) {
                ForEach(optionsWithCurrent(value.wrappedValue, options: options), id: \.self) { option in
                    Text(option.isEmpty ? "Unset" : option.replacingOccurrences(of: "_", with: " "))
                        .tag(option)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .onChange(of: value.wrappedValue) { _, _ in
                commit()
            }
        }
    }

    private func shotTextField(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 10))
            .onSubmit { commit() }
    }

    private func characterFrameControl(
        _ title: String,
        text: Binding<String>,
        facing: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            shotTextField(title, text: text)
            shotPicker(title: "Facing", value: facing, options: facingOptions)
        }
    }

    private var headline: String {
        let resolved = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !resolved.isEmpty { return resolved }
        if !shotSize.isEmpty { return shotSize.replacingOccurrences(of: "_", with: " ").capitalized }
        if !movement.isEmpty { return movement.replacingOccurrences(of: "_", with: " ").capitalized }
        if !notes.isEmpty { return notes }
        return "Direction"
    }

    private var subline: String {
        [
            shotSize.nilIfEmpty,
            movement.nilIfEmpty,
            focus.nilIfEmpty.map { "on \($0)" },
            intent.nilIfEmpty,
            bars.nilIfEmpty.map { "bars \($0)" }
        ]
        .compactMap { $0 }
        .joined(separator: "  |  ")
    }

    private var framingOptions: [String] {
        ["", "extreme_wide", "wide", "medium_wide", "medium", "medium_close", "close", "extreme_close"]
    }

    private var movementOptions: [String] {
        ["", "hold", "zoom_in", "zoom_out", "pan_left", "pan_right", "pan_up", "pan_down", "track", "shake"]
    }

    private var intentOptions: [String] {
        ["", "establishing", "reveal", "reaction", "handoff", "dialogue", "movement", "confrontation", "insert", "transition", "emotional"]
    }

    private var timeOfDayOptions: [String] {
        ["", "pre_dawn", "dawn", "morning", "midday", "afternoon", "golden_hour", "sunset", "dusk", "night", "late_night"]
    }

    private var interiorExteriorOptions: [String] {
        ["", "interior", "exterior", "interior_to_exterior", "exterior_to_interior"]
    }

    private var weatherAtmosphereOptions: [String] {
        ["", "clear", "haze", "dust", "smoke", "rain", "storm", "fog", "snow", "wind", "heat_shimmer"]
    }

    private var lightSourceOptions: [String] {
        ["", "natural_window", "sunlight", "moonlight", "firelight", "practical_lamp", "fluorescent", "neon", "vehicle_headlights", "candlelight", "stage_light"]
    }

    private var lensOptions: [String] {
        ["", "wide", "normal", "telephoto", "macro", "anamorphic"]
    }

    private var cameraAngleOptions: [String] {
        ["", "eye_level", "low_angle", "high_angle", "overhead", "dutch_angle", "ground_level", "shoulder_level"]
    }

    private var depthOfFieldOptions: [String] {
        ["", "deep_focus", "medium_depth", "shallow_focus", "background_blur", "foreground_blur"]
    }

    private var facingOptions: [String] {
        ["", "towards_camera", "away_from_camera", "left", "right", "three_quarter_left", "three_quarter_right", "profile_left", "profile_right", "up", "down"]
    }

    private func optionsWithCurrent(_ current: String, options: [String]) -> [String] {
        if current.isEmpty || options.contains(current) { return options }
        return options + [current]
    }

    private func commit() {
        guard canEdit else { return }
        let updated = ScriptShotMarkup.replacementCard(
            from: attachment.card,
            label: label,
            direction: attachment.card.direction,
            shotSize: shotSize,
            movement: movement,
            focus: focus,
            intent: intent,
            bars: bars,
            notes: notes,
            timeOfDay: timeOfDay,
            interiorExterior: interiorExterior,
            weatherAtmosphere: weatherAtmosphere,
            lightSource: lightSource,
            lens: lens,
            cameraAngle: cameraAngle,
            depthOfField: depthOfField,
            continuityNotes: continuityNotes,
            characters: "",
            characterLeft: characterLeft,
            characterMiddle: characterMiddle,
            characterRight: characterRight,
            characterLeftFacing: characterLeftFacing,
            characterMiddleFacing: characterMiddleFacing,
            characterRightFacing: characterRightFacing,
            places: places,
            props: props,
            mood: mood,
            lighting: lighting,
            landmarks: landmarks
        )
        onCommit(updated)
    }

    private static func barsString(from timing: TimingSpec) -> String {
        if let start = timing.startBar, let end = timing.endBar {
            return "\(start)-\(end)"
        }
        if let start = timing.startBar {
            return "\(start)"
        }
        return ""
    }

    private static func characterFramingStrings(for card: ScriptShotCard) -> (left: String, middle: String, right: String) {
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
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - Script Text Host View

/// Custom NSView that hosts an NSTextView directly (no NSScrollView)
/// and reports layout height via a callback so SwiftUI can size the frame.
@MainActor
final class ScriptTextHostView: NSView {
    let textView = NSTextView()
    let shotOverlayView = ShotOverlayContainerView()
    var onHeightChanged: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.autoresizingMask = [.width, .height]
        textView.backgroundColor = .clear
        addSubview(textView)
        shotOverlayView.wantsLayer = true
        shotOverlayView.layer?.backgroundColor = NSColor.clear.cgColor
        shotOverlayView.autoresizingMask = [.width, .height]
        addSubview(shotOverlayView, positioned: .above, relativeTo: textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        textView.frame = bounds
        shotOverlayView.frame = bounds
        addSubview(shotOverlayView, positioned: .above, relativeTo: textView)
        let w = bounds.width
        if w > 0 {
            textView.textContainer?.containerSize = NSSize(width: w, height: .greatestFiniteMagnitude)
            recalcHeight()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let overlayPoint = shotOverlayView.convert(point, from: self)
        if let overlayHit = shotOverlayView.hitTest(overlayPoint) {
            return overlayHit
        }
        let textPoint = textView.convert(point, from: self)
        return textView.hitTest(textPoint)
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

@MainActor
final class ShotOverlayHostingView<Content: View>: NSHostingView<Content> {
    var onFallbackClick: ((NSPoint) -> Void)?
    fileprivate var onFallbackBoundaryDrag: ((ScriptTextEditor.ShotBoundaryEdge, CGSize) -> Void)?
    var topHitHeight: CGFloat = 60
    var topDragHeight: CGFloat = 60
    var bottomHitHeight: CGFloat = 0
    private var mouseDownPoint: NSPoint?
    private var mouseDownEdge: ScriptTextEditor.ShotBoundaryEdge?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let hit, hit !== self {
            return hit
        }
        return isInteractive(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        mouseDownPoint = point
        mouseDownEdge = dragEdge(for: point)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        let upPoint = convert(event.locationInWindow, from: nil)
        let downPoint = mouseDownPoint
        let edge = mouseDownEdge
        super.mouseUp(with: event)
        defer {
            mouseDownPoint = nil
            mouseDownEdge = nil
        }
        guard let downPoint, let edge else { return }
        let dx = upPoint.x - downPoint.x
        let dy = upPoint.y - downPoint.y
        if hypot(dx, dy) >= 4 {
            onFallbackBoundaryDrag?(edge, CGSize(width: dx, height: dy))
            return
        }
        if edge == .start {
            onFallbackClick?(upPoint)
        }
    }

    private func isInteractive(_ point: NSPoint) -> Bool {
        let yFromTop = isFlipped ? point.y : bounds.height - point.y
        if yFromTop >= 0, yFromTop <= topHitHeight {
            return true
        }
        if bottomHitHeight > 0 {
            let yFromBottom = bounds.height - yFromTop
            if yFromBottom >= 0, yFromBottom <= bottomHitHeight {
                return true
            }
        }
        return false
    }

    private func dragEdge(for point: NSPoint) -> ScriptTextEditor.ShotBoundaryEdge? {
        let yFromTop = isFlipped ? point.y : bounds.height - point.y
        if yFromTop >= 0, yFromTop <= topDragHeight {
            return .start
        }
        if bottomHitHeight > 0 {
            let yFromBottom = bounds.height - yFromTop
            if yFromBottom >= 0, yFromBottom <= bottomHitHeight {
                return .end
            }
        }
        return nil
    }
}

@MainActor
private struct ShotOverlayHandleRegion {
    fileprivate let kind: ScriptTextEditor.ShotHandleKind
    fileprivate let frame: NSRect
    fileprivate var onDragEnded: ((CGSize) -> Void)?
    fileprivate var onClick: (() -> Void)?
    fileprivate var onRemove: (() -> Void)?

    fileprivate var cursor: NSCursor {
        switch kind {
        case .startBoundary, .endBoundary:
            return .resizeUpDown
        case .moveShot:
            return .openHand
        case .toggleCard:
            return .pointingHand
        }
    }
}

@MainActor
final class ShotOverlayContainerView: NSView {
    private var handleRegions: [ShotOverlayHandleRegion] = []
    private var activeHandle: ShotOverlayHandleRegion?
    private var mouseDownPoint: NSPoint?
    private var pendingRemoveAction: (() -> Void)?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func resetHandleRegions() {
        handleRegions.removeAll()
        activeHandle = nil
        mouseDownPoint = nil
        discardCursorRects()
    }

    fileprivate func addHandleRegion(
        kind: ScriptTextEditor.ShotHandleKind,
        frame: NSRect,
        onDragEnded: ((CGSize) -> Void)? = nil,
        onClick: (() -> Void)? = nil,
        onRemove: (() -> Void)? = nil
    ) {
        handleRegions.append(
            ShotOverlayHandleRegion(
                kind: kind,
                frame: frame,
                onDragEnded: onDragEnded,
                onClick: onClick,
                onRemove: onRemove
            )
        )
        discardCursorRects()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if handleRegion(at: point) != nil {
            return self
        }
        for subview in subviews.reversed() {
            let converted = subview.convert(point, from: self)
            if let hit = subview.hitTest(converted) {
                return hit
            }
        }
        return nil
    }

    override func resetCursorRects() {
        for handle in handleRegions {
            addCursorRect(handle.frame, cursor: handle.cursor)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        activeHandle = handleRegion(at: point)
        mouseDownPoint = point
        if activeHandle?.kind == .moveShot {
            NSCursor.closedHand.set()
        } else {
            activeHandle?.cursor.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if activeHandle?.kind == .moveShot {
            NSCursor.closedHand.set()
        } else {
            activeHandle?.cursor.set()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let upPoint = convert(event.locationInWindow, from: nil)
        defer {
            activeHandle = nil
            mouseDownPoint = nil
        }
        guard let handle = activeHandle, let downPoint = mouseDownPoint else { return }
        let dx = upPoint.x - downPoint.x
        let dy = upPoint.y - downPoint.y
        if hypot(dx, dy) >= 4 {
            handle.onDragEnded?(CGSize(width: dx, height: dy))
        } else {
            handle.onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let handle = handleRegion(at: point),
              let onRemove = handle.onRemove else { return }
        pendingRemoveAction = onRemove
        let menu = NSMenu()
        let remove = NSMenuItem(
            title: "Remove Shot",
            action: #selector(removeShotFromMenu(_:)),
            keyEquivalent: ""
        )
        remove.target = self
        menu.addItem(remove)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func removeShotFromMenu(_ sender: Any?) {
        pendingRemoveAction?()
        pendingRemoveAction = nil
    }

    private func handleRegion(at point: NSPoint) -> ShotOverlayHandleRegion? {
        handleRegions.reversed().first { $0.frame.contains(point) }
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
