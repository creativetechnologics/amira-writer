import SwiftUI

/// Shows the audio waveform for the currently-selected scene at the bottom of the
/// Animate workspace timeline.  The waveform is rendered by the existing
/// `AnimateAudioWaveformCache`; we observe its `@Published` properties so the
/// Image appears as soon as the background task finishes.
@available(macOS 26.0, *)
struct AudioWaveformTrackView: View {
    @Bindable var store: AnimateStore
    let scene: AnimationScene
    /// Shared cache — caller owns the @StateObject lifetime.
    @ObservedObject var waveformCache: AnimateAudioWaveformCache

    // Derived from cache — no separate @State polling needed
    private var waveformImage: CGImage? {
        guard let path = scene.defaultAudioPath, !path.isEmpty else { return nil }
        return waveformCache.waveformImage(for: path)
    }

    private var audioDuration: Double? {
        guard let path = scene.defaultAudioPath, !path.isEmpty else { return nil }
        return waveformCache.durationSeconds(for: path)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header row ────────────────────────────────────────────────
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("Audio")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let duration = audioDuration {
                    Text(formatDuration(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if scene.defaultAudioPath == nil || scene.defaultAudioPath!.isEmpty {
                    Text("No audio attached")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Pull from Mix button — posts a notification so MixAudioFlattenService
                // (built separately) can flatten and respond with a path.
                Button {
                    NotificationCenter.default.post(
                        name: AnimateAppSignals.requestMixAudioFlattenNotification,
                        object: nil,
                        userInfo: ["sceneID": scene.id]
                    )
                } label: {
                    Label("Pull from Mix", systemImage: "music.note.list")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Flatten the Mix audio for this scene into a single WAV and attach it here")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            // ── Waveform area ─────────────────────────────────────────────
            if let cgImage = waveformImage {
                Image(decorative: cgImage, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 48)
                    .clipped()
                    .background(Color.black.opacity(0.2))
            } else if let audioPath = scene.defaultAudioPath, !audioPath.isEmpty {
                // Audio is attached but not yet loaded — show spinner
                ProgressView()
                    .frame(height: 48)
                    .frame(maxWidth: .infinity)
            } else {
                // No audio attached
                Rectangle()
                    .fill(Color.secondary.opacity(0.05))
                    .frame(height: 48)
                    .overlay {
                        Text("Attach audio via Pull from Mix or set a path in the inspector")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .background(.bar)
        .task(id: scene.defaultAudioPath) {
            guard let path = scene.defaultAudioPath, !path.isEmpty else { return }
            waveformCache.request(path)
        }
    }

    // MARK: Helpers

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return "\(mins):\(String(format: "%02d", secs))"
    }
}
