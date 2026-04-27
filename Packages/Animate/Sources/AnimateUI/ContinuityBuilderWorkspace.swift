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

    private var projectRoot: URL? { store.owpURL?.deletingLastPathComponent() }
    private var activeTurn: ContinuityBuilderTurn? { session?.activeTurn }
    private var projectTitle: String { projectRoot?.lastPathComponent ?? "Untitled Opera" }

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
        .background(OperaChromeTheme.workspaceBackground)
    }

    private var sidebar: some View {
        OperaChromeFlatPane(headerPadding: OperaChromeSidebarMetrics.headerPadding) {
            OperaChromePaneHeader(
                eyebrow: "CONTINUITY",
                title: "Builder",
                subtitle: session.map { "\($0.turns.count) prompts • \($0.feedback.count) notes" } ?? "Loading…"
            ) {
                OperaChromeActionButton(systemImage: "sidebar.left") {
                    withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false }
                }
            }
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Knowledge pathways")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    ForEach(Array((session?.turns ?? []).enumerated()), id: \.element.id) { index, turn in
                        Button {
                            jump(to: index)
                        } label: {
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(index == session?.activeTurnIndex ? OperaChromeTheme.accent : OperaChromeTheme.stroke)
                                    .frame(width: 8, height: 8)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(turn.title)
                                        .font(.system(size: 12, weight: index == session?.activeTurnIndex ? .semibold : .regular))
                                        .foregroundStyle(OperaChromeTheme.textPrimary)
                                        .lineLimit(2)
                                    Text(turn.category.displayName)
                                        .font(.system(size: 10))
                                        .foregroundStyle(OperaChromeTheme.textTertiary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(8)
                            .background(index == session?.activeTurnIndex ? OperaChromeTheme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
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
            Text("No paid generation runs from this page yet. The current turn writes project-local feedback artifacts and prompt seeds only.")
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textTertiary)
        }
        .padding(14)
        .background(OperaChromeTheme.panelBackground, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func candidateGrid(_ turn: ContinuityBuilderTurn) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: max(1, min(3, turn.candidates.count)))
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(turn.candidates) { candidate in
                candidateCard(candidate)
            }
        }
    }

    private func candidateCard(_ candidate: ContinuityBuilderCandidate) -> some View {
        Button {
            selectedLabel = candidate.label
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    if let path = candidate.imagePath, FileManager.default.fileExists(atPath: path) {
                        AsyncStoreThumbnailImage.rounded(
                            store: store,
                            path: path,
                            maxSize: 900,
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

            TextEditor(text: $notesText)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 90)
                .background(OperaChromeTheme.workspaceBackground, in: RoundedRectangle(cornerRadius: 10))
                .onSubmit {
                    if autoSubmit { submit(turn) }
                }

            HStack(spacing: 12) {
                Text("Closeness: \(Int(closenessPercent))%")
                    .font(.system(size: 12, weight: .medium))
                Slider(value: $closenessPercent, in: 0...100, step: 5)
                Button("Previous") { move(delta: -1) }
                    .disabled((session?.activeTurnIndex ?? 0) == 0)
                Button("Submit & Next") { submit(turn) }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Generate candidate") {
                    statusMessage = "Paid generation is intentionally blocked here until Gary explicitly approves a test/run."
                }
                .buttonStyle(.borderedProminent)
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

    private func loadSession() async {
        guard let projectRoot else { return }
        isLoading = true
        let loaded = await ContinuityBuilderService(store: store).loadOrCreateSession(projectRoot: projectRoot)
        session = loaded
        selectedLabel = loaded.activeTurn?.candidates.first?.label
        notesText = ""
        isLoading = false
    }

    private func submit(_ turn: ContinuityBuilderTurn) {
        guard let projectRoot, let currentSession = session else { return }
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
                    selectedLabel: selectedLabel,
                    closenessPercent: Int(closenessPercent),
                    notes: combined,
                    transcriptAudioPath: dictationSession.lastAudioPath,
                    projectRoot: projectRoot
                )
                session = updated
                selectedLabel = updated.activeTurn?.candidates.first?.label
                notesText = ""
                closenessPercent = 55
                statusMessage = "Saved continuity feedback to Metadata/automation/continuity-builder."
            } catch {
                statusMessage = "Could not save continuity feedback: \(error.localizedDescription)"
            }
        }
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
