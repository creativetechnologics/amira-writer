import Foundation

@available(macOS 26.0, *)
@MainActor
final class GenerationSettingsStore {
    unowned let parent: AnimateStore
    init(parent: AnimateStore) { self.parent = parent }

    func logGeminiAPICall(endpoint: String, source: String) {
        parent.geminiAPICallCount += 1
        parent.geminiAPICallLog.append((date: Date(), endpoint: endpoint, source: source))
        if parent.geminiAPICallLog.count > 100 { parent.geminiAPICallLog.removeFirst(parent.geminiAPICallLog.count - 100) }
        print("[AnimateStore] Gemini API call #\(parent.geminiAPICallCount): \(source) → \(endpoint)")
    }
}
