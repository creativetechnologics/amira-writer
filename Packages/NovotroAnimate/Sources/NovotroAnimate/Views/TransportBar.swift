import SwiftUI

@available(macOS 26.0, *)
struct TransportBar: View {
    @Bindable var store: AnimateStore

    var body: some View {
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

            Spacer()

            Text(store.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
