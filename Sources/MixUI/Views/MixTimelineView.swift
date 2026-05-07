import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ProjectKit

@available(macOS 26.0, *)
struct MixArrangementView: View {
    @Bindable var store: MixStore
    let pixelsPerSecond: CGFloat
    @Binding var showMixerDock: Bool

    private let trackColumnWidth: CGFloat = 252
    private let rulerHeight: CGFloat = 34
    private let defaultLaneHeight: CGFloat = 104
    private let minLaneHeight: CGFloat = 56
    private let maxLaneHeight: CGFloat = 240
    private let mixerHeight: CGFloat = 210

    @State private var trackHeights: [UUID: CGFloat] = [:]
    /// Horizontal scroll offset of the timeline — used for viewport culling so
    /// only clips visible in the scroll region create SwiftUI views.
    @State private var timelineScrollOffsetX: CGFloat = 0

    private func laneHeight(for trackID: UUID) -> CGFloat {
        trackHeights[trackID] ?? defaultLaneHeight
    }

    private func totalContentHeight(tracks: [MixTrack]) -> CGFloat {
        rulerHeight + tracks.reduce(CGFloat(0)) { $0 + laneHeight(for: $1.id) }
    }

    var body: some View {
        if store.selectedScene == nil {
            OperaChromeEmptyState(
                systemImage: "waveform.badge.plus",
                title: "Choose A Scene",
                message: "Pick a scene on the left to open its dedicated mix session."
            )
        } else {
            GeometryReader { geometry in
                let timelineViewportWidth = max(geometry.size.width - trackColumnWidth - 1, 160)

                VStack(spacing: 0) {
                    if store.currentTracks.isEmpty {
                        HStack(spacing: 0) {
                            VStack(spacing: 0) {
                                MixTrackPanelHeaderView(store: store)
                                    .frame(width: trackColumnWidth, height: rulerHeight)
                                MixNoTracksPanelView(store: store)
                            }
                            .frame(width: trackColumnWidth)
                            .background(MixPalette.trackColumnBackground)

                            OperaChromeDivider(.vertical, opacity: 0.75)

                            MixEmptyArrangeView(
                                store: store,
                                pixelsPerSecond: pixelsPerSecond,
                                viewportWidth: timelineViewportWidth
                            )
                        }
                        .frame(width: geometry.size.width, alignment: .leading)
                    } else {
                        let tracks = store.currentTracks
                        // Pre-group all clips by track ID once per body evaluation so
                        // each MixTimelineLaneView receives a pre-filtered, pre-sorted
                        // slice rather than re-scanning all clips O(N × clips) times.
                        let allClips = store.currentClips
                        let clipsByTrack: [UUID: [MixClip]] = {
                            var dict: [UUID: [MixClip]] = [:]
                            for clip in allClips {
                                dict[clip.trackID, default: []].append(clip)
                            }
                            // Sort each bucket by startSeconds once (the same ordering
                            // store.clips(for:) produces) so lane views get sorted clips.
                            for key in dict.keys {
                                dict[key]?.sort {
                                    if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
                                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                                }
                            }
                            return dict
                        }()
                        ScrollView(.vertical, showsIndicators: true) {
                            HStack(spacing: 0) {
                                VStack(spacing: 0) {
                                    MixTrackPanelHeaderView(store: store)
                                        .frame(width: trackColumnWidth, height: rulerHeight)

                                    ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                        let h = laneHeight(for: track.id)
                                        MixTrackStripView(
                                            store: store,
                                            trackIndex: index,
                                            track: track,
                                            height: h
                                        )
                                        .frame(width: trackColumnWidth, height: h)
                                        .overlay(alignment: .bottom) {
                                            // Resize handle between lanes
                                            MixLaneResizeHandle { delta in
                                                let current = laneHeight(for: track.id)
                                                trackHeights[track.id] = min(max(current + delta, minLaneHeight), maxLaneHeight)
                                            }
                                        }
                                    }

                                    Spacer(minLength: 0)
                                }
                                .background(MixPalette.trackColumnBackground)

                                OperaChromeDivider(.vertical, opacity: 0.75)

                                ScrollView(.horizontal, showsIndicators: true) {
                                    let contentHeight = totalContentHeight(tracks: tracks)
                                    ZStack(alignment: .topLeading) {
                                        VStack(spacing: 0) {
                                            // Wrapped in an isolated view so the parent body
                                            // does NOT read store.playheadSeconds — avoids
                                            // rebuilding clipsByTrack 30-60×/sec during playback.
                                            MixRulerPlayheadWrapper(
                                                transport: store.transport,
                                                store: store,
                                                duration: store.activeSceneDurationSeconds,
                                                pixelsPerSecond: pixelsPerSecond,
                                                rulerHeight: rulerHeight,
                                                viewportOffsetX: timelineScrollOffsetX,
                                                viewportWidth: timelineViewportWidth
                                            )

                                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                                let h = laneHeight(for: track.id)
                                                let laneIsDragging = store.draggingClipTrackID == track.id
                                            MixTimelineLaneView(
                                                    store: store,
                                                    trackIndex: index,
                                                    track: track,
                                                    clips: clipsByTrack[track.id] ?? [],
                                                    duration: store.activeSceneDurationSeconds,
                                                    pixelsPerSecond: pixelsPerSecond,
                                                    height: h,
                                                    viewportOffsetX: timelineScrollOffsetX,
                                                    viewportWidth: timelineViewportWidth
                                                )
                                                .frame(height: h)
                                                // Elevate lane above siblings so a dragged clip
                                                // doesn't disappear behind adjacent lanes.
                                                .zIndex(laneIsDragging ? 1000 : 0)
                                                .overlay(alignment: .bottom) {
                                                    // Resize handle — timeline side
                                                    MixLaneResizeHandle { delta in
                                                        let current = laneHeight(for: track.id)
                                                        trackHeights[track.id] = min(max(current + delta, minLaneHeight), maxLaneHeight)
                                                    }
                                                }
                                            }
                                        }

                                        // Playhead line: observes `transport` directly
                                        // so 60fps CADisplayLink writes do not re-evaluate
                                        // parent body or unrelated views.
                                        MixPlayheadLineView(
                                            transport: store.transport,
                                            pixelsPerSecond: pixelsPerSecond,
                                            height: contentHeight
                                        )
                                    }
                                    .frame(minWidth: timelineViewportWidth, alignment: .topLeading)
                                    .padding(.trailing, 36)
                                }
                                .frame(width: timelineViewportWidth, alignment: .leading)
                                .clipped()
                                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                                    geometry.contentOffset.x
                                } action: { _, newOffset in
                                    timelineScrollOffsetX = newOffset
                                }
                                .background(MixPalette.arrangeBackground)
                            }
                            .frame(width: geometry.size.width, alignment: .leading)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    if showMixerDock {
                        OperaChromeDivider()
                        MixMixerDockView(store: store)
                            .frame(height: mixerHeight)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(MixPalette.arrangeBackdrop)
            }
        }
    }
}

// MARK: - Playhead Isolation Views
// These exist solely to prevent MixArrangementView.body from reading
// store.playheadSeconds directly. Without them, the expensive clipsByTrack
// dictionary rebuild and all ForEach closures re-execute 30-60×/sec during
// playback. With them, only these tiny leaf views re-evaluate on each tick.

/// Wraps the ruler so the parent body does not read `store.playheadSeconds`.
/// Observes the isolated `MixTransportState` instead — 60 fps playhead writes
/// from the CADisplayLink do NOT re-evaluate views that observe `MixStore`.
@available(macOS 26.0, *)
private struct MixRulerPlayheadWrapper: View {
    @Bindable var transport: MixTransportState
    let store: MixStore
    let duration: Double
    let pixelsPerSecond: CGFloat
    let rulerHeight: CGFloat
    let viewportOffsetX: CGFloat
    let viewportWidth: CGFloat

