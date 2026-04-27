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

    @AppStorage("novotro.continuityBuilder.autoAdvance") private var autoAdvance = true

    @State private var session: ContinuityBuilderSession?
    @State private var selectedLabel: ContinuityBuilderCandidateLabel?
    @State private var closenessPercent: Double = 55
    @State private var notesText = ""
    @State private var statusMessage = "Review mode is active. Submit feedback to generate the next 1K continuity candidate."
    @State private var isLoading = false
    @State private var generatingTurnIDs: Set<UUID> = []
    @State private var isPrebuffering = false

    private var projectRoot: URL? { Self.projectRoot(from: store.fileOWPURL ?? store.owpURL) }
    private var activeTurn: ContinuityBuilderTurn? { session?.activeTurn }
    private var projectTitle: String { projectRoot?.lastPathComponent ?? "Untitled Opera" }
    private var hasStarted: Bool { session?.hasStarted == true }
    private let maxBufferedContinuityImages = 5

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
        mainPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var mainPane: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            if let turn = activeTurn {
                VStack(spacing: 18) {
                    continuityImage(turn)
                        .frame(maxWidth: 980)
                    reviewControls(turn)
                        .frame(maxWidth: 520)
                    feedbackBox(turn)
                        .frame(maxWidth: 760)
                }
                .padding(.horizontal, 32)
            } else {
                OperaChromeEmptyState(
                    systemImage: "point.3.connected.trianglepath.dotted",
                    title: "No continuity image yet",
                    message: "Continuity Builder will generate one image at a time for like/reject review."
                )
                .padding(32)
            }
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OperaChromeTheme.workspaceBackground)
    }

    private func continuityImage(_ turn: ContinuityBuilderTurn) -> some View {
        Group {
            if generatingTurnIDs.contains(turn.id) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OperaChromeTheme.panelBackground)
                    .overlay { Color.clear }
            } else if let candidate = generatedCandidate(in: turn), let path = candidate.imagePath {
                AsyncStoreThumbnailImage.rounded(
                    store: store,
                    path: path,
                    maxSize: 900,
                    width: nil,
                    height: 560,
                    contentMode: .fit,
                    cornerRadius: 18
                )
                .background(OperaChromeTheme.panelBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OperaChromeTheme.panelBackground)
                    .overlay {
                        Button {
                            generateCandidates(turn)
                        } label: {
                            Label("Generate Current", systemImage: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isLoading)
                    }
            }
        }
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
    }

    private func reviewControls(_ turn: ContinuityBuilderTurn) -> some View {
        HStack(spacing: 18) {
            Button {
                reviewSelectedImage(rejected: true, liked: false, rating: nil, closenessOverride: 0, advance: autoAdvance)
            } label: {
                Image(systemName: "hand.thumbsdown.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .frame(width: 78, height: 56)
            }
            .buttonStyle(.bordered)
            .disabled(generatedCandidate(in: turn)?.imagePath == nil)
            .keyboardShortcut("/", modifiers: [])

            Button {
                reviewSelectedImage(rejected: false, liked: true, rating: nil, closenessOverride: 100, advance: autoAdvance)
            } label: {
                Image(systemName: "hand.thumbsup.fill")
                    .font(.system(size: 32, weight: .semibold))
                    .frame(width: 78, height: 56)
            }
            .buttonStyle(.borderedProminent)
            .disabled(generatedCandidate(in: turn)?.imagePath == nil)
            .keyboardShortcut(";", modifiers: [])
        }
    }

    private func feedbackBox(_ turn: ContinuityBuilderTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Notes")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Auto-advance", isOn: $autoAdvance)
                    .toggleStyle(.switch)
                    .font(.system(size: 11))
            }

            ReviewNotesTextView(text: $notesText) { command in
                handleReviewCommand(command, turn: turn)
            }
            .font(.system(size: 13))
            .frame(minHeight: 90)
            .background(OperaChromeTheme.workspaceBackground, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func turnHasGeneratedCandidates(_ turn: ContinuityBuilderTurn) -> Bool {
        turn.generationStatus == "generated_candidates_ready_for_feedback"
            && turn.candidates.contains { $0.source == "Continuity Builder generated candidate" }
    }

    private func generatedCandidate(in turn: ContinuityBuilderTurn) -> ContinuityBuilderCandidate? {
        guard turnHasGeneratedCandidates(turn) else { return nil }
        if let selectedLabel,
           let match = turn.candidates.first(where: { $0.label == selectedLabel && $0.source == "Continuity Builder generated candidate" }) {
            return match
        }
        return turn.candidates.first { $0.source == "Continuity Builder generated candidate" }
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

    private func handleReviewCommand(_ command: ImageReviewKeyboardCommand, turn: ContinuityBuilderTurn) -> Bool {
        switch command {
        case .previous:
            move(delta: -1)
        case .next:
            submit(turn)
        case .reject:
            reviewSelectedImage(rejected: true, liked: false, rating: nil, closenessOverride: 0, advance: autoAdvance)
        case .fiveStars:
            reviewSelectedImage(rejected: false, liked: true, rating: 5, closenessOverride: 100, advance: autoAdvance)
        case .setRating(let rating):
            reviewSelectedImage(rejected: false, liked: rating.map { $0 >= 4 } ?? false, rating: rating, closenessOverride: nil, advance: false)
        }
        return true
    }

    private func reviewSelectedImage(
        rejected: Bool,
        liked: Bool,
        rating: Int?,
        closenessOverride: Int?,
        advance: Bool
    ) {
        guard let currentTurn = activeTurn,
              let candidate = generatedCandidate(in: currentTurn),
              let path = candidate.imagePath else {
            statusMessage = "No displayed image is selected for review."
            return
        }
        if let closenessOverride {
            closenessPercent = Double(closenessOverride)
        }
        store.setImageLibraryRating(rating, for: path)
        store.setImageLibraryLiked(liked && !rejected, for: path)
        store.setImageLibraryRejected(rejected, for: path)
        statusMessage = rejected
            ? "Marked displayed Continuity Builder image rejected; it will not be reused as a future continuity reference."
            : "Marked displayed Continuity Builder image liked and available as a strong future continuity reference."
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
        schedulePrebufferIfUseful()
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
            schedulePrebufferIfUseful()
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
            let combined = notesText.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                if shouldAutoRejectForLearning(notes: combined, closenessPercent: Int(closenessPercent)),
                   let selected = generatedCandidate(in: turn),
                   let path = selected.imagePath {
                    store.setImageLibraryRejected(true, for: path)
                }
                let updated = try await ContinuityBuilderService(store: store).recordFeedback(
                    session: currentSession,
                    turn: turn,
                    selectedLabel: submittedLabel,
                    closenessPercent: Int(closenessPercent),
                    notes: combined,
                    transcriptAudioPath: nil,
                    projectRoot: projectRoot
                )
                notesText = ""
                closenessPercent = 55
                if let nextTurn = updated.activeTurn {
                    statusMessage = "Saved feedback. Updating continuity memory…"
                    await refreshContinuityRules(projectRoot: projectRoot)
                    if turnHasGeneratedCandidates(nextTurn) {
                        session = updated
                        selectedLabel = nextTurn.candidates.first?.label
                        statusMessage = "Continuity memory updated. Showing the next prebuffered 1K image while Gemini prepares another independent candidate."
                    } else {
                        generatingTurnIDs.insert(nextTurn.id)
                        statusMessage = "Continuity memory updated. Gemini is generating the next 1K continuity image now…"
                        let generation = await generateAndApply(session: updated, turn: nextTurn, count: generationCount(for: nextTurn))
                        generatingTurnIDs.remove(nextTurn.id)
                        session = generation.session
                        selectedLabel = generation.session.activeTurn?.candidates.first?.label
                        if generation.ok {
                            let completed = generation.records.filter { $0.status == "completed" }.count
                            statusMessage = completed == 1
                                ? "Generated the next 1K continuity image from your latest feedback."
                                : "Generated \(completed) buffered 1K continuity images."
                        } else {
                            statusMessage = (generation.blockers.first?.message ?? generation.records.first(where: { $0.errorMessage != nil })?.errorMessage)
                                ?? "Feedback was saved, but the next continuity image did not generate."
                            session = updated
                            selectedLabel = updated.activeTurn?.candidates.first?.label
                        }
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
            schedulePrebufferIfUseful()
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
        statusMessage = "Gemini is generating one smart 1K Continuity Builder candidate…"
        Task {
            let result = await generateAndApply(session: currentSession, turn: turn, count: count)
            generatingTurnIDs.remove(turn.id)
            session = result.session
            selectedLabel = result.session.activeTurn?.candidates.first?.label
            isLoading = false
            if result.ok {
                statusMessage = "Generated \(result.records.filter { $0.status == "completed" }.count) Continuity Builder candidate(s); immediate Image Intelligence analysis is queued/running."
                schedulePrebufferIfUseful()
            } else {
                statusMessage = (result.blockers.first?.message ?? result.records.first(where: { $0.errorMessage != nil })?.errorMessage) ?? "Continuity generation did not complete."
            }
        }
    }

    private func generateButtonTitle(for turn: ContinuityBuilderTurn) -> String {
        "Generate 1K"
    }

    private func submitButtonTitle(for turn: ContinuityBuilderTurn) -> String {
        turnHasGeneratedCandidates(turn) ? "Submit & Generate Next" : "Generate Current"
    }

    private func generationCount(for turn: ContinuityBuilderTurn) -> Int {
        return 1
    }

    private func schedulePrebufferIfUseful() {
        guard !isPrebuffering,
              !isLoading,
              let projectRoot,
              let currentSession = session,
              let activeTurn = currentSession.activeTurn,
              turnHasGeneratedCandidates(activeTurn) else { return }
        let futureGeneratedCount = currentSession.turns
            .dropFirst(currentSession.activeTurnIndex + 1)
            .filter { turnHasGeneratedCandidates($0) || generatingTurnIDs.contains($0.id) }
            .count
        guard futureGeneratedCount < maxBufferedContinuityImages else { return }

        isPrebuffering = true
        Task {
            var shouldContinue = false
            do {
                let prepared = try await ContinuityBuilderService(store: store).ensureBufferedTurn(
                    session: currentSession,
                    projectRoot: projectRoot,
                    maxBuffered: maxBufferedContinuityImages
                )
                session = prepared
                guard let pending = prepared.turns
                    .dropFirst(prepared.activeTurnIndex + 1)
                    .first(where: { $0.generationStatus == "ready_for_generation" }) else {
                    isPrebuffering = false
                    return
                }
                generatingTurnIDs.insert(pending.id)
                let result = await generateAndApply(session: prepared, turn: pending, count: 1)
                generatingTurnIDs.remove(pending.id)
                if result.ok {
                    session = result.session
                    shouldContinue = true
                }
            } catch {
                // Keep the current review flow silent; the title-bar Gemini pill
                // already exposes provider activity and failures for generated jobs.
            }
            isPrebuffering = false
            if shouldContinue {
                schedulePrebufferIfUseful()
            }
        }
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
                candidateCount: 1,
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


}
