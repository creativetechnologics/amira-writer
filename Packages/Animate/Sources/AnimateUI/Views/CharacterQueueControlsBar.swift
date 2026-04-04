import SwiftUI

@available(macOS 26.0, *)
struct CharacterQueueControlsBar: View {
    @Bindable var store: AnimateStore

    var body: some View {
        if !store.geminiQueue.isEmpty || !store.meshyQueue.isEmpty {
            HStack(spacing: 16) {
                if !store.geminiQueue.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Gemini: \(store.geminiQueue.count)")
                            .fontWeight(.medium)
                        Button("Submit") { /* TODO: wire to submit logic */ }
                            .buttonStyle(.borderedProminent).controlSize(.mini)
                        Button("Clear") { store.clearGeminiQueue() }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
                if !store.meshyQueue.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "cube.fill")
                        Text("Meshy: \(store.meshyQueue.count)")
                            .fontWeight(.medium)
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
}
