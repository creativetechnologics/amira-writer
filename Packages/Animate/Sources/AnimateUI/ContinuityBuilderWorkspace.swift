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
    @State private var reviewInFlightTurnID: UUID?
    @State private var generatingTurnIDs: Set<UUID> = []
    @State private var isPrebuffering = false
    @State private var promptReferencePaths: [String] = []
    @State private var promptReferenceDetails: [String: String] = [:]
    @State private var promptReferenceSubjectName: String?
    @State private var promptReferenceImagePath: String?

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
                    Text(reviewHeader(for: turn).uppercased())
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    continuityImage(turn)
                        .frame(maxWidth: 980)
                    reviewControls(turn)
                        .frame(maxWidth: 520)
                    feedbackBox(turn)
                        .frame(maxWidth: 760)
                    promptReferencesStrip(turn)
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

    private func reviewHeader(for turn: ContinuityBuilderTurn) -> String {
        let base = turn.category.reviewSubjectLabel
        guard turn.category == .characterIdentity || turn.category == .costumeContinuity else {
            return base
        }
        let currentImagePath = generatedCandidate(in: turn)?.imagePath
        let loadedSubject = promptReferenceImagePath == currentImagePath ? promptReferenceSubjectName : nil
        let name = loadedSubject ?? inferredCharacterName(for: turn)
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(base) — \(name)"
        }
        return base
    }

    private func inferredCharacterName(for turn: ContinuityBuilderTurn) -> String? {
        for candidate in turn.candidates {
            guard candidate.referenceRole == "character_identity" || candidate.referenceRole == "character_costume" else { continue }
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            if let colon = title.firstIndex(of: ":") {
                return String(title[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return title
        }
        return nil
    }

    private func continuityImage(_ turn: ContinuityBuilderTurn) -> some View {
        Group {
            if generatingTurnIDs.contains(turn.id) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(OperaChromeTheme.panelBackground)
                    .overlay {
                        ProgressView()
                            .controlSize(.large)
                    }
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
            reviewButton(
                systemImage: "hand.thumbsdown.fill",
                tint: .red,
                isDisabled: isReviewDisabled(for: turn)
            ) {
                reviewSelectedImage(rejected: true, liked: false, rating: nil, closenessOverride: 0, advance: autoAdvance)
            }
            .keyboardShortcut("/", modifiers: [])

            reviewButton(
                systemImage: "hand.thumbsup.fill",
                tint: .green,
                isDisabled: isReviewDisabled(for: turn)
            ) {
                reviewSelectedImage(rejected: false, liked: true, rating: nil, closenessOverride: 100, advance: autoAdvance)
            }
            .keyboardShortcut(";", modifiers: [])
        }
    }

    private func reviewButton(systemImage: String, tint: Color, isDisabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(isDisabled ? OperaChromeTheme.textTertiary : tint)
                .frame(width: 84, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(OperaChromeTheme.panelBackground)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isDisabled ? OperaChromeTheme.stroke : tint.opacity(0.8), lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func isReviewDisabled(for turn: ContinuityBuilderTurn) -> Bool {
        reviewInFlightTurnID == turn.id
            || generatingTurnIDs.contains(turn.id)
            || generatedCandidate(in: turn)?.imagePath == nil
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
            .padding(8)
            .frame(minHeight: 90)
            .background(OperaChromeTheme.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(OperaChromeTheme.stroke, lineWidth: 1)
            }
        }
    }

    private func promptReferencesStrip(_ turn: ContinuityBuilderTurn) -> some View {
        let currentImagePath = generatedCandidate(in: turn)?.imagePath
        let referencePaths = promptReferenceImagePath == currentImagePath ? promptReferencePaths : []
        return VStack(alignment: .leading, spacing: 8) {
            if !referencePaths.isEmpty {
                Text("Prompt references used for this image")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(84), spacing: 8)], spacing: 8) {
                        ForEach(referencePaths, id: \.self) { path in
                            UnifiedImageTile(
                                path: path,
                                resolvedPath: path,
                                thumbnailSize: 72,
                                sourceLabel: promptReferenceLabel(for: path),
                                sourceSystemImage: promptReferenceIcon(for: path),
                                isSelected: false,
                                isRejected: false,
                                isLiked: false,
                                hasNotes: false,
                                rating: nil
                            )
                            .frame(width: 84, height: 84)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(height: 92)
            }
        }
        .task(id: generatedCandidate(in: turn)?.imagePath ?? "\(turn.id.uuidString)-none") {
            await loadPromptReferenceMetadata(for: generatedCandidate(in: turn)?.imagePath)
        }
    }

    private func promptReferenceLabel(for path: String) -> String {
        switch promptReferenceDetails[path] {
        case "edit_source":
            return "EDIT"
        case "spatial_map":
            return "MAP"
        default:
            return "REF"
        }
    }

    private func promptReferenceIcon(for path: String) -> String {
        switch promptReferenceDetails[path] {
        case "edit_source":
            return "wand.and.stars"
        case "spatial_map":
            return "map"
        default:
            return "photo"
        }
    }

    private func loadPromptReferenceMetadata(for imagePath: String?) async {
        guard let imagePath else {
            promptReferencePaths = []
            promptReferenceDetails = [:]
            promptReferenceSubjectName = nil
            promptReferenceImagePath = nil
            return
        }
        if promptReferenceImagePath != imagePath {
            promptReferenceImagePath = imagePath
            promptReferencePaths = []
            promptReferenceDetails = [:]
            promptReferenceSubjectName = nil
        }
        let metadata = await Task.detached(priority: .utility) { () -> (paths: [String], details: [String: String], subject: String?) in
            let url = URL(fileURLWithPath: imagePath)
                .deletingPathExtension()
                .appendingPathExtension("continuity.json")
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ([], [:], nil)
            }
            let paths = (object["referencePaths"] as? [String] ?? []).filter {
                FileManager.default.fileExists(atPath: $0)
            }
            var details: [String: String] = [:]
            for item in object["referenceDetails"] as? [[String: Any]] ?? [] {
                guard let path = item["path"] as? String,
                      let role = item["role"] as? String else { continue }
                details[path] = role
            }
            return (paths, details, object["reviewSubjectName"] as? String)
        }.value
        guard imagePath == activeTurn.flatMap({ generatedCandidate(in: $0)?.imagePath }) else { return }
        promptReferencePaths = metadata.paths
        promptReferenceDetails = metadata.details
        promptReferenceSubjectName = metadata.subject
        promptReferenceImagePath = imagePath
    }

    private func turnHasGeneratedCandidates(_ turn: ContinuityBuilderTurn) -> Bool {
        guard let projectRoot else { return false }
        return turn.generationStatus == "generated_candidates_ready_for_feedback"
            && turn.candidates.contains { ContinuityBuilderService.isCurrentGeneratedCandidate($0, projectRoot: projectRoot) }
    }

    private func generatedCandidate(in turn: ContinuityBuilderTurn) -> ContinuityBuilderCandidate? {
        guard turnHasGeneratedCandidates(turn) else { return nil }
        if let selectedLabel,
           let projectRoot,
           let match = turn.candidates.first(where: {
               $0.label == selectedLabel && ContinuityBuilderService.isCurrentGeneratedCandidate($0, projectRoot: projectRoot)
           }) {
            return match
        }
        guard let projectRoot else { return nil }
        return turn.candidates.first { ContinuityBuilderService.isCurrentGeneratedCandidate($0, projectRoot: projectRoot) }
    }

    private func defaultSelectedLabel(for turn: ContinuityBuilderTurn?) -> ContinuityBuilderCandidateLabel? {
        guard let turn else { return nil }
        if let projectRoot,
           let current = turn.candidates.first(where: { ContinuityBuilderService.isCurrentGeneratedCandidate($0, projectRoot: projectRoot) }) {
            return current.label
        }
        return turn.candidates.first(where: { $0.source == ContinuityBuilderService.generatedCandidateSource })?.label
            ?? turn.candidates.first?.label
    }

    @discardableResult
    private func reloadLatestSession(projectRoot: URL) async -> ContinuityBuilderSession {
        let latest = await ContinuityBuilderService(store: store).loadOrCreateSession(projectRoot: projectRoot)
        session = latest
        selectedLabel = defaultSelectedLabel(for: latest.activeTurn)
        return latest
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
        if let rating {
            store.setImageLibraryRating(rating, for: path)
        }
        selectedLabel = candidate.label
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
        selectedLabel = defaultSelectedLabel(for: loaded.activeTurn)
        notesText = ""
        statusMessage = statusMessage(for: loaded)
        isLoading = false
        if loaded.hasStarted, let activeTurn = loaded.activeTurn, !turnHasGeneratedCandidates(activeTurn) {
            generateCandidates(activeTurn)
        } else {
            schedulePrebufferIfUseful()
        }
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
                    let latest = await reloadLatestSession(projectRoot: projectRoot)
                    statusMessage = generation.ok
                        ? "Generated the first 1K continuity image. Add feedback, then submit to generate the next one."
                        : (generation.blockers.first?.message ?? generation.records.first(where: { $0.errorMessage != nil })?.errorMessage ?? "Started the continuity session, but the first image did not generate.")
                    if !generation.ok {
                        session = latest
                    }
                } else {
                    session = updated
                    selectedLabel = defaultSelectedLabel(for: updated.activeTurn)
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
        let submittedLabel = generatedCandidate(in: turn)?.label ?? selectedLabel
        reviewInFlightTurnID = turn.id
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
                let service = ContinuityBuilderService(store: store)
                let latestBeforeFeedback = await service.loadOrCreateSession(projectRoot: projectRoot)
                let sessionForFeedback = latestBeforeFeedback.turns.contains(where: { $0.id == turn.id })
                    ? latestBeforeFeedback
                    : currentSession
                let updated = try await ContinuityBuilderService(store: store).recordFeedback(
                    session: sessionForFeedback,
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
                    if turnHasGeneratedCandidates(nextTurn) {
                        session = updated
                        selectedLabel = defaultSelectedLabel(for: nextTurn)
                        statusMessage = "Showing the next 1K continuity image."
                    } else {
                        generatingTurnIDs.insert(nextTurn.id)
                        session = updated
                        selectedLabel = defaultSelectedLabel(for: nextTurn)
                        statusMessage = "Gemini is generating the next 1K continuity image now…"
                        let generation = await generateAndApply(session: updated, turn: nextTurn, count: generationCount(for: nextTurn))
                        generatingTurnIDs.remove(nextTurn.id)
                        _ = await reloadLatestSession(projectRoot: projectRoot)
                        if generation.ok {
                            let completed = generation.records.filter { $0.status == "completed" }.count
                            statusMessage = completed == 1
                                ? "Generated the next 1K continuity image from your latest feedback."
                                : "Generated \(completed) buffered 1K continuity images."
                        } else {
                            statusMessage = (generation.blockers.first?.message ?? generation.records.first(where: { $0.errorMessage != nil })?.errorMessage)
                                ?? "Feedback was saved, but the next continuity image did not generate."
                            session = updated
                            selectedLabel = defaultSelectedLabel(for: updated.activeTurn)
                        }
                    }
                }
                if let latestActive = session?.activeTurn, turnHasGeneratedCandidates(latestActive) {
                    _ = await reloadLatestSession(projectRoot: projectRoot)
                }
                reviewInFlightTurnID = nil
                isLoading = false
                schedulePrebufferIfUseful()

                if let feedback = updated.feedback.first(where: { $0.turnID == turn.id }) {
                    let selectedCandidate = turn.candidates.first { $0.label == submittedLabel }
                    Task {
                        _ = await ContinuityFeedbackPropagationService(store: store).propagate(
                            feedback: feedback,
                            turn: turn,
                            selectedCandidate: selectedCandidate,
                            projectRoot: projectRoot
                        )
                    }
                }
                Task {
                    await refreshContinuityRules(projectRoot: projectRoot)
                }
            } catch {
                statusMessage = "Could not save continuity feedback: \(error.localizedDescription)"
                reviewInFlightTurnID = nil
                isLoading = false
            }
            generatingTurnIDs.remove(turn.id)
            if isLoading {
                reviewInFlightTurnID = nil
                isLoading = false
                schedulePrebufferIfUseful()
            }
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
            if let projectRoot {
                _ = await reloadLatestSession(projectRoot: projectRoot)
            } else {
                session = result.session
                selectedLabel = defaultSelectedLabel(for: result.session.activeTurn)
            }
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
        let expectedActiveTurnID = activeTurn.id
        Task {
            var shouldContinue = false
            do {
                let service = ContinuityBuilderService(store: store)
                let latest = await service.loadOrCreateSession(projectRoot: projectRoot)
                guard latest.activeTurn?.id == expectedActiveTurnID else {
                    isPrebuffering = false
                    return
                }
                let prepared = try await ContinuityBuilderService(store: store).ensureBufferedTurn(
                    session: latest,
                    projectRoot: projectRoot,
                    maxBuffered: maxBufferedContinuityImages
                )
                if session?.activeTurn?.id == expectedActiveTurnID {
                    session = prepared
                    selectedLabel = defaultSelectedLabel(for: prepared.activeTurn)
                }
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
                    let fresh = await service.loadOrCreateSession(projectRoot: projectRoot)
                    if session?.activeTurn?.id == expectedActiveTurnID {
                        session = fresh
                        selectedLabel = defaultSelectedLabel(for: fresh.activeTurn)
                    }
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
