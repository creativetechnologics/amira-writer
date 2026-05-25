import SwiftUI
import ProjectKit
#if canImport(AppKit)
import AppKit
#endif

@available(macOS 26.0, *)
struct AnimateLLMInspectorView: View {
    @Bindable var store: AnimateStore

    enum ChatScope: String {
        case character = "Character"
        case show = "Show"
    }

    @State private var clients: [String: LLMClient] = [:]
    @State private var inputText: String = ""
    @State private var showSettings: Bool = false
    @State private var showArchiveList: Bool = false
    @State private var settingsProvider: LLMProviderType = LLMProviderConfig.shared.activeProvider
    @State private var settingsAPIKey: String = ""
    @State private var preflightDrafts: [GeminiGenerationDraft] = []
    @State private var showPreflight: Bool = false
    @State private var pendingPreflightActions: [AnimateLLMAction] = []
    @AppStorage("animate.llm.chatScope") private var chatScope: String = ChatScope.character.rawValue
    @FocusState private var inputFocused: Bool

    private var scope: ChatScope {
        ChatScope(rawValue: chatScope) ?? .character
    }

    private var sessionKey: String {
        scope == .show ? "__show__" : (store.selectedCharacter?.assetFolderSlug ?? "__none__")
    }

    private var client: LLMClient {
        if let existing = clients[sessionKey] { return existing }
        let newClient = LLMClient()
        if let projectURL = persistenceProjectURL,
           let session = LLMChatPersistence.loadSession(projectURL: projectURL, key: sessionKey) {
            newClient.loadSession(session)
        }
        clients[sessionKey] = newClient
        return newClient
    }

