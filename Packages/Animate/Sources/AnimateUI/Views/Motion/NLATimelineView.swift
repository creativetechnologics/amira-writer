import SwiftUI
import UniformTypeIdentifiers

/// Main NLA timeline view. Lives in the Motion dock tab.
/// Vertical stack of track lanes with horizontal scrolling time ruler.
@available(macOS 26.0, *)
struct NLATimelineView: View {
    @Bindable var store: AnimateStore
    @State private var selectedTrackID: UUID?
    @State private var pixelsPerFrame: CGFloat = 4.0
    @State private var scrollOffset: CGFloat = 0
    @State private var showTrackInspector = false

    /// Map of motion clip UUID to display name, provided by parent.
    var clipNames: [UUID: String] = [:]

    private var timeline: NLATimeline {
        store.nlaTimeline ?? NLATimeline()
    }

    private var totalFrames: Int {
        max(timeline.totalFrames, store.totalFrames, 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar

            Divider()

            if timeline.tracks.isEmpty {
                emptyState
            } else {
                HSplitView {
                    // Timeline area
                    timelineArea
                        .frame(minWidth: 300)

                    // Track inspector (when a track is selected)
                    if showTrackInspector, let trackID = selectedTrackID,
                       let trackIndex = timeline.trackIndex(for: trackID) {
                        trackInspector(trackIndex: trackIndex)
                            .frame(width: 260)
                    }
                }
            }

            // Video import progress overlay
            if store._isImportingVideo {
                videoImportProgressOverlay
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Keyboard shortcuts — attached to the non-TextEditor container
        .focusable()
        .onKeyPress(.space) {
            store.togglePlayback()
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            switch press.key {
            case .leftArrow:
                if press.modifiers.contains(.shift) {
                    store.stepFrame(delta: -10)
                } else {
                    store.stepFrame(delta: -1)
                }
                return .handled
            case .rightArrow:
                if press.modifiers.contains(.shift) {
                    store.stepFrame(delta: 10)
                } else {
                    store.stepFrame(delta: 1)
                }
                return .handled
            case "=", "+":
                if press.modifiers.contains(.command) {
                    pixelsPerFrame = min(20, pixelsPerFrame * 1.25)
                    return .handled
                }
                return .ignored
            case "-":
                if press.modifiers.contains(.command) {
                    pixelsPerFrame = max(1, pixelsPerFrame / 1.25)
                    return .handled
                }
                return .ignored
            default:
                return .ignored
            }
        }
        // Accept video file drops
        .onDrop(of: [UTType.movie, UTType.mpeg4Movie], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    await store.importVideoToTimeline(url: url)
                }
            }
            return true
        }
    }

    // MARK: - Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 12) {
            // Add track button
            Menu {
                Button("Webcam Track") { addTrack(colorTag: .webcam) }
                Button("AI Motion Track") { addTrack(colorTag: .ai) }
                Button("Imported BVH Track") { addTrack(colorTag: .imported) }
                Button("Manual Track") { addTrack(colorTag: .manual) }
            } label: {
                Label("Add Track", systemImage: "plus")
                    .font(.system(size: 11))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Divider().frame(height: 16)

            // Zoom controls
            HStack(spacing: 4) {
                Button {
                    pixelsPerFrame = max(1, pixelsPerFrame / 1.5)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.plain)

                Text("\(Int(pixelsPerFrame))px/f")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 40)

                Button {
                    pixelsPerFrame = min(20, pixelsPerFrame * 1.5)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.plain)
            }

            Divider().frame(height: 16)

            // Track inspector toggle
            Toggle(isOn: $showTrackInspector) {
                Label("Inspector", systemImage: "sidebar.right")
                    .font(.system(size: 11))
            }
            .toggleStyle(.button)
            .disabled(selectedTrackID == nil)

            Spacer()

            // Track count
            Text("\(timeline.tracks.count) tracks")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    // MARK: - Timeline Area

