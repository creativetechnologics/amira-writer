import SwiftUI

@available(macOS 26.0, *)
struct MixClipView: View {
    @Bindable var store: MixStore
    let clip: MixClip
    let pixelsPerSecond: CGFloat
    let laneHeight: CGFloat
    /// Passed from parent to avoid deep @Observable read chain — prevents
    /// every clip view from re-rendering when any unrelated property changes.
    let isSelected: Bool
    /// Passed from parent (track.isMuted) — avoids O(tracks) scan per clip per render.
    let isTrackMuted: Bool

    @State private var dragOffsetX: CGFloat = 0
    @State private var dragOffsetY: CGFloat = 0
    @State private var leadingTrimOffset: CGFloat = 0
    @State private var trailingTrimOffset: CGFloat = 0
    @State private var didPushDragCursor = false
    @State private var didPushHoverCursor = false
    @State private var fadeInDragOffset: CGFloat = 0
    @State private var fadeOutDragOffset: CGFloat = 0
    @State private var isFadeInHovering = false
    @State private var isFadeOutHovering = false
    @State private var didPushFadeCursor = false
    /// Tracks whether we already called selectClip() for the current drag
    /// gesture so we don't trigger mutateCurrentSession → scheduleSave
    /// on every frame (60Hz+). Selection is committed once at drag start.
    @State private var didSelectForDrag = false
    /// Holds the snapped destination briefly after mouse-up so the clip does not
    /// visually jump back to its old position while the store publishes the move.
    @State private var committedStartSeconds: Double?
    @State private var committedLaneOffsetY: CGFloat = 0

    private var clipWidth: CGFloat {
        max(CGFloat(clip.durationSeconds) * pixelsPerSecond, 40)
    }

    private var displayedWidth: CGFloat {
        max(clipWidth + trailingTrimOffset - leadingTrimOffset, 40)
    }

    private var visualOffsetX: CGFloat {
        let committedOffsetX: CGFloat
        if let committedStartSeconds {
            committedOffsetX = CGFloat(committedStartSeconds - clip.startSeconds) * pixelsPerSecond
        } else {
            committedOffsetX = dragOffsetX
        }
        return committedOffsetX + leadingTrimOffset
    }

    private var visualOffsetY: CGFloat {
        committedStartSeconds == nil ? dragOffsetY : committedLaneOffsetY
    }

    private var isDragging: Bool {
        dragOffsetX != 0 || dragOffsetY != 0 || committedStartSeconds != nil
    }

    private var trackAccent: Color {
        Color(hex: clip.colorHex)
    }

    /// Fade-in width in pixels, accounting for live drag offset.
    private var displayedFadeInWidth: CGFloat {
        let baseWidth = CGFloat(clip.fadeInSeconds) * pixelsPerSecond
        return max(baseWidth + fadeInDragOffset, 0)
    }

    /// Fade-out width in pixels, accounting for live drag offset.
    private var displayedFadeOutWidth: CGFloat {
        let baseWidth = CGFloat(clip.fadeOutSeconds) * pixelsPerSecond
        return max(baseWidth + fadeOutDragOffset, 0)
    }

    private static let fadeHandleWidth: CGFloat = 16
    private static let fadeHandleHeightFraction: CGFloat = 0.3

    /// Diagonal resize cursor for fade handle corners.
    /// northeast=true → ↗ (fade-in, top-left corner, drag right to increase)
    /// northeast=false → ↖ (fade-out, top-right corner, drag left to increase)
    private static func diagonalResizeCursor(northeast: Bool) -> NSCursor {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.setLineWidth(1.5)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1, color: NSColor.black.withAlphaComponent(0.6).cgColor)

