import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct MotionGenerationPane: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter

    @State private var promptText: String = ""
    @State private var durationSeconds: Double = 4.0
    @State private var cfgScale: Double = 7.5
    @State private var selectedCategory: HunyuanMotionService.MotionCategory?
    @State private var isGenerating: Bool = false
    @State private var generationProgress: String = ""
    @State private var generationError: String?
    @State private var generatedMotionPaths: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            promptSection
            Divider()
            configSection
            Divider()
            actionSection

            if !generatedMotionPaths.isEmpty {
                Divider()
                generatedMotionsSection
            }
        }
    }

    // MARK: - Prompt

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Motion Prompt")
                .font(.subheadline.weight(.semibold))

            TextEditor(text: $promptText)
                .font(.callout)
                .frame(height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                )

            // Quick prompt buttons from categories
            HStack(spacing: 8) {
                Text("Quick:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(Array(HunyuanMotionService.MotionCategory.allCases.prefix(4)), id: \.self) { category in
                    Button(category.rawValue) {
                        if let example = category.examplePrompts.first {
                            promptText = example
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            // Auto-generate from character actions
            Button {
                promptText = HunyuanMotionService.motionPrompt(
                    for: "gesture",
                    characterName: character.name,
                    emotion: nil,
                    intensity: 0.5
                )
            } label: {
                Label("Auto-Prompt from Character", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Config

    private var configSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Settings")
                .font(.subheadline.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Duration")
                        .font(.callout)
                    HStack {
                        Slider(value: $durationSeconds, in: 1...12, step: 0.5)
                            .frame(width: 150)
                        Text("\(durationSeconds, specifier: "%.1f")s")
                            .font(.callout.monospaced())
                            .frame(width: 40)
                    }
                }

                GridRow {
                    Text("Guidance")
                        .font(.callout)
                    HStack {
                        Slider(value: $cfgScale, in: 1...15, step: 0.5)
                            .frame(width: 150)
                        Text("\(cfgScale, specifier: "%.1f")")
                            .font(.callout.monospaced())
                            .frame(width: 40)
                    }
                }
            }

            Text("Higher guidance follows the prompt more closely. Lower values produce more natural motion.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Action

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button {
                    Task { await generateMotion() }
                } label: {
                    Label("Generate Motion", systemImage: "figure.walk.motion")
                }
                .buttonStyle(.borderedProminent)
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating)

                if isGenerating {
                    ProgressView()
                        .controlSize(.small)
                    Text(generationProgress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = generationError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding(10)
                .background(.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Generated Motions

    private var generatedMotionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generated Motions")
                .font(.subheadline.weight(.semibold))

            ForEach(generatedMotionPaths, id: \.absoluteString) { path in
                HStack(spacing: 10) {
                    Image(systemName: "figure.walk.motion")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(path.lastPathComponent)
                            .font(.callout)
                        Text(path.deletingLastPathComponent().lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([path])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
                .padding(8)
                .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Generation

    private func generateMotion() async {
        isGenerating = true
        generationError = nil
        generationProgress = "Preparing..."

        guard let animateURL = store.animateURL else {
            generationError = "No project open."
            isGenerating = false
            return
        }

        let slug = character.owpSlug.isEmpty ? character.id.uuidString : character.owpSlug
        let destinationDir = animateURL
            .appendingPathComponent("Characters")
            .appendingPathComponent(slug)
            .appendingPathComponent("motions")

        let service = HunyuanMotionService()
        let request = HunyuanMotionService.MotionRequest(
            prompt: promptText.trimmingCharacters(in: .whitespacesAndNewlines),
            durationSeconds: durationSeconds,
            cfgScale: cfgScale
        )

        do {
            let fbxPath = try await service.generateAndDownload(
                request: request,
                destinationDirectory: destinationDir
            ) { progress in
                Task { @MainActor in
                    generationProgress = progress
                }
            }
            generatedMotionPaths.insert(fbxPath, at: 0)
            generationProgress = "Done!"
        } catch {
            generationError = error.localizedDescription
        }

        isGenerating = false
    }
}
