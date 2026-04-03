import SwiftUI
import ProjectKit
#if canImport(AppKit)
import AppKit
#endif

@available(macOS 26.0, *)
struct LLMInspectorView: View {
    @Bindable var store: ScriptStore

    enum ChatScope: String {
        case scene = "Scene"
        case show = "Show"
    }

    /// One client per session key — enables concurrent generation across scenes.
    @State private var clients: [String: MiniMaxClient] = [:]
    @State private var inputText: String = ""
    @State private var suggestions: [LLMSuggestion] = []
    @State private var undoStack: [LLMUndoEntry] = []
    @State private var showUndoHistory: Bool = false
    @State private var showArchiveList: Bool = false
    @State private var showSettings: Bool = false
    // providerConfig removed — use LLMProviderConfig.shared directly to avoid stale @State copies
    @AppStorage("operawriter.llm.chatScope") private var chatScope: String = ChatScope.scene.rawValue
    @FocusState private var inputFocused: Bool

    private var scope: ChatScope {
        ChatScope(rawValue: chatScope) ?? .scene
    }

    /// The persistence key for the current scope.
    private var sessionKey: String {
        scope == .show ? "__show__" : (store.activeSongPath ?? "__none__")
    }

    /// The active client for the current session key. Creates on demand if missing.
    private var client: MiniMaxClient {
        if let existing = clients[sessionKey] { return existing }
        // Create and cache the client, loading persisted session + suggestions
        let newClient = MiniMaxClient()
        if let projectURL = store.projectURL ?? store.workingProjectURL,
           let session = LLMChatPersistence.loadSession(projectURL: projectURL, key: sessionKey) {
            newClient.loadSession(session)
            if let savedSuggestions = session.writeSuggestions, !savedSuggestions.isEmpty {
                suggestions = savedSuggestions
            }
        }
        clients[sessionKey] = newClient
        return newClient
    }

    private var currentSceneName: String? {
        guard let path = store.activeSongPath else { return nil }
        return store.songAssets.first(where: { $0.relativePath == path })?.displayName
    }

    private var currentProjectName: String? {
        store.projectURL?.deletingPathExtension().lastPathComponent
    }

    private var currentLibretto: String? {
        if scope == .show {
            // Show mode: combine all scenes into a single libretto
            let sorted = store.songAssets.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            let parts = sorted.compactMap { asset -> String? in
                guard let file = store.librettoFiles.first(where: { $0.relativePath == asset.relativePath }),
                      !file.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                return "[\(asset.displayName)]\n\(file.content)"
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n\n---\n\n")
        }
        // Scene mode: just the active scene
        guard let path = store.activeSongPath else { return nil }
        return store.librettoFiles.first(where: { $0.relativePath == path })?.content
    }

    var body: some View {
        VStack(spacing: 0) {
            contextBar

            Divider()

            if showSettings {
                VStack(spacing: 0) {
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { showSettings = false }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(OperaChromeTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 10)
                        .padding(.top, 6)
                    }
                    LLMSettingsView(onSettingsChanged: { store.saveProjectSettings() })
                }
            } else if store.activeSongPath == nil && scope == .scene {
                noSceneState
            } else {
                VStack(spacing: 0) {
                    chatArea

                    if !undoStack.isEmpty {
                        undoBar
                    }

                    Divider()

                    inputArea
                }
            }
        }
        .onChange(of: store.activeSongPath) { _, _ in
            saveCurrentSession()  // save current suggestions before switching
            suggestions.removeAll()
            undoStack.removeAll()
            // New scene's suggestions will load via the client computed property
        }
        .onChange(of: chatScope) { _, _ in
            saveCurrentSession()
            suggestions.removeAll()
            undoStack.removeAll()
        }
        .onDisappear { saveAllSessions() }
    }

    // MARK: - Persistence

    /// Save all active client sessions to disk.
    private func saveAllSessions() {
        guard let projectURL = store.projectURL ?? store.workingProjectURL else { return }
        for (key, c) in clients where !c.messages.isEmpty {
            let title = key == "__show__" ? "Show Chat" : (store.songAssets.first(where: { $0.relativePath == key })?.displayName ?? key)
            // Include suggestions for the current session key
            let sug = key == sessionKey ? suggestions : nil
            var session = LLMChatSession(title: title, messages: c.messages)
            session.setWriteSuggestions(sug)
            LLMChatPersistence.saveSession(session, projectURL: projectURL, key: key)
        }
    }