            if northeast {
                // Arrow from bottom-left to top-right (↗)
                ctx.move(to: CGPoint(x: 3, y: 3))
                ctx.addLine(to: CGPoint(x: 13, y: 13))
                // Arrowhead
                ctx.move(to: CGPoint(x: 8, y: 13))
                ctx.addLine(to: CGPoint(x: 13, y: 13))
                ctx.addLine(to: CGPoint(x: 13, y: 8))
            } else {
                // Arrow from bottom-right to top-left (↖)
                ctx.move(to: CGPoint(x: 13, y: 3))
                ctx.addLine(to: CGPoint(x: 3, y: 13))
                // Arrowhead
                ctx.move(to: CGPoint(x: 8, y: 13))
                ctx.addLine(to: CGPoint(x: 3, y: 13))
                ctx.addLine(to: CGPoint(x: 3, y: 8))
            }
            ctx.strokePath()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 8, y: 8))
    }

    /// Compact duration + gain label shown on selected clips.
    private var clipTimecodeLabel: String {
        let dur = clip.durationSeconds
        let durMin = Int(dur) / 60
        let durSec = Int(dur) % 60
        let durMs = Int((dur - dur.rounded(.towardZero)) * 10)
        let timeStr = durMin > 0 ? String(format: "%d:%02d.%d", durMin, durSec, durMs) : String(format: "%d.%ds", durSec, durMs)
        if abs(clip.gainDB) > 0.1 {
            return "\(timeStr) \(String(format: "%+.0fdB", clip.gainDB))"
        }
        return timeStr
    }

    /// Compact description announced by VoiceOver as the accessibility value.
    private var accessibilityPositionDescription: String {
        let startMin = Int(clip.startSeconds) / 60
        let startSec = Int(clip.startSeconds) % 60
        let durSec = Int(clip.durationSeconds.rounded())
        return String(format: "at %02d:%02d, %d second\(durSec == 1 ? "" : "s") long", startMin, startSec, durSec)
    }

    var body: some View {
        // Full-height waveform block — minimal chrome, DAW-style
        ZStack(alignment: .topLeading) {
            // Waveform fill — full lane height
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    // Background fill
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    trackAccent.opacity(isSelected ? 0.62 : 0.44),
                                    trackAccent.opacity(isSelected ? 0.34 : 0.22),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    Rectangle()
                        .fill(.black.opacity(0.14))
                        .frame(height: min(laneHeight * 0.24, 18))
                        .frame(maxHeight: .infinity, alignment: .top)

                    // Waveform — three states:
                    //   nil  → still loading → show animated placeholder
                    //   []   → load failed (file missing/corrupt) → show missing indicator
                    //   […]  → loaded successfully → draw waveform bars
                    switch store.waveformCache.peaks(for: clip.filePath) {
                    case nil:
                        waveformPlaceholder(width: proxy.size.width, height: proxy.size.height)
                    case let peaks? where peaks.isEmpty:
                        missingFileIndicator(width: proxy.size.width, height: proxy.size.height)
                    case let peaks?:
                        waveformCanvas(peaks: peaks, width: proxy.size.width, height: proxy.size.height)
                    }
                }
            }
            .onAppear { store.waveformCache.request(clip.filePath) }

            // Fade-in S-curve overlay
            if displayedFadeInWidth > 0.5 {
                fadeCurveOverlay(width: displayedFadeInWidth, height: laneHeight, isFadeIn: true)
                    .allowsHitTesting(false)
            }

            // Fade-out S-curve overlay
            if displayedFadeOutWidth > 0.5 {
                fadeCurveOverlay(width: displayedFadeOutWidth, height: laneHeight, isFadeIn: false)
                    .offset(x: displayedWidth - displayedFadeOutWidth)
                    .allowsHitTesting(false)
            }

            // Clip name overlay — top-left; hidden on very narrow clips (<50px)
            // where the label would completely obscure the waveform.
            if displayedWidth >= 50 {
                VStack(alignment: .leading, spacing: 1) {
                    Text(clip.name)
                        .font(.system(size: displayedWidth < 80 ? 8.5 : 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    if isSelected, displayedWidth > 80 {
                        Text(clipTimecodeLabel)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, displayedWidth < 80 ? 3 : 6)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.black.opacity(0.45))
                )
                .padding(4)
            }
        }
        .frame(width: displayedWidth, height: laneHeight, alignment: .topLeading)
        .fixedSize(horizontal: true, vertical: false)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(
                    isSelected ? .white.opacity(0.9)
                    : trackAccent.opacity(isDragging ? 0.9 : 0.65),
                    lineWidth: isSelected ? 2.5 : 1.5
                )
        }
        // Trim handles
        .overlay(alignment: .leading) {
            trimHandle(isLeading: true)
        }
        .overlay(alignment: .trailing) {
            trimHandle(isLeading: false)
        }
        // Fade handles — top corners
        .overlay(alignment: .topLeading) {
            fadeHandle(isFadeIn: true)
        }
        .overlay(alignment: .topTrailing) {
            fadeHandle(isFadeIn: false)
        }
        // Drag position tooltip — shows where the clip will land when snapped
        .overlay(alignment: .top) {
            if isDragging {
                let snappedStart = committedStartSeconds
                    ?? max(store.snapToGrid(clip.startSeconds + Double(dragOffsetX / pixelsPerSecond)), 0)
                let totalSec = Int(snappedStart.rounded(.down))
                let label = String(format: "%d:%02d.%01d", totalSec / 60, totalSec % 60, Int((snappedStart - snappedStart.rounded(.towardZero)) * 10))
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(MixPalette.displayBackground.opacity(0.92))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(.white.opacity(0.2), lineWidth: 1)
                    )
                    .offset(y: -18)
                    .allowsHitTesting(false)
            }
        }
        .offset(x: visualOffsetX, y: visualOffsetY)
        .opacity(isTrackMuted ? 0.4 : 1.0)
        .shadow(color: isSelected ? .white.opacity(0.12) : .black.opacity(isDragging ? 0.4 : 0.18), radius: isSelected ? 8 : (isDragging ? 14 : 6), y: isSelected ? 0 : (isDragging ? 10 : 4))
        .zIndex(isDragging ? 100 : (isSelected ? 10 : 0))
        // Smooth 120ms transition for selection border/shadow/opacity changes.
        // Uses `isSelected` value — does not animate on drag offset changes.
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .contentShape(.interaction, RoundedRectangle(cornerRadius: 5, style: .continuous))
        // Use a dedicated spatial tap gesture so selection/split clicks don't
        // compete with the drag recognizer and we keep exact click location.
        .highPriorityGesture(clipTapGesture)
        // Drag gesture for move/split — minimumDistance: 2 so trim handle gestures
        // (minimumDistance: 1) can activate without the body gesture stealing them.
        .gesture(interactionGesture)
        .onHover { hovering in
            if hovering {
                if store.selectedTool == .split {
                    NSCursor.crosshair.push()
                } else {
                    NSCursor.openHand.push()
                }
                didPushHoverCursor = true
            } else {
                if didPushHoverCursor {
                    NSCursor.pop()
                    didPushHoverCursor = false
                }
            }
        }
        .onDisappear {
            // Clean up any lingering cursor pushes if the view is removed while
            // hovering (e.g. clip deleted, scene switch, undo while hovering).
            if didPushHoverCursor {
                NSCursor.pop()
                didPushHoverCursor = false
            }
            if didPushDragCursor {
                NSCursor.pop()
                didPushDragCursor = false
            }
            if didPushFadeCursor {
                NSCursor.pop()
                didPushFadeCursor = false
            }
        }
        // Update cursor when tool changes while hovering a clip (e.g. pressing
        // "1" or "2") — onHover only fires on mouse enter/exit, not state changes.
        .onChange(of: store.selectedTool) { _, newTool in
            if didPushFadeCursor {
                // Fade handle's diagonal cursor is on the stack — pop it and
                // push the appropriate cursor for the new tool.
                NSCursor.pop()
                didPushFadeCursor = false
                if newTool == .split {
                    NSCursor.crosshair.push()
                } else {
                    NSCursor.openHand.push()
                }
                didPushHoverCursor = true
            } else if didPushHoverCursor {
                NSCursor.pop()
                if newTool == .split {
                    NSCursor.crosshair.push()
                } else {
                    NSCursor.openHand.push()
                }
            }
        }
        .onChange(of: clip.startSeconds) { _, _ in
            // Reset stale visual offsets when the model position changes
            // (e.g., gesture cancelled, clip moved externally, undo/redo).
            clearInteractionState()
        }
        .onChange(of: clip.trackID) { _, _ in
            clearInteractionState()
        }
        .accessibilityLabel(clip.name)
        .accessibilityValue(accessibilityPositionDescription)
        .accessibilityHint(
            store.selectedTool == .split
                ? "Tap to split clip. Press S to split at playhead."
                : "Drag to move. Tap to select. Tab to cycle clips. Arrow keys to nudge. +/- to adjust gain."
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            Button("Preview") { store.previewAudio(at: clip.filePath) }

            Divider()

            Button("Duplicate (⌘D)") { store.duplicateClip(clip.id) }
            Button("Split At Center") {
                store.splitClip(clip.id, at: clip.startSeconds + clip.durationSeconds / 2)
            }
            if store.playheadSeconds > clip.startSeconds + 0.05,
               store.playheadSeconds < clip.startSeconds + clip.durationSeconds - 0.05 {
                Button("Split At Playhead (S)") {
                    store.splitClip(clip.id, at: store.playheadSeconds)
                }
            }

            Divider()

            Menu("Nudge") {
                Button("Left (←)") { store.nudgeClip(clip.id, by: -store.nudgeAmount) }
                Button("Right (→)") { store.nudgeClip(clip.id, by: store.nudgeAmount) }
                Divider()
                Button("To Playhead") {
                    store.moveClip(clip.id, to: clip.trackID, startSeconds: store.playheadSeconds)
                }
                Button("To Start") {
                    store.moveClip(clip.id, to: clip.trackID, startSeconds: 0)
                }
            }

            Menu("Gain") {
                Button("+1 dB") { store.adjustSelectedClipGain(by: 1) }
                Button("+3 dB") { store.adjustSelectedClipGain(by: 3) }
                Button("-1 dB") { store.adjustSelectedClipGain(by: -1) }
                Button("-3 dB") { store.adjustSelectedClipGain(by: -3) }
                Divider()
                Button("Reset to 0 dB") { store.updateClipGain(clip.id, value: 0) }
            }

            if store.currentTracks.count > 1 {
                Menu("Move To Track") {
                    ForEach(store.currentTracks.filter { $0.id != clip.trackID }) { track in
                        Button(track.name) {
                            store.moveClip(clip.id, to: track.id, startSeconds: clip.startSeconds)
                        }
                    }
                }
            }

            Divider()

            Menu("Assembly") {
                Button("Join To Previous Clip") {
                    store.selectClip(clip.id)
                    store.joinSelectedClipToPrevious()
                }
                Divider()
                Button("Sequence All (No Gap)") {
                    store.autoSequenceClips(on: clip.trackID, overlapSeconds: 0)
                }
                Button("Sequence All (0.5s Overlap)") {
                    store.autoSequenceClips(on: clip.trackID, overlapSeconds: 0.5)
                }
                Button("Sequence All (1s Overlap)") {
                    store.autoSequenceClips(on: clip.trackID, overlapSeconds: 1.0)
                }
            }

            Divider()

            Button("Reveal In Finder") { store.revealBrowserPath(clip.filePath) }
            Button("Remove Clip", role: .destructive) { store.removeClip(clip.id) }
        }
    }

    // MARK: - Trim Handles

    @ViewBuilder
    private func trimHandle(isLeading: Bool) -> some View {
        // Hide trim handles when the clip is too narrow for both to fit side-by-side
        // (less than 60px wide) — otherwise the two handles overlap and become unusable.
        if displayedWidth >= 60 {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(trackAccent.opacity(isSelected ? 0.85 : 0.65))
                .frame(width: 6, height: laneHeight - 20)
                .padding(.leading, isLeading ? 0 : nil)
                .padding(.trailing, isLeading ? nil : 0)
                .contentShape(Rectangle().inset(by: -4))
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            guard store.selectedTool != .split else { return }
                            if isLeading {
                                leadingTrimOffset = min(max(value.translation.width, -CGFloat(clip.sourceInSeconds) * pixelsPerSecond), clipWidth - 40)
                            } else {
                                trailingTrimOffset = max(value.translation.width, -(clipWidth - 40))
                            }
                        }
                        .onEnded { value in
                            guard store.selectedTool != .split else { return }
                            if isLeading {
                                store.trimClipLeading(clip.id, deltaSeconds: Double(value.translation.width / pixelsPerSecond))
                                leadingTrimOffset = 0
                            } else {
                                store.trimClipTrailing(clip.id, deltaSeconds: Double(value.translation.width / pixelsPerSecond))
                                trailingTrimOffset = 0
                            }
                        }
                )
                .onHover { hovering in
                    if hovering {
                        NSCursor.resizeLeftRight.push()
                    } else {
                        NSCursor.pop()
                    }
                }
        }
    }

    // MARK: - Fade Handles

    @ViewBuilder
    private func fadeHandle(isFadeIn: Bool) -> some View {
        // Hide fade handles on very narrow clips or when in split mode
        if displayedWidth >= 60, store.selectedTool != .split {
            let handleHeight = laneHeight * Self.fadeHandleHeightFraction
            Color.clear
                .frame(width: Self.fadeHandleWidth, height: handleHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let maxFadePixels = displayedWidth * 0.5
                            if isFadeIn {
                                let baseWidth = CGFloat(clip.fadeInSeconds) * pixelsPerSecond
                                fadeInDragOffset = min(max(value.translation.width, -baseWidth), maxFadePixels - baseWidth)
                            } else {
                                let baseWidth = CGFloat(clip.fadeOutSeconds) * pixelsPerSecond
                                // Dragging LEFT from the right edge increases fade-out
                                fadeOutDragOffset = min(max(-value.translation.width, -baseWidth), maxFadePixels - baseWidth)
                            }
                        }
                        .onEnded { value in
                            let maxFadeSeconds = clip.durationSeconds * 0.5
                            if isFadeIn {
                                let newSeconds = min(max(clip.fadeInSeconds + Double(value.translation.width / pixelsPerSecond), 0), maxFadeSeconds)
                                store.updateClipFadeIn(clip.id, value: newSeconds)
                                fadeInDragOffset = 0
                            } else {
                                let newSeconds = min(max(clip.fadeOutSeconds + Double(-value.translation.width / pixelsPerSecond), 0), maxFadeSeconds)
                                store.updateClipFadeOut(clip.id, value: newSeconds)
                                fadeOutDragOffset = 0
                            }
                        }
                )
                .onHover { hovering in
                    if hovering {
                        // Pop the parent's open-hand cursor before pushing fade cursor
                        if didPushHoverCursor {
                            NSCursor.pop()
                            didPushHoverCursor = false
                        }
                        if isFadeIn {
                            isFadeInHovering = true
                        } else {
                            isFadeOutHovering = true
                        }
                        // Guard against double-push if both fade handles fire rapidly
                        if !didPushFadeCursor {
                            Self.diagonalResizeCursor(northeast: isFadeIn).push()
                            didPushFadeCursor = true
                        }
                    } else {
                        if isFadeIn {
                            isFadeInHovering = false
                        } else {
                            isFadeOutHovering = false
                        }
                        if didPushFadeCursor {
                            NSCursor.pop()
                            didPushFadeCursor = false
                        }
                        // Restore the parent clip's open-hand cursor since we're
                        // still inside the clip bounds after leaving the fade zone.
                        if store.selectedTool != .split {
                            NSCursor.openHand.push()
                            didPushHoverCursor = true
                        }
                    }
                }
        }
    }

    // MARK: - Fade Curve Rendering

    @ViewBuilder
    private func fadeCurveOverlay(width: CGFloat, height: CGFloat, isFadeIn: Bool) -> some View {
        let isHovering = isFadeIn ? isFadeInHovering : isFadeOutHovering
        ZStack {
            // Filled area under the S-curve
            fadeSCurveFillPath(width: width, height: height, isFadeIn: isFadeIn)
                .fill(.black.opacity(0.22))

            // Bright stroke on the curve line itself
            fadeSCurveStrokePath(width: width, height: height, isFadeIn: isFadeIn)
                .stroke(.white.opacity(isHovering ? 0.8 : 0.5), lineWidth: isHovering ? 2 : 1.5)
        }
        .frame(width: width, height: height)
    }

    /// S-curve fill path: area between the curve and the faded edge.
    /// For fade-in: area from bottom-left, along the curve to top-right, down the right edge.
    /// For fade-out: area from top-left, along the curve to bottom-right, up the left edge.
    private func fadeSCurveFillPath(width: CGFloat, height: CGFloat, isFadeIn: Bool) -> Path {
        Path { path in
            if isFadeIn {
                // Fill the area above the curve (the faded region)
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 0, y: height))
                // S-curve from bottom-left to top-right
                path.addCurve(
                    to: CGPoint(x: width, y: 0),
                    control1: CGPoint(x: width * 0.4, y: height),
                    control2: CGPoint(x: width * 0.6, y: 0)
                )
                path.closeSubpath()
            } else {
                // Fill the area above the curve (the faded region)
                path.move(to: CGPoint(x: width, y: 0))
                path.addLine(to: CGPoint(x: width, y: height))
                // S-curve from bottom-right to top-left
                path.addCurve(
                    to: CGPoint(x: 0, y: 0),
                    control1: CGPoint(x: width * 0.6, y: height),
                    control2: CGPoint(x: width * 0.4, y: 0)
                )
                path.closeSubpath()
            }
        }
    }

    /// S-curve stroke path: just the curve line itself.
    private func fadeSCurveStrokePath(width: CGFloat, height: CGFloat, isFadeIn: Bool) -> Path {
        Path { path in
            if isFadeIn {
                path.move(to: CGPoint(x: 0, y: height))
                path.addCurve(
                    to: CGPoint(x: width, y: 0),
                    control1: CGPoint(x: width * 0.4, y: height),
                    control2: CGPoint(x: width * 0.6, y: 0)
                )
            } else {
                path.move(to: CGPoint(x: width, y: height))
                path.addCurve(
                    to: CGPoint(x: 0, y: 0),
                    control1: CGPoint(x: width * 0.6, y: height),
                    control2: CGPoint(x: width * 0.4, y: 0)
                )
            }
        }
    }

    // MARK: - Interaction Gesture

    private var clipTapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                if store.selectedTool == .split {
                    let splitTime = clip.startSeconds + Double(min(max(value.location.x, 0), displayedWidth) / pixelsPerSecond)
                    store.splitClip(clip.id, at: splitTime)
                } else {
                    store.selectClip(clip.id)
                }
            }
    }

    private var interactionGesture: some Gesture {
        // minimumDistance: 0 for split tool (instant tap), 2 for pointer (prevents
        // body drag from stealing trim-handle gestures which use minimumDistance: 1).
        DragGesture(minimumDistance: store.selectedTool == .split ? 0 : 2)
            .onChanged { value in
                if store.selectedTool == .split { return }
                // Select clip ONCE at drag start — not on every frame.
                // mutateCurrentSession() + scheduleSave() at 60Hz was the #1 choppiness cause.
                if !didSelectForDrag {
                    store.selectClip(clip.id)
                    didSelectForDrag = true
                }
                // Dead-zone: only show visual drag offset past 3pt to avoid jitter on tap
                if abs(value.translation.width) > 3 || abs(value.translation.height) > 3 {
                    let proposedStart = clip.startSeconds + Double(value.translation.width / pixelsPerSecond)
                    let snappedStart = max(store.snapToGrid(proposedStart), 0)
                    let laneDelta = Int((value.translation.height / laneHeight).rounded())
                    dragOffsetX = CGFloat(snappedStart - clip.startSeconds) * pixelsPerSecond
                    dragOffsetY = CGFloat(laneDelta) * laneHeight
                    store.draggingClipTrackID = store.targetTrackID(from: clip.trackID, laneDelta: laneDelta)
                    if !didPushDragCursor {
                        NSCursor.closedHand.push()
                        didPushDragCursor = true
                    }
                }
            }
            .onEnded { value in
                didSelectForDrag = false
                store.draggingClipTrackID = nil
                if didPushDragCursor {
                    NSCursor.pop()
                    didPushDragCursor = false
                }
                if store.selectedTool == .split {
                    let splitTime = clip.startSeconds + Double(min(max(value.location.x, 0), displayedWidth) / pixelsPerSecond)
                    store.splitClip(clip.id, at: splitTime)
                    return
                }
                let deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                let laneDelta = Int((value.translation.height / laneHeight).rounded())
                let targetTrackID = store.targetTrackID(from: clip.trackID, laneDelta: laneDelta)
                let newStart = clip.startSeconds + deltaSeconds
                let snappedStart = max(store.snapToGrid(newStart), 0)
                if abs(value.translation.width) < 4 && abs(value.translation.height) < 4 {
                    store.selectClip(clip.id)
                    clearInteractionState()
                } else {
                    committedStartSeconds = snappedStart
                    committedLaneOffsetY = targetTrackID == clip.trackID ? 0 : CGFloat(laneDelta) * laneHeight
                    dragOffsetX = 0
                    dragOffsetY = 0
                    store.moveClip(clip.id, to: targetTrackID, startSeconds: snappedStart)
                }
            }
    }

    private func clearInteractionState() {
        leadingTrimOffset = 0
        trailingTrimOffset = 0
        dragOffsetX = 0
        dragOffsetY = 0
        fadeInDragOffset = 0
        fadeOutDragOffset = 0
        committedStartSeconds = nil
        committedLaneOffsetY = 0
    }

    // MARK: - Waveform Rendering

    @ViewBuilder
    private func waveformCanvas(peaks: [Float], width: CGFloat, height: CGFloat) -> some View {
        // Prefer pre-rendered CGImage — zero per-frame draw cost.
        // Falls through to Canvas only if the image hasn't been pre-rendered yet.
        if let cgImage = store.waveformCache.waveformImage(for: clip.filePath) {
            Image(decorative: cgImage, scale: 2)
                .resizable()
                .interpolation(.medium)
                // Tint: white image × colorMultiply gives the desired color.
                // Selected clips stay white; unselected get the track accent.
                .colorMultiply(isSelected ? .white : trackAccent)
                .padding(.horizontal, 3)
        } else {
            // Fallback Canvas for the brief window between peaks arriving and
            // image rendering completing (should be < 1 frame in practice).
            Canvas { context, size in
                guard !peaks.isEmpty, size.width > 0, size.height > 0 else { return }
                let sampleCount = max(24, Int(size.width.rounded(.up)))
                let topInset: CGFloat = min(18, size.height * 0.24)
                let bottomInset: CGFloat = max(6, size.height * 0.1)
                let centerY = topInset + max(6, (size.height - topInset - bottomInset) * 0.5)
                let halfHeight = max(4, (size.height - topInset - bottomInset) * 0.42)
                let stepX = size.width / CGFloat(max(sampleCount - 1, 1))

                var envelope = [CGFloat](repeating: 0, count: sampleCount)
                for sampleIndex in 0..<sampleCount {
                    let start = sampleIndex * peaks.count / sampleCount
                    let end = min(peaks.count, max(start + 1, (sampleIndex + 1) * peaks.count / sampleCount))
                    var windowPeak: CGFloat = 0
                    for peakIndex in start..<end {
                        windowPeak = max(windowPeak, CGFloat(peaks[peakIndex]))
                    }
                    envelope[sampleIndex] = min(1, CGFloat(pow(Double(windowPeak), 0.86)))
                }

                if sampleCount >= 3 {
                    var filtered = envelope
                    for index in 1..<(sampleCount - 1) {
                        filtered[index] = (envelope[index - 1] + envelope[index] * 2 + envelope[index + 1]) / 4
                    }
                    envelope = filtered
                }

                var fillPath = Path()
                fillPath.move(to: CGPoint(x: 0, y: centerY))
                for index in 0..<sampleCount {
                    let x = CGFloat(index) * stepX
                    let amplitude = envelope[index] * halfHeight
                    fillPath.addLine(to: CGPoint(x: x, y: centerY - amplitude))
                }
                for index in stride(from: sampleCount - 1, through: 0, by: -1) {
                    let x = CGFloat(index) * stepX
                    let amplitude = envelope[index] * halfHeight
                    fillPath.addLine(to: CGPoint(x: x, y: centerY + amplitude))
                }
                fillPath.closeSubpath()
                context.fill(fillPath, with: .color(.white.opacity(0.18)))

                var upperStroke = Path()
                var lowerStroke = Path()
                for index in 0..<sampleCount {
                    let x = CGFloat(index) * stepX
                    let amplitude = envelope[index] * halfHeight
                    let upperPoint = CGPoint(x: x, y: centerY - amplitude)
                    let lowerPoint = CGPoint(x: x, y: centerY + amplitude)
                    if index == 0 {
                        upperStroke.move(to: upperPoint)
                        lowerStroke.move(to: lowerPoint)
                    } else {
                        upperStroke.addLine(to: upperPoint)
                        lowerStroke.addLine(to: lowerPoint)
                    }
                }
                context.stroke(upperStroke, with: .color(.white.opacity(isSelected ? 0.72 : 0.46)), lineWidth: 1)
                context.stroke(lowerStroke, with: .color(.white.opacity(isSelected ? 0.72 : 0.46)), lineWidth: 1)
                context.stroke(
                    Path(CGRect(x: 0, y: centerY, width: size.width, height: 1)),
                    with: .color(trackAccent.opacity(0.22)),
                    lineWidth: 1
                )
            }
            .padding(.horizontal, 3)
        }
    }

    @ViewBuilder
    private func waveformPlaceholder(width: CGFloat, height: CGFloat) -> some View {
        // Cap bar count to prevent thousands of ForEach items for very wide clips.
        let bars = min(max(Int(width / 8), 6), 256)
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<bars, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(trackAccent.opacity(0.35))
                    .frame(width: 3, height: CGFloat(4 + ((index * 7) % Int(max(height * 0.4, 8)))))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 4)
    }

    /// Shown when the audio file on disk cannot be found or decoded.
    @ViewBuilder
    private func missingFileIndicator(width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: min(height * 0.3, 14), weight: .semibold))
                .foregroundStyle(MixPalette.warn.opacity(0.82))
            if width > 80 {
                Text("File missing")
                    .font(.system(size: min(height * 0.22, 10), weight: .semibold))
                    .foregroundStyle(MixPalette.warn.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 4)
    }
}
