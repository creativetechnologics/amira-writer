import SwiftUI

@available(macOS 26.0, *)
struct CharacterQueueControlsBar: View {
    @Bindable var store: AnimateStore

    var body: some View {
        let isEmpty = store.geminiQueue.isEmpty
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                // Gemini queue
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(isEmpty ? .tertiary : .primary)
                    Text("Gemini: \(store.geminiQueue.count)")
                        .fontWeight(.medium)
                        .foregroundStyle(isEmpty ? .secondary : .primary)
                    if !isEmpty {
                        Button("Submit") { /* TODO: wire to submit logic */ }
                            .buttonStyle(.borderedProminent).controlSize(.mini)
                        Button("Clear") { store.clearGeminiQueue() }
                            .buttonStyle(.bordered).controlSize(.mini)
                    }
                }
            }
            .font(.caption)
            .padding(.horizontal, 16).padding(.vertical, 6)
            .background(.bar)

            Divider()
                .opacity(isEmpty ? 0 : 1)
        }
    }
}
