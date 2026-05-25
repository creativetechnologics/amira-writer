import SwiftUI

@available(macOS 26.0, *)
struct DebouncedTextEditorRow: View {
    let title: String
    let icon: String
    let storeValue: String
    let placeholder: String
    let onChange: (String) -> Void

    @State private var localText: String = ""
    @State private var hasAppeared = false
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $localText)
                    .font(.body)
                    .frame(minHeight: 100, maxHeight: 200)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
                    .onChange(of: localText) { _, newValue in
                        guard hasAppeared else { return }
                        debounceTask?.cancel()
                        let value = newValue
                        debounceTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(120))
                            guard !Task.isCancelled else { return }
                            onChange(value)
                        }
                    }

                if localText.isEmpty {
                    Text(placeholder)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
        }
        .onAppear {
            localText = storeValue
            hasAppeared = true
        }
        .onChange(of: storeValue) { _, newValue in
            if !hasAppeared || localText != newValue {
                localText = newValue
            }
        }
        .onDisappear {
            debounceTask?.cancel()
            debounceTask = nil
        }
    }
}