    /// Save just the current session.
    private func saveCurrentSession() {
        guard let projectURL = store.projectURL ?? store.workingProjectURL else { return }
        guard !client.messages.isEmpty else { return }
        let title = scope == .show ? "Show Chat" : (currentSceneName ?? sessionKey)
        let activeSuggestions = suggestions.isEmpty ? nil : suggestions
        var session = LLMChatSession(title: title, messages: client.messages)
        session.setWriteSuggestions(activeSuggestions)
        LLMChatPersistence.saveSession(session, projectURL: projectURL, key: sessionKey)
    }

    private func archiveAndClear() {
        guard let projectURL = store.projectURL ?? store.workingProjectURL else { return }
        let fresh = LLMChatPersistence.archiveSession(projectURL: projectURL, key: sessionKey)
        let newClient = MiniMaxClient()
        newClient.loadSession(fresh)
        clients[sessionKey] = newClient
        suggestions.removeAll()
        undoStack.removeAll()
    }

    // MARK: - Context Bar

    private var contextBar: some View {
        HStack(spacing: 6) {
            // Scope toggle
            Picker("", selection: $chatScope) {
                Text("Scene").tag(ChatScope.scene.rawValue)
                Text("Show").tag(ChatScope.show.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)

            Spacer()

            if client.isGenerating {
                ProgressView()
                    .scaleEffect(0.5)
                    .frame(width: 14, height: 14)
            }

            // Model dropdown
            Menu {
                ForEach(LLMProviderType.allCases) { provider in
                    Section(provider.displayName) {
                        ForEach(provider.knownModels) { model in
                            Button {
                                LLMProviderConfig.shared.activeProvider = provider
                                LLMProviderConfig.shared.activeModelID = model.id
                                store.saveProjectSettings()
                                NSLog("[LLMDropdown] Set provider=%@ model=%@", provider.rawValue, model.id)
                            } label: {
                                HStack {
                                    Text(model.name)
                                    Spacer()
                                    if LLMProviderConfig.shared.activeProvider == provider &&
                                       LLMProviderConfig.shared.activeModelID == model.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                }
                Divider()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showSettings.toggle() }
                } label: {
                    Label("Settings...", systemImage: "gearshape")
                }
            } label: {
                HStack(spacing: 3) {
                    Text(LLMProviderConfig.shared.activeModelDisplayName)
                        .font(.caption)
                        .foregroundStyle(.cyan.opacity(0.7))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.cyan.opacity(0.5))
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

            Menu {
                Button("Archive & New Chat") {
                    archiveAndClear()
                }
                .disabled(client.messages.isEmpty || client.isGenerating)

                Button("Clear Chat") {
                    client.clearHistory()
                    suggestions.removeAll()
                    saveCurrentSession()
                }
                .disabled(client.isGenerating)

                let archives = archiveList()
                if !archives.isEmpty {
                    Divider()
                    Menu("View Archives") {
                        ForEach(archives, id: \.url) { archive in
                            Button(archive.name) {
                                loadArchive(at: archive.url)
                            }
                        }
                    }
                }

                Divider()

                Button(showUndoHistory ? "Hide Edit History" : "Show Edit History") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showUndoHistory.toggle()
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(OperaChromeTheme.headerBackground.opacity(0.5))
    }

    private func archiveList() -> [(name: String, url: URL)] {
        guard let projectURL = store.projectURL ?? store.workingProjectURL else { return [] }
        return LLMChatPersistence.listArchives(projectURL: projectURL, key: sessionKey)
    }

    private func loadArchive(at url: URL) {
        guard let session = LLMChatPersistence.loadArchive(at: url) else { return }
        client.loadSession(session)
    }

    // MARK: - No Scene State

    private var noSceneState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.largeTitle)
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Text("Select a scene to start")
                .font(.body)
                .foregroundStyle(OperaChromeTheme.textSecondary)
            Spacer()
        }
    }

    // MARK: - Chat Area

    private var chatArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(client.messages) { message in
                        chatBubble(for: message)
                            .id(message.id)
                    }

                    if client.isGenerating && !client.streamingContent.isEmpty {
                        streamingBubble
                            .id("streaming")
                    }

                    if !suggestions.isEmpty {
                        suggestionsSection
                    }

                    if let error = client.errorMessage {
                        errorCard(error)
                    }

                    if showUndoHistory && !undoStack.isEmpty {
                        undoHistorySection
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .onChange(of: client.messages.count) { _, _ in
                if let lastID = client.messages.last?.id {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: client.streamingContent) { _, _ in
                withAnimation(.easeOut(duration: 0.1)) {
                    proxy.scrollTo("streaming", anchor: .bottom)
                }
            }
        }
    }

    // MARK: - Welcome Card

    // MARK: - Chat Bubbles

    private func chatBubble(for message: MiniMaxMessage) -> some View {
        HStack(alignment: .top, spacing: 6) {
            if message.role == "user" {
                Spacer(minLength: 20)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(message.content)
                        .font(.body)
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.accentColor.opacity(0.15))
                        )
                    Text(formatTime(message.timestamp))
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }
            } else if message.role == "assistant" {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayText(for: message.content))
                        .font(.body)
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(OperaChromeTheme.raisedBackground)
                        )
                    Text(formatTime(message.timestamp))
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }
                Spacer(minLength: 20)
            }
        }
    }

    private var streamingBubble: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.streamingContent)
                    .font(.body)
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(OperaChromeTheme.raisedBackground)
                    )

                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.4)
                        .frame(width: 10, height: 10)
                    Text("Generating...")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }
            }
            Spacer(minLength: 20)
        }
    }

    private func errorCard(_ error: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.body)
            Text(error)
                .font(.body)
                .foregroundStyle(.orange)
                .lineLimit(3)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.08))
        )
    }

    // MARK: - Suggestions Section

    private var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .font(.body)
                Text("Suggestions")
                    .font(.caption.bold())
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Spacer()

                Button("Apply All") {
                    applyAllSuggestions()
                }
                .font(.body)
                .foregroundStyle(.cyan)
                .buttonStyle(.plain)
                .disabled(suggestions.allSatisfy(\.applied))

                Button("Dismiss") {
                    withAnimation { suggestions.removeAll() }
                }
                .font(.body)
                .foregroundStyle(OperaChromeTheme.textTertiary)
                .buttonStyle(.plain)
            }

            ForEach(suggestions) { suggestion in
                suggestionCard(suggestion)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.yellow.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.yellow.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    private func suggestionCard(_ suggestion: LLMSuggestion) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if let sceneName = suggestion.sceneName {
                    Text("\(sceneName) — Line \(suggestion.lineIndex + 1)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                } else {
                    Text("Line \(suggestion.lineIndex + 1):")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                }
                Spacer()
            }

            Text(suggestion.originalLine)
                .font(.body)
                .foregroundStyle(.red.opacity(0.7))
                .strikethrough(suggestion.applied)

            Image(systemName: "arrow.down")
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textTertiary)

            Text(suggestion.suggestedLine)
                .font(.body)
                .foregroundStyle(.green.opacity(0.8))
                .fontWeight(suggestion.applied ? .semibold : .regular)

            if !suggestion.applied {
                Button {
                    applySuggestion(suggestion)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Apply")
                    }
                    .font(.body)
                    .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            } else if suggestion.applied {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                    Text("Applied")
                }
                .font(.body)
                .foregroundStyle(.green.opacity(0.6))
                .padding(.top, 2)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.5))
        )
    }

    // MARK: - Undo Bar

    private var undoBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.body)
                .foregroundStyle(OperaChromeTheme.textTertiary)

            Text("\(undoStack.count) change\(undoStack.count == 1 ? "" : "s")")
                .font(.body)
                .foregroundStyle(OperaChromeTheme.textSecondary)

            Spacer()

            Button("Undo Last") {
                undoLastChange()
            }
            .font(.body)
            .foregroundStyle(.orange)
            .buttonStyle(.plain)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showUndoHistory.toggle()
                }
            } label: {
                Image(systemName: showUndoHistory ? "chevron.up" : "chevron.down")
                    .font(.body)
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.orange.opacity(0.05))
    }

    // MARK: - Undo History Section

    private var undoHistorySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Change History")
                    .font(.caption.bold())
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                Spacer()
            }

            ForEach(undoStack.reversed()) { entry in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.description)
                            .font(.body)
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text(formatTime(entry.timestamp))
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                    }

                    Spacer()

                    Button("Revert") {
                        revertTo(entry)
                    }
                    .font(.body)
                    .foregroundStyle(.orange)
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 3)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Input Area

    private var inputArea: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Send message...", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(3...10)
                .focused($inputFocused)
                .onSubmit {
                    if !NSEvent.modifierFlags.contains(.shift) {
                        sendMessage()
                    }
                }

            Button {
                sendMessage()
            } label: {
                Image(systemName: client.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !client.isGenerating
                            ? OperaChromeTheme.textTertiary
                            : .cyan
                    )
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !client.isGenerating)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        // Capture context BEFORE the await so suggestions are built against the
        // correct scene even if the user scrolls to a different scene during generation.
        let capturedScope = scope
        let capturedLibretto = currentLibretto
        let capturedSceneFiles: [(path: String, name: String, lines: [String])]
        if capturedScope == .show {
            let sorted = store.songAssets.sorted {
                $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
            }
            capturedSceneFiles = sorted.compactMap { asset -> (path: String, name: String, lines: [String])? in
                guard let file = store.librettoFiles.first(where: { $0.relativePath == asset.relativePath }) else { return nil }
                return (path: asset.relativePath, name: asset.displayName, lines: file.content.components(separatedBy: "\n"))
            }
        } else {
            capturedSceneFiles = []
        }

        Task {
            await client.send(
                text,
                projectName: currentProjectName,
                songName: currentSceneName,
                librettoText: capturedLibretto,
                trackNames: []
            )

            if let lastAssistant = client.messages.last, lastAssistant.role == "assistant" {
                let newSuggestions: [LLMSuggestion]
                if capturedScope == .show {
                    newSuggestions = MiniMaxClient.parseSuggestionsAcrossScenes(
                        from: lastAssistant.content, sceneFiles: capturedSceneFiles
                    )
                } else {
                    let librettoLines = (capturedLibretto ?? "").components(separatedBy: "\n")
                    newSuggestions = MiniMaxClient.parseSuggestions(from: lastAssistant.content, librettoLines: librettoLines)
                }
                if !newSuggestions.isEmpty {
                    withAnimation { suggestions = newSuggestions }
                }
            }

            saveCurrentSession()
        }
    }

    private func applySuggestion(_ suggestion: LLMSuggestion) {
        if scope == .show {
            var snapshots: [String: String]? = [:]
            applyShowModeSuggestion(suggestion, snapshotAccumulator: &snapshots)
            if let snapshots, !snapshots.isEmpty {
                undoStack.append(LLMUndoEntry(
                    description: "Replace \"\(suggestion.originalLine.prefix(30))...\"",
                    sceneSnapshots: snapshots,
                    timestamp: Date()
                ))
            }
        } else {
            applySceneModeSuggestion(suggestion)
        }
    }

    private func applySceneModeSuggestion(_ suggestion: LLMSuggestion) {
        guard let path = store.activeSongPath else { return }
        guard let libretto = currentLibretto else { return }
        var lines = libretto.components(separatedBy: "\n")
        guard suggestion.lineIndex < lines.count else { return }

        // Verify the line still matches what was parsed — reject if the scene changed
        let currentLine = lines[suggestion.lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentLine == suggestion.originalLine else { return }

        undoStack.append(LLMUndoEntry(
            description: "Replace line \(suggestion.lineIndex + 1): \"\(suggestion.originalLine.prefix(30))...\"",
            previousContent: libretto,
            scenePath: path,
            timestamp: Date()
        ))

        lines[suggestion.lineIndex] = suggestion.suggestedLine
        store.updateLyricsForSong(atPath: path, lyrics: lines.joined(separator: "\n"))

        if let idx = suggestions.firstIndex(where: { $0.id == suggestion.id }) {
            withAnimation { suggestions[idx].applied = true }
        }
    }

    /// Show mode: apply a suggestion to its specific scene using the scenePath
    /// and lineIndex already resolved during parsing.
    private func applyShowModeSuggestion(_ suggestion: LLMSuggestion, snapshotAccumulator: inout [String: String]?) {
        guard let scenePath = suggestion.scenePath else { return }
        guard let file = store.librettoFiles.first(where: { $0.relativePath == scenePath }) else { return }

        var lines = file.content.components(separatedBy: "\n")
        guard suggestion.lineIndex < lines.count else { return }

        // Verify the line still matches — reject if the scene content changed
        let currentLine = lines[suggestion.lineIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentLine == suggestion.originalLine else { return }

        // Snapshot this scene before modifying (only if not already snapshotted)
        if snapshotAccumulator != nil, snapshotAccumulator?[scenePath] == nil {
            snapshotAccumulator?[scenePath] = file.content
        }

        lines[suggestion.lineIndex] = suggestion.suggestedLine
        store.updateLyricsForSong(atPath: scenePath, lyrics: lines.joined(separator: "\n"))

        if let idx = suggestions.firstIndex(where: { $0.id == suggestion.id }) {
            withAnimation { suggestions[idx].applied = true }
        }
    }

    private func applyAllSuggestions() {
        if scope == .show {
            let unapplied = suggestions.enumerated().filter { !$0.element.applied }
            guard !unapplied.isEmpty else { return }

            // Group by scene and apply all edits per scene in one pass
            var byScene: [String: [(index: Int, suggestion: LLMSuggestion)]] = [:]
            for (i, suggestion) in unapplied {
                guard let path = suggestion.scenePath else { continue }
                byScene[path, default: []].append((index: i, suggestion: suggestion))
            }

            var snapshots: [String: String] = [:]
            for (scenePath, items) in byScene {
                guard let file = store.librettoFiles.first(where: { $0.relativePath == scenePath }) else { continue }
                snapshots[scenePath] = file.content  // snapshot BEFORE any edits
                var lines = file.content.components(separatedBy: "\n")
                for item in items {
                    guard item.suggestion.lineIndex < lines.count else { continue }
                    lines[item.suggestion.lineIndex] = item.suggestion.suggestedLine
                }
                store.updateLyricsForSong(atPath: scenePath, lyrics: lines.joined(separator: "\n"))
            }

            if !snapshots.isEmpty {
                undoStack.append(LLMUndoEntry(
                    description: "Apply \(unapplied.count) suggestion(s) across show",
                    sceneSnapshots: snapshots,
                    timestamp: Date()
                ))
            }
            withAnimation {
                for i in suggestions.indices { suggestions[i].applied = true }
            }
        } else {
            guard let path = store.activeSongPath else { return }
            guard let libretto = currentLibretto else { return }

            undoStack.append(LLMUndoEntry(
                description: "Apply \(suggestions.filter { !$0.applied }.count) suggestion(s)",
                previousContent: libretto,
                scenePath: path,
                timestamp: Date()
            ))

            var lines = libretto.components(separatedBy: "\n")
            var appliedLines = Set<Int>()
            for suggestion in suggestions where !suggestion.applied {
                guard suggestion.lineIndex < lines.count, !appliedLines.contains(suggestion.lineIndex) else { continue }
                lines[suggestion.lineIndex] = suggestion.suggestedLine
                appliedLines.insert(suggestion.lineIndex)
            }
            store.updateLyricsForSong(atPath: path, lyrics: lines.joined(separator: "\n"))

            withAnimation {
                for i in suggestions.indices { suggestions[i].applied = true }
            }
        }
    }

    private func undoLastChange() {
        guard let entry = undoStack.popLast() else { return }
        restoreFromEntry(entry)
        // Mark the corresponding suggestion(s) as unapplied instead of removing all
        markSuggestionsUnapplied(for: entry)
    }

    /// Revert to the state before this entry's change was applied.
    /// Removes this entry and all newer entries from the undo stack.
    private func revertTo(_ entry: LLMUndoEntry) {
        // Collect all entries being removed so we can un-apply their suggestions
        let removedEntries: [LLMUndoEntry]
        if let idx = undoStack.firstIndex(where: { $0.id == entry.id }) {
            removedEntries = Array(undoStack[idx...])
            undoStack.removeSubrange(idx...)
        } else {
            removedEntries = [entry]
        }
        restoreFromEntry(entry)
        for removed in removedEntries {
            markSuggestionsUnapplied(for: removed)
        }
    }

    /// Mark suggestions as unapplied based on the undo entry's description.
    private func markSuggestionsUnapplied(for entry: LLMUndoEntry) {
        // For show mode entries, un-apply suggestions targeting the restored scenes
        if let snapshots = entry.sceneSnapshots {
            let restoredPaths = Set(snapshots.keys)
            for i in suggestions.indices {
                if let path = suggestions[i].scenePath, restoredPaths.contains(path), suggestions[i].applied {
                    suggestions[i].applied = false
                }
            }
        } else if let path = entry.undoScenePath {
            // Scene mode: un-apply suggestions for this scene
            for i in suggestions.indices where suggestions[i].applied {
                if suggestions[i].scenePath == nil || suggestions[i].scenePath == path {
                    suggestions[i].applied = false
                }
            }
        }
    }

    private func restoreFromEntry(_ entry: LLMUndoEntry) {
        if let snapshots = entry.sceneSnapshots {
            // Show mode: restore each affected scene
            for (path, content) in snapshots {
                store.updateLyricsForSong(atPath: path, lyrics: content)
            }
        } else if let path = entry.undoScenePath {
            // Scene mode: restore to the specific scene that was snapshotted
            store.updateLyricsForSong(atPath: path, lyrics: entry.previousContent)
        }
    }

    // MARK: - Helpers

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func displayText(for content: String) -> String {
        var cleaned = MiniMaxClient.stripThinkTags(content)
        if let regex = try? NSRegularExpression(pattern: #"\[SUGGEST\].*?\[/SUGGEST\]"#, options: [.dotMatchesLineSeparators]) {
            cleaned = regex.stringByReplacingMatches(
                in: cleaned,
                range: NSRange(location: 0, length: (cleaned as NSString).length),
                withTemplate: ""
            )
        }
        return cleaned
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