    @ViewBuilder
    private var timelineArea: some View {
        VStack(spacing: 0) {
            // Time ruler
            NLATimeRulerView(
                totalFrames: totalFrames,
                fps: timeline.fps > 0 ? timeline.fps : store.fps,
                currentFrame: store.currentFrame,
                pixelsPerFrame: pixelsPerFrame,
                scrollOffset: scrollOffset,
                onSeek: { frame in
                    store.currentFrame = frame
                    store.evaluateNLAAtCurrentFrame()
                }
            )

            Divider()

            // Track lanes (scrollable)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // Track lane backgrounds + clip rectangles
                    VStack(spacing: 0) {
                        ForEach(timeline.sortedTracks) { track in
                            trackLane(track: track)
                        }
                    }

                    // Playhead line (spans full height)
                    let playheadX = CGFloat(store.currentFrame) * pixelsPerFrame
                    Rectangle()
                        .fill(Color.red.opacity(0.6))
                        .frame(width: 1)
                        .offset(x: 200 + playheadX)  // 200 = header width
                }
            }
            .onAppear {
                scrollOffset = 0
            }
            // Pinch to zoom
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let newPPF = pixelsPerFrame * value.magnification
                        pixelsPerFrame = max(1, min(20, newPPF))
                    }
            )
        }
    }

    // MARK: - Track Lane

    @ViewBuilder
    private func trackLane(track: NLATrack) -> some View {
        let isSelected = selectedTrackID == track.id
        let sortedClips = track.clips.sorted { $0.startFrame < $1.startFrame }

        HStack(spacing: 0) {
            // Track header
            NLATrackHeaderView(
                track: binding(for: track.id),
                isSelected: isSelected,
                onDelete: { deleteTrack(id: track.id) }
            )
            .onTapGesture {
                selectedTrackID = track.id
            }

            // Clip area
            ZStack(alignment: .leading) {
                // Background
                Rectangle()
                    .fill(isSelected
                        ? Color.accentColor.opacity(0.04)
                        : Color(nsColor: .controlBackgroundColor).opacity(0.3))

                // Crossfade overlays for overlapping consecutive clips
                crossfadeOverlays(for: sortedClips, pixelsPerFrame: pixelsPerFrame, trackHeight: 40)

                // Clips with context menu
                ForEach(track.clips) { clip in
                    NLAClipRectangleView(
                        clip: clip,
                        clipName: clipNames[clip.motionClipID] ?? "Clip",
                        colorTag: track.colorTag,
                        pixelsPerFrame: pixelsPerFrame,
                        totalTimelineFrames: totalFrames,
                        motionClipFrameCount: motionClipFrameCount(for: clip.motionClipID),
                        onMove: { clipID, newStart in
                            moveClip(trackID: track.id, clipID: clipID, newStartFrame: newStart)
                        }
                    )
                    .contextMenu {
                        Menu("Speed") {
                            Button("0.25x") { store.setClipSpeed(clipID: clip.id, speed: 0.25) }
                            Button("0.5x")  { store.setClipSpeed(clipID: clip.id, speed: 0.5) }
                            Button("1x")    { store.setClipSpeed(clipID: clip.id, speed: 1.0) }
                            Button("2x")    { store.setClipSpeed(clipID: clip.id, speed: 2.0) }
                        }
                        Divider()
                        Button("Export as BVH...") {
                            store.exportClipAsBVH(clipID: clip.motionClipID)
                        }
                        Button("Remove from Track") {
                            removeClipFromTrack(trackID: track.id, clipID: clip.id)
                        }
                    }
                }
            }
            .frame(width: CGFloat(totalFrames) * pixelsPerFrame, height: 40)
        }
        .frame(height: 40)
        .background(
            Rectangle()
                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Crossfade Overlays

    @ViewBuilder
    private func crossfadeOverlays(
        for sortedClips: [NLAClip],
        pixelsPerFrame: CGFloat,
        trackHeight: CGFloat
    ) -> some View {
        ZStack(alignment: .leading) {
            ForEach(Array(sortedClips.enumerated()), id: \.element.id) { index, clip in
                if index + 1 < sortedClips.count {
                    let next = sortedClips[index + 1]
                    let clipEnd = clip.startFrame + clip.timelineDuration(
                        motionClipFrameCount: motionClipFrameCount(for: clip.motionClipID))
                    let overlapFrames = clipEnd - next.startFrame
                    if overlapFrames > 0 {
                        CrossfadeOverlayView(
                            overlapStartX: CGFloat(next.startFrame) * pixelsPerFrame,
                            overlapWidth: CGFloat(overlapFrames) * pixelsPerFrame,
                            trackHeight: trackHeight
                        )
                    }
                }
            }
        }
    }

    // MARK: - Track Inspector

    @ViewBuilder
    private func trackInspector(trackIndex: Int) -> some View {
        NLATrackInspectorView(
            track: Binding(
                get: { store.nlaTimeline?.tracks[trackIndex] ?? NLATrack() },
                set: { newTrack in
                    store.nlaTimeline?.tracks[trackIndex] = newTrack
                    store.evaluateNLAAtCurrentFrame()
                }
            ),
            clipNames: clipNames
        )
    }

    // MARK: - Empty State

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No Motion Tracks")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Add a track and drag motion clips from the library to start building your animation. You can also drop a video file here to extract motion.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Add Track") { addTrack(colorTag: .webcam) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Video Import Progress Overlay

    @ViewBuilder
    private var videoImportProgressOverlay: some View {
        HStack {
            Spacer()
            VStack(spacing: 8) {
                if let progress = store._videoImportProgress {
                    ProgressView(value: progress.fraction) {
                        Text("Processing video...")
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    Text("Frame \(progress.framesProcessed) / \(progress.totalFrames)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing video import...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") {
                    store.cancelVideoImport()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 280)
            Spacer()
        }
        .padding()
    }

    // MARK: - Actions

    private func addTrack(colorTag: NLATrackColorTag) {
        if store.nlaTimeline == nil {
            store.nlaTimeline = NLATimeline(fps: store.fps)
        }
        let trackNumber = (store.nlaTimeline?.tracks.count ?? 0) + 1
        let track = NLATrack(
            name: "\(colorTag.displayName) \(trackNumber)",
            colorTag: colorTag
        )
        store.nlaTimeline?.addTrack(track)
        selectedTrackID = track.id
        store.saveNLATimeline()
    }

    private func deleteTrack(id: UUID) {
        store.nlaTimeline?.removeTrack(id: id)
        if selectedTrackID == id {
            selectedTrackID = nil
        }
        store.evaluateNLAAtCurrentFrame()
        store.saveNLATimeline()
    }

    private func moveClip(trackID: UUID, clipID: UUID, newStartFrame: Int) {
        guard let trackIndex = store.nlaTimeline?.trackIndex(for: trackID),
              let clipIndex = store.nlaTimeline?.tracks[trackIndex].clips.firstIndex(where: { $0.id == clipID }) else { return }
        store.nlaTimeline?.tracks[trackIndex].clips[clipIndex].startFrame = newStartFrame
        store.evaluateNLAAtCurrentFrame()
        store.saveNLATimeline()
    }

    private func removeClipFromTrack(trackID: UUID, clipID: UUID) {
        guard let trackIndex = store.nlaTimeline?.trackIndex(for: trackID) else { return }
        store.nlaTimeline?.tracks[trackIndex].clips.removeAll { $0.id == clipID }
        store.evaluateNLAAtCurrentFrame()
        store.saveNLATimeline()
    }

    // MARK: - Helpers

    private func binding(for trackID: UUID) -> Binding<NLATrack> {
        Binding(
            get: {
                store.nlaTimeline?.tracks.first { $0.id == trackID } ?? NLATrack()
            },
            set: { newTrack in
                if let index = store.nlaTimeline?.trackIndex(for: trackID) {
                    store.nlaTimeline?.tracks[index] = newTrack
                    store.evaluateNLAAtCurrentFrame()
                }
            }
        )
    }

    private func motionClipFrameCount(for clipID: UUID) -> Int {
        store.motionClips.first(where: { $0.id == clipID })?.frameCount ?? 240
    }
}

// MARK: - CrossfadeOverlayView

/// Renders a diagonal gradient crossfade indicator in clip overlap zones.
@available(macOS 26.0, *)
struct CrossfadeOverlayView: View {
    let overlapStartX: CGFloat
    let overlapWidth: CGFloat
    let trackHeight: CGFloat

    var body: some View {
        if overlapWidth > 0 {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.blue.opacity(0.3),
                            Color.orange.opacity(0.3)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: overlapWidth, height: trackHeight)
                .offset(x: overlapStartX)
                .allowsHitTesting(false)
        }
    }
}
