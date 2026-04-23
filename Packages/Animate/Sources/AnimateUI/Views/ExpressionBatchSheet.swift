import SwiftUI

@available(macOS 26.0, *)
struct ExpressionBatchSheet: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter
    @Environment(\.dismiss) private var dismiss

    @State private var batchItems: [ExpressionBatchService.ExpressionBatchItem] = []
    @State private var isRunning = false
    @State private var progressCurrent = 0
    @State private var progressTotal = 0
    @State private var progressMessage: String?
    @State private var results: [ExpressionBatchService.ExpressionBatchResult] = []
    @State private var expandedPromptID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Expression Batch Generation")
                        .font(.headline)
                    Text("\(character.name) — \(batchItems.filter(\.isQueued).count) expressions queued")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !isRunning {
                    Button("Select All") {
                        for i in batchItems.indices { batchItems[i].isQueued = true }
                    }
                    .controlSize(.small)
                    Button("Deselect All") {
                        for i in batchItems.indices { batchItems[i].isQueued = false }
                    }
                    .controlSize(.small)
                }
            }
            .padding()

            Divider()

            if isRunning {
                // Progress
                VStack(spacing: 12) {
                    ProgressView(value: Double(progressCurrent), total: Double(max(progressTotal, 1)))
                    Text(progressMessage ?? "Generating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(progressCurrent)/\(progressTotal)")
                        .font(.caption.monospaced())
                }
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !results.isEmpty {
                // Results
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(results, id: \.emotionName) { result in
                            HStack {
                                Image(systemName: result.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(result.error == nil ? .green : .red)
                                Text(result.emotionName)
                                    .font(.subheadline)
                                Spacer()
                                if let error = result.error {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.vertical)
                }
            } else {
                // Expression list with toggles and prompt preview
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach($batchItems) { $item in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Toggle(isOn: $item.isQueued) {
                                        Text(item.emotionName)
                                            .font(.subheadline)
                                    }
                                    .toggleStyle(.checkbox)

                                    Spacer()

                                    Button {
                                        withAnimation {
                                            expandedPromptID = expandedPromptID == item.id ? nil : item.id
                                        }
                                    } label: {
                                        Image(systemName: "eye")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Preview prompt")
                                }

                                if expandedPromptID == item.id {
                                    Text(item.prompt)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .padding(8)
                                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            Divider()

            // Footer
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                if !results.isEmpty {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                } else if !isRunning {
                    Button {
                        runBatch()
                    } label: {
                        Label("Generate \(batchItems.filter(\.isQueued).count) Expressions", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(batchItems.filter(\.isQueued).isEmpty || !store.canGenerateGeminiImagesImmediately)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
        }
        .frame(width: 500, height: 450)
        .onAppear {
            loadBatchItems()
        }
    }

    private func loadBatchItems() {
        // Get all emotion displayNames from the preset library
        let emotionNames = EmotionLibrary.presets.map(\.displayName)
        batchItems = ExpressionBatchService.buildBatch(for: character, emotions: emotionNames)
    }

    private func runBatch() {
        isRunning = true
        progressCurrent = 0
        progressTotal = batchItems.filter(\.isQueued).count

        Task {
            do {
                results = try await ExpressionBatchService.runBatch(
                    items: batchItems,
                    character: character,
                    referenceImagePaths: character.referenceImagePaths,
                    store: store,
                    onProgress: { current, total, message in
                        progressCurrent = current
                        progressTotal = total
                        progressMessage = message
                    }
                )
            } catch {
                progressMessage = error.localizedDescription
            }
            isRunning = false
        }
    }
}