    var body: some View {
        MixTimelineRulerView(
            duration: duration,
            pixelsPerSecond: pixelsPerSecond,
            height: rulerHeight,
            playheadSeconds: transport.playheadSeconds,
            viewportOffsetX: viewportOffsetX,
            viewportWidth: viewportWidth,
            onSeek: { store.seekPlayhead(to: $0) }
        )
    }
}

/// Thin red vertical line spanning all lanes — reads `transport.playheadSeconds`
/// on the isolated ``MixTransportState`` so 60 fps CADisplayLink writes do not
/// trigger re-evaluation of views that observe the main ``MixStore``.
@available(macOS 26.0, *)
private struct MixPlayheadLineView: View {
    @Bindable var transport: MixTransportState
    let pixelsPerSecond: CGFloat
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(Color.red.opacity(0.85))
            .frame(width: 2, height: height)
            .offset(x: CGFloat(transport.playheadSeconds) * pixelsPerSecond - 1)
            .allowsHitTesting(false)
    }
}

/// Horizontal drag handle at the bottom edge of a lane — drag vertically to resize.
@available(macOS 26.0, *)
struct MixLaneResizeHandle: View {
    let onDrag: (CGFloat) -> Void
    @State private var lastY: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(MixPalette.panelStroke.opacity(0.55))
            .frame(height: 3)
            .contentShape(Rectangle().inset(by: -4))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        onDrag(value.translation.height - lastY)
                        lastY = value.translation.height
                    }
                    .onEnded { _ in lastY = 0 }
            )
    }
}

