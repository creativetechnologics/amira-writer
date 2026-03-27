import SwiftUI
import NovotroProjectKit

@available(macOS 26.0, *)
struct MixMixerDockView: View {
    @Bindable var store: MixStore

    var body: some View {
        MixMixerDockContent(store: store)
    }
}

/// Extracted inner view so that the heavy track/clip data is captured once at the top of body
/// and reused for all downstream computations (strip loop, masterLevel, header counts) without
/// re-reading the store multiple times per render frame.
@available(macOS 26.0, *)
private struct MixMixerDockContent: View {
    @Bindable var store: MixStore

    var body: some View {
        // Capture session arrays once per body evaluation so every downstream
        // access (header counts, strip loop, masterLevel) reuses the same values.
        let tracks = store.currentTracks
        let clips = store.currentClips

        /// Clip count keyed by track ID — built once to avoid O(tracks × clips) per strip.
        let countsByTrack: [UUID: Int] = {
            var counts: [UUID: Int] = [:]
            for clip in clips { counts[clip.trackID, default: 0] += 1 }
            return counts
        }()

        let masterLevel: Double = {
            guard tracks.isEmpty == false else { return 0.12 }
            let values = tracks.map { track -> Double in
                let count = countsByTrack[track.id] ?? 0
                let clipFactor = min(Double(max(count, 1)) * 0.12 + 0.12, 0.86)
                let volumeFactor = max(0.08, min((track.volumeDB + 60) / 72, 1))
                let mutedMultiplier = track.isMuted ? 0.08 : 1
                return clipFactor * volumeFactor * mutedMultiplier
            }
            return min(max(values.reduce(0, +) / Double(values.count), 0.08), 1)
        }()

        VStack(spacing: 0) {
            // Compact dock header
            HStack(spacing: 8) {
                MixSectionLabel("Mixer")
                Text("·")
                    .foregroundStyle(.white.opacity(0.25))
                    .font(.system(size: 10))
                Text(store.selectedScene?.displayTitle ?? "—")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Text("\(tracks.count)T · \(clips.count)C · \(shortTimecode(store.activeSceneDurationSeconds))")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            OperaChromeDivider(opacity: 0.7)

            GeometryReader { geometry in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            MixMixerStripView(
                                store: store,
                                trackIndex: index,
                                track: track,
                                clipCount: countsByTrack[track.id] ?? 0
                            )
                        }

                        MixMasterStripView(
                            sceneTitle: store.selectedScene?.displayTitle ?? "Master",
                            trackCount: tracks.count,
                            clipCount: clips.count,
                            level: masterLevel,
                            sceneDuration: store.activeSceneDurationSeconds
                        )
                    }
                    .frame(minWidth: max(geometry.size.width - 24, 0), alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(width: geometry.size.width, alignment: .leading)
                .clipped()
            }
        }
        .background(
            LinearGradient(
                colors: [MixPalette.mixerTop, MixPalette.mixerBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func shortTimecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

@available(macOS 26.0, *)
struct MixMixerStripView: View {
    @Bindable var store: MixStore
    let trackIndex: Int
    let track: MixTrack
    /// Pre-computed clip count passed from the parent to avoid O(clips) per strip render.
    let clipCount: Int

    private var accent: Color { MixPalette.trackNeutral }
    private var isSelected: Bool { track.id == store.selectedTrack?.id }

    private var staticLevel: Double {
        let clipFactor = min(Double(max(clipCount, 1)) * 0.14 + 0.1, 0.9)
        let volumeFactor = max(0.08, min((track.volumeDB + 60) / 72, 1))
        let selectedBoost = isSelected ? 0.12 : 0
        let mutedMultiplier = track.isMuted ? 0.08 : 1
        return min(max((clipFactor * volumeFactor * mutedMultiplier) + selectedBoost, 0.03), 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Top accent bar
            Rectangle()
                .fill(accent)
                .frame(height: 3)

            VStack(spacing: 5) {
                // Track name + number
                HStack(spacing: 5) {
                    Text(String(format: "T%02d", trackIndex + 1))
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.38))
                    Text(track.name)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // R/S/M buttons
                HStack(spacing: 4) {
                    MixTrackButton(title: "R", isOn: track.isRecordArmed, tint: MixPalette.recordArmed) {
                        store.selectTrack(track.id, clearSelectedClip: false)
                        store.toggleTrackRecordArm(track.id)
                    }
                    MixTrackButton(title: "S", isOn: track.isSolo, tint: MixPalette.gold) {
                        store.selectTrack(track.id, clearSelectedClip: false)
                        store.toggleTrackSolo(track.id)
                    }
                    MixTrackButton(title: "M", isOn: track.isMuted, tint: MixPalette.warn) {
                        store.selectTrack(track.id, clearSelectedClip: false)
                        store.toggleTrackMute(track.id)
                    }
                    Spacer(minLength: 0)
                    Text("\(clipCount)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(MixPalette.gold.opacity(0.7))
                }

                // Fader row: meter + vertical slider
                HStack(alignment: .bottom, spacing: 6) {
                    MixVerticalMeterView(level: staticLevel)
                        .frame(width: 10, height: 80)

                    // Vertical fader: rotate a slider so it runs bottom→top
                    Slider(
                        value: Binding(
                            get: { track.volumeDB },
                            set: {
                                store.selectTrack(track.id, clearSelectedClip: false)
                                store.updateTrackVolume(track.id, value: $0)
                            }
                        ),
                        in: -60...12
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 80, height: 16)   // pre-rotation size
                    .frame(width: 16, height: 80)    // post-rotation footprint
                }
                .frame(height: 80)

                // Volume readout
                Text(String(format: "%+.1f dB", track.volumeDB))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.65))

                // Pan slider + label
                Slider(
                    value: Binding(
                        get: { track.pan },
                        set: {
                            store.selectTrack(track.id, clearSelectedClip: false)
                            store.updateTrackPan(track.id, value: $0)
                        }
                    ),
                    in: -1...1
                )
                Text(panLabel)
                    .font(.system(size: 8.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.48))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(width: 108)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? MixPalette.mixerStripSelected : MixPalette.mixerStrip)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? accent.opacity(0.72) : MixPalette.panelStroke.opacity(0.55), lineWidth: 1)
        }
        // Background tap so sliders and buttons are not swallowed by the outer gesture.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { store.selectTrack(track.id, clearSelectedClip: false) }
        }
        .accessibilityLabel(track.name)
    }

    private var panLabel: String {
        switch track.pan {
        case let v where v < -0.01: return String(format: "L%.2f", abs(v))
        case let v where v > 0.01:  return String(format: "R%.2f", v)
        default: return "C"
        }
    }
}

@available(macOS 26.0, *)
struct MixMasterStripView: View {
    let sceneTitle: String
    let trackCount: Int
    let clipCount: Int
    let level: Double
    let sceneDuration: Double

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(MixPalette.steel.opacity(0.6))
                .frame(height: 3)

            VStack(spacing: 6) {
                Text("MASTER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(sceneTitle)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                MixVerticalMeterView(level: level)
                    .frame(width: 14, height: 80)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text(shortTimecode(sceneDuration))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))

                Text("\(trackCount)T  \(clipCount)C")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(width: 96)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(MixPalette.masterStrip)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MixPalette.panelStroke.opacity(0.7), lineWidth: 1)
        }
    }

    private func shortTimecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
