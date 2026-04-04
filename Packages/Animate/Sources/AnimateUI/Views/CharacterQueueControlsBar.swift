import SwiftUI

@available(macOS 26.0, *)
struct CharacterQueueControlsBar: View {
    @Bindable var store: AnimateStore

    var body: some View {
        HStack(spacing: 16) {
            // Gemini queue
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundStyle(store.geminiQueue.isEmpty ? .tertiary : .primary)
                Text("Gemini: \(store.geminiQueue.count)")
                    .fontWeight(.medium)
                    .foregroundStyle(store.geminiQueue.isEmpty ? .secondary : .primary)
                if !store.geminiQueue.isEmpty {
                    Button("Submit") { /* TODO: wire to submit logic */ }
                        .buttonStyle(.borderedProminent).controlSize(.mini)
                    Button("Clear") { store.clearGeminiQueue() }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            }

            Divider().frame(height: 16)

            // Meshy queue
            HStack(spacing: 6) {
                Image(systemName: "cube.fill")
                    .foregroundStyle(store.meshyQueue.isEmpty ? .tertiary : .primary)
                Text("Meshy: \(store.meshyQueue.count)")
                    .fontWeight(.medium)
                    .foregroundStyle(store.meshyQueue.isEmpty ? .secondary : .primary)
                if !store.meshyQueue.isEmpty {
                    Button("Submit") { /* TODO: wire to submit logic */ }
                        .buttonStyle(.borderedProminent).controlSize(.mini)
                    Button("Clear") { store.clearMeshyQueue() }
                        .buttonStyle(.bordered).controlSize(.mini)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.bar)
    }
}
