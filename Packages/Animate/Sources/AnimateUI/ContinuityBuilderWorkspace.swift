import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
public struct ContinuityBuilderWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            ContinuityBuilderWorkspaceContent(store: controller.store)
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Continuity Builder" : "Refreshing Continuity Builder",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

@available(macOS 26.0, *)
private struct ContinuityBuilderWorkspaceContent: View {
    @Bindable var store: AnimateStore

    @AppStorage("novotro.continuityBuilder.sidebarVisible") private var sidebarVisible = true
    @AppStorage("novotro.continuityBuilder.sidebar.width") private var sidebarWidth: Double = 320
    @AppStorage("novotro.continuityBuilder.showInspector") private var inspectorVisible = true
    @AppStorage("novotro.continuityBuilder.inspector.width") private var inspectorWidth: Double = 340
    @AppStorage("novotro.continuityBuilder.autoSubmit") private var autoSubmit = false

    @State private var session: ContinuityBuilderSession?
    @State private var selectedLabel: ContinuityBuilderCandidateLabel?
    @State private var closenessPercent: Double = 55
    @State private var notesText = ""
    @State private var statusMessage = "Review mode is active. Submit feedback to generate the next 1K continuity candidate."
    @State private var isLoading = false
    @State private var generatingTurnIDs: Set<UUID> = []
    @State private var dictationSession = ImageReviewDictationSession()

