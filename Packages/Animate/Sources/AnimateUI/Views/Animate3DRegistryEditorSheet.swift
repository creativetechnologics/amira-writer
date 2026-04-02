import SwiftUI

@available(macOS 26.0, *)
enum Animate3DRegistryManifestKind: String, Hashable, Sendable {
    case assetRegistry
    case characterRegistry
    case motionRegistry
    case worldCatalog
    case styleProfiles
    case cameraPresets
    case lightRigs
    case atmospherePresets
}

@available(macOS 26.0, *)
struct Animate3DRegistryEditorContext: Identifiable, Hashable {
    var id: String { "\(kind.rawValue):\(relativePath)" }
    var kind: Animate3DRegistryManifestKind
    var title: String
    var relativePath: String
}

@available(macOS 26.0, *)
struct Animate3DRegistryEditorSheet: View {
    let projectURL: URL
    let context: Animate3DRegistryEditorContext
    let onClose: () -> Void

    @State private var text: String = ""
    @State private var errorMessage: String?
    @State private var validationMessage: String = "Loading…"
    @State private var didLoad = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.title)
                        .font(.title3.weight(.semibold))
                    Text(context.relativePath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                statusPill
                Button("Reload") { load() }
                    .buttonStyle(.bordered)
                Button("Format JSON") { format() }
                    .buttonStyle(.bordered)
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()

            Divider()

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .padding(12)

            Divider()

            HStack {
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Edit raw JSON manifest content here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { onClose() }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
        .frame(minWidth: 840, minHeight: 620)
        .task {
            guard !didLoad else { return }
            didLoad = true
            load()
        }
    }

    private func load() {
        let url = projectURL.appendingPathComponent(context.relativePath)
        do {
            let data = try Data(contentsOf: url)
            text = String(decoding: data, as: UTF8.self)
            validate()
        } catch {
            text = defaultTemplate()
            errorMessage = "Could not load manifest. Starting with empty JSON."
            validate()
        }
    }

    private func save() {
        let url = projectURL.appendingPathComponent(context.relativePath)
        do {
            let normalized = try normalizedJSON(text)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try normalized.write(to: url, atomically: true, encoding: .utf8)
            text = normalized
            errorMessage = nil
            validationMessage = "Valid • Saved"
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
            validationMessage = "Invalid JSON"
        }
    }

    private func format() {
        do {
            text = try normalizedJSON(text)
            errorMessage = nil
            validationMessage = "Valid JSON"
        } catch {
            errorMessage = "Format failed: \(error.localizedDescription)"
            validationMessage = "Invalid JSON"
        }
    }

    private func validate() {
        do {
            _ = try normalizedJSON(text)
            validationMessage = "Valid JSON"
        } catch {
            validationMessage = "Invalid JSON"
        }
    }

    private func normalizedJSON(_ source: String) throws -> String {
        let data = Data(source.utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        switch context.kind {
        case .assetRegistry:
            let manifest = try JSONDecoder().decode(Animate3DAssetRegistry.self, from: data)
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        case .characterRegistry:
            let manifest = try JSONDecoder().decode(Animate3DCharacterRegistry.self, from: data)
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        case .motionRegistry:
            let manifest = try JSONDecoder().decode(Animate3DMotionRegistry.self, from: data)
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        case .worldCatalog:
            let manifest = try JSONDecoder().decode(Animate3DWorldCatalog.self, from: data)
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        case .styleProfiles:
            let manifest = try JSONDecoder().decode(Animate3DStyleProfileManifest.self, from: data)
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        case .cameraPresets:
            let manifest = try JSONDecoder().decode(Animate3DCameraPresetManifest.self, from: data)
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        case .lightRigs:
            let manifest = try JSONDecoder().decode(Animate3DLightRigManifest.self, from: data)
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        case .atmospherePresets:
            let manifest = try JSONDecoder().decode(Animate3DAtmospherePresetManifest.self, from: data)
            return String(decoding: try encoder.encode(manifest), as: UTF8.self)
        }
    }

    private func defaultTemplate() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data: Data?

        switch context.kind {
        case .assetRegistry:
            data = try? encoder.encode(Animate3DAssetRegistry())
        case .characterRegistry:
            data = try? encoder.encode(Animate3DCharacterRegistry())
        case .motionRegistry:
            data = try? encoder.encode(Animate3DMotionRegistry())
        case .worldCatalog:
            data = try? encoder.encode(Animate3DWorldCatalog())
        case .styleProfiles:
            data = try? encoder.encode(Animate3DStyleProfileManifest())
        case .cameraPresets:
            data = try? encoder.encode(Animate3DCameraPresetManifest())
        case .lightRigs:
            data = try? encoder.encode(Animate3DLightRigManifest())
        case .atmospherePresets:
            data = try? encoder.encode(Animate3DAtmospherePresetManifest())
        }

        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    private var statusPill: some View {
        Text(validationMessage)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(validationMessage.hasPrefix("Valid") ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
            )
            .foregroundStyle(validationMessage.hasPrefix("Valid") ? Color.green : Color.orange)
    }
}
