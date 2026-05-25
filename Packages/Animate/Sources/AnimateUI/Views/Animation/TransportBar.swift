import SwiftUI

@available(macOS 26.0, *)
struct TransportBar: View {
    @Bindable var store: AnimateStore

    private var timelineFrameCount: Int {
        let sceneFrameCount: Int = {
            guard let scene = store.selectedScene else { return 0 }
            let keyframeCount = (scene.keyframes.map(\.frame).max().map { $0 + 1 }) ?? 0
            let shotCount = (scene.shots.map(\.endFrame).max().map { $0 + 1 }) ?? 0
            return max(keyframeCount, shotCount, 1)
        }()

        return max(sceneFrameCount, store.currentFrame + 1, 1)
    }

    private var maxPlayableFrame: Int {
        max(timelineFrameCount - 1, 0)
    }

    private var frameBinding: Binding<Double> {
        Binding(
            get: {
                Double(min(max(store.currentFrame, 0), maxPlayableFrame))
            },
            set: { newValue in
                store.currentFrame = min(max(Int(newValue.rounded()), 0), maxPlayableFrame)
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: {
                    store.stopPlayback()
                    store.currentFrame = 0
                }) {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(.borderless)

                Button(action: { store.togglePlayback() }) {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)

                Text("Frame \(store.currentFrame)")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 80, alignment: .leading)

                Spacer(minLength: 12)

                Text(store.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Text("Playhead")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)

                Slider(
                    value: frameBinding,
                    in: 0...Double(maxPlayableFrame),
                    step: 1,
                    onEditingChanged: { isEditing in
                        if isEditing {
                            store.stopPlayback()
                        }
                    }
                )
                .tint(.accentColor)
                .disabled(maxPlayableFrame == 0)

                Text("\(timelineFrameCount)f")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
