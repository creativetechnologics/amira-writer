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
    @State private var statusMessage = "Continuity Builder is dry-run only until paid generation is explicitly approved."
    @State private var isLoading = false
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
                if isLoading {
                    ProgressView("Preparing continuity prompt…")
                        .padding()
                }
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
            Text("Generation is execute-gated and cost-capped; feedback writes project-local continuity artifacts.")
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textTertiary)
        }
        .padding(14)
        .background(OperaChromeTheme.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func candidateGrid(_ turn: ContinuityBuilderTurn) -> some View {
        guard !turn.candidates.isEmpty else {
            return AnyView(noCandidateCard(turn))
        }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: max(1, min(3, turn.candidates.count)))
        return AnyView(LazyVGrid(columns: columns, spacing: 12) {
            ForEach(turn.candidates) { candidate in
                candidateCard(candidate)
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
                        Text("Use Smart Generate 1K to create the minimum useful candidate, or add approved refs to the project library.")
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

    private func candidateCard(_ candidate: ContinuityBuilderCandidate) -> some View {
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
                    Text(candidate.label.displayName.uppercased())
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
                    .stroke(selectedLabel == candidate.label ? OperaChromeTheme.accent : OperaChromeTheme.stroke, lineWidth: selectedLabel == candidate.label ? 2 : 1)
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
                Button("Submit & Next") { submit(turn) }
                    .keyboardShortcut(.return, modifiers: [])
                Button(generateButtonTitle(for: turn)) {
                    generateCandidates(turn)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isLoading)
            }
            if isLoading {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(statusMessage)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
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
            OperaChromePaneHeader(eyebrow: "CONTINUITY", title: "Prompt Seed", subtitle: "Dry-run scaffold") {
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
                        inspectorSection("Status", turn.generationStatus)
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
        isLoading = false
    }

    private func beginContinuityStream() {
        guard let projectRoot, let currentSession = session else { return }
        isLoading = true
        statusMessage = "Beginning continuous Continuity Builder stream…"
        Task {
            do {
                let updated = try await ContinuityBuilderService(store: store).begin(session: currentSession, projectRoot: projectRoot)
                session = updated
                selectedLabel = updated.activeTurn?.candidates.first?.label
                notesText = ""
                closenessPercent = 55
                statusMessage = "Started one continuous Continuity Builder session."
            } catch {
                statusMessage = "Could not begin Continuity Builder: \(error.localizedDescription)"
            }
            isLoading = false
        }
    }

    private func submit(_ turn: ContinuityBuilderTurn) {
        guard let projectRoot, let currentSession = session else { return }
        let submittedLabel = selectedLabel
        statusMessage = "Saving continuity feedback and preparing the next prompt…"
        Task {
            let transcript = await dictationSession.cycleForReviewCommand(projectRoot: projectRoot)
            let combined = [notesText, transcript].compactMap { text in
                let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }.joined(separator: "\n")
            do {
                let updated = try await ContinuityBuilderService(store: store).recordFeedback(
                    session: currentSession,
                    turn: turn,
                    selectedLabel: submittedLabel,
                    closenessPercent: Int(closenessPercent),
                    notes: combined,
                    transcriptAudioPath: dictationSession.lastAudioPath,
                    projectRoot: projectRoot
                )
                session = updated
                selectedLabel = updated.activeTurn?.candidates.first?.label
                notesText = ""
                closenessPercent = 55
                if let feedback = updated.feedback.first(where: { $0.turnID == turn.id }) {
                    statusMessage = store.miniMaxAPIKey.isEmpty
                        ? "Checking similar images and updating local continuity memory…"
                        : "Checking similar images and making the feedback available for MiniMax rule extraction…"
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
                    statusMessage = "Saved continuity feedback to Metadata/automation/continuity-builder.\(suffix)"
                } else {
                    statusMessage = "Saved continuity feedback to Metadata/automation/continuity-builder."
                }
            } catch {
                statusMessage = "Could not save continuity feedback: \(error.localizedDescription)"
            }
        }
    }


    private func generateCandidates(_ turn: ContinuityBuilderTurn) {
        guard let projectRoot, let currentSession = session else { return }
        let count = smartGenerationCount(for: turn)
        isLoading = true
        statusMessage = count == 1
            ? "Gemini is generating one smart 1K Continuity Builder candidate with a $0.50 cap…"
            : "Gemini is generating \(count) smart 1K Continuity Builder candidates with a $0.50 cap…"
        Task {
            let result = await ContinuityBuilderGenerationService(store: store).generate(
                .init(
                    session: currentSession,
                    turnID: turn.id,
                    projectRoot: projectRoot,
                    mode: "execute",
                    maxCostUSD: 0.50,
                    candidateCount: count,
                    model: store.selectedGeminiModel,
                    imageSize: "1K",
                    aspectRatio: "4:3",
                    apiKey: store.geminiAPIKey
                )
            )
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
        let count = smartGenerationCount(for: turn)
        return count == 1 ? "Smart Generate 1K" : "Smart Generate \(count) × 1K"
    }

    private func smartGenerationCount(for turn: ContinuityBuilderTurn) -> Int {
        if turn.candidates.isEmpty { return 1 }
        if let session,
           session.feedback.contains(where: { $0.turnID == turn.id && $0.closenessPercent < 35 }) {
            return 2
        }
        let comparisonCategories: Set<ContinuityBuilderCategory> = [.costumeContinuity, .styleContinuity]
        if comparisonCategories.contains(turn.category), turn.candidates.count < 2 {
            return 2
        }
        return 1
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
