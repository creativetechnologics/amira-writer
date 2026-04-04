import AppKit
import ProjectKit
import SwiftUI
import UniformTypeIdentifiers

/// Sheet for exporting the current 3D scene as a video file.
///
/// Lets the user pick resolution, FPS, and cel-shading options before
/// triggering `Scene3DVideoExporter.export(...)`.  A progress bar and
/// status label keep the user informed during the (potentially long)
/// render pass, and a "Reveal in Finder" button appears on success.
@available(macOS 26.0, *)
struct Scene3DExportSheet: View {

    // MARK: - Inputs

    let renderer: ScenePreviewRenderer
    let scenario: Animate3DPreviewScenario

    @Environment(\.dismiss) private var dismiss

    // MARK: - Export settings

    @State private var selectedResolution: ExportResolution = .hd1080
    @State private var selectedFPS: ExportFPS = .fps24
    @State private var applyCelShading: Bool = true

    // MARK: - Runtime state

    @State private var isExporting: Bool = false
    @State private var exportProgress: Double = 0.0   // 0…1
    @State private var exportedURL: URL? = nil
    @State private var errorMessage: String? = nil
    @State private var statusLabel: String = ""

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 4) {
                Text("EXPORT 3D VIDEO")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Text(scenario.sceneName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text("\(scenario.totalFrames) frames · \(scenario.baseFPS) fps base")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }

            Divider()

            // Settings
            Group {
                settingRow(label: "Resolution") {
                    Picker("Resolution", selection: $selectedResolution) {
                        ForEach(ExportResolution.allCases) { res in
                            Text(res.title).tag(res)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 240)
                }

                settingRow(label: "Frame Rate") {
                    Picker("FPS", selection: $selectedFPS) {
                        ForEach(ExportFPS.allCases) { fps in
                            Text(fps.title).tag(fps)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                }

                settingRow(label: "Cel Shading") {
                    Toggle("Apply Cel Shading", isOn: $applyCelShading)
                        .toggleStyle(.checkbox)
                }
            }

            Divider()

            // Progress / result area
            if isExporting {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: exportProgress)
                        .progressViewStyle(.linear)
                    if !statusLabel.isEmpty {
                        Text(statusLabel)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }
                }
            } else if let url = exportedURL {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if let error = errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Action buttons
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
                .disabled(isExporting)

                Button {
                    startExport()
                } label: {
                    if isExporting {
                        Label("Exporting…", systemImage: "film.stack")
                    } else {
                        Label("Export Video", systemImage: "film.stack")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isExporting)
            }
        }
        .padding(24)
        .frame(minWidth: 480, maxWidth: 560)
        .background(OperaChromeTheme.workspaceBackground)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(OperaChromeTheme.textSecondary)
                .frame(width: 90, alignment: .trailing)
            content()
        }
    }

    // MARK: - Export flow

    private func startExport() {
        // Ask the user where to save before kicking off the render.
        let panel = NSSavePanel()
        panel.title = "Export 3D Video"
        panel.prompt = "Export"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "\(scenario.sceneName.replacingOccurrences(of: " ", with: "-")).mp4"

        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        // Remove any existing file at the destination so AVAssetWriter won't fail.
        try? FileManager.default.removeItem(at: outputURL)

        isExporting = true
        exportProgress = 0.0
        exportedURL = nil
        errorMessage = nil
        statusLabel = "Preparing renderer…"

        let exporter = Scene3DVideoExporter()
        exporter.applyCelShading = applyCelShading

        let totalFrames = max(scenario.totalFrames, 1)
        exporter.onProgress = { current, total in
            Task { @MainActor in
                exportProgress = Double(current) / Double(max(total, 1))
                statusLabel = "Frame \(current) / \(total)"
            }
        }

        let settings = Scene3DVideoExporter.Settings(
            outputURL: outputURL,
            width: selectedResolution.width,
            height: selectedResolution.height,
            fps: selectedFPS.rawValue,
            startFrame: 0,
            endFrame: max(totalFrames - 1, 0)
        )

        Task { @MainActor in
            do {
                statusLabel = "Rendering frames…"
                try await exporter.export(renderer: renderer, settings: settings)
                exportedURL = outputURL
                exportProgress = 1.0
                statusLabel = "Export complete."
            } catch {
                errorMessage = error.localizedDescription
                statusLabel = ""
            }
            isExporting = false
        }
    }

    // MARK: - Nested enums

    enum ExportResolution: Int, CaseIterable, Identifiable {
        case hd720 = 720
        case hd1080 = 1080
        case uhd4k = 2160

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .hd720:  return "720p"
            case .hd1080: return "1080p"
            case .uhd4k:  return "4K"
            }
        }

        var width: Int {
            switch self {
            case .hd720:  return 1280
            case .hd1080: return 1920
            case .uhd4k:  return 3840
            }
        }

        var height: Int { rawValue }
    }

    enum ExportFPS: Int, CaseIterable, Identifiable {
        case fps24 = 24
        case fps30 = 30
        case fps60 = 60

        var id: Int { rawValue }
        var title: String { "\(rawValue) fps" }
    }
}
