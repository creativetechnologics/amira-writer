import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct MixTrackStripView: View {
    @Bindable var store: MixStore
    let trackIndex: Int
    let track: MixTrack
    let height: CGFloat
    @State private var confirmingDelete = false

    private var accent: Color {
        MixPalette.trackNeutral
    }

    // MARK: — Performance helpers
    // Computed once per body evaluation so that O(n) store traversals are not
    // repeated for individual rows in the layout (accent bar, meter, etc.).

    /// Number of clips on this track — O(clips) filter, captured once per render.
    private var clipCount: Int {
        store.currentClips.filter { $0.trackID == track.id }.count
    }

    /// Whether this track is currently selected — O(1) with pre-cached selectedTrackID.
    private var isSelected: Bool {
        store.currentSelectedTrackID == track.id
    }

    /// Total number of tracks — O(1) from currentSession to avoid currentTracks traversal.
    private var trackCount: Int {
        store.currentSession?.tracks.count ?? 0
    }

    private var staticLevel: Double {
        let clipFactor = min(Double(max(clipCount, 1)) * 0.12 + 0.12, 0.86)
        let volumeFactor = max(0.08, min((track.volumeDB + 60) / 72, 1))
        let selectedBoost = isSelected ? 0.12 : 0
        let armedBoost = track.isRecordArmed ? 0.08 : 0
        let mutedMultiplier = track.isMuted ? 0.08 : 1
        return min(max((clipFactor * volumeFactor * mutedMultiplier) + selectedBoost + armedBoost, 0.03), 1)
    }

    var body: some View {
        // Capture O(n) derived values once so each is computed exactly once per render.
        let selected = isSelected
        let trkCount = trackCount
        let lvl = staticLevel   // depends on clipCount + isSelected
        HStack(spacing: 0) {
            // Left accent edge — no floating card, just a flush color bar
            Rectangle()
                .fill(selected ? accent : accent.opacity(0.55))
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 0) {
                // Row 1: track number + name + vol readout + delete
                HStack(spacing: 6) {
                    Text(String(format: "T%02d", trackIndex + 1))
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent.opacity(0.9))
                        .frame(width: 24, alignment: .leading)

                    TextField(
                        "Track name",
                        text: Binding(
                            get: { track.name },
                            set: {
                                store.selectTrack(track.id, clearSelectedClip: false)
                                store.updateTrackName(track.id, name: $0)
                            }
                        )
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(String(format: "%+.0f", track.volumeDB))
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 30, alignment: .trailing)

                    if trkCount > 1 {
                        Button { confirmingDelete = true } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white.opacity(0.32))
                                .frame(width: 16, height: 16)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove track")
                    }
                }
                .frame(height: 26)
                .padding(.horizontal, 8)
                .confirmationDialog(
                    "Remove \"\(track.name)\"?",
                    isPresented: $confirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Remove Track", role: .destructive) { store.removeTrack(track.id) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("All clips on this track will be deleted.")
                }

                // Row 2: R/S/M + pan label + meter
                HStack(spacing: 5) {
                    MixTrackButton(title: "R", isOn: track.isRecordArmed, tint: MixPalette.recordArmed) {
                        store.selectTrack(track.id, clearSelectedClip: false)
                        store.toggleTrackRecordArm(track.id)
                    }
                    .accessibilityLabel(track.isRecordArmed ? "Disarm \(track.name)" : "Arm \(track.name) for recording")
                    MixTrackButton(title: "S", isOn: track.isSolo, tint: MixPalette.gold) {
                        store.selectTrack(track.id, clearSelectedClip: false)
                        store.toggleTrackSolo(track.id)
                    }
                    .accessibilityLabel(track.isSolo ? "Unsolo \(track.name)" : "Solo \(track.name)")
                    MixTrackButton(title: "M", isOn: track.isMuted, tint: MixPalette.warn) {
                        store.selectTrack(track.id, clearSelectedClip: false)
                        store.toggleTrackMute(track.id)
                    }
                    .accessibilityLabel(track.isMuted ? "Unmute \(track.name)" : "Mute \(track.name)")

                    Spacer(minLength: 4)

                    Text(panLabel)
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.42))

                    MixVerticalMeterView(level: lvl)
                        .frame(width: 8, height: 22)
                }
                .frame(height: 24)
                .padding(.horizontal, 8)

                // Row 3: Volume slider
                HStack(spacing: 6) {
                    Text("VOL")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                        .frame(width: 22, alignment: .leading)
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
                }
                .frame(height: 22)
                .padding(.horizontal, 8)

                // Row 4: Pan slider
                HStack(spacing: 6) {
                    Text("PAN")
                        .font(.system(size: 8, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.32))
                        .frame(width: 22, alignment: .leading)
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
                }
                .frame(height: 22)
                .padding(.horizontal, 8)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(selected ? MixPalette.trackSelected : MixPalette.trackSurface)
        // Use background tap so controls (TextField, Slider, Buttons) aren't swallowed.
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { store.selectTrack(track.id, clearSelectedClip: true) }
        }
        .accessibilityLabel(track.name)
        .accessibilityHint("Tap to select track.")
        .contextMenu {
            Button("Add Track") { _ = store.addTrack() }
            // Route through confirmingDelete so the same confirmation sheet is shown
            // regardless of whether the user clicks the button or uses the context menu.
            Button("Remove Track", role: .destructive) { confirmingDelete = true }
                .disabled(trkCount <= 1)
        }
    }

    private var panLabel: String {
        switch track.pan {
        case let value where value < -0.01:
            return String(format: "L %.2f", abs(value))
        case let value where value > 0.01:
            return String(format: "R %.2f", value)
        default:
            return "C"
        }
    }
}