    private var projectRoot: URL? { Self.projectRoot(from: store.fileOWPURL ?? store.owpURL) }
    private var activeTurn: ContinuityBuilderTurn? { session?.activeTurn }
    private var projectTitle: String { projectRoot?.lastPathComponent ?? "Untitled Opera" }
    private var hasStarted: Bool { session?.hasStarted == true }

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "point.3.connected.trianglepath.dotted",
                    title: "Open A Project",
                    message: "Use File > Open Project to choose a local Amira project folder before training continuity."
                )
            } else {
                workspaceBody
            }
        }
        .task(id: projectRoot?.path) {
            await loadSession()
        }
    }

    private var workspaceBody: some View {
        Group {
            if hasStarted {
                startedWorkspaceBody
            } else {
                beginWorkspaceBody
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    private var startedWorkspaceBody: some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar
                    .frame(width: max(sidebarWidth, 260))
                OperaChromeSplitHandle(onDragChanged: resizeSidebar, onDragEnded: { })
            }

            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if inspectorVisible {
                OperaChromeSplitHandle(onDragChanged: resizeInspector, onDragEnded: { })
                inspector
                    .frame(width: max(inspectorWidth, 300))
            }
        }
    }

    private var beginWorkspaceBody: some View {
        OperaChromeFlatPane {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONTINUITY BUILDER")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text(projectTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                }
                Spacer()
            }
        } content: {
            VStack(spacing: 18) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Text("Start from zero")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text("Continuity Builder will run as one long guided session. It will choose the next best question, keep going from where you left off, and use your feedback to build continuity memory over time.")
                    .font(.system(size: 14))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .frame(maxWidth: 720)
                Button {
                    beginContinuityStream()
                } label: {
                    Label("Begin", systemImage: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading || session == nil)
                if isLoading {
                    ProgressView("Preparing first continuity prompt…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
        }
    }

    private var sidebar: some View {
        OperaChromeFlatPane(headerPadding: OperaChromeSidebarMetrics.headerPadding) {
            OperaChromePaneHeader(
                eyebrow: "CONTINUITY",
                title: "Builder",
                subtitle: session.map { "One stream • prompt #\($0.activeTurnIndex + 1) • \($0.feedback.count) notes" } ?? "Loading…"
            ) {
                OperaChromeActionButton(systemImage: "sidebar.left") {
                    withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false }
                }
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("One continuous stream")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(OperaChromeTheme.accent)
                                .frame(width: 8, height: 8)
                            Text("Current continuity judgment")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(OperaChromeTheme.textPrimary)
                        }
                        Text(activeTurn?.title ?? "Waiting for next prompt")
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(3)
                        Text("The builder dynamically chooses what to ask next; it is not a menu of separate tracks.")
                            .font(.system(size: 10))
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(OperaChromeTheme.selection, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if let session {
                        sidebarMetric("Judgments", "\(session.feedback.count)")
                        sidebarMetric("Prompt", "#\(session.activeTurnIndex + 1)")
                        sidebarMetric("Learned notes", "\(session.feedback.filter { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)")
                    }
                }
                .padding(14)
            }
        }
    }

    private var mainPane: some View {
        OperaChromeFlatPane {
            HStack(alignment: .center, spacing: 12) {
                if !sidebarVisible {
                    OperaChromeActionButton(systemImage: "sidebar.left") {
                        withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = true }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("CONTINUITY BUILDER")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text(projectTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                    Text(activeTurn?.priorityReason ?? "Guided continuity training from local project assets")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                if !inspectorVisible {
                    OperaChromeActionButton(systemImage: "sidebar.right") {
                        withAnimation(.easeInOut(duration: 0.2)) { inspectorVisible = true }
                    }
                }
            }
        } content: {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let turn = activeTurn {
                            turnHeader(turn)
                            candidateGrid(turn)
                            feedbackBox(turn)
                        } else {
                            OperaChromeEmptyState(
                                systemImage: "point.3.connected.trianglepath.dotted",
                                title: "No continuity prompts yet",
                                message: "Open a project with scenes, places, and character packages to seed the trainer."
                            )
                        }
                    }
                    .padding(18)
                }
            }
        }
    }

    private func turnHeader(_ turn: ContinuityBuilderTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(turn.category.displayName.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text(turn.title)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                }
                Spacer()
                Text("\(turn.recommendedAspectRatio) • \(turn.recommendedImageSize)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(OperaChromeTheme.selection, in: Capsule())
            }
            Text(turn.question)
                .font(.system(size: 14))
                .foregroundStyle(OperaChromeTheme.textPrimary)
            Text("Use this image to teach the continuity system what should stay, what should change, and what future prompts must remember.")
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textTertiary)
        }
        .padding(14)
        .background(OperaChromeTheme.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func candidateGrid(_ turn: ContinuityBuilderTurn) -> some View {
        if generatingTurnIDs.contains(turn.id) {
            return AnyView(Color.clear.frame(height: 360).accessibilityHidden(true))
        }
        guard !turn.candidates.isEmpty else {
            return AnyView(noCandidateCard(turn))
        }
        let visibleCandidates = Array(turn.candidates.prefix(2))
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: max(1, min(2, visibleCandidates.count)))
        return AnyView(VStack(alignment: .leading, spacing: 10) {
            if !turnHasGeneratedCandidates(turn) {
                Label("Reference inputs for the next generation — not regenerated results yet.", systemImage: "info.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(OperaChromeTheme.selection, in: Capsule())
            } else if visibleCandidates.count == 2 {
                Label("A/B comparison: choose the better candidate before submitting feedback.", systemImage: "rectangle.split.2x1")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(OperaChromeTheme.selection, in: Capsule())
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(visibleCandidates) { candidate in
                    candidateCard(candidate, showSelection: visibleCandidates.count > 1)
                }
            }
        })
    }

    private func noCandidateCard(_ turn: ContinuityBuilderTurn) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OperaChromeTheme.selection)
                .frame(height: 240)
                .overlay {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 34, weight: .light))
                        Text("No existing reference image found for this prompt.")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Use Generate 1K to create the minimum useful candidate, or add selected reference images to the project library.")
                            .font(.system(size: 12))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .padding()
                }
            Text(turn.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(OperaChromeTheme.textPrimary)
            Text("No candidate image • \(turn.category.displayName)")
                .font(.system(size: 10))
                .foregroundStyle(OperaChromeTheme.textTertiary)
        }
        .padding(10)
        .background(OperaChromeTheme.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func candidateCard(_ candidate: ContinuityBuilderCandidate, showSelection: Bool) -> some View {
        Button {
            selectedLabel = candidate.label
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if let path = candidate.imagePath {
                        AsyncStoreThumbnailImage.rounded(
                            store: store,
                            path: path,
                            maxSize: 360,
                            width: nil,
                            height: 320,
                            contentMode: .fit,
                            cornerRadius: 12
                        )
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(OperaChromeTheme.selection)
                            .frame(height: 320)
                            .overlay {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo.badge.exclamationmark")
                                    Text("No image yet")
                                }
                                .foregroundStyle(OperaChromeTheme.textTertiary)
                            }
                    }
                    Text(candidateBadge(for: candidate).uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(8)
                }
                Text(candidate.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(2)
                Text("\(candidate.referenceRole) • \(candidate.source)")
                    .font(.system(size: 10))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .lineLimit(1)
            }
            .padding(10)
            .background(OperaChromeTheme.panelBackground, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(showSelection && selectedLabel == candidate.label ? OperaChromeTheme.accent : OperaChromeTheme.stroke, lineWidth: showSelection && selectedLabel == candidate.label ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func feedbackBox(_ turn: ContinuityBuilderTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Feedback")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Auto submit", isOn: $autoSubmit)
                    .toggleStyle(.switch)
                    .font(.system(size: 11))
                Button {
                    dictationSession.toggle(projectRoot: projectRoot)
                } label: {
                    Label(dictationSession.isEnabled ? "Mic on" : "Mic", systemImage: dictationSession.isRecording ? "mic.fill" : "mic")
                }
                .buttonStyle(.bordered)
            }

            ReviewNotesTextView(text: $notesText) { command in
                handleReviewCommand(command, turn: turn)
            }
            .font(.system(size: 13))
            .frame(minHeight: 90)
            .background(OperaChromeTheme.workspaceBackground, in: RoundedRectangle(cornerRadius: 10))

            HStack(spacing: 12) {
                Text("Closeness: \(Int(closenessPercent))%")
                    .font(.system(size: 12, weight: .medium))
                Slider(value: $closenessPercent, in: 0...100, step: 5)
                Button("Reject Image") { reviewSelectedImage(rejected: true, rating: nil, advance: true) }
                    .disabled(selectedCandidate(in: turn)?.imagePath == nil)
                    .keyboardShortcut("/", modifiers: [])
                Button("5★ Image") { reviewSelectedImage(rejected: false, rating: 5, advance: true) }
                    .disabled(selectedCandidate(in: turn)?.imagePath == nil)
                    .keyboardShortcut(";", modifiers: [])
                Button(submitButtonTitle(for: turn)) { submit(turn) }
                    .keyboardShortcut(.return, modifiers: [])
                Button(generateButtonTitle(for: turn)) {
                    generateCandidates(turn)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
            Text(dictationSession.statusMessage.isEmpty ? statusMessage : "\(statusMessage) • \(dictationSession.statusMessage)")
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textTertiary)
        }
        .padding(14)
        .background(OperaChromeTheme.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var inspector: some View {
        OperaChromeFlatPane {
            OperaChromePaneHeader(eyebrow: "CONTINUITY", title: "Generation Prompt", subtitle: "Live prompt context") {
                OperaChromeActionButton(systemImage: "xmark") {
                    withAnimation(.easeInOut(duration: 0.2)) { inspectorVisible = false }
                }
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let turn = activeTurn {
                        inspectorSection("Prompt seed", turn.promptSeed)
                        inspectorSection("Negative guardrails", turn.negativeGuardrails.joined(separator: "\n• "))
                        inspectorSection("Context tags", turn.contextTags.joined(separator: ", "))
                        inspectorSection("Status", displayStatus(for: turn.generationStatus))
                    }
                }
                .padding(14)
            }
        }
    }

    private func inspectorSection(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Text(value.isEmpty ? "—" : value)
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    private func sidebarMetric(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(OperaChromeTheme.textSecondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(OperaChromeTheme.panelBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func livePromptSeed(for turn: ContinuityBuilderTurn) -> String {
        guard let projectRoot else { return turn.promptSeed }
        let rules = ContinuityRuleExtractionService.relevantPromptClauses(
            projectRoot: projectRoot,
            query: [turn.title, turn.question, turn.promptSeed, turn.contextTags.joined(separator: " ")].joined(separator: "\n"),
            limit: 8
        )
        return [
            turn.promptSeed,
            rules.isEmpty ? nil : "Latest relevant continuity memory injected at generation time:\n\(rules.joined(separator: "\n"))"
        ].compactMap { $0 }.joined(separator: "\n\n")
    }

    private func displayStatus(for status: String) -> String {
        switch status {
        case "dry_run_ready", "ready_for_generation":
            return "ready_for_generation"
        case "generated_candidates_ready_for_feedback":
            return "ready_for_feedback"
        default:
            return status
        }
    }

    private func turnHasGeneratedCandidates(_ turn: ContinuityBuilderTurn) -> Bool {
        turn.generationStatus == "generated_candidates_ready_for_feedback"
            && turn.candidates.contains { $0.source == "Continuity Builder generated candidate" }
    }

    private func candidateBadge(for candidate: ContinuityBuilderCandidate) -> String {
        if candidate.source == "Continuity Builder generated candidate" {
            return candidate.label == .single ? "Current image" : "Candidate \(candidate.label.displayName)"
        }
        return "Reference input"
    }

    private func statusMessage(for loadedSession: ContinuityBuilderSession) -> String {
        guard loadedSession.hasStarted else {
            return "Ready to begin one continuous Continuity Builder stream."
        }
        if let activeTurn = loadedSession.activeTurn, turnHasGeneratedCandidates(activeTurn) {
            return "Review mode is active. Rate/reject the generated image, add notes, then submit to generate the next 1K candidate."
        }
        return "No generated candidate is ready yet. Submit feedback or click Generate 1K to create one."
    }

    private func selectedCandidate(in turn: ContinuityBuilderTurn) -> ContinuityBuilderCandidate? {
        if let selectedLabel, let match = turn.candidates.first(where: { $0.label == selectedLabel }) {
            return match
        }
        return turn.candidates.first
    }

    private func handleReviewCommand(_ command: ImageReviewKeyboardCommand, turn: ContinuityBuilderTurn) -> Bool {
        switch command {
        case .previous:
            move(delta: -1)
        case .next:
            submit(turn)
        case .reject:
            reviewSelectedImage(rejected: true, rating: nil, advance: true)
        case .fiveStars:
            reviewSelectedImage(rejected: false, rating: 5, advance: true)
        case .setRating(let rating):
            reviewSelectedImage(rejected: false, rating: rating, advance: false)
        }
        return true
    }

    private func reviewSelectedImage(rejected: Bool, rating: Int?, advance: Bool) {
        guard let currentTurn = activeTurn,
              let candidate = selectedCandidate(in: currentTurn),
              let path = candidate.imagePath else {
            statusMessage = "No displayed image is selected for review."
            return
        }
        store.setImageLibraryRating(rating, for: path)
        store.setImageLibraryRejected(rejected, for: path)
        statusMessage = rejected
            ? "Marked displayed Continuity Builder image rejected; it will not be reused as a future continuity reference."
            : "Marked displayed Continuity Builder image 5★ and available as a strong future continuity reference."
        if advance {
            submit(currentTurn)
        }
    }

    private func loadSession() async {
        guard let projectRoot else { return }
        isLoading = true
        let loaded = await ContinuityBuilderService(store: store).loadOrCreateSession(projectRoot: projectRoot)
        session = loaded
        selectedLabel = loaded.activeTurn?.candidates.first?.label
        notesText = ""
        statusMessage = statusMessage(for: loaded)
        isLoading = false
    }

    private func beginContinuityStream() {
        guard let projectRoot, let currentSession = session else { return }
        isLoading = true
        statusMessage = "Beginning continuous Continuity Builder stream…"
        Task {
            do {
                let updated = try await ContinuityBuilderService(store: store).begin(session: currentSession, projectRoot: projectRoot)
                notesText = ""
                closenessPercent = 55
                if let firstTurn = updated.activeTurn {
                    generatingTurnIDs.insert(firstTurn.id)
                    session = updated
                    selectedLabel = nil
                    statusMessage = "Started one continuous Continuity Builder session. Gemini is generating the first 1K image…"
                    let generation = await generateAndApply(session: updated, turn: firstTurn, count: generationCount(for: firstTurn))
                    generatingTurnIDs.remove(firstTurn.id)
                    session = generation.session
                    selectedLabel = generation.session.activeTurn?.candidates.first?.label
                    statusMessage = generation.ok
                        ? "Generated the first 1K continuity image. Add feedback, then submit to generate the next one."
                        : (generation.blockers.first?.message ?? generation.records.first(where: { $0.errorMessage != nil })?.errorMessage ?? "Started the continuity session, but the first image did not generate.")
                } else {
                    session = updated
                    selectedLabel = updated.activeTurn?.candidates.first?.label
                    statusMessage = "Started one continuous Continuity Builder session."
                }
            } catch {
                statusMessage = "Could not begin Continuity Builder: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func submit(_ turn: ContinuityBuilderTurn) {
        guard turnHasGeneratedCandidates(turn) else {
            generateCandidates(turn)
            return
        }
        guard let projectRoot, let currentSession = session else { return }
        let submittedLabel = selectedLabel
        isLoading = true
        statusMessage = "Saving continuity feedback, then Gemini will generate the next 1K image…"
        Task {
            let transcript = await dictationSession.cycleForReviewCommand(projectRoot: projectRoot)
            let combined = [notesText, transcript].compactMap { text in
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }.joined(separator: "\n")
            do {
                if shouldAutoRejectForLearning(notes: combined, closenessPercent: Int(closenessPercent)),
                   let selected = selectedCandidate(in: turn),
                   selected.source == "Continuity Builder generated candidate",
                   let path = selected.imagePath {
                    store.setImageLibraryRejected(true, for: path)
                }
                let updated = try await ContinuityBuilderService(store: store).recordFeedback(
                    session: currentSession,
                    turn: turn,
                    selectedLabel: submittedLabel,
                    closenessPercent: Int(closenessPercent),
                    notes: combined,
                    transcriptAudioPath: dictationSession.lastAudioPath,
                    projectRoot: projectRoot
                )
                notesText = ""
                closenessPercent = 55
                if let nextTurn = updated.activeTurn {
                    generatingTurnIDs.insert(nextTurn.id)
                    statusMessage = "Saved feedback. Updating continuity memory, then Gemini will generate the next 1K image…"
                    await refreshContinuityRules(projectRoot: projectRoot)
                    statusMessage = "Continuity memory updated. Gemini is generating the next 1K continuity image now…"
                    let generation = await generateAndApply(session: updated, turn: nextTurn, count: generationCount(for: nextTurn))
                    generatingTurnIDs.remove(nextTurn.id)
                    session = generation.session
                    selectedLabel = generation.session.activeTurn?.candidates.first?.label
                    if generation.ok {
                        let completed = generation.records.filter { $0.status == "completed" }.count
                        statusMessage = completed == 1
                            ? "Generated the next 1K continuity image from your latest feedback."
                            : "Generated \(completed) A/B continuity candidates from your latest feedback."
                    } else {
                        statusMessage = (generation.blockers.first?.message ?? generation.records.first(where: { $0.errorMessage != nil })?.errorMessage)
                            ?? "Feedback was saved, but the next continuity image did not generate."
                        session = updated
                        selectedLabel = updated.activeTurn?.candidates.first?.label
                    }
                }
                if let feedback = updated.feedback.first(where: { $0.turnID == turn.id }) {
                    let baseStatus = statusMessage
                    let selectedCandidate = turn.candidates.first { $0.label == submittedLabel }
                    let propagation = await ContinuityFeedbackPropagationService(store: store).propagate(
                        feedback: feedback,
                        turn: turn,
                        selectedCandidate: selectedCandidate,
                        projectRoot: projectRoot
                    )
                    let suffix = propagation.autoRejectedCount > 0
                        ? " Auto-rejected \(propagation.autoRejectedCount) high-confidence similar image(s)."
                        : propagation.reviewCandidateCount > 0
                            ? " Found \(propagation.reviewCandidateCount) possible similar issue(s) for review; none auto-rejected."
                            : ""
                    if !suffix.isEmpty {
                        statusMessage = "\(baseStatus)\(suffix)"
                    }
                }
            } catch {
                statusMessage = "Could not save continuity feedback: \(error.localizedDescription)"
            }
            if let activeID = session?.activeTurn?.id {
                generatingTurnIDs.remove(activeID)
            }
            isLoading = false
        }
    }

    private func shouldAutoRejectForLearning(notes: String, closenessPercent: Int) -> Bool {
        if closenessPercent < 45 { return true }
        guard closenessPercent < 75 else { return false }
        let lower = notes.lowercased()
        let correctionMarkers = [
            "wrong", "incorrect", "not ", "doesn't", "does not", "too ",
            "needs to", "should be", "should not", "fix", "instead", "missing"
        ]
        return correctionMarkers.contains { lower.contains($0) }
    }

    private func refreshContinuityRules(projectRoot: URL) async {
        let key = store.miniMaxAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try? await ContinuityRuleExtractionService(store: store).build(
            .init(
                projectRoot: projectRoot,
                mode: key.isEmpty ? "dry_run" : "execute",
                model: "MiniMax-M2.7",
                writeSidecars: true,
                apiKey: key,
                maxSources: 160
            )
        )
    }


    private func generateCandidates(_ turn: ContinuityBuilderTurn) {
        guard let currentSession = session else { return }
        let count = generationCount(for: turn)
        isLoading = true
        generatingTurnIDs.insert(turn.id)
        statusMessage = count == 1
            ? "Gemini is generating one smart 1K Continuity Builder candidate…"
            : "Gemini is generating an A/B pair of 1K Continuity Builder candidates…"
        Task {
            let result = await generateAndApply(session: currentSession, turn: turn, count: count)
            generatingTurnIDs.remove(turn.id)
            session = result.session
            selectedLabel = result.session.activeTurn?.candidates.first?.label
            isLoading = false
            if result.ok {
                statusMessage = "Generated \(result.records.filter { $0.status == "completed" }.count) Continuity Builder candidate(s); immediate Image Intelligence analysis is queued/running."
            } else {
                statusMessage = (result.blockers.first?.message ?? result.records.first(where: { $0.errorMessage != nil })?.errorMessage) ?? "Continuity generation did not complete."
            }
        }
    }

    private func generateButtonTitle(for turn: ContinuityBuilderTurn) -> String {
        let count = generationCount(for: turn)
        return count == 1 ? "Generate 1K" : "Generate A/B 1K"
    }

    private func submitButtonTitle(for turn: ContinuityBuilderTurn) -> String {
        turnHasGeneratedCandidates(turn) ? "Submit & Generate Next" : "Generate Current"
    }

    private func generationCount(for turn: ContinuityBuilderTurn) -> Int {
        let compareText = [turn.title, turn.question, turn.promptSeed].joined(separator: " ").lowercased()
        if compareText.contains("a/b") || compareText.contains("which image is better") || compareText.contains("choose the better") {
            return 2
        }
        return 1
    }

    private func generateAndApply(
        session currentSession: ContinuityBuilderSession,
        turn: ContinuityBuilderTurn,
        count: Int
    ) async -> ContinuityBuilderGenerationResult {
        guard let projectRoot else {
            return ContinuityBuilderGenerationResult(
                ok: false,
                mode: "execute",
                isDryRun: false,
                estimatedCostUSD: 0,
                maxCostUSD: 0.50,
                records: [],
                session: currentSession,
                blockers: [.init(code: .needsManualReview, message: "Project root is unavailable.", field: "projectRoot")]
            )
        }
        return await ContinuityBuilderGenerationService(store: store).generate(
            .init(
                session: currentSession,
                turnID: turn.id,
                projectRoot: projectRoot,
                mode: "execute",
                maxCostUSD: 0.50,
                candidateCount: min(max(count, 1), 2),
                model: store.selectedGeminiModel,
                imageSize: "1K",
                aspectRatio: "4:3",
                apiKey: store.geminiAPIKey
            )
        )
    }

    private static func projectRoot(from url: URL?) -> URL? {
        guard let url else { return nil }
        if url.lastPathComponent == "Animate" {
            return url.deletingLastPathComponent()
        }
        if url.pathExtension.lowercased() == "owp" {
            return url.deletingLastPathComponent()
        }
        return url
    }

    private func move(delta: Int) {
        guard let projectRoot, let currentSession = session else { return }
        do {
            let updated = try ContinuityBuilderService(store: store).move(session: currentSession, delta: delta, projectRoot: projectRoot)
            session = updated
            selectedLabel = updated.activeTurn?.candidates.first?.label
            notesText = ""
        } catch {
            statusMessage = "Could not move continuity prompt: \(error.localizedDescription)"
        }
    }

    private func jump(to index: Int) {
        guard let projectRoot, var currentSession = session else { return }
        currentSession.activeTurnIndex = index
        currentSession.updatedAt = Date()
        session = currentSession
        selectedLabel = currentSession.activeTurn?.candidates.first?.label
        notesText = ""
        _ = try? ContinuityBuilderService(store: store).move(session: currentSession, delta: 0, projectRoot: projectRoot)
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(max(sidebarWidth + Double(delta), 260), 520)
    }

    private func resizeInspector(_ delta: CGFloat) {
        inspectorWidth = min(max(inspectorWidth - Double(delta), 300), 640)
    }
}
