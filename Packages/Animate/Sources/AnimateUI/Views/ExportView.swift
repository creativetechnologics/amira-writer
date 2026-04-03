import SwiftUI
import AVFoundation

/// Export settings and progress UI.
///
/// Allows the user to configure resolution, format, frame range, and audio,
/// then kicks off video export via the `VideoExporter`.
@available(macOS 26.0, *)
struct ExportView: View {
    @Bindable var store: AnimateStore
    @Environment(\.dismiss) private var dismiss

    @State private var format: VideoExporter.ExportFormat = .mp4
    @State private var resolution: VideoExporter.ExportResolution = .hd1080
    @State private var fps: Int = 24
    @State private var startFrame: Int = 0
    @State private var endFrame: Int = 0
    @State private var audioURL: URL?
    @State private var isExporting = false
    @State private var exportProgress: Double = 0
    @State private var exportMessage: String = ""
    @State private var exportError: String?
    @State private var exporter: VideoExporter?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if isExporting {
                exportProgressView
            } else {
                settingsForm
            }

            Divider()
            footer
        }
        .frame(width: 480, height: isExporting ? 240 : 420)
        .onAppear {
            fps = store.fps
            endFrame = max(store.totalFrames, 1)
            if audioURL == nil {
                audioURL = store.suggestedExportAudioURL()
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack {
            Image(systemName: "film.stack")
                .foregroundStyle(.blue)
            Text("Export Video")
                .font(.headline)
            Spacer()
        }
        .padding()
    }

    // MARK: - Settings Form

    @ViewBuilder
    private var settingsForm: some View {
        Form {
            Section("Format") {
                Picker("Container", selection: $format) {
                    ForEach(VideoExporter.ExportFormat.allCases, id: \.self) { fmt in
                        Text(fmt.rawValue).tag(fmt)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Resolution", selection: $resolution) {
                    ForEach(VideoExporter.ExportResolution.allCases, id: \.self) { res in
                        Text(res.rawValue).tag(res)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Frame Rate")
                    Spacer()
                    Picker("", selection: $fps) {
                        Text("12 fps").tag(12)
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 100)
                }
            }

            Section("Frame Range") {
                HStack {
                    LabeledContent("Start") {
                        TextField("", value: $startFrame, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .monospacedDigit()
                    }

                    LabeledContent("End") {
                        TextField("", value: $endFrame, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .monospacedDigit()
                    }
                }

                let totalFrames = max(endFrame - startFrame, 0)
                let durationSec = fps > 0 ? Double(totalFrames) / Double(fps) : 0
                Text("\(totalFrames) frames (\(String(format: "%.1f", durationSec))s at \(fps) fps)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let scene = store.selectedScene {
                Section("Scene Framing") {
                    LabeledContent("Active Shot") {
                        Text(activeCameraShot(for: scene)?.displayName ?? "None")
                    }

                    LabeledContent("Active Focus") {
                        Text(sceneTemplateFocusName(for: scene) ?? "None")
                    }

                    LabeledContent("Shot Intent") {
                        Text(activeShotIntent()?.displayName ?? "None")
                    }

                    LabeledContent("Suggested Move") {
                        Text(suggestedCameraMovement()?.displayName ?? "None")
                    }

                    LabeledContent("Beat Label") {
                        Text(activeBeatLabel() ?? "None")
                    }

                    if let notes = activeBeatNotes() {
                        Text(notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Audio") {
                HStack {
                    if let audioURL {
                        Image(systemName: "waveform")
                            .foregroundStyle(.green)
                        Text(audioURL.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Remove") {
                            self.audioURL = nil
                        }
                        .controlSize(.small)
                    } else {
                        Text("No audio track")
                            .foregroundStyle(.tertiary)
                        Spacer()
                    }

                    Button("Choose Audio...") {
                        chooseAudio()
                    }
                    .controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal)
    }

    // MARK: - Export Progress

    @ViewBuilder
    private var exportProgressView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView(value: exportProgress) {
                Text(exportMessage)
                    .font(.callout)
            }
            .progressViewStyle(.linear)

            Text("\(Int(exportProgress * 100))%")
                .font(.title2)
                .monospacedDigit()

            if let error = exportError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }

            Spacer()
        }
        .padding(32)
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            Button("Cancel") {
                if isExporting {
                    exporter?.isCancelled = true
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            if !isExporting {
                Button("Export...") {
                    startExport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(endFrame <= startFrame)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
    }

    // MARK: - Actions

    private func chooseAudio() {
        let panel = NSOpenPanel()
        panel.title = "Choose Audio File"
        panel.allowedContentTypes = [.audio, .wav, .mp3, .aiff]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            audioURL = url
        }
    }

    private func startExport() {
        let panel = NSSavePanel()
        panel.title = "Export Video"
        let projectName = store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
            panel.nameFieldStringValue = "\(projectName).\(format.fileExtension)"
        panel.begin { response in
            guard response == .OK, let outputURL = panel.url else { return }

            let settings = VideoExporter.ExportSettings(
                format: format,
                resolution: resolution,
                fps: fps,
                startFrame: startFrame,
                endFrame: endFrame,
                audioURL: audioURL,
                outputURL: outputURL
            )

            isExporting = true
            exportError = nil

            let videoExporter = VideoExporter()
            exporter = videoExporter

            Task { @MainActor in
                // Start progress polling concurrently
                let pollTask = Task { @MainActor in
                    while !Task.isCancelled {
                        exportProgress = videoExporter.progress
                        exportMessage = videoExporter.progressMessage
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }

                do {
                    try await store.exportVideo(settings: settings, exporter: videoExporter)
                    pollTask.cancel()

                    exportProgress = 1.0
                    exportMessage = "Export complete!"
                    store.statusMessage = "Exported to \(outputURL.lastPathComponent)"

                    try await Task.sleep(for: .seconds(1))
                    dismiss()
                } catch {
                    pollTask.cancel()
                    exportError = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }

    private func activeCameraShot(for _: AnimationScene) -> CameraShot? {
        store.evaluatedEffectiveCameraShot(at: startFrame)
    }

    private func sceneTemplateFocusName(for _: AnimationScene) -> String? {
        guard let focusCharacterID = store.evaluatedCameraFocusCharacterID(at: startFrame) else {
            return nil
        }

        return store.characters.first(where: { $0.id == focusCharacterID })?.name
    }

    private func activeShotIntent() -> ShotIntent? {
        store.evaluatedCameraShotIntent(at: startFrame)
    }

    private func suggestedCameraMovement() -> CameraMovement? {
        store.recommendedCameraMovementFromIntent(at: startFrame)
    }

    private func activeBeatLabel() -> String? {
        let label = store.evaluatedCameraBeatLabel(at: startFrame)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (label?.isEmpty == false) ? label : nil
    }

    private func activeBeatNotes() -> String? {
        let notes = store.evaluatedCameraBeatNotes(at: startFrame)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (notes?.isEmpty == false) ? notes : nil
    }
}