@available(macOS 26.0, *)
struct MixTrackPanelHeaderView: View {
    @Bindable var store: MixStore

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                MixSectionLabel("Tracks")
                Text(store.selectedTrack?.name ?? "Audio tracks")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                MixToolbarIconButton(systemImage: "plus") {
                    _ = store.addTrack()
                }
                .accessibilityLabel("Add Audio Track")
                MixToolbarIconButton(systemImage: "mic.badge.plus") {
                    _ = store.addTrack(armForRecording: true)
                }
                .accessibilityLabel("Add Vocal Track")
            }
        }
        .padding(.horizontal, 12)
        .background(
            LinearGradient(
                colors: [MixPalette.trackHeaderTop, MixPalette.trackHeaderBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

@available(macOS 26.0, *)
struct MixNoTracksPanelView: View {
    @Bindable var store: MixStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("No tracks yet")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Text("Create an empty audio track or drag files into the arrange area and Mix will build the first track for you.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.62))
                .fixedSize(horizontal: false, vertical: true)

            MixToolbarButton(title: "Add Audio Track", systemImage: "plus") {
                _ = store.addTrack()
            }
            MixToolbarButton(title: "Add Vocal Track", systemImage: "mic.badge.plus") {
                _ = store.addTrack(armForRecording: true)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

@available(macOS 26.0, *)
struct MixEmptyArrangeView: View {
    @Bindable var store: MixStore
    let pixelsPerSecond: CGFloat
    let viewportWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            MixTimelineRulerView(duration: min(max(store.activeSceneDurationSeconds, 45), 36_000), pixelsPerSecond: pixelsPerSecond, height: 34, viewportWidth: max(viewportWidth, 1600))

            Rectangle()
                .fill(MixPalette.arrangeBackground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onDrop(
                    of: [UTType.fileURL, UTType.url],
                    delegate: MixTimelineDropDelegate(
                        store: store,
                        sceneID: store.selectedSceneID,
                        trackID: nil,
                        pixelsPerSecond: pixelsPerSecond
                    )
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@available(macOS 26.0, *)
private struct MixTimelineClipStartKey: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

@available(macOS 26.0, *)
private struct MixTimelineClipLayout: Layout {
    let width: CGFloat
    let height: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let clipProposal = ProposedViewSize(width: nil, height: height)
        for subview in subviews {
            let startX = subview[MixTimelineClipStartKey.self]
            subview.place(
                at: CGPoint(x: bounds.minX + startX, y: bounds.minY),
                anchor: .topLeading,
                proposal: clipProposal
            )
        }
    }
}


@available(macOS 26.0, *)
struct MixTimelineLaneView: View {
    @Bindable var store: MixStore
    let trackIndex: Int
    let track: MixTrack
    /// Pre-filtered and pre-sorted clips for this track — passed by the parent so the
    /// O(allClips) filter+sort is done once for all lanes rather than once per lane.
    let clips: [MixClip]
    let duration: Double
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    /// Horizontal scroll offset (pixels) — used for viewport culling.
    var viewportOffsetX: CGFloat = 0
    /// Visible viewport width (pixels) — used for viewport culling.
    var viewportWidth: CGFloat = 1600

    /// Clips whose pixel range overlaps the visible viewport (with generous margin
    /// to prevent popping at edges during fast scrolling or drag overshoot).
    private var visibleClips: [MixClip] {
        let margin: CGFloat = 400 // extra pixels outside viewport to pre-render
        let visibleMinX = viewportOffsetX - margin
        let visibleMaxX = viewportOffsetX + viewportWidth + margin
        return clips.filter { clip in
            let clipStartX = CGFloat(clip.startSeconds) * pixelsPerSecond
            let clipEndX = clipStartX + max(CGFloat(clip.durationSeconds) * pixelsPerSecond, 40)
            return clipEndX >= visibleMinX && clipStartX <= visibleMaxX
        }
    }

    var body: some View {
        let width = max(CGFloat(duration) * pixelsPerSecond, 1600)

        ZStack(alignment: .topLeading) {
            laneBackground(width: width)
            laneTapSurface(width: width)

            if clips.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.28))
                    Text("Drop audio files here or use the browser to add clips")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.36))
                }
                .padding(.leading, 18)
                .padding(.top, 18)
            }

            MixTimelineClipLayout(width: width, height: height) {
                // Viewport-culled: only create views for clips visible in the scroll region.
                // A 400px margin prevents visual popping during fast scrolling.
                ForEach(visibleClips) { clip in
                    let clipSelected = store.currentSelectedClipID == clip.id
                    MixClipView(
                        store: store,
                        clip: clip,
                        pixelsPerSecond: pixelsPerSecond,
                        laneHeight: height,
                        isSelected: clipSelected,
                        isTrackMuted: track.isMuted
                    )
                    .layoutValue(
                        key: MixTimelineClipStartKey.self,
                        value: CGFloat(clip.startSeconds) * pixelsPerSecond
                    )
                }
            }
            .frame(width: width, height: height)

            if store.selectedTool == .automation, track.id == store.selectedTrack?.id {
                MixAutomationEnvelopeView(
                    store: store,
                    track: track,
                    duration: duration,
                    pixelsPerSecond: pixelsPerSecond,
                    laneHeight: height
                )
            }

            // Ghost clip preview while dragging over this lane
            if store.dropPreviewTrackID == track.id,
               let previewTime = store.dropPreviewTime {
                let accent = Color(hex: track.accentHex)
                let ghostWidth = min(
                    max(CGFloat(store.dropPreviewDurationSeconds ?? 1.2) * pixelsPerSecond, 96),
                    560
                )
                let xOffset = CGFloat(previewTime) * pixelsPerSecond

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.38),
                                    accent.opacity(0.18),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    Rectangle()
                        .fill(.black.opacity(0.14))
                        .frame(height: min(18, height * 0.24))
                        .frame(maxHeight: .infinity, alignment: .top)

                    dropPreviewWaveform(accent: accent)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 8)

                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(accent.opacity(0.72), lineWidth: 1.5)

                    Text(store.dropPreviewName ?? "Audio File")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(.black.opacity(0.35))
                        )
                        .padding(4)
                }
                .frame(width: ghostWidth, height: height)
                .offset(x: xOffset)
                .allowsHitTesting(false)
            }
        }
        .frame(width: width, height: height)
        // Highlight outline when files are being dragged over this lane
        .overlay {
            if store.dropPreviewTrackID == track.id {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(MixPalette.cyan.opacity(0.45), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(
            of: [UTType.fileURL, UTType.url],
            delegate: MixTimelineDropDelegate(
                store: store,
                sceneID: store.selectedSceneID,
                trackID: track.id,
                pixelsPerSecond: pixelsPerSecond
            )
        )
    }

    @ViewBuilder
    private func laneTapSurface(width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(.interaction, Rectangle())
            .gesture(
                SpatialTapGesture()
                    .onEnded { value in
                        let time = max(0, Double(value.location.x / pixelsPerSecond))
                        if store.selectedTool == .automation {
                            store.selectTrack(track.id, clearSelectedClip: false)
                            let normalizedValue = 1 - min(max(value.location.y / height, 0), 1)
                            store.addVolumeAutomationPoint(to: track.id, timeSeconds: time, value: normalizedValue)
                        } else {
                            store.seekPlayhead(to: store.snapToGrid(time))
                            store.selectTrack(track.id, clearSelectedClip: true)
                        }
                    }
            )
    }

    @ViewBuilder
    private func dropPreviewWaveform(accent: Color) -> some View {
        if let previewPath = store.dropPreviewFilePath,
           let image = store.waveformCache.waveformImage(for: previewPath) {
            Image(decorative: image, scale: 2)
                .resizable()
                .interpolation(.medium)
                .colorMultiply(.white)
        } else {
            HStack(spacing: 2) {
                ForEach(0..<24, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(accent.opacity(0.42))
                        .frame(width: 3, height: CGFloat(8 + (index * 11) % Int(max(height * 0.46, 12))))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    @ViewBuilder
    private func laneBackground(width: CGFloat) -> some View {
        let accent = MixPalette.trackNeutral
        let isSelected = track.id == store.selectedTrack?.id

        ZStack(alignment: .leading) {
            Rectangle()
                .fill(isSelected ? MixPalette.laneSelected : (trackIndex.isMultiple(of: 2) ? MixPalette.laneBase : MixPalette.laneAlternate))

            Canvas { context, size in
                // Viewport-culled grid: only draw lines in the visible scroll region
                // plus a small margin. This reduces iterations from 200,000+ (full
                // timeline) to ~100-400 (visible portion) — a 500-2000× reduction.
                let margin: CGFloat = 100
                let visibleMinX = max(viewportOffsetX - margin, 0)
                let visibleMaxX = viewportOffsetX + viewportWidth + margin

                let halfSecondPixels = pixelsPerSecond * 0.5
                let drawSubdivisions = halfSecondPixels >= 4
                let drawMinorGrid = pixelsPerSecond >= 8

                // Convert pixel range to step range (half-second steps)
                let startStep = max(0, Int(floor(visibleMinX / halfSecondPixels)))
                let endStep = min(Int(ceil(visibleMaxX / halfSecondPixels)), Int(ceil(duration * 2)))

                guard startStep <= endStep else { return }
                for step in startStep...endStep {
                    let seconds = Double(step) / 2
                    let isHalfSecond = !step.isMultiple(of: 2)
                    if isHalfSecond && !drawSubdivisions { continue }
                    if !isHalfSecond && !drawMinorGrid && !Int(seconds).isMultiple(of: 5) { continue }
                    let x = CGFloat(seconds) * pixelsPerSecond
                    let color = gridColor(for: seconds)
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                        with: .color(color)
                    )
                }
            }

            Rectangle()
                .fill(LinearGradient(colors: [accent.opacity(isSelected ? 0.24 : 0.15), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: width)

            Rectangle()
                .fill(accent.opacity(isSelected ? 0.72 : 0.42))
                .frame(width: 3)

            VStack(spacing: 0) {
                Rectangle()
                    .fill(.white.opacity(0.06))
                    .frame(height: 1)
                Spacer(minLength: 0)
                Rectangle()
                    .fill(.black.opacity(0.24))
                    .frame(height: 1)
            }
        }
        // CRITICAL: Prevent the lane background from intercepting taps.
        // Without this, the filled Rectangles absorb all clicks before the
        // parent's .onTapGesture fires, making it impossible to deselect
        // clips by clicking empty lane space.
        .allowsHitTesting(false)
    }

    private func gridColor(for seconds: Double) -> Color {
        if seconds == 0 { return .white.opacity(0.22) }
        if Int(seconds).isMultiple(of: 5) && seconds.rounded() == seconds {
            return MixPalette.gridMajor
        }
        if seconds.rounded() == seconds {
            return MixPalette.gridMinor
        }
        return MixPalette.gridSubdivision
    }
}

@available(macOS 26.0, *)
struct MixTimelineDropDelegate: DropDelegate {
    let store: MixStore
    let sceneID: UUID?
    let trackID: UUID?
    let pixelsPerSecond: CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.fileURL]) ||
        info.hasItemsConforming(to: [UTType.url])
    }

    func dropEntered(info: DropInfo) {
        let time = max(0, Double(info.location.x / pixelsPerSecond))
        let providers = info.itemProviders(for: [UTType.fileURL]) +
                        info.itemProviders(for: [UTType.url])
        let name = providers.first?.suggestedName ?? "Audio File"
        let generation = store.beginDropPreview(trackID: trackID, time: time, name: name)
        // Pre-resolve URLs eagerly so performDrop has them ready.
        // Capture sceneID and trackID so the Task can discard results if the scene or
        // lane changed while the URL resolution was in flight (fast drag, scene switch).
        let capturedSceneID = sceneID
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadURL(from: provider) {
                    urls.append(url)
                }
            }
            let previewDuration = await loadPreviewDuration(for: urls.first)
            await MainActor.run {
                guard store.selectedSceneID == capturedSceneID else { return }
                store.resolveDropPreview(
                    generation: generation,
                    urls: urls,
                    durationSeconds: previewDuration
                )
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let time = max(0, Double(info.location.x / pixelsPerSecond))
        store.updateDropPreview(trackID: trackID, time: time)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        store.clearDropPreview()
    }

    func performDrop(info: DropInfo) -> Bool {
        let dropTime = max(0, Double(info.location.x / pixelsPerSecond))
        // Consume and immediately clear the cache so stale URLs from a prior drag
        // session can never leak into the next drop.  Without this eager clear, a
        // quick drag-out → drag-in → drop sequence could use URLs pre-fetched for
        // a different lane or a previous drag entirely.
        let cachedURLs = store.cachedDropURLs
        store.clearDropPreview()

        if !cachedURLs.isEmpty {
            Task { @MainActor in
                guard store.selectedSceneID == sceneID else {
                    store.statusMessage = "Drop canceled because the scene changed."
                    return
                }
                store.addClips(from: cachedURLs, to: trackID ?? UUID(), startingAt: dropTime)
            }
            return true
        }

        // Fallback: resolve URLs from providers
        var providers = info.itemProviders(for: [UTType.fileURL])
        if providers.isEmpty {
            providers = info.itemProviders(for: [UTType.url])
        }
        guard !providers.isEmpty else {
            store.statusMessage = "Drop failed: no file providers found in drop info."
            return false
        }

        Task {
            var droppedURLs: [URL] = []
            for provider in providers {
                if let url = await loadURL(from: provider) {
                    droppedURLs.append(url)
                } else {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    if let url = await loadURL(from: provider) {
                        droppedURLs.append(url)
                    }
                }
            }
            guard !droppedURLs.isEmpty else {
                await MainActor.run {
                    store.statusMessage = "Drop failed: could not resolve any file URLs."
                }
                return
            }
            await MainActor.run {
                guard store.selectedSceneID == sceneID else {
                    store.statusMessage = "Drop canceled because the scene changed."
                    return
                }
                store.addClips(from: droppedURLs, to: trackID ?? UUID(), startingAt: dropTime)
            }
        }
        return true
    }

    private func loadPreviewDuration(for url: URL?) async -> Double? {
        guard let url else { return nil }
        return await Task.detached(priority: .utility) {
            MixStore.dropPreviewDuration(for: url)
        }.value
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        // Attempt 1: loadObject as NSURL (cast through NSURL, not URL, to avoid bridging
        // failures when the object is typed as NSItemProviderReading at the call site)
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let url = await loadViaObject(provider: provider) { return url }
            if let url = await loadViaItem(provider: provider, uti: UTType.fileURL.identifier) { return url }
        }
        // Attempt 2: generic URL type
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadViaItem(provider: provider, uti: UTType.url.identifier) { return url }
        }
        return nil
    }

    private func loadViaObject(provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                // Cast through NSURL explicitly — direct `as? URL` can fail when
                // `object` is typed as the NSItemProviderReading protocol.
                if let nsURL = object as? NSURL {
                    continuation.resume(returning: nsURL as URL)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadViaItem(provider: NSItemProvider, uti: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: uti, options: nil) { item, _ in
                if let nsURL = item as? NSURL {
                    continuation.resume(returning: nsURL as URL)
                } else if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let string = item as? String,
                          let url = URL(string: string) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