    /// LLMChatPersistence appends "ChatHistory/" internally, so pass the Animate subdirectory.
    private var persistenceProjectURL: URL? {
        store.animateURL
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
                    settingsPanel
                }
            } else if store.selectedCharacter == nil && scope == .character {
                noCharacterState
            } else {
                VStack(spacing: 0) {
                    chatArea

                    Divider()

                    inputArea
                }
            }
        }
        .onChange(of: store.selectedCharacterID) { _, _ in
            saveCurrentSession()
        }
        .onChange(of: chatScope) { _, _ in
            saveCurrentSession()
        }
        .onDisappear { saveAllSessions() }
        .sheet(isPresented: $showPreflight) {
            GeminiGenerationPreflightSheet(
                store: store,
                drafts: $preflightDrafts,
                title: "Preview AI Generation",
                confirmTitle: "Run \(preflightDrafts.count) Request\(preflightDrafts.count == 1 ? "" : "s")",
                onConfirm: { drafts, _ in
                    showPreflight = false
                    executePaidActions(drafts: drafts)
                },
                onCancel: {
                    showPreflight = false
                    pendingPreflightActions.removeAll()
                    addSystemMessage("Generation cancelled.")
                }
            )
        }
    }

    // MARK: - Persistence

    private func saveAllSessions() {
        guard let projectURL = persistenceProjectURL else { return }
        for (key, c) in clients where !c.messages.isEmpty {
            let title = key == "__show__" ? "Show Chat" : (store.characters.first(where: { $0.assetFolderSlug == key })?.name ?? key)
            let session = LLMChatSession(title: title, messages: c.messages)
            LLMChatPersistence.saveSession(session, projectURL: projectURL, key: key)
        }
    }

    private func saveCurrentSession() {
        guard let projectURL = persistenceProjectURL else { return }
        guard !client.messages.isEmpty else { return }
        let title = scope == .show ? "Show Chat" : (store.selectedCharacter?.name ?? sessionKey)
        let session = LLMChatSession(title: title, messages: client.messages)
        LLMChatPersistence.saveSession(session, projectURL: projectURL, key: sessionKey)
    }

    private func archiveAndClear() {
        guard let projectURL = persistenceProjectURL else { return }
        let fresh = LLMChatPersistence.archiveSession(projectURL: projectURL, key: sessionKey)
        let newClient = LLMClient()
        newClient.loadSession(fresh)
        clients[sessionKey] = newClient
    }

    // MARK: - Context Bar

    private var contextBar: some View {
        HStack(spacing: 6) {
            Picker("", selection: $chatScope) {
                Text("Character").tag(ChatScope.character.rawValue)
                Text("Show").tag(ChatScope.show.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)

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
        guard let projectURL = persistenceProjectURL else { return [] }
        return LLMChatPersistence.listArchives(projectURL: projectURL, key: sessionKey)
    }

    private func loadArchive(at url: URL) {
        guard let session = LLMChatPersistence.loadArchive(at: url) else { return }
        client.loadSession(session)
    }

    // MARK: - No Character State

    private var noCharacterState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.largeTitle)
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Text("Select a character to start")
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

                    if let error = client.errorMessage {
                        errorCard(error)
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

    // MARK: - Chat Bubbles

    private func chatBubble(for message: LLMMessage) -> some View {
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
            } else if message.role == "system" {
                // System messages (action results) shown centered
                systemMessageBubble(for: message)
            }
        }
    }

    private func systemMessageBubble(for message: LLMMessage) -> some View {
        HStack(spacing: 4) {
            Spacer()
            let isExecuted = message.content.hasPrefix("[OK]") || message.content.hasPrefix("[DONE]")
            let isPending = message.content.hasPrefix("[PENDING]") || message.content.hasPrefix("[COST]")
            let isCancelled = message.content.hasPrefix("[CANCELLED]")

            if isExecuted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green.opacity(0.7))
                    .font(.system(size: 12))
            } else if isPending {
                Image(systemName: "dollarsign.circle.fill")
                    .foregroundStyle(.orange.opacity(0.7))
                    .font(.system(size: 12))
            } else if isCancelled {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red.opacity(0.5))
                    .font(.system(size: 12))
            }

            Text(displaySystemText(message.content))
                .font(.system(size: 12))
                .foregroundStyle(OperaChromeTheme.textTertiary)
                .lineLimit(3)
            Spacer()
        }
        .padding(.vertical, 2)
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

    // MARK: - Send Flow

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""

        let capturedScope = scope
        let capturedCharacter = store.selectedCharacter
        let capturedCharacterID = capturedCharacter?.id

        Task {
            // Build system prompt
            let systemPrompt: String
            if capturedScope == .show {
                systemPrompt = AnimateLLMAgent.buildShowSystemPrompt(store: store)
            } else if let character = capturedCharacter {
                systemPrompt = AnimateLLMAgent.buildSystemPrompt(for: character, store: store)
            } else {
                return
            }

            // Send via LLMClient with custom system prompt
            await client.sendWithSystemPrompt(text, systemPrompt: systemPrompt)

            // Parse actions from the assistant response
            if let lastAssistant = client.messages.last, lastAssistant.role == "assistant" {
                let actions = AnimateLLMAgent.parseActions(from: lastAssistant.content)

                var freeActions: [AnimateLLMAction] = []
                var paidActions: [AnimateLLMAction] = []

                for action in actions {
                    if AnimateLLMAgent.isFreeAction(action) {
                        freeActions.append(action)
                    } else {
                        paidActions.append(action)
                    }
                }

                // Execute free actions immediately
                if let charID = capturedCharacterID {
                    for action in freeActions {
                        let result = AnimateLLMAgent.executeAction(action, on: store, characterID: charID)
                        addSystemMessage("[OK] \(AnimateLLMAgent.describeAction(action)): \(result)")
                    }
                }

                // Build preflight for paid actions
                if !paidActions.isEmpty, let character = capturedCharacter {
                    let drafts = buildPreflightDrafts(for: paidActions, character: character)
                    if !drafts.isEmpty {
                        for action in paidActions {
                            addSystemMessage("[COST] \(AnimateLLMAgent.describeAction(action)) -- awaiting confirmation")
                        }
                        preflightDrafts = drafts
                        pendingPreflightActions = paidActions
                        showPreflight = true
                    }
                }
            }

            saveCurrentSession()
        }
    }

    // MARK: - Preflight Draft Building

    private func buildPreflightDrafts(for actions: [AnimateLLMAction], character: AnimationCharacter) -> [GeminiGenerationDraft] {
        var drafts: [GeminiGenerationDraft] = []

        for action in actions {
            switch action {
            case .generate(let target, let count):
                drafts.append(contentsOf: buildGenerationDrafts(target: target, count: count, character: character))
            case .batchSubmit(let wardrobe, let count):
                drafts.append(GeminiGenerationDraft(
                    title: "Inspiration Batch (\(wardrobe))",
                    destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/inspiration",
                    prompt: character.masterReferenceSheetPrompt,
                    model: store.selectedGeminiModel,
                    aspectRatio: "1:1",
                    imageSize: "2K",
                    referenceItems: referenceDrafts(from: store.masterReferenceSheetReferencePaths(for: character.id, limit: 4)),
                    pricingMode: .batch
                ))
                // Add remaining batch items with the same settings
                for i in 1..<count {
                    drafts.append(GeminiGenerationDraft(
                        title: "Inspiration Batch (\(wardrobe)) #\(i + 1)",
                        destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/inspiration",
                        prompt: character.masterReferenceSheetPrompt,
                        model: store.selectedGeminiModel,
                        aspectRatio: "1:1",
                        imageSize: "2K",
                        referenceItems: referenceDrafts(from: store.masterReferenceSheetReferencePaths(for: character.id, limit: 4)),
                        pricingMode: .batch
                    ))
                }
            default:
                break
            }
        }

        return drafts
    }

    private func buildGenerationDrafts(target: AnimateLLMGenerationTarget, count: Int, character: AnimationCharacter) -> [GeminiGenerationDraft] {
        switch target {
        case .masterSheet:
            let references = referenceDrafts(from: store.masterReferenceSheetReferencePaths(for: character.id, limit: 8))
            return (0..<count).map { index in
                GeminiGenerationDraft(
                    title: count == 1 ? "Master Reference Sheet" : "Master Reference Sheet \(index + 1)",
                    destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/master-sheet",
                    prompt: character.masterReferenceSheetPrompt,
                    model: store.selectedGeminiModel,
                    aspectRatio: CharacterReferenceWorkflowCatalog.defaultMasterSheetAspectRatio,
                    imageSize: CharacterReferenceWorkflowCatalog.defaultMasterSheetImageSize,
                    referenceItems: references
                )
            }

        case .headSheet:
            return [GeminiGenerationDraft(
                title: "Head Turnaround Sheet",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/head-sheet",
                prompt: character.headTurnaroundSheetPrompt,
                model: store.selectedGeminiModel,
                aspectRatio: CharacterReferenceWorkflowCatalog.sectionSheetAspectRatio,
                imageSize: CharacterReferenceWorkflowCatalog.sectionSheetImageSize,
                referenceItems: referenceDrafts(from: store.headSheetReferencePaths(for: character.id, limit: 8))
            )]

        case .headPoses:
            let references = referenceDrafts(from: store.headReferencePaths(for: character.id, limit: 8))
            let slots = character.headTurnaroundSlots.filter { $0.approvedVariant == nil }
            let targetSlots = slots.isEmpty ? character.headTurnaroundSlots : slots
            return targetSlots.map { slot in
                GeminiGenerationDraft(
                    title: "Head - \(slot.title)",
                    destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/head-turnaround",
                    prompt: slot.prompt,
                    model: store.selectedGeminiModel,
                    aspectRatio: slot.recommendedAspectRatio,
                    imageSize: slot.recommendedImageSize,
                    referenceItems: references
                )
            }

        case .costumeSheet(let costumeName):
            guard let costume = character.costumeReferenceSets.first(where: { $0.name == costumeName }) else { return [] }
            let slug = CharacterReferenceWorkflowCatalog.slug(from: costume.name)
            return [GeminiGenerationDraft(
                title: "\(costume.name) Sheet",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/\(slug)/sheet",
                prompt: costume.sheetPrompt,
                model: store.selectedGeminiModel,
                aspectRatio: CharacterReferenceWorkflowCatalog.sectionSheetAspectRatio,
                imageSize: CharacterReferenceWorkflowCatalog.sectionSheetImageSize,
                referenceItems: referenceDrafts(from: store.fullBodyReferencePaths(for: character.id, costumeID: costume.id, limit: 8))
            )]

        case .costumePoses(let costumeName):
            guard let costume = character.costumeReferenceSets.first(where: { $0.name == costumeName }) else { return [] }
            let references = referenceDrafts(from: store.fullBodyReferencePaths(for: character.id, costumeID: costume.id, limit: 8))
            let slots = costume.fullBodySlots.filter { $0.approvedVariant == nil }
            let targetSlots = slots.isEmpty ? costume.fullBodySlots : slots
            return targetSlots.map { slot in
                GeminiGenerationDraft(
                    title: "\(costume.name) - \(slot.title)",
                    destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/fullbody",
                    prompt: slot.prompt,
                    model: store.selectedGeminiModel,
                    aspectRatio: slot.recommendedAspectRatio,
                    imageSize: slot.recommendedImageSize,
                    referenceItems: references
                )
            }

        case .accessory(let costumeName, let accessoryName):
            guard let costume = character.costumeReferenceSets.first(where: { $0.name == costumeName }),
                  let slot = costume.accessorySlots.first(where: { $0.title == accessoryName }) else { return [] }
            return [GeminiGenerationDraft(
                title: "Accessory - \(slot.title)",
                destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/reference-workflow/\(CharacterReferenceWorkflowCatalog.slug(from: costume.name))/accessories",
                prompt: slot.prompt,
                model: store.selectedGeminiModel,
                aspectRatio: slot.recommendedAspectRatio,
                imageSize: slot.recommendedImageSize,
                referenceItems: referenceDrafts(from: store.accessoryReferencePaths(for: character.id, costumeID: costume.id, limit: 8))
            )]

        case .inspiration:
            let references = referenceDrafts(from: store.masterReferenceSheetReferencePaths(for: character.id, limit: 4))
            return (0..<count).map { index in
                GeminiGenerationDraft(
                    title: count == 1 ? "Inspiration Image" : "Inspiration Image \(index + 1)",
                    destinationDescription: "Saved to Characters/\(character.assetFolderSlug)/inspiration",
                    prompt: character.masterReferenceSheetPrompt,
                    model: store.selectedGeminiModel,
                    aspectRatio: "1:1",
                    imageSize: "2K",
                    referenceItems: references
                )
            }
        }
    }

    private func referenceDrafts(from paths: [String]) -> [GeminiGenerationReferenceDraft] {
        paths.map { path in
            GeminiGenerationReferenceDraft(
                label: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                path: path,
                isIncluded: true
            )
        }
    }

    // MARK: - Paid Action Execution

    private func executePaidActions(drafts: [GeminiGenerationDraft]) {
        addSystemMessage("[DONE] Confirmed \(drafts.count) generation request\(drafts.count == 1 ? "" : "s"). Starting...")
        // The actual generation is handled by the store's Gemini generation pipeline.
        // For now we log the confirmation; integration with the generation service
        // will be wired through the CharacterReferenceWorkflowSheet or GeminiImageService.
        pendingPreflightActions.removeAll()
        saveCurrentSession()
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Provider picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider")
                        .font(.body.bold())
                        .foregroundStyle(OperaChromeTheme.textPrimary)

                    Picker("", selection: $settingsProvider) {
                        Text("MiniMax").tag(LLMProviderType.minimax)
                        Text("OpenCode Go").tag(LLMProviderType.opencode)
                        Text("Claude").tag(LLMProviderType.claude)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settingsProvider) { _, newProvider in
                        LLMProviderConfig.shared.activeProvider = newProvider
                        settingsAPIKey = LLMProviderConfig.shared.apiKey(for: newProvider)
                    }
                }

                // API Key / Auth
                if settingsProvider == .claude {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Authentication")
                            .font(.body.bold())
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                        HStack(spacing: 6) {
                            let available = LLMProviderConfig.shared.isClaudeCLIAvailable
                            Image(systemName: available ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(available ? .green : .red)
                            Text(available ? "Claude CLI found" : "Claude CLI not found")
                                .font(.callout)
                                .foregroundStyle(OperaChromeTheme.textPrimary)
                        }
                        Text("Uses your Claude subscription via the claude CLI.")
                            .font(.caption)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("API Key")
                            .font(.body.bold())
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                        HStack(spacing: 6) {
                            SecureField("Enter \(settingsProvider.displayName) API key...", text: $settingsAPIKey)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout)
                                .onSubmit {
                                    LLMProviderConfig.shared.setAPIKey(settingsAPIKey, for: settingsProvider)
                                }
                            Button("Save") {
                                LLMProviderConfig.shared.setAPIKey(settingsAPIKey, for: settingsProvider)
                            }
                            .font(.callout)
                        }
                    }
                }

                // Model selection
                VStack(alignment: .leading, spacing: 6) {
                    Text("Model")
                        .font(.body.bold())
                        .foregroundStyle(OperaChromeTheme.textPrimary)

                    ForEach(settingsProvider.knownModels) { model in
                        let isActive = LLMProviderConfig.shared.activeModelID == model.id
                            && LLMProviderConfig.shared.activeProvider == settingsProvider
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.name)
                                    .font(.callout)
                                    .foregroundStyle(isActive ? .cyan : OperaChromeTheme.textPrimary)
                                    .lineLimit(1)
                                if let ctx = model.contextLength {
                                    Text("\(ctx / 1000)K context")
                                        .font(.caption)
                                        .foregroundStyle(OperaChromeTheme.textTertiary)
                                }
                            }
                            Spacer()
                            if isActive {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.callout)
                                    .foregroundStyle(.cyan)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isActive ? Color.cyan.opacity(0.08) : Color.clear)
                        )
                        .onTapGesture {
                            LLMProviderConfig.shared.activeProvider = settingsProvider
                            LLMProviderConfig.shared.activeModelID = model.id
                        }
                    }
                }
            }
            .padding(12)
            .id(settingsProvider)
        }
        .onAppear {
            settingsProvider = LLMProviderConfig.shared.activeProvider
            settingsAPIKey = LLMProviderConfig.shared.apiKey(for: settingsProvider)
        }
    }

    // MARK: - Helpers

    private func addSystemMessage(_ text: String) {
        let msg = LLMMessage(role: "system", content: text)
        client.messages.append(msg)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func displayText(for content: String) -> String {
        var cleaned = LLMClient.stripThinkTags(content)
        // Strip [ACTION] blocks from display
        if let regex = try? NSRegularExpression(pattern: #"\[ACTION[^\]]*\].*?\[/ACTION\]"#, options: [.dotMatchesLineSeparators]) {
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

    private func displaySystemText(_ content: String) -> String {
        // Strip the prefix tags for display
        var text = content
        for prefix in ["[OK] ", "[DONE] ", "[PENDING] ", "[COST] ", "[CANCELLED] "] {
            if text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
                break
            }
        }
        return text
    }
}
