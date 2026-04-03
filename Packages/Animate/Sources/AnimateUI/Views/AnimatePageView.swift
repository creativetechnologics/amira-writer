import AppKit
import ProjectKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 26.0, *)
struct AnimatePageView: View {
    enum Presentation {
        case workspace
        case inspector
        case assets
    }

    private enum ShotBoundaryEdge {
        case start
        case end
    }

    private struct TimelineShotBoundaryDrag {
        var shotID: UUID
        var edge: ShotBoundaryEdge
        var baseStartFrame: Int
        var baseEndFrame: Int
    }

    @Bindable var store: AnimateStore
    @Bindable var workspaceState: AnimateWorkspaceState
    var presentation: Presentation = .workspace
    @StateObject private var audioWaveformCache = AnimateAudioWaveformCache()
    @AppStorage("animate.workspace.timelinePaneHeight") private var timelinePaneHeight = 360.0
    @State private var selectedTimelineShotID: UUID?
    @State private var activeTimelineShotBoundaryDrag: TimelineShotBoundaryDrag?

    private var executionService: AnimateSceneExecutionService {
        AnimateSceneExecutionService(
            store: store,
            parsedPlan: parsedPlanResult?.plan
        )
    }

    private var orchestrationService: AnimateSceneOrchestrationService {
        AnimateSceneOrchestrationService(
            store: store,
            parsedPlan: parsedPlanResult?.plan,
            parsedPlanErrorDescription: parsedPlanResult?.error?.localizedDescription,
            hasPlanJSONText: !workspaceState.planJSONText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    private var shotSeedingService: AnimateSceneShotSeedingService {
        AnimateSceneShotSeedingService(store: store)
    }

    private var assetRequirementsService: AnimateAssetRequirementsService {
        AnimateAssetRequirementsService(store: store)
    }

    private var shotSegmentationService: AnimateShotSegmentationService {
        AnimateShotSegmentationService(
            store: store,
            previewPlan: presentation == .workspace ? parsedPlanResult?.plan : nil
        )
    }

    var body: some View {
        Group {
            if let scene = store.selectedScene {
                content(for: scene)
                    .onAppear {
                        seedTemplateIfNeeded(for: scene, force: false)
                    }
                    .onChange(of: store.selectedSceneID) { _, _ in
                        if let newScene = store.selectedScene {
                            seedTemplateIfNeeded(for: newScene, force: true)
                        }
                    }
                    .task(id: scene.id) {
                        await prepareSceneWorkspace(for: scene)
                    }
            } else {
                emptyState
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    @ViewBuilder
    private func content(for scene: AnimationScene) -> some View {
        switch presentation {
        case .workspace:
            workspace(for: scene)
        case .inspector:
            inspectorPanel(for: scene)
        case .assets:
            assetInspectorPanel(for: scene)
        }
    }

    private func workspace(for scene: AnimationScene) -> some View {
        GeometryReader { proxy in
            let splitHandleHeight: CGFloat = 14
            let minPreviewHeight: CGFloat = 340
            let minTimelineHeight: CGFloat = 300
            let availableHeight = max(proxy.size.height - splitHandleHeight, minPreviewHeight + minTimelineHeight)
            let maxTimelineHeight = max(minTimelineHeight, availableHeight - minPreviewHeight)
            let clampedTimelineHeight = min(max(CGFloat(timelinePaneHeight), minTimelineHeight), maxTimelineHeight)
            let previewHeight = max(minPreviewHeight, availableHeight - clampedTimelineHeight)

            VStack(spacing: 0) {
                previewDeck(for: scene)
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)

                VStack(spacing: 4) {
                    OperaChromeSplitHandle(axis: .vertical, thickness: splitHandleHeight) { delta in
                        resizeTimelinePane(delta, totalHeight: proxy.size.height)
                    }
                    .frame(height: splitHandleHeight)

                    Capsule(style: .continuous)
                        .fill(OperaChromeTheme.divider.opacity(0.9))
                        .frame(width: 80, height: 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)

                timelineDeck(for: scene)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: clampedTimelineHeight)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)

            Text("Select a scene to open the animation engine workspace.")
                .font(.title3.weight(.semibold))

            Text("This workspace is designed to stage reusable character kits, plan lighting and camera intent, apply LLM animation JSON, and sequence everything on a timeline.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OperaChromeTheme.workspaceBackground)
    }

    private func resizeTimelinePane(_ delta: CGFloat, totalHeight: CGFloat) {
        let splitHandleHeight: CGFloat = 14
        let minPreviewHeight: CGFloat = 340
        let minTimelineHeight: CGFloat = 300
        let availableHeight = max(totalHeight - splitHandleHeight, minPreviewHeight + minTimelineHeight)
        let maxTimelineHeight = max(minTimelineHeight, availableHeight - minPreviewHeight)
        let proposedHeight = CGFloat(timelinePaneHeight) - delta
        timelinePaneHeight = Double(min(max(proposedHeight, minTimelineHeight), maxTimelineHeight))
    }

    private func inspectorPanel(for scene: AnimationScene) -> some View {
        VSplitView {
            sceneInspectorDeck(for: scene)
                .frame(minHeight: 280, idealHeight: 360)

            planningDock(for: scene)
                .frame(minHeight: 360, idealHeight: 520)
        }
    }

    private func assetInspectorPanel(for scene: AnimationScene) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                assetsDeck(for: scene)
            }
            .padding(.vertical, 16)
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    private func sceneInspectorDeck(for scene: AnimationScene) -> some View {
        ScrollView {
            sceneOverviewCards(for: scene)
                .padding(16)
        }
        .background(OperaChromeTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.top, 16)
        .padding(.bottom, 8)
        .padding(.trailing, 16)
    }

    @ViewBuilder
    private func sceneOverviewCards(for scene: AnimationScene) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            workspaceCard(
                title: "Scene packet",
                systemImage: "film.stack",
                subtitle: "A single source of truth for the scene, its cast, and the current render contract."
            ) {
                let background = backgroundPlate(for: scene)
                let cast = sceneCharacters(for: scene)

                metricGrid([
                    ("Cast", "\(cast.count)"),
                    ("Tracks", "\(store.orderedTimelineTracks(for: scene).count)"),
                    ("FPS", "\(store.fps)"),
                    ("Frames", "\(max(store.totalFrames, 0))")
                ])

                VStack(alignment: .leading, spacing: 8) {
                    labeledValue("Scene", scene.name)
                    labeledValue("Background", background?.name ?? "Not assigned")
                    sceneAudioPickerRow(for: scene)
                    labeledValue("Resolution", resolutionLabel)
                }

                if let template = scene.directionTemplate, !template.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Direction template")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(OperaChromeTheme.textSecondary)

                        if let shot = template.defaultCameraShot {
                            infoChip(shot.displayName, color: .blue)
                        }

                        if let focusID = template.focusCharacterID,
                           let character = store.characters.first(where: { $0.id == focusID }) {
                            infoChip("Focus \(character.name)", color: .mint)
                        }

                        if !template.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text(template.notes)
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            workspaceCard(
                title: "Engine route",
                systemImage: "point.3.filled.connected.trianglepath.dotted",
                subtitle: "The system decides whether this scene is ready for kit-first playback, hybrid escalation, or fallback."
            ) {
                if let plan = store.selectedSceneAutomationPlan() {
                    HStack(spacing: 8) {
                        infoChip("Recommended \(plan.recommendedExecutionMode.displayName)", color: .blue)
                        infoChip("Effective \(plan.effectiveExecutionMode.displayName)", color: effectiveModeColor(plan.effectiveExecutionMode))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(plan.summary)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(Int(plan.readinessScore * 100))% ready")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        }

                        ProgressView(value: plan.readinessScore)
                            .progressViewStyle(.linear)

                        Text("Complexity \(Int(plan.complexityScore * 100)) · \(plan.supportedPasses.count) passes active")
                            .font(.caption2)
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(plan.checklist.prefix(5)) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(readinessColor(item.readiness))
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 4)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(item.title)
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(item.metric)
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                    }
                                    Text(item.detail)
                                        .font(.caption2)
                                        .foregroundStyle(OperaChromeTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                } else {
                    Text("Choose a scene to compute its internal / hybrid / fallback recommendation.")
                        .font(.caption)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            }

            workspaceCard(
                title: "Subsystem readiness",
                systemImage: "switch.2",
                subtitle: "Body, mouth, lighting, and camera are tracked independently so the engine knows what should stay internal."
            ) {
                subsystemReadinessStrip(for: scene)
            }

            workspaceCard(
                title: "Cast coverage",
                systemImage: "person.3.sequence",
                subtitle: "The timeline only becomes automatic when each character is backed by the right package, angles, poses, and viseme coverage."
            ) {
                let cast = sceneCharacters(for: scene)
                let summaries = store.selectedSceneAutomationPlan()?.characterSummaries ?? []

                if cast.isEmpty {
                    Text("This scene has no cast linked yet.")
                        .font(.caption)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(cast) { character in
                            let summary = summaries.first(where: { $0.id == character.id })
                            castCoverageRow(character: character, summary: summary)
                        }
                    }
                }
            }

            workspaceCard(
                title: "Script migration handoff",
                systemImage: "text.badge.star",
                subtitle: "Use this brief to update legacy libretto animation notes into the new engine contract scene by scene."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(scriptMigrationPrompt(for: scene))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .textSelection(.enabled)
                        .lineLimit(16)

                    HStack(spacing: 8) {
                        Button("Copy LLM Brief") {
                            copyToPasteboard(scriptMigrationPrompt(for: scene))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Button("Copy JSON Template") {
                            copyToPasteboard(sampleLLMPlanTemplate(for: scene))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func previewDeck(for scene: AnimationScene) -> some View {
        let segments = shotSegmentationService.shotSegments(for: scene)
        let activeShot = segments.first(where: \.containsCurrentFrame)

        return VStack(spacing: 0) {
            workspaceHeader(
                title: scene.name,
                subtitle: "Live preview driven by timeline tracks, camera intent, and package-backed render selection."
            ) {
                HStack(spacing: 8) {
                    if let shot = store.evaluatedEffectiveCameraShot() {
                        infoChip(shot.displayName, color: .blue)
                    }

                    if let intent = store.evaluatedCameraShotIntent() {
                        infoChip(intent.displayName, color: .orange)
                    }

                    if let focusID = store.evaluatedCameraFocusCharacterID(),
                       let focus = store.characters.first(where: { $0.id == focusID }) {
                        infoChip("Focus \(focus.name)", color: .mint)
                    }

                    if let beat = store.evaluatedCameraBeatLabel(),
                       !beat.isEmpty {
                        infoChip(beat, color: .purple)
                    }
                }
            }

            previewStage(
                title: "Preview",
                subtitle: "Current 2D render path",
                previewMode: .live,
                scene: scene,
                activeShot: activeShot
            )
            .padding(16)

            Divider()

            shotStrip(for: scene)

            Divider()

            TransportBar(store: store)
                .background(OperaChromeTheme.headerBackground.opacity(0.6))
        }
        .background(OperaChromeTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private func previewStage(
        title: String,
        subtitle: String,
        previewMode: AnimationCanvasPreviewMode,
        scene: AnimationScene,
        activeShot: AnimateShotSegment?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                Spacer()
                infoChip(previewMode == .live ? "LIVE" : "PLACEHOLDER", color: previewMode == .live ? .blue : .mint)
            }

            ZStack(alignment: .topLeading) {
                AnimationPreviewImageView(
                    store: store,
                    scene: scene,
                    previewMode: previewMode
                )
                .background(Color.black.opacity(0.92))

                VStack(alignment: .leading, spacing: 6) {
                    overlayRow(title: "Preview", value: "Frame \(store.currentFrame) · \(resolutionLabel)")

                    if let activeShot {
                        overlayRow(title: "Shot", value: activeShot.title)
                    }

                    if previewMode == .live,
                       let background = backgroundPlate(for: scene) {
                        overlayRow(title: "Place", value: background.name)
                    }

                    if let notes = store.evaluatedCameraBeatNotes(),
                       !notes.isEmpty {
                        overlayRow(title: "Beat", value: notes)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.black.opacity(0.38))
                )
                .padding(14)
            }
            .aspectRatio(21.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func timelineDeck(for scene: AnimationScene) -> some View {
        let audioSummary = sceneAudioTimelineSummary(for: scene)
        let editableShot = selectedEditableShot(for: scene)

        return VStack(spacing: 0) {
            workspaceHeader(
                title: "Timeline",
                subtitle: "Scene-local shot timing over the scene’s music bed, with timeline cues layered underneath."
            ) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        infoChip(audioSummary.basisLabel, color: .purple)
                        infoChip(audioSummary.durationLabel, color: .mint)
                        ForEach(trackRoleSummaries(for: scene)) { summary in
                            infoChip("\(summary.title) \(summary.count)", color: summary.color)
                        }
                    }
                }
                .frame(maxWidth: 340)
            }

            Divider()

            if let editableShot {
                selectedShotTimingCard(for: scene, shot: editableShot)
                Divider()
            }

            sceneAudioTimelineStrip(for: scene, summary: audioSummary)

            Divider()

            TimelineRepresentable(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: "\(scene.id.uuidString)|\(audioSummary.audioPath ?? "")") {
            await store.loadSongData(for: scene)
            if let audioPath = audioSummary.audioPath {
                audioWaveformCache.request(audioPath)
            }
        }
        .background(OperaChromeTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.leading, 16)
        .padding(.bottom, 16)
        .padding(.top, 16)
    }

    private func sceneAudioTimelineStrip(
        for scene: AnimationScene,
        summary: SceneAudioTimelineSummary
    ) -> some View {
        let segments = shotSegmentationService.shotSegments(for: scene)
        let authoredShots = scene.shots.sorted {
            if $0.startFrame == $1.startFrame {
                return $0.endFrame < $1.endFrame
            }
            return $0.startFrame < $1.startFrame
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Scene-local music timeline")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text("Shots are anchored to this scene’s own music timing, so retiming one scene does not shift the rest of the show.")
                        .font(.caption2)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let audioName = summary.audioName {
                    Text(audioName)
                        .font(.caption2.monospaced())
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .lineLimit(1)
                }
            }

            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                let height = max(proxy.size.height, 1)
                let frameCount = max(summary.timelineFrameCount, 1)
                let maxPlayableFrame = max(frameCount - 1, 0)
                let playheadFrame = min(max(store.currentFrame, 0), maxPlayableFrame)
                let playheadX = playheadX(for: playheadFrame, width: width, frameCount: frameCount)
                let scrubGesture = DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if store.isPlaying {
                            store.stopPlayback()
                        }
                        store.currentFrame = frameIndex(
                            for: value.location.x,
                            width: width,
                            frameCount: frameCount
                        )
                    }

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(OperaChromeTheme.raisedBackground.opacity(0.72))

                    if let audioPath = summary.audioPath,
                       let waveformImage = audioWaveformCache.waveformImage(for: audioPath) {
                        Image(decorative: waveformImage, scale: 2)
                            .resizable()
                            .scaledToFill()
                            .frame(width: width, height: height)
                            .clipped()
                            .opacity(0.92)
                    } else {
                        timelineFallbackBed(
                            width: width,
                            height: height,
                            frameCount: frameCount,
                            title: summary.audioName == nil ? "Waveform-free timing mode" : "Waveform pending",
                            subtitle: summary.audioName == nil
                                ? "Shots still align to scene-local timing even before mix waveforms exist."
                                : "Using scene-local timing while the waveform cache catches up."
                        )
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 1)
                        .offset(y: height * 0.5)

                    if authoredShots.isEmpty {
                        ForEach(segments) { segment in
                            let startX = width * CGFloat(segment.startFrame) / CGFloat(frameCount)
                            let segmentWidth = max(44, width * CGFloat(segment.durationFrames) / CGFloat(frameCount))
                            Button {
                                store.currentFrame = segment.startFrame
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(segment.title)
                                            .font(.caption2.weight(.semibold))
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(sceneLocalTimecode(for: segment.startFrame))
                                            .font(.caption2.monospacedDigit())
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                    }

                                    Text(segment.detail)
                                        .font(.caption2)
                                        .lineLimit(2)
                                        .foregroundStyle(OperaChromeTheme.textSecondary)
                                }
                                .padding(8)
                                .frame(width: segmentWidth, height: 48, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(segment.containsCurrentFrame ? Color.accentColor.opacity(0.22) : Color.black.opacity(0.34))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(segment.containsCurrentFrame ? Color.accentColor : Color.white.opacity(0.08), lineWidth: segment.containsCurrentFrame ? 1.5 : 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .offset(
                                x: min(max(0, startX), max(0, width - segmentWidth - 4)) + 2,
                                y: 10
                            )
                        }
                    } else {
                        ForEach(authoredShots) { shot in
                            let startX = width * CGFloat(shot.startFrame) / CGFloat(frameCount)
                            let segmentWidth = max(52, width * CGFloat(max(shot.endFrame - shot.startFrame + 1, 1)) / CGFloat(frameCount))
                            let isSelected = selectedTimelineShotID == shot.id
                            let containsCurrentFrame = (shot.startFrame...max(shot.startFrame, shot.endFrame)).contains(playheadFrame)

                            timelineShotClip(
                                scene: scene,
                                shot: shot,
                                width: segmentWidth,
                                height: 52,
                                frameCount: frameCount,
                                timelineWidth: width,
                                maxFrame: maxPlayableFrame,
                                isSelected: isSelected,
                                containsCurrentFrame: containsCurrentFrame
                            )
                            .offset(
                                x: min(max(0, startX), max(0, width - segmentWidth - 4)) + 2,
                                y: 8
                            )
                        }
                    }

                    Rectangle()
                        .fill(Color.accentColor.opacity(0.95))
                        .frame(width: 2, height: height)
                        .offset(x: min(max(playheadX, 0), max(0, width - 2)))

                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 10, height: 22)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.9), lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(0.28), radius: 4, x: 0, y: 2)
                        .offset(
                            x: min(max(playheadX - 5, 0), max(0, width - 10)),
                            y: max(0, height * 0.5 - 11)
                        )
                }
                .contentShape(Rectangle())
                .simultaneousGesture(scrubGesture)
            }
            .frame(height: 88)

            HStack {
                infoChip("Start \(sceneLocalTimecode(for: 0))", color: .secondary)
                Spacer()
                infoChip("Current \(sceneLocalTimecode(for: store.currentFrame))", color: .accentColor)
                Spacer()
                infoChip("End \(sceneLocalTimecode(for: max(summary.timelineFrameCount - 1, 0)))", color: .secondary)
            }

            if authoredShots.isEmpty {
                issueCard(
                    title: "Shot timing is currently inferred",
                    detail: "Adopt authored shots in the Shots workspace to make clip in/out points directly editable on this timeline.",
                    color: .orange
                )
            } else if let selectedShot = selectedTimelineShot(in: scene) {
                timelineClipInspector(
                    scene: scene,
                    shot: selectedShot,
                    maxFrame: max(summary.timelineFrameCount - 1, 0)
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .onAppear {
            syncSelectedTimelineShot(for: scene)
        }
        .onChange(of: scene.id) { _, _ in
            syncSelectedTimelineShot(for: scene)
        }
        .onChange(of: scene.shots.map { "\($0.id.uuidString):\($0.startFrame):\($0.endFrame)" }) { _, _ in
            syncSelectedTimelineShot(for: scene)
        }
    }

    private func selectedShotTimingCard(
        for scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected clip")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text(displayShotTitle(shot))
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
                infoChip("\(shot.startFrame)–\(shot.endFrame)", color: .orange)
                if shot.lockedBoundaries {
                    infoChip("Locked", color: .orange)
                }
            }

            HStack(spacing: 10) {
                Stepper(value: shotBinding(for: shot.id, defaultValue: shot.startFrame, keyPath: \.startFrame), in: 0...max(0, shot.endFrame)) {
                    Text("In \(sceneLocalTimecode(for: shot.startFrame)) · F\(shot.startFrame)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                .disabled(shot.lockedBoundaries)

                Stepper(value: shotBinding(for: shot.id, defaultValue: shot.endFrame, keyPath: \.endFrame), in: max(shot.startFrame, 0)...max(shot.startFrame, shotSegmentationService.sceneFrameCount(for: scene))) {
                    Text("Out \(sceneLocalTimecode(for: shot.endFrame)) · F\(shot.endFrame)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                .disabled(shot.lockedBoundaries)
            }

            HStack(spacing: 8) {
                Button("Use Playhead As In") {
                    store.updateSelectedSceneShots { shots in
                        guard let index = shots.firstIndex(where: { $0.id == shot.id }) else { return }
                        shots[index].startFrame = min(max(store.currentFrame, 0), shots[index].endFrame)
                    }
                    store.save()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(shot.lockedBoundaries)

                Button("Use Playhead As Out") {
                    store.updateSelectedSceneShots { shots in
                        guard let index = shots.firstIndex(where: { $0.id == shot.id }) else { return }
                        shots[index].endFrame = max(shots[index].startFrame, store.currentFrame)
                    }
                    store.save()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(shot.lockedBoundaries)

                Spacer()

                Button("Open Detailed Shot Editor") {
                    workspaceState.selectedDockTab = .shots
                    store.currentFrame = shot.startFrame
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(OperaChromeTheme.raisedBackground.opacity(0.32))
    }

    private func shotStrip(for scene: AnimationScene) -> some View {
        let segments = shotSegmentationService.shotSegments(for: scene)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Shot strip")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                Spacer()
                Text("\(segments.count) shots")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }

            if segments.isEmpty {
                Text("No shot boundaries detected yet. Add beat labels, shot cues, or preset applications to segment this scene.")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(segments) { segment in
                            Button {
                                store.currentFrame = segment.startFrame
                            } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(segment.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(OperaChromeTheme.textPrimary)
                                            .lineLimit(1)
                                        Spacer(minLength: 8)
                                        Text(segment.frameRangeLabel)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                    }

                                    Text(segment.provenance.label)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(segment.containsCurrentFrame ? Color.accentColor : OperaChromeTheme.textSecondary)

                                    Text(segment.detail)
                                        .font(.caption2)
                                        .foregroundStyle(OperaChromeTheme.textSecondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .padding(10)
                                .frame(width: max(160, CGFloat(segment.durationFrames) * 1.8), alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(segment.containsCurrentFrame ? Color.accentColor.opacity(0.18) : OperaChromeTheme.raisedBackground.opacity(0.72))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(segment.containsCurrentFrame ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func timelineShotClip(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        width: CGFloat,
        height: CGFloat,
        frameCount: Int,
        timelineWidth: CGFloat,
        maxFrame: Int,
        isSelected: Bool,
        containsCurrentFrame: Bool
    ) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.24) : Color.black.opacity(0.38))

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor : (containsCurrentFrame ? Color.white.opacity(0.26) : Color.white.opacity(0.08)),
                    lineWidth: isSelected ? 1.6 : 1
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(displayShotTitle(shot))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(shot.startFrame)–\(shot.endFrame)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }

                if let cameraShot = shot.cameraShot {
                    Text(cameraShot.displayName)
                        .font(.caption2)
                        .foregroundStyle(containsCurrentFrame ? Color.accentColor : OperaChromeTheme.textSecondary)
                        .lineLimit(1)
                } else {
                    Text(shot.source.displayName)
                        .font(.caption2)
                        .foregroundStyle(containsCurrentFrame ? Color.accentColor : OperaChromeTheme.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if !shot.lockedBoundaries {
                HStack(spacing: 0) {
                    timelineShotBoundaryHandle(
                        scene: scene,
                        shot: shot,
                        edge: .start,
                        frameCount: frameCount,
                        timelineWidth: timelineWidth,
                        maxFrame: maxFrame
                    )
                    Spacer(minLength: 0)
                    timelineShotBoundaryHandle(
                        scene: scene,
                        shot: shot,
                        edge: .end,
                        frameCount: frameCount,
                        timelineWidth: timelineWidth,
                        maxFrame: maxFrame
                    )
                }
                .padding(.vertical, 4)
            }
        }
        .frame(width: width, height: height, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    moveTimelineShot(
                        in: scene,
                        shot: shot,
                        translationWidth: value.translation.width,
                        frameCount: frameCount,
                        timelineWidth: timelineWidth,
                        maxFrame: maxFrame
                    )
                }
                .onEnded { _ in
                    store.save()
                }
        )
        .onTapGesture {
            selectedTimelineShotID = shot.id
            store.currentFrame = shot.startFrame
        }
        .help(shot.lockedBoundaries ? "Shot boundaries are locked." : "Drag the clip to move it, or drag the left/right edges to trim it.")
    }

    private func timelineShotBoundaryHandle(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        edge: ShotBoundaryEdge,
        frameCount: Int,
        timelineWidth: CGFloat,
        maxFrame: Int
    ) -> some View {
        Capsule(style: .continuous)
            .fill(Color.white.opacity(activeTimelineShotBoundaryDrag?.shotID == shot.id && activeTimelineShotBoundaryDrag?.edge == edge ? 0.95 : 0.72))
            .frame(width: 12, height: 24)
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.black.opacity(0.3), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        updateTimelineShotBoundaryDrag(
                            in: scene,
                            for: shot,
                            edge: edge,
                            translationWidth: value.translation.width,
                            frameCount: frameCount,
                            timelineWidth: timelineWidth,
                            maxFrame: maxFrame
                        )
                    }
                    .onEnded { _ in
                        activeTimelineShotBoundaryDrag = nil
                        store.save()
                    }
            )
            .padding(edge == .start ? .leading : .trailing, 4)
    }

    private func updateTimelineShotBoundaryDrag(
        in scene: AnimationScene,
        for shot: AnimationSceneShot,
        edge: ShotBoundaryEdge,
        translationWidth: CGFloat,
        frameCount: Int,
        timelineWidth: CGFloat,
        maxFrame: Int
    ) {
        guard timelineWidth > 0, frameCount > 0, !shot.lockedBoundaries else { return }

        if activeTimelineShotBoundaryDrag?.shotID != shot.id || activeTimelineShotBoundaryDrag?.edge != edge {
            activeTimelineShotBoundaryDrag = TimelineShotBoundaryDrag(
                shotID: shot.id,
                edge: edge,
                baseStartFrame: shot.startFrame,
                baseEndFrame: shot.endFrame
            )
        }

        guard let drag = activeTimelineShotBoundaryDrag else { return }
        let deltaFrames = Int((translationWidth / timelineWidth * CGFloat(frameCount)).rounded())
        let orderedShots = scene.shots.sorted {
            if $0.startFrame == $1.startFrame {
                return $0.endFrame < $1.endFrame
            }
            return $0.startFrame < $1.startFrame
        }
        let previousShot = orderedShots.last(where: { $0.endFrame < drag.baseStartFrame && $0.id != shot.id })
        let nextShot = orderedShots.first(where: { $0.startFrame > drag.baseEndFrame && $0.id != shot.id })

        store.updateSelectedSceneShots { shots in
            guard let index = shots.firstIndex(where: { $0.id == shot.id }) else { return }

            switch edge {
            case .start:
                let minimumStart = (previousShot?.endFrame ?? -1) + 1
                let proposedStart = drag.baseStartFrame + deltaFrames
                shots[index].startFrame = min(
                    max(proposedStart, minimumStart),
                    drag.baseEndFrame
                )
            case .end:
                let maximumEnd = min(maxFrame, (nextShot?.startFrame ?? (maxFrame + 1)) - 1)
                let proposedEnd = drag.baseEndFrame + deltaFrames
                shots[index].endFrame = max(
                    drag.baseStartFrame,
                    min(maximumEnd, proposedEnd)
                )
            }
        }

        selectedTimelineShotID = shot.id
    }

    private func moveTimelineShot(
        in scene: AnimationScene,
        shot: AnimationSceneShot,
        translationWidth: CGFloat,
        frameCount: Int,
        timelineWidth: CGFloat,
        maxFrame: Int
    ) {
        guard timelineWidth > 0, frameCount > 0, !shot.lockedBoundaries else { return }

        let deltaFrames = Int((translationWidth / timelineWidth * CGFloat(frameCount)).rounded())
        let duration = max(0, shot.endFrame - shot.startFrame)
        let orderedShots = scene.shots.sorted {
            if $0.startFrame == $1.startFrame {
                return $0.endFrame < $1.endFrame
            }
            return $0.startFrame < $1.startFrame
        }
        guard let shotIndex = orderedShots.firstIndex(where: { $0.id == shot.id }) else { return }

        let previousShot = shotIndex > 0 ? orderedShots[shotIndex - 1] : nil
        let nextShot = shotIndex < orderedShots.count - 1 ? orderedShots[shotIndex + 1] : nil
        let minimumStart = (previousShot?.endFrame ?? -1) + 1
        let maximumStart = min(maxFrame - duration, (nextShot?.startFrame ?? (maxFrame + 1)) - duration - 1)
        let newStart = min(
            max(shot.startFrame + deltaFrames, minimumStart),
            max(minimumStart, maximumStart)
        )

        store.updateSelectedSceneShots { shots in
            guard let index = shots.firstIndex(where: { $0.id == shot.id }) else { return }
            shots[index].startFrame = newStart
            shots[index].endFrame = newStart + duration
        }

        selectedTimelineShotID = shot.id
    }

    private func timelineClipInspector(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        maxFrame: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Selected clip")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                Spacer()
                infoChip(displayShotTitle(shot), color: .accentColor)
                if shot.lockedBoundaries {
                    infoChip("Locked", color: .orange)
                }
            }

            HStack(spacing: 10) {
                Stepper(value: shotBinding(for: shot.id, defaultValue: shot.startFrame, keyPath: \.startFrame), in: 0...max(0, shot.endFrame)) {
                    Text("In \(sceneLocalTimecode(for: shot.startFrame)) · F\(shot.startFrame)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                .disabled(shot.lockedBoundaries)

                Stepper(value: shotBinding(for: shot.id, defaultValue: shot.endFrame, keyPath: \.endFrame), in: max(shot.startFrame, 0)...max(shot.startFrame, maxFrame)) {
                    Text("Out \(sceneLocalTimecode(for: shot.endFrame)) · F\(shot.endFrame)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                .disabled(shot.lockedBoundaries)
            }

            HStack(spacing: 8) {
                Button("Jump To In") {
                    store.currentFrame = shot.startFrame
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Jump To Out") {
                    store.currentFrame = shot.endFrame
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Detailed Shot Editor") {
                    workspaceState.selectedDockTab = .shots
                    store.currentFrame = shot.startFrame
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.76))
        )
    }

    private func selectedTimelineShot(in scene: AnimationScene) -> AnimationSceneShot? {
        if let selectedTimelineShotID,
           let selected = scene.shots.first(where: { $0.id == selectedTimelineShotID }) {
            return selected
        }

        return scene.shots.first(where: { shot in
            (shot.startFrame...max(shot.startFrame, shot.endFrame)).contains(store.currentFrame)
        }) ?? scene.shots.sorted {
            if $0.startFrame == $1.startFrame {
                return $0.endFrame < $1.endFrame
            }
            return $0.startFrame < $1.startFrame
        }.first
    }

    private func syncSelectedTimelineShot(for scene: AnimationScene) {
        selectedTimelineShotID = selectedTimelineShot(in: scene)?.id
    }

    private func selectedEditableShot(for scene: AnimationScene) -> AnimationSceneShot? {
        selectedTimelineShot(in: scene)
    }

    private func planningDock(for scene: AnimationScene) -> some View {
        VStack(spacing: 0) {
            workspaceHeader(
                title: "Scene intelligence",
                subtitle: "Paste plans, inspect missing asset coverage, and stage the script-to-engine handoff."
            ) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(AnimateWorkspaceDockTab.allCases) { tab in
                            Button {
                                workspaceState.selectedDockTab = tab
                            } label: {
                                Text(tab.title)
                                    .font(.caption.weight(workspaceState.selectedDockTab == tab ? .semibold : .regular))
                                    .foregroundStyle(workspaceState.selectedDockTab == tab ? Color.white : OperaChromeTheme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(workspaceState.selectedDockTab == tab ? Color.accentColor : OperaChromeTheme.raisedBackground.opacity(0.72))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: 360)
            }

            Divider()

            Group {
                switch workspaceState.selectedDockTab {
                case .plan:
                    planComposer(for: scene)
                case .review:
                    reviewDeck(for: scene)
                case .resolve:
                    resolutionDeck(for: scene)
                case .assets:
                    assetsDeck(for: scene)
                case .shots:
                    shotsDeck(for: scene)
                case .execute:
                    executionDeck(for: scene)
                case .sync:
                    scriptSyncDeck(for: scene)
                case .lighting:
                    lightingDeck(for: scene)
                case .graph:
                    sceneGraph(for: scene)
                case .handoff:
                    handoffDeck(for: scene)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(OperaChromeTheme.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.trailing, 16)
        .padding(.bottom, 16)
        .padding(.top, 16)
    }

    private func planComposer(for scene: AnimationScene) -> some View {
        let parsedPlan = parsedPlanResult
        let parsedValue = parsedPlan?.plan
        let parseError = parsedPlan?.error
        let assetRequests = parsedValue.map { store.missingAssetRequests(for: $0) } ?? []
        let shotAnchorSummary: ShotAnchorSummary? = {
            guard let parsedValue else { return nil }
            return makeShotAnchorSummary(for: scene, plan: parsedValue)
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("LLM animation JSON")
                    .font(.headline)
                Spacer()

                Button("Load Template") {
                    workspaceState.planJSONText = sampleLLMPlanTemplate(for: scene)
                    workspaceState.lastDialogueVisemePreview = nil
                    workspaceState.lastDialogueVisemePreviewPlanText = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            HStack(spacing: 8) {
                Button("Apply") {
                    applyPlan(generateDialogue: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(parsedValue == nil)

                Button(workspaceState.isApplyingDialoguePlan ? "Applying…" : "Apply + Visemes") {
                    applyPlan(generateDialogue: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(parsedValue == nil || workspaceState.isApplyingDialoguePlan)

                Spacer()

                Button("Copy Prompt") {
                    copyToPasteboard(scriptMigrationPrompt(for: scene))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)

            TextEditor(text: $workspaceState.planJSONText)
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(OperaChromeTheme.raisedBackground.opacity(0.65))
                )
                .padding(.horizontal, 14)
                .frame(minHeight: 220)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let parseError {
                        issueCard(
                            title: "JSON could not be parsed",
                            detail: parseError.localizedDescription,
                            color: .red
                        )
                    } else if let parsedValue {
                        metricGrid([
                            ("Placements", "\(parsedValue.characterPlacements.count)"),
                            ("Objects", "\(parsedValue.objectPlacements.count + parsedValue.objectMotions.count + parsedValue.objectStateCues.count)"),
                            ("Motions", "\(parsedValue.motions.count)"),
                            ("Dialogue", "\(parsedValue.dialogueBeats.count)"),
                            ("Camera", "\(parsedValue.cameraMoves.count)")
                        ])

                        if let shotAnchorSummary, shotAnchorSummary.referenceCount > 0 || !shotAnchorSummary.warnings.isEmpty {
                            workspaceMiniCard(title: "Shot anchors") {
                                metricGrid([
                                    ("Anchors", "\(shotAnchorSummary.referenceCount)"),
                                    ("Resolved shots", "\(shotAnchorSummary.uniqueShotLabels.count)"),
                                    ("Warnings", "\(shotAnchorSummary.warnings.count)"),
                                    ("Mode", "Shot-aware")
                                ])

                                if !shotAnchorSummary.uniqueShotLabels.isEmpty {
                                    FlexibleChipList(items: shotAnchorSummary.uniqueShotLabels, color: .mint)
                                }

                                ForEach(shotAnchorSummary.warnings, id: \.self) { warning in
                                    issueCard(title: "Shot anchor warning", detail: warning, color: .orange)
                                }
                            }
                        }

                        if !assetRequests.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                sectionLabel("Missing asset requests")

                                ForEach(assetRequests) { request in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(request.characterName)
                                                .font(.caption.weight(.semibold))
                                            Spacer()
                                            Text(request.kind.rawValue)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                        }
                                        Text(request.target)
                                            .font(.caption)
                                        Text(request.reason)
                                            .font(.caption2)
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                                }
                            }
                        } else {
                            issueCard(
                                title: "No missing asset requests detected",
                                detail: "The current JSON plan appears compatible with the available character coverage.",
                                color: .green
                            )
                        }
                    }

                    if let report = workspaceState.lastAppliedReport {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionLabel("Latest apply report")

                            if report.issues.isEmpty {
                                issueCard(
                                    title: "Applied cleanly",
                                    detail: "The scene tracks were updated and no validation warnings were emitted.",
                                    color: .green
                                )
                            } else {
                                ForEach(report.issues) { issue in
                                    issueCard(
                                        title: issue.code.rawValue,
                                        detail: issue.message,
                                        color: issue.severity == .error ? .red : .orange
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func sceneGraph(for scene: AnimationScene) -> some View {
        let cast = sceneCharacters(for: scene)
        let plan = store.selectedSceneAutomationPlan()
        let background = backgroundPlate(for: scene)

        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                graphSection(title: "Master graph") {
                    graphNode(
                        title: scene.name,
                        subtitle: "Scene node",
                        detail: "\(cast.count) character links · \(store.orderedTimelineTracks(for: scene).count) tracks · \(store.shotPresets.count) shot presets available",
                        accent: .blue
                    )

                    graphNode(
                        title: background?.name ?? "Background missing",
                        subtitle: "Place node",
                        detail: background?.resolvedApprovedImagePath != nil ? "Approved plate ready for playback" : "Needs an approved plate before final scene staging",
                        accent: background?.resolvedApprovedImagePath != nil ? .green : .orange
                    )

                    graphNode(
                        title: scene.defaultAudioPath ?? scene.owpSongPath,
                        subtitle: "Audio node",
                        detail: "Dialogue visemes and beat staging resolve from this path once the plan is applied.",
                        accent: .purple
                    )
                }

                graphSection(title: "Character package links") {
                    if cast.isEmpty {
                        Text("No characters linked to this scene yet.")
                            .font(.caption)
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    } else {
                        let summaries = plan?.characterSummaries ?? []
                        ForEach(cast) { character in
                            let summary = summaries.first(where: { $0.id == character.id })
                            graphNode(
                                title: character.name,
                                subtitle: summary?.activePackageName ?? "No active package",
                                detail: summary?.summaryLine ?? "Needs head sheet, poses, and viseme coverage before automatic playback can scale.",
                                accent: readinessColor(summary?.readiness ?? .missing)
                            )
                        }
                    }
                }

                graphSection(title: "Engine database needs") {
                    let notes = [
                        "Scene → place → approved background plate",
                        "Scene → cast → preferred costume set → active package",
                        "Scene → track roles → render contract (pose, view, facing, mouth, camera)",
                        "Scene → script migration brief → deterministic JSON plan"
                    ]

                    ForEach(Array(notes.enumerated()), id: \.offset) { index, note in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(index + 1).")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                            Text(note)
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let plan {
                    graphSection(title: "Automation next steps") {
                        ForEach(Array(plan.recommendedNextSteps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(step)
                                    .font(.caption)
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    private func scriptSyncDeck(for scene: AnimationScene) -> some View {
        let lyrics = currentLyrics(for: scene)
        let parseResult = lyrics.isEmpty ? nil : SceneDirectionParser.parse(lyrics)
        let packetJSON = sceneSyncPacketJSON(for: scene, lyrics: lyrics, parseResult: parseResult)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Script + scene sync")
                    .font(.headline)
                Spacer()

                Button("Refresh Song Data") {
                    Task { await store.loadSongData(for: scene) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Copy Scene Packet") {
                    copyToPasteboard(packetJSON)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workspaceMiniCard(title: "Sync status") {
                        metricGrid([
                            ("Lyrics", lyrics.isEmpty ? "Missing" : "Loaded"),
                            ("Lines", "\(lyricsLineCount(lyrics))"),
                            ("Directions", "\(parseResult?.directions.count ?? 0)"),
                            ("Errors", "\(parseResult?.errors.count ?? 0)")
                        ])
                    }

                    workspaceMiniCard(title: "Legacy direction detection") {
                        if let parseResult, !parseResult.directions.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(parseResult.directions.prefix(8))) { direction in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            infoChip(direction.tag.rawValue.uppercased(), color: .orange)
                                            Text("Line \(direction.sourceLineNumber)")
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                        }

                                        Text(direction.primaryValue.isEmpty ? "No primary value" : direction.primaryValue)
                                            .font(.caption)

                                        if !direction.parameters.isEmpty {
                                            Text(direction.parameters.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · "))
                                                .font(.caption2)
                                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                                }
                            }
                        } else {
                            Text("No bracketed legacy direction markup detected in the current scene text.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        }

                        if let parseResult, !parseResult.errors.isEmpty {
                            Divider()
                            VStack(alignment: .leading, spacing: 6) {
                                sectionLabel("Parse errors")
                                ForEach(Array(parseResult.errors.prefix(5).enumerated()), id: \.offset) { _, error in
                                    issueCard(
                                        title: "Line \(error.lineNumber)",
                                        detail: error.message,
                                        color: .red
                                    )
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Scene packet JSON") {
                        Text(packetJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }

                    workspaceMiniCard(title: "Scene lyrics") {
                        if lyrics.isEmpty {
                            Text("No lyrics/libretto text is loaded for this scene yet.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        } else {
                            Text(lyrics)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private func reviewDeck(for scene: AnimationScene) -> some View {
        let review = planReview(for: scene)
        let reviewJSON = planReviewJSON(review)
        let applyPreview = planApplyPreview(for: scene)
        let applyPreviewJSON = planApplyPreviewJSON(applyPreview)
        let dialogueVisemePreview = currentDialogueVisemePreview(for: scene)
        let dialogueVisemePreviewJSON = dialogueVisemePreview.map(dialogueVisemePreviewJSON)
        let hasApplyBlockers = applyPreview.warnings.contains { $0.contains("ERROR") }
        let focusedShot = focusedReviewShot(in: scene)
        let focusedApplyGrouping: FocusedApplyEffectGrouping? = {
            guard let focusedShot else { return nil }
            return focusedApplyEffects(for: focusedShot, preview: applyPreview)
        }()
        let focusedVisemeGrouping: FocusedDialogueVisemeEffectGrouping? = {
            guard let focusedShot, let dialogueVisemePreview else { return nil }
            return focusedDialogueVisemeEffects(for: focusedShot, preview: dialogueVisemePreview)
        }()
        let shotAnchorSummary: ShotAnchorSummary? = {
            guard let parsedValue = parsedPlanResult?.plan else { return nil }
            return makeShotAnchorSummary(for: scene, plan: parsedValue)
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Plan review")
                    .font(.headline)
                Spacer()
                Button("Apply Scene Plan") {
                    applyPlan(generateDialogue: false)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(hasApplyBlockers || parsedPlanResult?.plan == nil)
                Button(workspaceState.isApplyingDialoguePlan ? "Applying…" : "Apply + Visemes") {
                    applyPlan(generateDialogue: true)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(hasApplyBlockers || parsedPlanResult?.plan == nil || workspaceState.isApplyingDialoguePlan)
                Button("Copy Apply Preview JSON") {
                    copyToPasteboard(applyPreviewJSON)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button(workspaceState.isPreviewingDialogueVisemes ? "Previewing Visemes…" : "Preview Viseme Effects") {
                    previewDialogueVisemeEffects(for: scene)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(hasApplyBlockers || parsedPlanResult?.plan == nil || workspaceState.isPreviewingDialogueVisemes)
                if let dialogueVisemePreviewJSON {
                    Button("Copy Viseme Preview JSON") {
                        copyToPasteboard(dialogueVisemePreviewJSON)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button("Copy Review JSON") {
                    copyToPasteboard(reviewJSON)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workspaceMiniCard(title: "Current vs proposed") {
                        metricGrid([
                            ("Current tracks", "\(review.currentTrackCount)"),
                            ("Proposed tracks", "\(review.proposedTrackCount)"),
                            ("Current frames", "\(review.currentFrames)"),
                            ("Proposed frames", "\(review.proposedFrames)")
                        ])
                    }

                    workspaceMiniCard(title: "Deterministic apply preview") {
                        metricGrid([
                            ("Effects", "\(applyPreview.effectCount)"),
                            ("Apply", "\(applyPreview.actionableEffectCount)"),
                            ("Tracks", "\(applyPreview.currentTrackCount) → \(applyPreview.proposedTrackCount)"),
                            ("Frames", "\(applyPreview.currentFrames) → \(applyPreview.proposedFrames)")
                        ])
                    }

                    if let focusedShot {
                        workspaceMiniCard(title: "Shot review focus") {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(displayShotTitle(focusedShot))
                                        .font(.caption.weight(.semibold))
                                    HStack(spacing: 8) {
                                        infoChip("\(focusedShot.startFrame)–\(focusedShot.endFrame)", color: .purple)
                                        infoChip(focusedShot.source.displayName, color: .secondary)
                                    }
                                    Text("Review below is filtered to this authored shot plus any cross-shot or scene-wide effects that still impact it.")
                                        .font(.caption2)
                                        .foregroundStyle(OperaChromeTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Button("Clear Shot Focus") {
                                    clearFocusedReviewShot()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            if let focusedApplyGrouping {
                                metricGrid([
                                    ("Shot-only effects", "\(focusedApplyGrouping.shotEffects.count)"),
                                    ("Cross-shot", "\(focusedApplyGrouping.crossShotEffects.count)"),
                                    ("Scene-wide", "\(focusedApplyGrouping.sceneWideEffects.count)"),
                                    ("Apply", "\(focusedApplyGrouping.actionableEffectCount)")
                                ])
                            }
                        }
                    }

                    if let shotAnchorSummary, shotAnchorSummary.referenceCount > 0 || !shotAnchorSummary.warnings.isEmpty {
                        workspaceMiniCard(title: "Shot-targeted plan coverage") {
                            metricGrid([
                                ("Anchors", "\(shotAnchorSummary.referenceCount)"),
                                ("Shots", "\(shotAnchorSummary.uniqueShotLabels.count)"),
                                ("Warnings", "\(shotAnchorSummary.warnings.count)"),
                                ("Current mode", "Shot-aware")
                            ])

                            if !shotAnchorSummary.uniqueShotLabels.isEmpty {
                                FlexibleChipList(items: shotAnchorSummary.uniqueShotLabels, color: .mint)
                            }

                            ForEach(shotAnchorSummary.warnings, id: \.self) { warning in
                                issueCard(title: "Shot anchor warning", detail: warning, color: .orange)
                            }
                        }
                    }

                    if !review.warnings.isEmpty {
                        workspaceMiniCard(title: "Warnings") {
                            ForEach(Array(review.warnings.enumerated()), id: \.offset) { _, warning in
                                issueCard(title: "Review warning", detail: warning, color: .orange)
                            }
                        }
                    }

                    if !applyPreview.warnings.isEmpty {
                        workspaceMiniCard(title: "Apply blockers and warnings") {
                            ForEach(Array(applyPreview.warnings.enumerated()), id: \.offset) { _, warning in
                                issueCard(
                                    title: warning.contains("ERROR") ? "Apply blocker" : "Apply warning",
                                    detail: warning,
                                    color: warning.contains("ERROR") ? .red : .orange
                                )
                            }
                        }
                    }

                    if let dialogueVisemePreview {
                        workspaceMiniCard(title: "Generated viseme side effects") {
                            let groupedVisemeEffects = groupedDialogueVisemeEffects(preview: dialogueVisemePreview)
                            metricGrid([
                                ("Dialogue beats", "\(dialogueVisemePreview.beatCount)"),
                                ("Effects", "\(dialogueVisemePreview.effectCount)"),
                                ("Apply", "\(dialogueVisemePreview.actionableEffectCount)"),
                                ("Shot groups", "\(groupedVisemeEffects.shotGroups.count)")
                            ])

                            if !dialogueVisemePreview.warnings.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(dialogueVisemePreview.warnings.enumerated()), id: \.offset) { _, warning in
                                        issueCard(
                                            title: warning.contains("ERROR") ? "Viseme preview blocker" : "Viseme preview warning",
                                            detail: warning,
                                            color: warning.contains("ERROR") ? .red : .orange
                                        )
                                    }
                                }
                            }

                            if dialogueVisemePreview.effects.isEmpty {
                                Text("No generated viseme side effects were produced for the current dialogue beats.")
                                    .font(.caption)
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                            } else {
                                if let focusedShot, let focusedVisemeGrouping {
                                    focusedDialogueVisemeSections(for: focusedShot, grouping: focusedVisemeGrouping)
                                } else {
                                    dialogueVisemeSections(preview: dialogueVisemePreview)
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Exact plan-apply effects") {
                        if applyPreview.effects.isEmpty {
                            Text("No deterministic scene mutations are available until the plan parses and validates.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        } else {
                            if let focusedShot, let focusedApplyGrouping {
                                focusedApplyEffectSections(for: focusedShot, grouping: focusedApplyGrouping)
                            } else {
                                applyEffectSections(for: scene, preview: applyPreview)
                            }
                        }
                    }

                    workspaceMiniCard(title: "Track changes") {
                        VStack(alignment: .leading, spacing: 10) {
                            trackChangeBlock(title: "New tracks", items: review.newTracks, color: .green)
                            trackChangeBlock(title: "Replaced tracks", items: review.overlappingTracks, color: .blue)
                            trackChangeBlock(title: "Existing-only tracks", items: review.currentOnlyTracks, color: .orange)
                        }
                    }

                    workspaceMiniCard(title: "Role deltas") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(review.roleDeltas) { delta in
                                HStack {
                                    Text(delta.role)
                                        .font(.caption.weight(.semibold))
                                    Spacer()
                                    Text("\(delta.currentCount) → \(delta.proposedCount)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(OperaChromeTheme.textSecondary)
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Proposed character setups") {
                        if review.characterSetups.isEmpty {
                            Text("No character setup changes detected in the current plan.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(review.characterSetups) { setup in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(setup.characterName)
                                            .font(.caption.weight(.semibold))
                                        Text("Enter \(setup.enterFrame) · Facing \(setup.initialFacing.displayName) · Emotion \(setup.initialEmotion)")
                                            .font(.caption2)
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Apply preview JSON") {
                        Text(applyPreviewJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
        }
    }

    private func lightingDeck(for scene: AnimationScene) -> some View {
        let packet = lightingPacket(for: scene)
        let packetJSON = lightingPacketJSON(packet)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lighting engine")
                    .font(.headline)
                Spacer()
                Button("Copy Lighting Packet") {
                    copyToPasteboard(packetJSON)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workspaceMiniCard(title: "Light world summary") {
                        metricGrid([
                            ("Lighting state", packet.lightingState),
                            ("Practical count", "\(packet.practicals.count)"),
                            ("Cast", "\(packet.characterPriorities.count)"),
                            ("Mode", packet.executionBias)
                        ])
                    }

                    workspaceMiniCard(title: "Channel contract") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(packet.channels, id: \.name) { channel in
                                HStack(alignment: .top, spacing: 8) {
                                    infoChip(channel.name, color: lightingChannelColor(channel.name))
                                    Text(channel.purpose)
                                        .font(.caption)
                                        .foregroundStyle(OperaChromeTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Character priorities") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(packet.characterPriorities, id: \.characterID) { character in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(character.name)
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text(character.protectChannel)
                                            .font(.caption2.monospaced())
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                    }
                                    Text(character.priorityNotes.joined(separator: " · "))
                                        .font(.caption2)
                                        .foregroundStyle(OperaChromeTheme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                )
                            }
                        }
                    }

                    workspaceMiniCard(title: "Lighting packet JSON") {
                        Text(packetJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
        }
    }

    @ViewBuilder
    private func applyEffectSections(
        for scene: AnimationScene,
        preview: AnimatePlanApplyPreview
    ) -> some View {
        let grouped = groupedApplyEffects(for: scene, preview: preview)

        VStack(alignment: .leading, spacing: 12) {
            if !grouped.shotGroups.isEmpty || !grouped.crossShotEffects.isEmpty {
                Text("Shot grouping is based on the current scene shot map. Cross-shot effects span more than one current shot.")
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !grouped.shotGroups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Shot-by-shot effects")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouped.shotGroups.count) shots")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouped.shotGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(group.title)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(group.frameRangeLabel)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                            }

                            ForEach(group.effects) { effect in
                                applyEffectCard(effect, showShotContexts: false)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                        )
                    }
                }
            }

            if !grouped.crossShotEffects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cross-shot effects")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouped.crossShotEffects.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouped.crossShotEffects) { effect in
                        applyEffectCard(effect, showShotContexts: true)
                    }
                }
            }

            if !grouped.sceneWideEffects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Scene-wide effects")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouped.sceneWideEffects.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouped.sceneWideEffects) { effect in
                        applyEffectCard(effect, showShotContexts: true)
                    }
                }
            }
        }
    }

    private func groupedApplyEffects(
        for scene: AnimationScene,
        preview: AnimatePlanApplyPreview
    ) -> ApplyEffectGrouping {
        let shotSegments = shotSegmentationService.shotSegments(for: scene)
        let groupedByShotID = Dictionary(grouping: preview.effects.filter { $0.shotContexts.count == 1 }) { effect in
            effect.shotContexts[0].id
        }

        var shotGroups: [ApplyEffectShotGroup] = shotSegments.compactMap { segment in
            guard let effects = groupedByShotID[segment.id], !effects.isEmpty else { return nil }
            return ApplyEffectShotGroup(
                id: segment.id,
                title: segment.title,
                frameRangeLabel: segment.frameRangeLabel,
                effects: effects
            )
        }

        let knownIDs = Set(shotGroups.map(\.id))
        let extraGroups = groupedByShotID
            .filter { !knownIDs.contains($0.key) }
            .values
            .compactMap { effects -> ApplyEffectShotGroup? in
                guard let context = effects.first?.shotContexts.first else { return nil }
                return ApplyEffectShotGroup(
                    id: context.id,
                    title: context.title,
                    frameRangeLabel: context.frameRangeLabel,
                    effects: effects
                )
            }
            .sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }

        shotGroups.append(contentsOf: extraGroups)

        return ApplyEffectGrouping(
            shotGroups: shotGroups,
            crossShotEffects: preview.effects.filter { $0.shotContexts.count > 1 },
            sceneWideEffects: preview.effects.filter { $0.shotContexts.isEmpty }
        )
    }

    private func applyEffectCard(
        _ effect: AnimatePlanApplyPreview.Effect,
        showShotContexts: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(effect.title)
                    .font(.caption.weight(.semibold))
                Spacer()
                infoChip(effect.changeKindLabel, color: executionChangeColor(effect.changeKind))
            }

            Text(effect.target)
                .font(.caption2)
                .foregroundStyle(OperaChromeTheme.textSecondary)

            if let frameRangeLabel = effect.frameRangeLabel {
                infoChip(frameRangeLabel, color: .purple)
            }

            if showShotContexts && !effect.shotContexts.isEmpty {
                FlexibleChipList(
                    items: effect.shotContexts.map { "\($0.title) · \($0.frameRangeLabel)" },
                    color: .mint
                )
            }

            Text(effect.detail)
                .font(.caption2)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: 10) {
                executionValueColumn(
                    title: "Current",
                    value: effect.currentValue ?? "None",
                    subtitle: effect.scope.rawValue
                )
                executionValueColumn(
                    title: "Proposed",
                    value: effect.proposedValue ?? "None",
                    subtitle: effect.scope.rawValue
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
        )
    }

    @ViewBuilder
    private func dialogueVisemeSections(
        preview: AnimateDialogueVisemePreview
    ) -> some View {
        let grouped = groupedDialogueVisemeEffects(preview: preview)

        VStack(alignment: .leading, spacing: 12) {
            if !grouped.shotGroups.isEmpty || !grouped.crossShotEffects.isEmpty {
                Text("Shot grouping is based on the current scene shot map. Cross-shot viseme effects span more than one current shot.")
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !grouped.shotGroups.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Shot-by-shot viseme effects")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouped.shotGroups.count) shots")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouped.shotGroups) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(group.title)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                Text(group.frameRangeLabel)
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                            }

                            HStack(spacing: 8) {
                                infoChip("\(group.effects.count) beats", color: .mint)
                                infoChip("\(group.effects.reduce(0) { $0 + $1.visemeCount }) visemes", color: .pink)
                            }

                            ForEach(group.effects) { effect in
                                dialogueVisemeEffectCard(effect, showShotContexts: false)
                            }
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                        )
                    }
                }
            }

            if !grouped.crossShotEffects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Cross-shot viseme effects")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouped.crossShotEffects.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouped.crossShotEffects) { effect in
                        dialogueVisemeEffectCard(effect, showShotContexts: true)
                    }
                }
            }

            if !grouped.sceneWideEffects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Scene-wide viseme effects")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouped.sceneWideEffects.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouped.sceneWideEffects) { effect in
                        dialogueVisemeEffectCard(effect, showShotContexts: true)
                    }
                }
            }
        }
    }

    private func groupedDialogueVisemeEffects(
        preview: AnimateDialogueVisemePreview
    ) -> DialogueVisemeEffectGrouping {
        var orderedShotIDs: [String] = []
        var groupedByShotID: [String: [AnimateDialogueVisemePreview.Effect]] = [:]
        var contextsByShotID: [String: AnimatePlanApplyPreview.Effect.ShotContext] = [:]

        for effect in preview.effects where effect.shotContexts.count == 1 {
            let context = effect.shotContexts[0]
            if groupedByShotID[context.id] == nil {
                orderedShotIDs.append(context.id)
                contextsByShotID[context.id] = context
            }
            groupedByShotID[context.id, default: []].append(effect)
        }

        let shotGroups = orderedShotIDs.compactMap { shotID -> DialogueVisemeShotGroup? in
            guard let context = contextsByShotID[shotID],
                  let effects = groupedByShotID[shotID], !effects.isEmpty else { return nil }
            return DialogueVisemeShotGroup(
                id: shotID,
                title: context.title,
                frameRangeLabel: context.frameRangeLabel,
                effects: effects
            )
        }

        return DialogueVisemeEffectGrouping(
            shotGroups: shotGroups,
            crossShotEffects: preview.effects.filter { $0.shotContexts.count > 1 },
            sceneWideEffects: preview.effects.filter { $0.shotContexts.isEmpty }
        )
    }

    private func dialogueVisemeEffectCard(
        _ effect: AnimateDialogueVisemePreview.Effect,
        showShotContexts: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(effect.characterName)
                        .font(.caption.weight(.semibold))
                    Text(effect.trackName)
                        .font(.caption2)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                Spacer()
                infoChip(effect.changeKindLabel, color: executionChangeColor(effect.changeKind))
            }

            HStack(spacing: 8) {
                infoChip(effect.frameRangeLabel, color: .purple)
                infoChip("\(effect.visemeCount) visemes", color: .pink)
            }

            if showShotContexts && !effect.shotContexts.isEmpty {
                FlexibleChipList(
                    items: effect.shotContexts.map { "\($0.title) · \($0.frameRangeLabel)" },
                    color: .mint
                )
            }

            Text(effect.detail)
                .font(.caption2)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let transcriptExcerpt = effect.transcriptExcerpt {
                Text("“\(transcriptExcerpt)”")
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .italic()
            }

            HStack(alignment: .top, spacing: 10) {
                executionValueColumn(
                    title: "Current",
                    value: effect.currentValue ?? "None",
                    subtitle: effect.audioPath
                )
                executionValueColumn(
                    title: "Proposed",
                    value: effect.proposedValue ?? "None",
                    subtitle: effect.audioPath
                )
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
        )
    }

    private func resolutionDeck(for scene: AnimationScene) -> some View {
        let packet = sceneExecutionPacket(for: scene)
        let packetJSON = sceneExecutionPacketJSON(packet)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scene asset resolution")
                    .font(.headline)
                Spacer()

                Button("Activate Recommended Packages") {
                    activateRecommendedPackages(for: scene)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Copy Execution Packet") {
                    copyToPasteboard(packetJSON)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workspaceMiniCard(title: "Resolution summary") {
                        metricGrid([
                            ("Characters", "\(packet.characterResolutions.count)"),
                            ("Packages ready", "\(packet.characterResolutions.filter(\.packageValid).count)"),
                            ("Place", packet.place.approvedImagePath == nil ? "Missing" : "Ready"),
                            ("Gaps", "\(packet.unresolvedNeeds.count)")
                        ])
                    }

                    workspaceMiniCard(title: "Place resolution") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(packet.place.name)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                infoChip(packet.place.approvedImagePath == nil ? "Needs approved plate" : "Approved plate ready", color: packet.place.approvedImagePath == nil ? .orange : .green)
                            }

                            Text(packet.place.summary)
                                .font(.caption2)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if let path = packet.place.approvedImagePath {
                                Text(path)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }

                    workspaceMiniCard(title: "Resolved character packages") {
                        if packet.characterResolutions.isEmpty {
                            Text("No scene characters are linked yet.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(packet.characterResolutions, id: \.characterID) { item in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(item.name)
                                                .font(.caption.weight(.semibold))
                                            Spacer()
                                            infoChip(item.packageValid ? "Package ready" : "Needs package work", color: item.packageValid ? .green : .orange)
                                        }

                                        Text(item.packageName ?? "No active package")
                                            .font(.caption2)
                                            .foregroundStyle(OperaChromeTheme.textSecondary)

                                        HStack(spacing: 8) {
                                            compactMetric("Head", "\(item.headPoseCount)/6")
                                            compactMetric("Visemes", "\(item.visemeCount)")
                                            compactMetric("Expr", "\(item.expressionCount)")
                                            compactMetric("Assets", "\(item.assetCount)")
                                        }

                                        if !item.priorityWork.isEmpty {
                                            Text(item.priorityWork.joined(separator: " · "))
                                                .font(.caption2)
                                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Unresolved engine pulls") {
                        if packet.unresolvedNeeds.isEmpty {
                            issueCard(
                                title: "Scene packet is internally resolvable",
                                detail: "The current scene has a place, active packages, and enough visible coverage to stay mostly internal.",
                                color: .green
                            )
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(packet.unresolvedNeeds, id: \.id) { need in
                                    issueCard(
                                        title: "\(need.scope) · \(need.title)",
                                        detail: need.detail,
                                        color: need.severity == "error" ? .red : .orange
                                    )
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Execution packet JSON") {
                        Text(packetJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
        }
    }

    private func assetsDeck(for scene: AnimationScene) -> some View {
        let database = workspaceState.lastAssetRequirementsDatabase
        let sceneEntries = assetEntries(for: scene, database: database)
        let databaseJSON = database.map(assetRequirementsService.databaseJSON) ?? "{}"
        let sceneSummary = database?.scenes.first(where: { $0.sceneID == scene.id.uuidString })
        let inventoryEntries = sceneAssetInventory(for: scene)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Asset requirements")
                    .font(.headline)
                Spacer()

                Button(workspaceState.isRefreshingAssetRequirements ? "Refreshing…" : "Refresh Database") {
                    Task { await refreshAssetRequirementsDatabase() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(workspaceState.isRefreshingAssetRequirements)

                Button("Copy Database JSON") {
                    copyToPasteboard(databaseJSON)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(database == nil)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workspaceMiniCard(title: "Scene asset inventory") {
                        if inventoryEntries.isEmpty {
                            Text("No scene-linked assets are available yet.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(inventoryEntries) { entry in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(entry.title)
                                                .font(.caption.weight(.semibold))
                                            Spacer()
                                            infoChip(entry.kind, color: .secondary)
                                            infoChip(entry.statusLabel, color: entry.statusColor)
                                        }

                                        Text(entry.detail)
                                            .font(.caption2)
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)

                                        if let path = entry.path {
                                            Text(path)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Database summary") {
                        if let database {
                            metricGrid([
                                ("Scenes", "\(database.summary.sceneCount)"),
                                ("Entries", "\(database.summary.entryCount)"),
                                ("Ready", "\(database.summary.readyCount)"),
                                ("Needs art", "\(database.summary.needsArtCount)"),
                                ("Needs definition", "\(database.summary.needsDefinitionCount)")
                            ])

                            Text("Generated \(assetDatabaseTimestamp(database.generatedAt))")
                                .font(.caption2)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        } else {
                            Text("Generate the database to see cross-scene requirements for places, objects, and scene-driven asset gaps.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        }
                    }

                    workspaceMiniCard(title: "Current scene coverage") {
                        metricGrid([
                            ("Scene", scene.name),
                            ("Shots", "\(sceneSummary?.shotCount ?? scene.shots.count)"),
                            ("Object mentions", "\(sceneSummary?.objectMentionCount ?? scene.objectSetups.count)"),
                            ("Open gaps", "\(sceneSummary?.unresolvedCount ?? 0)")
                        ])
                    }

                    workspaceMiniCard(title: "Scene asset inventory") {
                        let cast = sceneCharacters(for: scene)
                        let objectNames = Array(
                            Set(scene.objectSetups.map { $0.objectName.trimmingCharacters(in: .whitespacesAndNewlines) })
                        )
                        .filter { !$0.isEmpty }
                        .sorted()

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Background")
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                infoChip(backgroundPlate(for: scene) == nil ? "Unassigned" : "Bound", color: backgroundPlate(for: scene) == nil ? .orange : .green)
                            }

                            Text(backgroundPlate(for: scene)?.name ?? "No place/background is currently bound to this scene.")
                                .font(.caption2)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            if !cast.isEmpty {
                                flexibleInfoGrid(
                                    title: "Cast",
                                    items: cast.map(\.name),
                                    color: .blue
                                )
                            }

                            if !objectNames.isEmpty {
                                flexibleInfoGrid(
                                    title: "Objects on stage",
                                    items: objectNames,
                                    color: .mint
                                )
                            }
                        }
                    }

                    workspaceMiniCard(title: "Required from scene directions") {
                        if sceneEntries.isEmpty {
                            Text("No asset entries were inferred yet for this scene. Refresh the database after loading the libretto-backed scene directions.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(sceneEntries) { entry in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(entry.name)
                                                .font(.caption.weight(.semibold))
                                            Spacer()
                                            infoChip(entry.kind.capitalized, color: .secondary)
                                            infoChip(entry.status.rawValue.replacingOccurrences(of: "_", with: " "), color: assetStatusColor(entry.status))
                                        }

                                        Text(entry.summary)
                                            .font(.caption2)
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)

                                        HStack(spacing: 8) {
                                            compactMetric("Variants", "\(entry.variantCount)")
                                            compactMetric("States", "\(entry.requiredStates.count)")
                                            compactMetric("Shots", "\(Set(entry.occurrences.flatMap(\.shotTitles)).count)")
                                        }

                                        if !entry.requiredStates.isEmpty {
                                            flexibleInfoGrid(
                                                title: "Required states",
                                                items: entry.requiredStates,
                                                color: .mint
                                            )
                                        }

                                        if !entry.requiredAttachments.isEmpty {
                                            flexibleInfoGrid(
                                                title: "Attachments",
                                                items: entry.requiredAttachments,
                                                color: .purple
                                            )
                                        }

                                        if !entry.requiredCameraShots.isEmpty {
                                            flexibleInfoGrid(
                                                title: "Shot coverage",
                                                items: entry.requiredCameraShots,
                                                color: .blue
                                            )
                                        }

                                        if !entry.placementHints.isEmpty {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("Placement hints")
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                                                ForEach(entry.placementHints.prefix(3)) { hint in
                                                    Text([
                                                        hint.shotTitle,
                                                        hint.detail,
                                                        hint.attachmentTarget
                                                    ]
                                                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? $0 : nil }
                                                    .joined(separator: " · "))
                                                        .font(.caption2)
                                                        .foregroundStyle(OperaChromeTheme.textSecondary)
                                                }
                                            }
                                        }

                                        if let approved = entry.approvedImagePath {
                                            Text(approved)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                                .textSelection(.enabled)
                                        }
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Database JSON") {
                        Text(databaseJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
        }
        .task(id: "\(scene.id.uuidString)|\(workspaceState.selectedDockTab.rawValue)") {
            guard presentation == .assets || workspaceState.selectedDockTab == .assets,
                  workspaceState.lastAssetRequirementsDatabase == nil else { return }
            await refreshAssetRequirementsDatabase()
        }
    }

    private func shotsDeck(for scene: AnimationScene) -> some View {
        let authoredShots = scene.shots.sorted {
            if $0.startFrame == $1.startFrame {
                return $0.endFrame < $1.endFrame
            }
            return $0.startFrame < $1.startFrame
        }
        let inferredShots = shotSegmentationService.inferredShots(for: scene)
        let lyrics = currentLyrics(for: scene)
        let parseResult = lyrics.isEmpty ? nil : SceneDirectionParser.parse(lyrics)
        let seedReport = shotSeedReport(for: scene, lyrics: lyrics, parseResult: parseResult)
        let shotsJSON = sceneShotsJSON(authoredShots.isEmpty ? inferredShots : authoredShots)
        let seedJSON = shotSeedReportJSON(seedReport)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scene shots")
                    .font(.headline)
                Spacer()

                Button("Seed From Script") {
                    seedShotsFromScript(for: scene)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button(authoredShots.isEmpty ? "Adopt Inferred Shots" : "Reset From Cues") {
                    store.replaceSelectedSceneShots(inferredShots)
                    store.save()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Add Manual Shot") {
                    var updated = authoredShots
                    updated.append(defaultManualShot(for: scene, existing: authoredShots))
                    store.replaceSelectedSceneShots(updated)
                    store.save()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Save Shots") {
                    store.save()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Copy Shots JSON") {
                    copyToPasteboard(shotsJSON)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workspaceMiniCard(title: "Shot list status") {
                        metricGrid([
                            ("Authored", "\(authoredShots.count)"),
                            ("Inferred", "\(inferredShots.count)"),
                            ("Mode", authoredShots.isEmpty ? "Cue-derived" : "Scene-authored"),
                            ("Frames", "\(shotSegmentationService.sceneFrameCount(for: scene))")
                        ])
                    }

                    workspaceMiniCard(title: "Script seeding") {
                        metricGrid([
                            ("Directions", "\(seedReport.scriptDirectionCount)"),
                            ("Camera dirs", "\(seedReport.cameraDirectionCount)"),
                            ("Object dirs", "\(seedReport.objectDirectionCount)"),
                            ("Lyric lines", "\(seedReport.lyricLineCount)"),
                            ("Seeded", "\(seedReport.seededShots.count)")
                        ])

                        if !seedReport.warnings.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(seedReport.warnings, id: \.self) { warning in
                                    issueCard(title: "Shot seeding note", detail: warning, color: .orange)
                                }
                            }
                        } else if let first = seedReport.seededShots.first {
                            issueCard(
                                title: "Script seed is ready",
                                detail: "\(first.title) · \(first.startFrame)–\(first.endFrame)",
                                color: .green
                            )
                        }

                        HStack(spacing: 8) {
                            Button("Copy Seed Report") {
                                copyToPasteboard(seedJSON)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if let latest = workspaceState.lastShotSeedReport,
                               latest.sceneID == scene.id.uuidString {
                                Text("Last seeded \(latest.seededShots.count) shots")
                                    .font(.caption2)
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                            }
                        }
                    }

                    if authoredShots.isEmpty {
                        workspaceMiniCard(title: "Inferred fallback shots") {
                            Text("This scene does not have authored shots yet, so Animate is deriving shot boundaries from camera cues, beat labels, and preview plan boundaries.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)

                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(inferredShots.indices, id: \.self) { index in
                                    inferredShotRow(inferredShots[index], index: index)
                                }
                            }
                        }
                    } else {
                        workspaceMiniCard(title: "Authored shot packets") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(authoredShots.indices, id: \.self) { index in
                                    authoredShotRow(
                                        scene: scene,
                                        shot: authoredShots[index],
                                        index: index,
                                        canMoveUp: index > 0,
                                        canMoveDown: index < authoredShots.count - 1
                                    )
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Shot packet JSON") {
                        Text(shotsJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
        }
    }

    private func executionDeck(for scene: AnimationScene) -> some View {
        let bundle = executionBundle(for: scene)
        let preview = executionPreview(for: scene, bundle: bundle)
        let bundleJSON = executionBundleJSON(bundle)
        let previewJSON = executionPreviewJSON(preview)

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scene execution bundle")
                    .font(.headline)
                Spacer()

                Button("Apply Previewed Staging") {
                    stageExecutionBundle(bundle, preview: preview)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(bundle.actions.isEmpty)

                Button("Copy Bundle") {
                    copyToPasteboard(bundleJSON)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workspaceMiniCard(title: "Execution summary") {
                        metricGrid([
                            ("Effects", "\(preview.effectCount)"),
                            ("Apply", "\(preview.actionableEffectCount)"),
                            ("Packages", "\(preview.packageEffectCount)"),
                            ("Timeline", "\(preview.timelineEffectCount)"),
                            ("Warnings", "\(preview.warnings.count)"),
                            ("Presets", "\(bundle.recommendedPresets.count)"),
                            ("Route", bundle.executionMode)
                        ])
                    }

                    if let lastExecutionPreview = workspaceState.lastExecutionPreview,
                       lastExecutionPreview.sceneID == scene.id.uuidString {
                        workspaceMiniCard(title: "Latest staged receipt") {
                            metricGrid([
                                ("Applied", "\(lastExecutionPreview.actionableEffectCount)"),
                                ("Packages", "\(lastExecutionPreview.packageEffectCount)"),
                                ("Timeline", "\(lastExecutionPreview.timelineEffectCount)"),
                                ("Warnings", "\(lastExecutionPreview.warnings.count)")
                            ])
                        }
                    }

                    workspaceMiniCard(title: "Exact staged effects") {
                        if preview.effects.isEmpty {
                            issueCard(
                                title: "No default staging actions needed",
                                detail: "This scene already has its core package and camera defaults staged.",
                                color: .green
                            )
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(preview.effects) { effect in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(effect.title)
                                                .font(.caption.weight(.semibold))
                                            Spacer()
                                            infoChip(effect.scope == .packageSelection ? "PACKAGE" : "TIMELINE", color: effect.scope == .packageSelection ? .green : .blue)
                                            infoChip(effect.changeKindLabel, color: executionChangeColor(effect.changeKind))
                                        }
                                        HStack {
                                            Text(effect.target)
                                                .font(.caption2.weight(.semibold))
                                            Spacer()
                                            if let trackName = effect.trackName {
                                                Text(trackName)
                                                    .font(.caption2.monospaced())
                                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                                            }
                                        }
                                        .foregroundStyle(OperaChromeTheme.textSecondary)

                                        Text(effect.detail)
                                            .font(.caption2)
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)

                                        HStack(alignment: .top, spacing: 10) {
                                            executionValueColumn(
                                                title: "Current",
                                                value: effect.currentValue ?? "None",
                                                subtitle: effect.currentSource
                                            )
                                            executionValueColumn(
                                                title: "Proposed",
                                                value: effect.proposedValue ?? "None",
                                                subtitle: effect.frame.map { "Frame \($0)" } ?? "Selection"
                                            )
                                        }
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Recommended shot grammar") {
                        if bundle.recommendedPresets.isEmpty {
                            Text("No shot presets match the current inferred intent yet.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(bundle.recommendedPresets) { preset in
                                    HStack(alignment: .top, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(preset.name)
                                                    .font(.caption.weight(.semibold))
                                                Spacer()
                                                if let shot = preset.cameraShot {
                                                    infoChip(shot, color: .blue)
                                                }
                                            }

                                            Text(preset.summary)
                                                .font(.caption2)
                                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }

                                        VStack(spacing: 6) {
                                            Button("Preview") {
                                                previewRecommendedPreset(id: preset.id)
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)

                                            Button("Apply") {
                                                applyRecommendedPreset(id: preset.id)
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                        }
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                                }
                            }
                        }
                    }

                    if let presetPreview = selectedPresetPreview(for: scene) {
                        workspaceMiniCard(title: "Preset preview · \(presetPreview.presetName)") {
                            VStack(alignment: .leading, spacing: 10) {
                                metricGrid([
                                    ("Frame", "\(presetPreview.frame)"),
                                    ("Effects", "\(presetPreview.effectCount)"),
                                    ("Apply", "\(presetPreview.actionableEffectCount)"),
                                    ("Clears", "\(presetPreview.clearEffectCount)")
                                ])

                                ForEach(presetPreview.effects) { effect in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(effect.title)
                                                .font(.caption.weight(.semibold))
                                            Spacer()
                                            infoChip(effect.changeKindLabel, color: executionChangeColor(effect.changeKind))
                                        }
                                        if let trackName = effect.trackName {
                                            Text(trackName)
                                                .font(.caption2.monospaced())
                                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                        }
                                        Text(effect.detail)
                                            .font(.caption2)
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack(alignment: .top, spacing: 10) {
                                            executionValueColumn(
                                                title: "Current",
                                                value: effect.currentValue ?? "None",
                                                subtitle: effect.currentSource
                                            )
                                            executionValueColumn(
                                                title: "Proposed",
                                                value: effect.proposedValue ?? "None",
                                                subtitle: effect.frame.map { "Frame \($0)" } ?? "Preset"
                                            )
                                        }
                                    }
                                    .padding(10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                                }

                                if !presetPreview.warnings.isEmpty {
                                    ForEach(Array(presetPreview.warnings.enumerated()), id: \.offset) { _, warning in
                                        issueCard(title: "Preset warning", detail: warning, color: .orange)
                                    }
                                }
                            }
                        }
                    }

                    if let lastPresetPreview = workspaceState.lastPresetPreview {
                        workspaceMiniCard(title: "Latest preset apply receipt") {
                            metricGrid([
                                ("Preset", lastPresetPreview.presetName),
                                ("Frame", "\(lastPresetPreview.frame)"),
                                ("Applied", "\(lastPresetPreview.actionableEffectCount)"),
                                ("Clears", "\(lastPresetPreview.clearEffectCount)")
                            ])
                        }
                    }

                    if !preview.warnings.isEmpty {
                        workspaceMiniCard(title: "Execution warnings") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(preview.warnings.enumerated()), id: \.offset) { _, warning in
                                    issueCard(title: "Execution warning", detail: warning, color: .orange)
                                }
                            }
                        }
                    }

                    workspaceMiniCard(title: "Execution preview JSON") {
                        Text(previewJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }

                    workspaceMiniCard(title: "Execution bundle JSON") {
                        Text(bundleJSON)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
            }
        }
    }

    private func handoffDeck(for scene: AnimationScene) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("External LLM handoff")
                    .font(.headline)
                Spacer()
                Button("Copy Engine Packet") {
                    copyToPasteboard(orchestrationPacketJSON(for: scene))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Copy Brief") {
                    copyToPasteboard(scriptMigrationPrompt(for: scene))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Copy Operator Prompt") {
                    copyToPasteboard(librettoAuthorOperatorPrompt(for: scene))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    workspaceMiniCard(title: "Libretto rewrite operator prompt") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Fill the optional placeholders below, then copy the fully populated scene-by-scene prompt for the external libretto-writing LLM.")
                                .font(.caption)
                                .foregroundStyle(OperaChromeTheme.textSecondary)

                            TextField(
                                "Approved recurring object names override",
                                text: librettoPromptOverrideBinding(for: scene, keyPath: \.approvedRecurringObjects)
                            )
                            .textFieldStyle(.roundedBorder)

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Timing notes")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                                TextEditor(text: librettoPromptOverrideBinding(for: scene, keyPath: \.timingNotes))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minHeight: 58)
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Additional directing guidance")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                                TextEditor(text: librettoPromptOverrideBinding(for: scene, keyPath: \.directingGuidance))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minHeight: 58)
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                            }

                            VStack(alignment: .leading, spacing: 6) {
                                Text("Operator notes")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(OperaChromeTheme.textSecondary)
                                TextEditor(text: librettoPromptOverrideBinding(for: scene, keyPath: \.operatorNotes))
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(minHeight: 58)
                                    .padding(6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
                                    )
                            }

                            HStack(spacing: 8) {
                                Button("Copy Filled Prompt") {
                                    copyToPasteboard(librettoAuthorOperatorPrompt(for: scene))
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                Button("Copy Placeholder Template") {
                                    copyToPasteboard(librettoAuthorOperatorTemplate())
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Text(librettoAuthorOperatorPrompt(for: scene))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }

                    workspaceMiniCard(title: "Scene migration brief") {
                        Text(scriptMigrationPrompt(for: scene))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }

                    workspaceMiniCard(title: "Unified engine packet") {
                        Text(orchestrationPacketJSON(for: scene))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }

                    workspaceMiniCard(title: "Expected JSON keys") {
                        Text(jsonKeyGuide)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .textSelection(.enabled)
                    }

                    workspaceMiniCard(title: "Automatic workflow target") {
                        Text("""
                        1. Scene brief defines cast, place, intent, and package expectations.
                        2. External LLM converts libretto/camera notes into deterministic JSON.
                        3. JSON is applied here to populate timeline tracks.
                        4. Missing asset requests become explicit package tasks instead of surprises.
                        5. Lighting, mouth, and body subsystems can later run from the same contract.
                        """)
                        .font(.caption)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
            }
        }
    }

    private func castCoverageRow(
        character: AnimationCharacter,
        summary: SceneAutomationCharacterSummary?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(character.name)
                    .font(.caption.weight(.semibold))
                Spacer()
                infoChip(summary?.readiness.displayName ?? "Missing", color: readinessColor(summary?.readiness ?? .missing))
            }

            Text(summary?.summaryLine ?? "No package summary yet.")
                .font(.caption2)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                compactMetric("Head", "\(summary?.approvedHeadPoseCount ?? 0)/6")
                compactMetric("Visemes", "\(summary?.activePackageVisemeCount ?? 0)")
                compactMetric("Expressions", "\(summary?.activePackageExpressionCount ?? 0)")
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.6))
        )
    }

    private func subsystemReadinessStrip(for scene: AnimationScene) -> some View {
        let metrics = subsystemReadinessMetrics(for: scene)

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 8) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.title)
                                .font(.caption.weight(.semibold))
                            Text(metric.readiness.displayName)
                                .font(.caption2)
                                .foregroundStyle(metric.color)
                        }

                        Spacer(minLength: 8)

                        Text("\(Int(metric.score * 100))%")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ProgressView(value: metric.score)
                        .tint(metric.color)

                    Text(metric.detail)
                        .font(.caption2)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(OperaChromeTheme.raisedBackground.opacity(0.62))
                )
            }
        }
    }

    private func subsystemReadinessMetrics(for scene: AnimationScene) -> [AnimateSubsystemReadinessMetric] {
        let cast = sceneCharacters(for: scene)
        let plan = store.selectedSceneAutomationPlan()
        let summaries = plan?.characterSummaries ?? []
        let approvedBackground = backgroundPlate(for: scene)?.resolvedApprovedImagePath != nil
        let currentTracks = store.orderedTimelineTracks(for: scene)

        let validPackageCount = summaries.filter(\.activePackageValid).count
        let averageHeadCoverage = summaries.isEmpty ? 0 : summaries.map { min(Double($0.approvedHeadPoseCount) / 6.0, 1.0) }.reduce(0, +) / Double(summaries.count)
        let bodyScore = summaries.isEmpty ? 0 : min(1.0, (Double(validPackageCount) / Double(max(summaries.count, 1))) * 0.55 + averageHeadCoverage * 0.45)

        let averageVisemes = summaries.isEmpty ? 0 : summaries.map(\.activePackageVisemeCount).reduce(0, +) / summaries.count
        let averageExpressions = summaries.isEmpty ? 0 : summaries.map(\.activePackageExpressionCount).reduce(0, +) / summaries.count
        let mouthScore = summaries.isEmpty ? 0 : min(1.0, min(Double(averageVisemes) / 8.0, 1.0) * 0.7 + min(Double(averageExpressions) / 6.0, 1.0) * 0.3)

        let hasLightingPhrase = !(parsedPlanResult?.plan?.lighting?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let lightingScore = (approvedBackground ? 0.45 : 0.0)
            + ((store.evaluatedEffectiveCameraShot() != nil || scene.directionTemplate?.defaultCameraShot != nil) ? 0.2 : 0.0)
            + (hasLightingPhrase ? 0.35 : 0.0)

        let cameraTrackCount = currentTracks.filter {
            switch $0.role {
            case .camera, .cameraShot, .cameraDefaultShot, .cameraFocus, .cameraIntent, .cameraBeat, .cameraNotes:
                return true
            default:
                return false
            }
        }.count
        let hasCameraPresetSignal = scene.directionTemplate?.defaultCameraShot != nil || !store.shotPresets.isEmpty
        let cameraScore = min(
            1.0,
            (cameraTrackCount > 0 ? 0.65 : 0.0) +
                (hasCameraPresetSignal ? 0.2 : 0.0) +
                (store.evaluatedEffectiveCameraShot() != nil ? 0.15 : 0.0)
        )

        return [
            AnimateSubsystemReadinessMetric(
                title: "Body",
                score: bodyScore,
                readiness: readinessFromScore(bodyScore, isMissing: cast.isEmpty || summaries.isEmpty),
                detail: cast.isEmpty
                    ? "No cast linked yet."
                    : "\(validPackageCount)/\(max(summaries.count, 1)) active packages • avg head coverage \(Int(averageHeadCoverage * 100))%"
            ),
            AnimateSubsystemReadinessMetric(
                title: "Mouth",
                score: mouthScore,
                readiness: readinessFromScore(mouthScore, isMissing: summaries.isEmpty),
                detail: summaries.isEmpty
                    ? "No package summaries yet."
                    : "Avg visemes \(averageVisemes) • avg expressions \(averageExpressions)"
            ),
            AnimateSubsystemReadinessMetric(
                title: "Lighting",
                score: min(max(lightingScore, 0), 1),
                readiness: readinessFromScore(lightingScore, isMissing: !approvedBackground && !hasLightingPhrase),
                detail: approvedBackground
                    ? "\(backgroundPlate(for: scene)?.name ?? "Place") plate approved • lighting phrase \(hasLightingPhrase ? "ready" : "missing")"
                    : "Needs approved place plate and explicit light-world note."
            ),
            AnimateSubsystemReadinessMetric(
                title: "Camera",
                score: cameraScore,
                readiness: readinessFromScore(cameraScore, isMissing: cameraTrackCount == 0 && !hasCameraPresetSignal),
                detail: "\(cameraTrackCount) camera tracks • \(store.evaluatedEffectiveCameraShot()?.displayName ?? "No resolved shot")"
            )
        ]
    }

    private func readinessFromScore(_ score: Double, isMissing: Bool = false) -> SceneAutomationReadiness {
        if isMissing { return .missing }
        if score >= 0.72 { return .ready }
        if score >= 0.28 { return .partial }
        return .missing
    }

    private func planReview(for scene: AnimationScene) -> AnimatePlanReview {
        orchestrationService.planReview(for: scene)
    }

    private func planReviewJSON(for scene: AnimationScene) -> String {
        planReviewJSON(planReview(for: scene))
    }

    private func planReviewJSON(_ review: AnimatePlanReview) -> String {
        orchestrationService.planReviewJSON(review)
    }

    private func planApplyPreview(for scene: AnimationScene) -> AnimatePlanApplyPreview {
        orchestrationService.planApplyPreview(for: scene)
    }

    private func planApplyPreviewJSON(_ preview: AnimatePlanApplyPreview) -> String {
        orchestrationService.planApplyPreviewJSON(preview)
    }

    private func dialogueVisemePreviewJSON(_ preview: AnimateDialogueVisemePreview) -> String {
        orchestrationService.dialogueVisemePreviewJSON(preview)
    }

    private func trackChangeBlock(title: String, items: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(items.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }

            if items.isEmpty {
                Text("None")
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            } else {
                FlexibleChipList(items: items, color: color)
            }
        }
    }

    private func lightingPacket(for scene: AnimationScene) -> AnimateLightingPacket {
        orchestrationService.lightingPacket(for: scene)
    }

    private func lightingPacketJSON(for scene: AnimationScene) -> String {
        lightingPacketJSON(lightingPacket(for: scene))
    }

    private func lightingPacketJSON(_ packet: AnimateLightingPacket) -> String {
        orchestrationService.lightingPacketJSON(packet)
    }

    private func lightingChannelColor(_ name: String) -> Color {
        switch name {
        case "ch01_world_key": .orange
        case "ch02_world_fill": .blue
        case "ch03_world_rim": .purple
        case "ch04_background_separation": .cyan
        case "ch05_practical_accent": .yellow
        case "ch06_atmosphere_grade": .teal
        case "ch07_primary_subject_protect": .mint
        case "ch08_secondary_subject_protect": .pink
        default: .secondary
        }
    }

    private func sceneExecutionPacket(for scene: AnimationScene) -> AnimateSceneExecutionPacket {
        executionService.sceneExecutionPacket(
            for: scene,
            subsystemMetrics: subsystemReadinessMetrics(for: scene).map {
                AnimateSceneExecutionPacket.SubsystemMetric(
                    title: $0.title,
                    score: $0.score,
                    readiness: $0.readiness.rawValue,
                    detail: $0.detail
                )
            }
        )
    }

    private func sceneExecutionPacketJSON(for scene: AnimationScene) -> String {
        sceneExecutionPacketJSON(sceneExecutionPacket(for: scene))
    }

    private func sceneExecutionPacketJSON(_ packet: AnimateSceneExecutionPacket) -> String {
        executionService.sceneExecutionPacketJSON(packet)
    }

    private func orchestrationPacket(for scene: AnimationScene) -> AnimateSceneOrchestrationPacket {
        let lyrics = currentLyrics(for: scene)
        let parseResult = lyrics.isEmpty ? nil : SceneDirectionParser.parse(lyrics)
        return orchestrationService.orchestrationPacket(
            for: scene,
            lyrics: lyrics,
            parseResult: parseResult,
            subsystemMetrics: subsystemReadinessMetrics(for: scene).map {
                AnimateSceneExecutionPacket.SubsystemMetric(
                    title: $0.title,
                    score: $0.score,
                    readiness: $0.readiness.rawValue,
                    detail: $0.detail
                )
            }
        )
    }

    private func orchestrationPacketJSON(for scene: AnimationScene) -> String {
        orchestrationService.orchestrationPacketJSON(orchestrationPacket(for: scene))
    }

    private func activateRecommendedPackages(for scene: AnimationScene) {
        guard store.animateURL != nil else {
            store.statusMessage = "Open a project before resolving packages."
            return
        }

        let activated = executionService.activateRecommendedPackages(for: scene)
        store.statusMessage = activated == 0
            ? "No scene packages could be resolved."
            : "Activated \(activated) recommended package\(activated == 1 ? "" : "s") for this scene."
    }

    private func executionBundle(for scene: AnimationScene) -> AnimateExecutionBundle {
        executionService.executionBundle(for: scene, packet: sceneExecutionPacket(for: scene))
    }

    private func executionPreview(
        for scene: AnimationScene,
        bundle: AnimateExecutionBundle
    ) -> AnimateExecutionPreview {
        executionService.executionPreview(
            for: scene,
            bundle: bundle,
            packet: sceneExecutionPacket(for: scene)
        )
    }

    private func executionBundleJSON(_ bundle: AnimateExecutionBundle) -> String {
        executionService.executionBundleJSON(bundle)
    }

    private func executionPreviewJSON(_ preview: AnimateExecutionPreview) -> String {
        executionService.executionPreviewJSON(preview)
    }

    private func selectedPresetPreview(for scene: AnimationScene) -> AnimatePresetPreview? {
        guard let previewID = workspaceState.selectedPresetPreviewID,
              let preset = bundleRecommendedPreset(for: scene, id: previewID) else {
            return nil
        }
        return executionService.shotPresetPreview(preset, frame: 0)
    }

    private func stageExecutionBundle(_ bundle: AnimateExecutionBundle, preview: AnimateExecutionPreview) {
        let applied = executionService.applyExecutionBundle(bundle)
        workspaceState.lastExecutionPreview = preview
        store.statusMessage = applied == 0
            ? "No execution defaults were staged."
            : "Staged \(applied) execution default\(applied == 1 ? "" : "s") for this scene."
    }

    private func applyRecommendedPreset(id: UUID) {
        guard let preset = store.shotPreset(id: id) else { return }
        let preview = executionService.shotPresetPreview(preset, frame: 0)
        workspaceState.selectedPresetPreviewID = id
        workspaceState.lastPresetPreview = preview
        store.applyShotPreset(preset, frame: 0)
    }

    private func previewRecommendedPreset(id: UUID) {
        workspaceState.selectedPresetPreviewID = id
    }

    private func bundleRecommendedPreset(for scene: AnimationScene, id: UUID) -> SceneShotPreset? {
        let bundle = executionBundle(for: scene)
        guard bundle.recommendedPresets.contains(where: { $0.id == id }) else { return nil }
        return store.shotPreset(id: id)
    }

    private func actionColor(_ kind: AnimateExecutionBundle.Action.Kind) -> Color {
        switch kind {
        case .activatePackage: .green
        case .cameraDefaultShot: .blue
        case .cameraShot: .purple
        case .cameraFocus: .mint
        case .cameraIntent: .orange
        case .cameraBeatLabel: .pink
        }
    }

    private func executionChangeColor(_ kind: AnimateExecutionPreview.Effect.ChangeKind) -> Color {
        switch kind {
        case .create: .blue
        case .update: .orange
        case .clear: .red
        case .activate: .green
        case .switchSelection: .purple
        case .noChange: .secondary
        }
    }

    private func executionValueColumn(
        title: String,
        value: String,
        subtitle: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OperaChromeTheme.textSecondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(OperaChromeTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func graphSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel(title)
            content()
        }
    }

    private func graphNode(
        title: String,
        subtitle: String,
        detail: String,
        accent: Color
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(accent)
                .frame(width: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2.monospaced())
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
        )
    }

    private func workspaceHeader<Accessory: View>(
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            accessory()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(OperaChromeTheme.headerBackground.opacity(0.7))
    }

    private func workspaceCard<Content: View>(
        title: String,
        systemImage: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.cyan)
                    .font(.headline)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OperaChromeTheme.panelBackground)
        )
    }

    private func workspaceMiniCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel(title)
            content()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.65))
        )
    }

    private func sectionLabel(_ value: String) -> some View {
        Text(value)
            .font(.caption.weight(.semibold))
            .foregroundStyle(OperaChromeTheme.textSecondary)
    }

    private func issueCard(title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }

    private func labeledValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Text(value)
                .font(.caption)
                .foregroundStyle(OperaChromeTheme.textPrimary)
                .lineLimit(2)
        }
    }

    /// A labeled row for picking or clearing the scene's default audio path.
    @ViewBuilder
    private func sceneAudioPickerRow(for scene: AnimationScene) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SCENE AUDIO")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OperaChromeTheme.textTertiary)

            HStack(spacing: 6) {
                let displayName: String = {
                    if let path = scene.defaultAudioPath, !path.isEmpty {
                        return URL(fileURLWithPath: path).lastPathComponent
                    }
                    return "None"
                }()

                Text(displayName)
                    .font(.caption)
                    .foregroundStyle(
                        scene.defaultAudioPath != nil
                            ? OperaChromeTheme.textPrimary
                            : OperaChromeTheme.textSecondary
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = false
                    panel.allowsMultipleSelection = false
                    panel.allowedContentTypes = [
                        UTType.mp3,
                        UTType.wav,
                        UTType.mpeg4Audio,
                        UTType.aiff,
                        UTType(filenameExtension: "caf") ?? .audio
                    ]
                    panel.begin { response in
                        guard response == .OK, let url = panel.url else { return }
                        store.setDefaultAudioPath(url.path, for: scene.id)
                    }
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)

                if scene.defaultAudioPath != nil {
                    Button {
                        store.setDefaultAudioPath(nil, for: scene.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
            }
        }
    }

    private func metricGrid(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.0.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text(item.1)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(OperaChromeTheme.raisedBackground.opacity(0.6))
                )
            }
        }
    }

    private func compactMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(OperaChromeTheme.textPrimary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.6))
        )
    }

    private func overlayRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text(value)
                .font(.caption)
                .foregroundStyle(.white)
                .lineLimit(2)
        }
    }

    private func infoChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.12))
            )
    }

    private func flexibleInfoGrid(
        title: String,
        items: [String],
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OperaChromeTheme.textSecondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], alignment: .leading, spacing: 6) {
                ForEach(items, id: \.self) { item in
                    infoChip(item, color: color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func sceneCharacters(for scene: AnimationScene) -> [AnimationCharacter] {
        scene.characterIDs.compactMap { id in
            store.characters.first(where: { $0.id == id })
        }
    }

    private func backgroundPlate(for scene: AnimationScene) -> BackgroundPlate? {
        guard let backgroundID = scene.backgroundID else { return nil }
        return store.backgrounds.first(where: { $0.id == backgroundID })
    }

    private func assetEntries(
        for scene: AnimationScene,
        database: AnimateAssetRequirementDatabase?
    ) -> [AnimateAssetRequirementDatabase.Entry] {
        guard let database else { return [] }
        return database.entries.filter { entry in
            entry.occurrences.contains(where: { $0.sceneID == scene.id.uuidString })
        }
    }

    private func sceneAssetInventory(for scene: AnimationScene) -> [SceneAssetInventoryEntry] {
        var entries: [SceneAssetInventoryEntry] = []

        if let background = backgroundPlate(for: scene) {
            entries.append(
                SceneAssetInventoryEntry(
                    title: background.name,
                    kind: "Background",
                    statusLabel: background.resolvedApprovedImagePath == nil ? "Missing plate" : "Linked",
                    statusColor: background.resolvedApprovedImagePath == nil ? .orange : .green,
                    detail: background.notes.isEmpty ? "Scene background plate." : background.notes,
                    path: background.resolvedApprovedImagePath
                )
            )
        }

        for character in sceneCharacters(for: scene) {
            let resolvedPath = character.approvedHeadTurnaroundSheetVariant?.imagePath
                ?? character.approvedMasterReferenceSheetVariant?.imagePath
            let detail = [
                "Asset slug \(character.assetFolderSlug)",
                character.preferredViewAngle.map { "Prefers \($0.rawValue)" }
            ]
            .compactMap { $0 }
            .joined(separator: " · ")

            entries.append(
                SceneAssetInventoryEntry(
                    title: character.name,
                    kind: "Character",
                    statusLabel: resolvedPath == nil ? "Needs refs" : "Referenced",
                    statusColor: resolvedPath == nil ? .orange : .green,
                    detail: detail.isEmpty ? "Scene character." : detail,
                    path: resolvedPath
                )
            )
        }

        for object in scene.objectSetups {
            let detail = [
                object.notes.isEmpty ? nil : object.notes,
                object.attachmentTarget.map { "Attached to \($0)" },
                "State \(object.initialState)"
            ]
            .compactMap { $0 }
            .joined(separator: " · ")

            entries.append(
                SceneAssetInventoryEntry(
                    title: object.objectName,
                    kind: "Object",
                    statusLabel: object.resolvedApprovedImagePath == nil ? "Needs art" : "Linked",
                    statusColor: object.resolvedApprovedImagePath == nil ? .orange : .green,
                    detail: detail.isEmpty ? "Scene object." : detail,
                    path: object.resolvedApprovedImagePath
                )
            )
        }

        return entries
    }

    private func assetStatusColor(
        _ status: AnimateAssetRequirementDatabase.Entry.Status
    ) -> Color {
        switch status {
        case .ready:
            return .green
        case .needsArt:
            return .orange
        case .needsDefinition:
            return .red
        }
    }

    private func assetDatabaseTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var resolutionLabel: String {
        if let resolution = store.animateMetadata?.resolution {
            return "\(resolution.width)×\(resolution.height)"
        }
        return "1920×1080"
    }

    private func seedTemplateIfNeeded(for scene: AnimationScene, force: Bool) {
        guard force || workspaceState.seededSceneID != scene.id || workspaceState.planJSONText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        workspaceState.planJSONText = sampleLLMPlanTemplate(for: scene)
        workspaceState.lastAppliedReport = nil
        workspaceState.lastDialogueVisemePreview = nil
        workspaceState.lastDialogueVisemePreviewPlanText = ""
        workspaceState.seededSceneID = scene.id
    }

    private func prepareSceneWorkspace(for scene: AnimationScene) async {
        await store.loadSongData(for: scene)
        autoSeedShotsIfNeeded(for: scene)
    }

    private func autoSeedShotsIfNeeded(for scene: AnimationScene) {
        guard scene.id == store.selectedSceneID,
              scene.shots.isEmpty else {
            return
        }

        let lyrics = currentLyrics(for: scene)
        guard !lyrics.isEmpty else { return }

        let parseResult = SceneDirectionParser.parse(lyrics)
        let seeded = shotSeedingService.seededShots(
            for: scene,
            songData: store.currentSongData,
            parseResult: parseResult
        )

        guard !seeded.isEmpty else { return }

        store.replaceSelectedSceneShots(seeded)
        store.save()
        workspaceState.lastShotSeedReport = shotSeedReport(for: scene, lyrics: lyrics, parseResult: parseResult)
        store.statusMessage = "Loaded \(seeded.count) scene-local shots from the libretto"
    }

    private func refreshAssetRequirementsDatabase() async {
        guard !workspaceState.isRefreshingAssetRequirements else { return }
        workspaceState.isRefreshingAssetRequirements = true
        let database = await assetRequirementsService.buildDatabase()
        workspaceState.lastAssetRequirementsDatabase = database
        workspaceState.isRefreshingAssetRequirements = false
    }

    private func sampleLLMPlanTemplate(for scene: AnimationScene) -> String {
        let cast = sceneCharacters(for: scene)
        let backgroundName = backgroundPlate(for: scene)?.name
        let placements = cast.enumerated().map { offset, character in
            LLMCharacterPlacement(
                characterName: character.name,
                frame: 0,
                position: LLMAnimationPoint(
                    x: min(0.8, max(0.2, 0.25 + (Double(offset) * 0.18))),
                    y: 0.58
                ),
                facing: offset.isMultiple(of: 2) ? .right : .left,
                viewAngle: .front,
                pose: .neutral,
                emotion: "neutral",
                zOrder: offset + 1
            )
        }

        let plan = LLMAnimationPlan(
            sceneName: scene.name,
            backgroundName: backgroundName,
            lighting: "Set this from the scene’s dramatic time-of-day and practical sources.",
            sceneAudioPath: scene.defaultAudioPath,
            characterPlacements: placements,
            objectPlacements: [],
            motions: [],
            objectMotions: [],
            expressions: [],
            dialogueBeats: [],
            shadowCues: [],
            objectStateCues: [],
            cameraMoves: [],
            shotPresetApplications: [],
            notes: [
                "Use normalized 0...1 coordinates.",
                "Prefer reusable package coverage over bespoke one-off poses.",
                "Treat props and set dressing as first-class scene objects with stable objectName values.",
                "Use attachmentTarget as bare character name or character/object/world-prefixed target when objects are held, attached, or explicitly detached with attachmentTarget=none.",
                "Only request new angles / expressions / visemes when the package does not cover the beat.",
                "If scene shots are already authored, align camera and blocking changes to those shot boundaries.",
                "Use shotName plus frameOffset/startFrameOffset/endFrameOffset when you want to target authored shots instead of raw frame numbers."
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(plan),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func inferredShotRow(_ shot: AnimationSceneShot, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(shot.name.isEmpty ? "Shot \(index + 1)" : shot.name)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(sceneLocalTimecode(for: shot.startFrame)) → \(sceneLocalTimecode(for: shot.endFrame))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }

            HStack(spacing: 8) {
                if let cameraShot = shot.cameraShot {
                    infoChip(cameraShot.displayName, color: .blue)
                }
                if let shotIntent = shot.shotIntent {
                    infoChip(shotIntent.displayName, color: .orange)
                }
                infoChip(shot.source.displayName, color: .secondary)
            }

            if let excerpt = nonEmpty(shot.sourceLyricExcerpt) {
                Text(excerpt)
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
        )
    }

    private func authoredShotRow(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        index: Int,
        canMoveUp: Bool,
        canMoveDown: Bool
    ) -> some View {
        let isReviewFocused = isFocusedReviewShot(shot, in: scene)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Shot name", text: shotBinding(for: shot.id, defaultValue: shot.name, keyPath: \.name))
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Stepper(value: shotBinding(for: shot.id, defaultValue: shot.startFrame, keyPath: \.startFrame), in: 0...max(0, shot.endFrame)) {
                            Text("Start \(sceneLocalTimecode(for: shot.startFrame)) · F\(shot.startFrame)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        }

                        Stepper(value: shotBinding(for: shot.id, defaultValue: shot.endFrame, keyPath: \.endFrame), in: max(shot.startFrame, 0)...max(shot.startFrame, shotSegmentationService.sceneFrameCount(for: scene))) {
                            Text("End \(sceneLocalTimecode(for: shot.endFrame)) · F\(shot.endFrame)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        }
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Button {
                            store.currentFrame = shot.startFrame
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button {
                            moveShot(shot.id, by: -1)
                        } label: {
                            Image(systemName: "arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(!canMoveUp)

                        Button {
                            moveShot(shot.id, by: 1)
                        } label: {
                            Image(systemName: "arrow.down")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(!canMoveDown)

                        Button {
                            duplicateShot(shot.id)
                        } label: {
                            Image(systemName: "plus.square.on.square")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)

                        Button(role: .destructive) {
                            removeShot(shot.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }

                    Button(isReviewFocused ? "Review Focused" : "Review Shot") {
                        focusReview(on: shot, in: scene)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(isReviewFocused ? .accentColor : .secondary)

                    Text("Shot \(index + 1)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            }

            HStack(spacing: 10) {
                cameraShotPicker(shot: shot)
                shotIntentPicker(shot: shot)
            }

            HStack(spacing: 10) {
                shotFocusPicker(scene: scene, shot: shot)
                shotPresetPicker(shot: shot)
            }

            TextField("Notes", text: shotBinding(for: shot.id, defaultValue: shot.notes, keyPath: \.notes))
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 8) {
                infoChip(shot.source.displayName, color: .secondary)

                if let line = shot.sourceLineNumber {
                    infoChip("Line \(line)", color: .purple)
                }

                infoChip(sceneLocalTimecode(for: shot.startFrame), color: .blue)
                infoChip(sceneLocalTimecode(for: shot.endFrame), color: .mint)

                if isReviewFocused {
                    infoChip("Review focus", color: .mint)
                }

                if let excerpt = nonEmpty(shot.sourceLyricExcerpt) {
                    Text(excerpt)
                        .font(.caption2)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.55))
        )
    }

    private func cameraShotPicker(shot: AnimationSceneShot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Camera")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OperaChromeTheme.textSecondary)

            Picker("Camera", selection: shotBinding(for: shot.id, defaultValue: shot.cameraShot, keyPath: \.cameraShot)) {
                Text("Inherit").tag(CameraShot?.none)
                ForEach(availableCameraShots, id: \.self) { option in
                    Text(option.displayName).tag(Optional(option))
                }
            }
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shotIntentPicker(shot: AnimationSceneShot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Intent")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OperaChromeTheme.textSecondary)

            Picker("Intent", selection: shotBinding(for: shot.id, defaultValue: shot.shotIntent, keyPath: \.shotIntent)) {
                Text("Unspecified").tag(ShotIntent?.none)
                ForEach(ShotIntent.allCases, id: \.self) { option in
                    Text(option.displayName).tag(Optional(option))
                }
            }
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shotFocusPicker(scene: AnimationScene, shot: AnimationSceneShot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Focus")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OperaChromeTheme.textSecondary)

            Picker("Focus", selection: shotBinding(for: shot.id, defaultValue: shot.focusCharacterID, keyPath: \.focusCharacterID)) {
                Text("Unspecified").tag(UUID?.none)
                ForEach(sceneCharacters(for: scene)) { character in
                    Text(character.name).tag(Optional(character.id))
                }
            }
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shotPresetPicker(shot: AnimationSceneShot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preset")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(OperaChromeTheme.textSecondary)

            Picker("Preset", selection: shotBinding(for: shot.id, defaultValue: shot.presetID, keyPath: \.presetID)) {
                Text("None").tag(UUID?.none)
                ForEach(store.shotPresets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shotBinding<Value>(
        for shotID: UUID,
        defaultValue: Value,
        keyPath: WritableKeyPath<AnimationSceneShot, Value>
    ) -> Binding<Value> {
        Binding(
            get: {
                guard let scene = store.selectedScene,
                      let shot = scene.shots.first(where: { $0.id == shotID }) else {
                    return defaultValue
                }
                return shot[keyPath: keyPath]
            },
            set: { newValue in
                store.updateSelectedSceneShots { shots in
                    guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
                    shots[index][keyPath: keyPath] = newValue
                }
            }
        )
    }

    private func moveShot(_ shotID: UUID, by offset: Int) {
        store.updateSelectedSceneShots { shots in
            guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
            let targetIndex = index + offset
            guard shots.indices.contains(targetIndex) else { return }
            let shot = shots.remove(at: index)
            shots.insert(shot, at: targetIndex)
        }
        store.save()
    }

    private func duplicateShot(_ shotID: UUID) {
        store.updateSelectedSceneShots { shots in
            guard let index = shots.firstIndex(where: { $0.id == shotID }) else { return }
            var duplicate = shots[index]
            duplicate.id = UUID()
            duplicate.name = duplicate.name.isEmpty ? "Shot Copy" : "\(duplicate.name) Copy"
            shots.insert(duplicate, at: index + 1)
        }
        store.save()
    }

    private func removeShot(_ shotID: UUID) {
        store.updateSelectedSceneShots { shots in
            shots.removeAll { $0.id == shotID }
        }
        if workspaceState.reviewFocusedShotID == shotID {
            clearFocusedReviewShot()
        }
        store.save()
    }

    private func focusReview(on shot: AnimationSceneShot, in scene: AnimationScene) {
        workspaceState.reviewFocusedSceneID = scene.id
        workspaceState.reviewFocusedShotID = shot.id
        workspaceState.selectedDockTab = .review
    }

    private func clearFocusedReviewShot() {
        workspaceState.reviewFocusedSceneID = nil
        workspaceState.reviewFocusedShotID = nil
    }

    private func focusedReviewShot(in scene: AnimationScene) -> AnimationSceneShot? {
        guard workspaceState.reviewFocusedSceneID == scene.id,
              let shotID = workspaceState.reviewFocusedShotID else {
            return nil
        }
        return scene.shots.first(where: { $0.id == shotID })
    }

    private func isFocusedReviewShot(_ shot: AnimationSceneShot, in scene: AnimationScene) -> Bool {
        workspaceState.reviewFocusedSceneID == scene.id && workspaceState.reviewFocusedShotID == shot.id
    }

    private func displayShotTitle(_ shot: AnimationSceneShot) -> String {
        if let title = nonEmpty(shot.name) {
            return title
        }
        return "Shot \(shot.startFrame)–\(shot.endFrame)"
    }

    private func focusedApplyEffects(
        for shot: AnimationSceneShot,
        preview: AnimatePlanApplyPreview
    ) -> FocusedApplyEffectGrouping {
        let shotID = shot.id.uuidString
        let shotEffects = preview.effects.filter {
            $0.shotContexts.count == 1 && $0.shotContexts[0].id == shotID
        }
        let crossShotEffects = preview.effects.filter {
            $0.shotContexts.count > 1 && $0.shotContexts.contains(where: { $0.id == shotID })
        }
        let sceneWideEffects = preview.effects.filter(\.shotContexts.isEmpty)
        return FocusedApplyEffectGrouping(
            shotTitle: displayShotTitle(shot),
            frameRangeLabel: "\(shot.startFrame)–\(shot.endFrame)",
            shotEffects: shotEffects,
            crossShotEffects: crossShotEffects,
            sceneWideEffects: sceneWideEffects
        )
    }

    @ViewBuilder
    private func focusedApplyEffectSections(
        for shot: AnimationSceneShot,
        grouping: FocusedApplyEffectGrouping
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filtered to \(grouping.shotTitle). Cross-shot and scene-wide effects are still shown because they can change the selected shot’s result.")
                .font(.caption2)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !grouping.shotEffects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("This shot")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouping.shotEffects.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouping.shotEffects) { effect in
                        applyEffectCard(effect, showShotContexts: false)
                    }
                }
            }

            if !grouping.crossShotEffects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Also spans other shots")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouping.crossShotEffects.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouping.crossShotEffects) { effect in
                        applyEffectCard(effect, showShotContexts: true)
                    }
                }
            }

            if !grouping.sceneWideEffects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Scene-wide effects")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouping.sceneWideEffects.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouping.sceneWideEffects) { effect in
                        applyEffectCard(effect, showShotContexts: true)
                    }
                }
            }

            if grouping.shotEffects.isEmpty && grouping.crossShotEffects.isEmpty && grouping.sceneWideEffects.isEmpty {
                Text("No current plan effects resolve into this shot.")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
        }
    }

    private func focusedDialogueVisemeEffects(
        for shot: AnimationSceneShot,
        preview: AnimateDialogueVisemePreview
    ) -> FocusedDialogueVisemeEffectGrouping {
        let shotID = shot.id.uuidString
        let shotEffects = preview.effects.filter {
            $0.shotContexts.count == 1 && $0.shotContexts[0].id == shotID
        }
        let crossShotEffects = preview.effects.filter {
            $0.shotContexts.count > 1 && $0.shotContexts.contains(where: { $0.id == shotID })
        }
        let sceneWideEffects = preview.effects.filter(\.shotContexts.isEmpty)
        return FocusedDialogueVisemeEffectGrouping(
            shotTitle: displayShotTitle(shot),
            frameRangeLabel: "\(shot.startFrame)–\(shot.endFrame)",
            shotEffects: shotEffects,
            crossShotEffects: crossShotEffects,
            sceneWideEffects: sceneWideEffects
        )
    }

    @ViewBuilder
    private func focusedDialogueVisemeSections(
        for shot: AnimationSceneShot,
        grouping: FocusedDialogueVisemeEffectGrouping
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filtered to \(grouping.shotTitle). Cross-shot and scene-wide viseme effects are still shown because they can affect readability through this shot.")
                .font(.caption2)
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !grouping.shotEffects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("This shot")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouping.shotEffects.count) beats · \(grouping.shotEffects.reduce(0) { $0 + $1.visemeCount }) visemes")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouping.shotEffects) { effect in
                        dialogueVisemeEffectCard(effect, showShotContexts: false)
                    }
                }
            }

            if !grouping.crossShotEffects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Also spans other shots")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouping.crossShotEffects.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouping.crossShotEffects) { effect in
                        dialogueVisemeEffectCard(effect, showShotContexts: true)
                    }
                }
            }

            if !grouping.sceneWideEffects.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Scene-wide viseme effects")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text("\(grouping.sceneWideEffects.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }

                    ForEach(grouping.sceneWideEffects) { effect in
                        dialogueVisemeEffectCard(effect, showShotContexts: true)
                    }
                }
            }

            if grouping.shotEffects.isEmpty && grouping.crossShotEffects.isEmpty && grouping.sceneWideEffects.isEmpty {
                Text("No current generated viseme side effects resolve into this shot.")
                    .font(.caption)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
        }
    }

    private func defaultManualShot(
        for scene: AnimationScene,
        existing: [AnimationSceneShot]
    ) -> AnimationSceneShot {
        let totalFrames = max(1, shotSegmentationService.sceneFrameCount(for: scene))
        let nextStart = min((existing.map(\.endFrame).max() ?? -1) + 1, max(0, totalFrames - 1))
        let nextEnd = min(nextStart + 47, max(nextStart, totalFrames - 1))
        return AnimationSceneShot(
            name: "Shot \(existing.count + 1)",
            startFrame: nextStart,
            endFrame: nextEnd,
            source: .manual,
            lockedBoundaries: true
        )
    }

    private func sceneShotsJSON(_ shots: [AnimationSceneShot]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(shots),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    private func sceneAudioTimelineSummary(for scene: AnimationScene) -> SceneAudioTimelineSummary {
        let sceneFrameCount = max(shotSegmentationService.sceneFrameCount(for: scene), 1)
        let songFrameCount: Int? = {
            guard store.selectedSceneID == scene.id,
                  let songData = store.currentSongData,
                  songData.lengthTicks > 0 else { return nil }
            return max(songData.tickToFrame(songData.lengthTicks, fps: store.fps), 1)
        }()

        let audioURL = store.suggestedExportAudioURL(for: scene)
        let audioPath = audioURL?.path
        let audioDurationSeconds = audioPath.flatMap { audioWaveformCache.durationSeconds(for: $0) }
        let audioFrameCount = audioDurationSeconds.map { max(Int(($0 * Double(store.fps)).rounded(.up)), 1) }
        let timelineFrameCount = max(sceneFrameCount, songFrameCount ?? 0, audioFrameCount ?? 0, 1)

        let basisLabel: String = {
            if audioFrameCount != nil { return "Audio-led timing" }
            if songFrameCount != nil { return "Song-data timing" }
            return scene.shots.isEmpty ? "Scene-shot timing" : "Authored-shot timing"
        }()

        let durationLabel: String = {
            if let audioFrameCount {
                return "\(sceneLocalTimecode(for: audioFrameCount)) · \(audioFrameCount)f"
            }
            if let songFrameCount {
                return "\(sceneLocalTimecode(for: songFrameCount)) · \(songFrameCount)f"
            }
            return "\(sceneLocalTimecode(for: timelineFrameCount)) · \(timelineFrameCount)f"
        }()

        return SceneAudioTimelineSummary(
            audioPath: audioPath,
            audioName: audioURL?.lastPathComponent ?? scene.defaultAudioPath ?? scene.owpSongPath,
            audioDurationSeconds: audioDurationSeconds,
            songFrameCount: songFrameCount,
            timelineFrameCount: timelineFrameCount,
            basisLabel: basisLabel,
            durationLabel: durationLabel
        )
    }

    private func sceneLocalTimecode(for frame: Int) -> String {
        let clampedFrame = max(frame, 0)
        guard store.fps > 0 else { return "00:00.00" }
        let totalSeconds = clampedFrame / store.fps
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let frameComponent = clampedFrame % store.fps
        let frameDigits = max(2, String(max(store.fps - 1, 0)).count)
        return String(format: "%02d:%02d.%0*d", minutes, seconds, frameDigits, frameComponent)
    }

    private func playheadX(for frame: Int, width: CGFloat, frameCount: Int) -> CGFloat {
        let maxFrame = max(frameCount - 1, 0)
        guard maxFrame > 0 else { return 0 }
        return width * CGFloat(min(max(frame, 0), maxFrame)) / CGFloat(maxFrame)
    }

    private func frameIndex(for locationX: CGFloat, width: CGFloat, frameCount: Int) -> Int {
        let maxFrame = max(frameCount - 1, 0)
        guard maxFrame > 0 else { return 0 }
        let clampedX = min(max(locationX, 0), width)
        return min(max(Int((clampedX / width * CGFloat(maxFrame)).rounded()), 0), maxFrame)
    }

    private func waveformPlaceholder(title: String, subtitle: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    OperaChromeTheme.raisedBackground.opacity(0.92),
                    OperaChromeTheme.panelBackground.opacity(0.82)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            VStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func timelineFallbackBed(
        width: CGFloat,
        height: CGFloat,
        frameCount: Int,
        title: String,
        subtitle: String
    ) -> some View {
        let tickCount = max(8, min(24, max(frameCount / max(store.fps, 1), 8)))

        return ZStack {
            LinearGradient(
                colors: [
                    OperaChromeTheme.raisedBackground.opacity(0.92),
                    OperaChromeTheme.panelBackground.opacity(0.84)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            HStack(spacing: 0) {
                ForEach(0..<tickCount, id: \.self) { index in
                    Rectangle()
                        .fill(Color.white.opacity(index.isMultiple(of: 4) ? 0.12 : 0.05))
                        .frame(width: index == tickCount - 1 ? 1 : 0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 10)

            VStack(spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func shotSeedReport(
        for scene: AnimationScene,
        lyrics: String,
        parseResult: SceneDirectionParser.ParseResult?
    ) -> AnimateShotSeedReport {
        let effectiveParseResult = lyrics.isEmpty ? nil : parseResult
        return shotSeedingService.seedReport(
            for: scene,
            songData: store.currentSongData,
            parseResult: effectiveParseResult
        )
    }

    private func shotSeedReportJSON(_ report: AnimateShotSeedReport) -> String {
        shotSeedingService.seedReportJSON(report)
    }

    private func makeShotAnchorSummary(for scene: AnimationScene, plan: LLMAnimationPlan) -> ShotAnchorSummary {
        let labels = (
            plan.characterPlacements.compactMap(\.shotName) +
            plan.objectPlacements.compactMap(\.shotName) +
            plan.motions.compactMap(\.shotName) +
            plan.objectMotions.compactMap(\.shotName) +
            plan.expressions.compactMap(\.shotName) +
            plan.dialogueBeats.compactMap(\.shotName) +
            plan.shadowCues.compactMap(\.shotName) +
            plan.objectStateCues.compactMap(\.shotName) +
            plan.cameraMoves.compactMap(\.shotName) +
            plan.shotPresetApplications.compactMap(\.shotName)
        )
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        let resolverIssues = AnimatePlanShotAnchorResolver(store: store)
            .resolve(plan, for: scene)
            .issues
            .filter { $0.code == .unknownShotAnchor || $0.code == .ambiguousShotAnchor }
            .map(\.message)

        let placementAnchorCount = plan.characterPlacements.filter { $0.shotID != nil || $0.shotName != nil }.count
        let objectPlacementAnchorCount = plan.objectPlacements.filter { $0.shotID != nil || $0.shotName != nil }.count
        let motionAnchorCount = plan.motions.filter { $0.shotID != nil || $0.shotName != nil }.count
        let objectMotionAnchorCount = plan.objectMotions.filter { $0.shotID != nil || $0.shotName != nil }.count
        let expressionAnchorCount = plan.expressions.filter { $0.shotID != nil || $0.shotName != nil }.count
        let dialogueAnchorCount = plan.dialogueBeats.filter { $0.shotID != nil || $0.shotName != nil }.count
        let shadowAnchorCount = plan.shadowCues.filter { $0.shotID != nil || $0.shotName != nil }.count
        let objectStateAnchorCount = plan.objectStateCues.filter { $0.shotID != nil || $0.shotName != nil }.count
        let cameraAnchorCount = plan.cameraMoves.filter { $0.shotID != nil || $0.shotName != nil }.count
        let presetAnchorCount = plan.shotPresetApplications.filter { $0.shotID != nil || $0.shotName != nil }.count
        let referenceCount = placementAnchorCount + objectPlacementAnchorCount + motionAnchorCount + objectMotionAnchorCount + expressionAnchorCount + dialogueAnchorCount + shadowAnchorCount + objectStateAnchorCount + cameraAnchorCount + presetAnchorCount

        return ShotAnchorSummary(
            referenceCount: referenceCount,
            uniqueShotLabels: Array(Set(labels)).sorted(),
            warnings: resolverIssues
        )
    }

    private func seedShotsFromScript(for scene: AnimationScene) {
        Task { @MainActor in
            await store.loadSongData(for: scene)
            let lyrics = currentLyrics(for: scene)
            let parseResult = lyrics.isEmpty ? nil : SceneDirectionParser.parse(lyrics)
            let report = shotSeedReport(for: scene, lyrics: lyrics, parseResult: parseResult)
            workspaceState.lastShotSeedReport = report

            let seeded = shotSeedingService.seededShots(
                for: scene,
                songData: store.currentSongData,
                parseResult: parseResult
            )

            guard !seeded.isEmpty else {
                store.statusMessage = "No script-seeded shots could be derived"
                return
            }

            store.replaceSelectedSceneShots(seeded)
            store.save()
            store.statusMessage = "Seeded \(seeded.count) scene shots from script"
        }
    }

    private var availableCameraShots: [CameraShot] {
        [.extremeWide, .wide, .medium, .mediumClose, .close, .extremeClose]
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private var parsedPlanResult: (plan: LLMAnimationPlan?, error: Error?)? {
        let trimmed = workspaceState.planJSONText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            let plan = try LLMAnimationPlanCompiler().parse(json: trimmed)
            return (plan, nil)
        } catch {
            return (nil, error)
        }
    }

    private func currentDialogueVisemePreview(
        for scene: AnimationScene
    ) -> AnimateDialogueVisemePreview? {
        let currentPlanText = workspaceState.planJSONText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard workspaceState.lastDialogueVisemePreviewPlanText == currentPlanText,
              workspaceState.lastDialogueVisemePreview?.sceneID == scene.id.uuidString else {
            return nil
        }
        return workspaceState.lastDialogueVisemePreview
    }

    private func previewDialogueVisemeEffects(for scene: AnimationScene) {
        guard parsedPlanResult?.plan != nil else { return }
        let currentPlanText = workspaceState.planJSONText.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaceState.isPreviewingDialogueVisemes = true

        Task {
            let preview = await orchestrationService.dialogueVisemePreview(for: scene)
            await MainActor.run {
                workspaceState.lastDialogueVisemePreview = preview
                workspaceState.lastDialogueVisemePreviewPlanText = currentPlanText
                workspaceState.isPreviewingDialogueVisemes = false
            }
        }
    }

    private func applyPlan(generateDialogue: Bool) {
        guard let plan = parsedPlanResult?.plan else { return }

        if generateDialogue {
            workspaceState.isApplyingDialoguePlan = true
            Task {
                let report = await store.applyLLMAnimationPlanIncludingGeneratedDialogue(plan)
                await MainActor.run {
                    workspaceState.lastAppliedReport = report
                    workspaceState.isApplyingDialoguePlan = false
                }
            }
        } else {
            workspaceState.lastAppliedReport = store.applyLLMAnimationPlan(plan)
        }
    }

    private func scriptMigrationPrompt(for scene: AnimationScene) -> String {
        orchestrationService.scriptMigrationPrompt(for: scene)
    }

    private func librettoPromptOverrides(for scene: AnimationScene) -> AnimateLibrettoPromptOverrides {
        workspaceState.librettoPromptOverridesBySceneID[scene.id.uuidString] ?? .init()
    }

    private func librettoPromptOverrideBinding(
        for scene: AnimationScene,
        keyPath: WritableKeyPath<AnimateLibrettoPromptOverrides, String>
    ) -> Binding<String> {
        let sceneKey = scene.id.uuidString
        return Binding(
            get: { workspaceState.librettoPromptOverridesBySceneID[sceneKey]?[keyPath: keyPath] ?? "" },
            set: { newValue in
                var overrides = workspaceState.librettoPromptOverridesBySceneID[sceneKey] ?? .init()
                overrides[keyPath: keyPath] = newValue
                workspaceState.librettoPromptOverridesBySceneID[sceneKey] = overrides
            }
        )
    }

    private func librettoAuthorOperatorTemplate() -> String {
        orchestrationService.librettoAuthorOperatorTemplate()
    }

    private func librettoAuthorOperatorPrompt(for scene: AnimationScene) -> String {
        let lyrics = currentLyrics(for: scene)
        let parseResult = lyrics.isEmpty ? nil : SceneDirectionParser.parse(lyrics)
        let packet = sceneSyncPacket(for: scene, lyrics: lyrics, parseResult: parseResult)
        return orchestrationService.librettoAuthorOperatorPrompt(
            for: packet,
            overrides: librettoPromptOverrides(for: scene)
        )
    }

    private func currentLyrics(for scene: AnimationScene) -> String {
        guard scene.id == store.selectedSceneID else { return "" }
        guard let text = store.currentSongData?.extractLyrics() else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func lyricsLineCount(_ lyrics: String) -> Int {
        guard !lyrics.isEmpty else { return 0 }
        return lyrics.components(separatedBy: .newlines).count
    }

    private func sceneSyncPacketJSON(
        for scene: AnimationScene,
        lyrics: String,
        parseResult: SceneDirectionParser.ParseResult?
    ) -> String {
        orchestrationService.sceneSyncPacketJSON(
            sceneSyncPacket(for: scene, lyrics: lyrics, parseResult: parseResult)
        )
    }

    private func sceneSyncPacket(
        for scene: AnimationScene,
        lyrics: String,
        parseResult: SceneDirectionParser.ParseResult?
    ) -> AnimateSceneSyncPacket {
        orchestrationService.sceneSyncPacket(for: scene, lyrics: lyrics, parseResult: parseResult)
    }

    private var jsonKeyGuide: String {
        """
        {
          "sceneName": "Scene Name",
          "backgroundName": "Approved place name",
          "lighting": "short lighting phrase",
          "sceneAudioPath": "optional path",
          "characterPlacements": [{"frame": 0, "shotName": "Optional Shot", "frameOffset": 0, ...}],
          "objectPlacements": [{"frame": 0, "objectName": "lantern", "shotName": "Optional Shot", "frameOffset": 0, "attachmentTarget": "character:amira:hand_right", ...}],
          "motions": [{"startFrame": 0, "endFrame": 24, "shotName": "Optional Shot", "startFrameOffset": 0, "endFrameOffset": 0, ...}],
          "objectMotions": [{"startFrame": 0, "objectName": "lantern", "shotName": "Optional Shot", "startFrameOffset": 0, "endFrameOffset": 0, "attachmentTarget": "object:tea-tray:top", ...}],
          "expressions": [{"frame": 0, "shotName": "Optional Shot", "frameOffset": 0, ...}],
          "dialogueBeats": [{"startFrame": 0, "shotName": "Optional Shot", "frameOffset": 0, ...}],
          "shadowCues": [{"frame": 0, "shotName": "Optional Shot", "frameOffset": 0, ...}],
          "objectStateCues": [{"frame": 0, "objectName": "lantern", "shotName": "Optional Shot", "frameOffset": 0, "attachmentTarget": "none", ...}],
          "cameraMoves": [{"startFrame": 0, "endFrame": 24, "shotName": "Optional Shot", "startFrameOffset": 0, "endFrameOffset": 0, ...}],
          "shotPresetApplications": [{"frame": 0, "shotName": "Optional Shot", "frameOffset": 0, ...}],
          "notes": ["warnings or asset asks"]
        }
        """
    }

    private func trackRoleSummaries(for scene: AnimationScene) -> [TrackRoleSummary] {
        let counts = Dictionary(grouping: store.orderedTimelineTracks(for: scene)) { track in
            track.role ?? .custom
        }

        return counts
            .map { role, tracks in
                TrackRoleSummary(
                    id: role.rawValue,
                    title: role.displayLabel,
                    count: tracks.count,
                    color: trackRoleColor(role)
                )
            }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.title < rhs.title
                }
                return lhs.count > rhs.count
            }
    }

    private func trackRoleColor(_ role: TimelineTrackRole) -> Color {
        switch role {
        case .transform: .cyan
        case .visibility: .teal
        case .facing, .view, .pose: .blue
        case .expression, .mouth, .action: .pink
        case .shadowStyle, .shadowOpacity: .orange
        case .camera, .cameraShot, .cameraDefaultShot, .cameraFocus, .cameraIntent, .cameraBeat, .cameraNotes:
            .purple
        case .drawing: .green
        case .custom: .secondary
        }
    }

    private func readinessColor(_ readiness: SceneAutomationReadiness) -> Color {
        switch readiness {
        case .missing: .red
        case .partial: .orange
        case .ready: .green
        }
    }

    private func effectiveModeColor(_ mode: SceneExecutionMode) -> Color {
        switch mode {
        case .autoRecommend: .blue
        case .animateKitOnly: .green
        case .hybrid: .orange
        case .generativeAssist: .purple
        }
    }

    private func copyToPasteboard(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        store.statusMessage = "Copied to clipboard"
    }
}

@available(macOS 26.0, *)
private struct SceneAssetInventoryEntry: Identifiable {
    let id = UUID()
    let title: String
    let kind: String
    let statusLabel: String
    let statusColor: Color
    let detail: String
    let path: String?
}

@available(macOS 26.0, *)
private struct FlexibleChipList: View {
    let items: [String]
    let color: Color

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Capsule(style: .continuous)
                            .fill(color.opacity(0.12))
                    )
            }
        }
    }
}

@available(macOS 26.0, *)
private struct TrackRoleSummary: Identifiable {
    let id: String
    let title: String
    let count: Int
    let color: Color
}

@available(macOS 26.0, *)
private struct AnimateSubsystemReadinessMetric: Identifiable {
    let id = UUID()
    let title: String
    let score: Double
    let readiness: SceneAutomationReadiness
    let detail: String

    var color: Color {
        switch readiness {
        case .missing: .red
        case .partial: .orange
        case .ready: .green
        }
    }
}

@available(macOS 26.0, *)
private struct ShotAnchorSummary {
    let referenceCount: Int
    let uniqueShotLabels: [String]
    let warnings: [String]
}

@available(macOS 26.0, *)
private struct ApplyEffectShotGroup: Identifiable {
    let id: String
    let title: String
    let frameRangeLabel: String
    let effects: [AnimatePlanApplyPreview.Effect]
}

@available(macOS 26.0, *)
private struct ApplyEffectGrouping {
    let shotGroups: [ApplyEffectShotGroup]
    let crossShotEffects: [AnimatePlanApplyPreview.Effect]
    let sceneWideEffects: [AnimatePlanApplyPreview.Effect]
}

@available(macOS 26.0, *)
private struct DialogueVisemeShotGroup: Identifiable {
    let id: String
    let title: String
    let frameRangeLabel: String
    let effects: [AnimateDialogueVisemePreview.Effect]
}

@available(macOS 26.0, *)
private struct DialogueVisemeEffectGrouping {
    let shotGroups: [DialogueVisemeShotGroup]
    let crossShotEffects: [AnimateDialogueVisemePreview.Effect]
    let sceneWideEffects: [AnimateDialogueVisemePreview.Effect]
}

@available(macOS 26.0, *)
private struct SceneAudioTimelineSummary {
    let audioPath: String?
    let audioName: String?
    let audioDurationSeconds: Double?
    let songFrameCount: Int?
    let timelineFrameCount: Int
    let basisLabel: String
    let durationLabel: String
}

@available(macOS 26.0, *)
private struct FocusedApplyEffectGrouping {
    let shotTitle: String
    let frameRangeLabel: String
    let shotEffects: [AnimatePlanApplyPreview.Effect]
    let crossShotEffects: [AnimatePlanApplyPreview.Effect]
    let sceneWideEffects: [AnimatePlanApplyPreview.Effect]

    var actionableEffectCount: Int {
        (shotEffects + crossShotEffects + sceneWideEffects)
            .filter { $0.changeKind != .noChange }
            .count
    }
}

@available(macOS 26.0, *)
private struct FocusedDialogueVisemeEffectGrouping {
    let shotTitle: String
    let frameRangeLabel: String
    let shotEffects: [AnimateDialogueVisemePreview.Effect]
    let crossShotEffects: [AnimateDialogueVisemePreview.Effect]
    let sceneWideEffects: [AnimateDialogueVisemePreview.Effect]
}

@available(macOS 26.0, *)
private struct AnimationPreviewImageView: View {
    @Bindable var store: AnimateStore
    let scene: AnimationScene
    let previewMode: AnimationCanvasPreviewMode

    @State private var renderedImage: NSImage?
    @State private var lastRenderedKey = ""

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.opacity(0.92)

                if let renderedImage {
                    Image(nsImage: renderedImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            .task(id: renderKey(for: proxy.size)) {
                await renderPreview(for: proxy.size)
            }
            .onChange(of: store.currentFrame) { _, _ in
                Task { await renderPreview(for: proxy.size) }
            }
            .onChange(of: store.selectedSceneID) { _, _ in
                Task { await renderPreview(for: proxy.size) }
            }
        }
    }

    private func renderKey(for size: CGSize) -> String {
        [
            scene.id.uuidString,
            previewMode.rawValue,
            "\(store.currentFrame)",
            "\(Int(renderSize(for: size).width.rounded()))x\(Int(renderSize(for: size).height.rounded()))"
        ].joined(separator: "|")
    }

    @MainActor
    private func renderPreview(for size: CGSize) async {
        let renderKey = renderKey(for: size)
        guard renderKey != lastRenderedKey else { return }
        guard size.width > 1, size.height > 1 else { return }
        let renderSize = renderSize(for: size)

        lastRenderedKey = renderKey
        renderedImage = AnimationPreviewSnapshotExporter.renderImage(
            store: store,
            scene: scene,
            frame: store.currentFrame,
            mode: previewMode == .live ? .live : .placeholder,
            size: renderSize
        )
    }

    private func renderSize(for size: CGSize) -> CGSize {
        if let resolution = store.animateMetadata?.resolution,
           resolution.width > 0,
           resolution.height > 0 {
            let aspectRatio = CGFloat(resolution.width) / CGFloat(resolution.height)
            let targetWidth = min(CGFloat(resolution.width), max(960, size.width * 1.5))
            let targetHeight = max(1, targetWidth / aspectRatio)
            return CGSize(width: targetWidth.rounded(.up), height: targetHeight.rounded(.up))
        }

        let fallbackWidth = max(960, size.width * 1.5)
        let fallbackHeight = max(1, fallbackWidth * 9.0 / 16.0)
        return CGSize(width: fallbackWidth.rounded(.up), height: fallbackHeight.rounded(.up))
    }
}
