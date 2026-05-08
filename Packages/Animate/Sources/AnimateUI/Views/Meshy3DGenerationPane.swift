import SwiftUI
import AppKit
import ProjectKit

/// Characters-page collapsible for Meshy.ai 3D model generation.
///
/// Auto-selects up to 4 full-body pose images from the character's first costume,
/// lets the user configure generation parameters, and triggers the Meshy API pipeline.
@available(macOS 26.0, *)
struct Meshy3DGenerationPane: View {
    @Bindable var store: AnimateStore
    let characterID: UUID

    @State private var selectedImagePaths: [String] = []
    @State private var aiModel: String = "latest"
    @State private var topology: String = "triangle"
    @State private var targetPolycount: Int = 100_000
    @State private var shouldTexture: Bool = true
    @State private var enablePBR: Bool = false
    @State private var removeLighting: Bool = true
    @State private var targetFormats: [String] = ["glb", "usdz"]
    @State private var symmetryMode: String = "auto"
    @State private var isGenerating: Bool = false
    @State private var generationStatus: String = ""
    @State private var generationProgress: Int = 0
    @State private var lastTaskID: String? = nil
    @State private var lastError: String? = nil
    @State private var meshyBalance: Int? = nil
    @State private var isCheckingBalance: Bool = false

    private var character: AnimationCharacter? {
        store.characters.first(where: { $0.id == characterID })
    }

    /// All available full-body pose slots from the first costume (or all costumes)
    private var availablePoseSlots: [(pose: CharacterReferencePose, path: String)] {
        guard let character = character else { return [] }
        let costumes = character.costumeReferenceSets
        guard !costumes.isEmpty else { return [] }
        // Use the first costume that has approved full-body poses
        for costume in costumes {
            let slots = costume.fullBodySlots.compactMap { slot -> (CharacterReferencePose, String)? in
                guard let path = slot.approvedVariant?.imagePath else { return nil }
                return (slot.pose, path)
            }
            if !slots.isEmpty { return slots }
        }
        return []
    }

    /// Default selection: up to 4 poses (front, left, right, back)
    private var defaultSelectedPaths: [String] {
        let poses: [CharacterReferencePose] = [.frontNeutral, .leftProfile, .rightProfile, .back]
        return poses.compactMap { pose in
            availablePoseSlots.first(where: { $0.pose == pose })?.path
        }
    }

    private var estimatedCredits: Int {
        let request = MeshyMultiImageRequest(
            imageURLs: selectedImagePaths,
            aiModel: aiModel,
            topology: topology,
            targetPolycount: targetPolycount,
            shouldRemesh: true,
            shouldTexture: shouldTexture,
            enablePBR: enablePBR,
            removeLighting: removeLighting,
            targetFormats: targetFormats,
            symmetryMode: symmetryMode
        )
        return request.estimatedCredits
    }

    private var hasAPIKey: Bool {
        !store.meshyAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canGenerate: Bool {
        hasAPIKey && !selectedImagePaths.isEmpty && !isGenerating
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Image selection
            imageSelectionSection

            Divider()

            // Configuration
            configurationSection

            Divider()

            // Generation controls
            generationSection
        }
        .onAppear {
            if selectedImagePaths.isEmpty {
                selectedImagePaths = defaultSelectedPaths
            }
            Task { await checkBalance() }
        }
    }

    // MARK: - Image Selection

    private var imageSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Reference Images", systemImage: "photo.stack")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(selectedImagePaths.count)/4 selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if availablePoseSlots.isEmpty {
                Text("No approved full-body poses found. Generate poses in the Character Reference Workflow first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(availablePoseSlots, id: \.path) { slot in
                            poseThumbnail(slot: slot)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
        }
    }

    @ViewBuilder
    private func poseThumbnail(slot: (pose: CharacterReferencePose, path: String)) -> some View {
        let isSelected = selectedImagePaths.contains(slot.path)
        let imageURL = store.resolvedCharacterAssetURL(for: slot.path)
            ?? (FileManager.default.fileExists(atPath: slot.path) ? URL(fileURLWithPath: slot.path) : nil)

        Button {
            if isSelected {
                selectedImagePaths.removeAll { $0 == slot.path }
            } else if selectedImagePaths.count < 4 {
                selectedImagePaths.append(slot.path)
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if let url = imageURL,
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.2))
                            .overlay(
                                Image(systemName: "person.fill")
                                    .foregroundStyle(.tertiary)
                            )
                    }
                }
                .frame(width: 80, height: 100)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                )

                Text(slot.pose.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .clipShape(Capsule())
                    .padding(4)
            }
        }
        .buttonStyle(.plain)
        .opacity(isSelected ? 1.0 : 0.5)
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Configuration", systemImage: "gearshape.2")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 16) {
                // AI Model
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI Model")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $aiModel) {
                        Text("Latest").tag("latest")
                        Text("Meshy-6").tag("meshy-6")
                        Text("Meshy-5").tag("meshy-5")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }

                // Topology
                VStack(alignment: .leading, spacing: 4) {
                    Text("Topology")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $topology) {
                        Text("Triangle").tag("triangle")
                        Text("Quad").tag("quad")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 140)
                }
            }

            HStack(spacing: 16) {
                // Target Polycount
                VStack(alignment: .leading, spacing: 4) {
                    Text("Polycount: \(targetPolycount.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(targetPolycount) },
                        set: { targetPolycount = Int($0) }
                    ), in: 10000...300000, step: 10000)
                    .frame(width: 200)
                }

                // Symmetry
                VStack(alignment: .leading, spacing: 4) {
                    Text("Symmetry")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $symmetryMode) {
                        Text("Auto").tag("auto")
                        Text("On").tag("on")
                        Text("Off").tag("off")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
            }

            HStack(spacing: 20) {
                Toggle("Texture", isOn: $shouldTexture)
                    .toggleStyle(.switch)
                Toggle("PBR Maps", isOn: $enablePBR)
                    .toggleStyle(.switch)
                Toggle("Remove Lighting", isOn: $removeLighting)
                    .toggleStyle(.switch)
            }
            .font(.caption)

            // Output formats
            VStack(alignment: .leading, spacing: 4) {
                Text("Output Formats")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    ForEach(["glb", "usdz", "obj", "fbx"], id: \.self) { format in
                        FormatToggle(format: format, selectedFormats: $targetFormats)
                    }
                }
            }
        }
    }

    // MARK: - Generation

    private var generationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    if let balance = meshyBalance {
                        Text("Balance: \(balance) credits")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("Estimated cost: \(estimatedCredits) credits")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isGenerating {
                    VStack(alignment: .trailing, spacing: 4) {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text(generationStatus)
                                .font(.caption)
                        }
                        if generationProgress > 0 {
                            ProgressView(value: Double(generationProgress), total: 100)
                                .frame(width: 120)
                        }
                    }
                } else if let error = lastError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else if let taskID = lastTaskID {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Task \(taskID.prefix(8))... completed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await startGeneration() }
                } label: {
                    Label("Generate 3D Model", systemImage: "cube")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!canGenerate)
            }

            if !hasAPIKey {
                HStack(spacing: 6) {
                    Image(systemName: "key.fill")
                        .foregroundStyle(.orange)
                    Text("Meshy API key required. Add it in API Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Actions

    private func checkBalance() async {
        guard hasAPIKey else { return }
        isCheckingBalance = true
        defer { isCheckingBalance = false }

        let service = MeshyService(apiKey: store.meshyAPIKey)
        do {
            let balance = try await service.checkBalance()
            meshyBalance = balance
        } catch {
            // Silently fail on balance check — not critical
            meshyBalance = nil
        }
    }

    private func startGeneration() async {
        guard !selectedImagePaths.isEmpty else { return }
        guard hasAPIKey else { return }

        isGenerating = true
        lastError = nil
        lastTaskID = nil
        generationStatus = "Uploading images..."
        generationProgress = 0

        do {
            // Convert selected images to JPEG base64 (resized to manageable size)
            let imageDataURIs = try selectedImagePaths.map { path -> String in
                let url = store.resolvedCharacterAssetURL(for: path)
                    ?? URL(fileURLWithPath: path)
                let sourceImage = NSImage(contentsOf: url)
                let data = sourceImage?.resizedJPEGData(maxDimension: 1024, quality: 0.85)
                    ?? (try? Data(contentsOf: url)) ?? Data()
                let base64 = data.base64EncodedString()
                return "data:image/jpeg;base64,\(base64)"
            }

            // Create the request
            let request = MeshyMultiImageRequest(
                imageURLs: imageDataURIs,
                aiModel: aiModel,
                topology: topology,
                targetPolycount: targetPolycount,
                shouldRemesh: true,
                shouldTexture: shouldTexture,
                enablePBR: enablePBR,
                removeLighting: removeLighting,
                textureImageURL: imageDataURIs.first,
                targetFormats: targetFormats,
                symmetryMode: symmetryMode
            )

            let service = MeshyService(apiKey: store.meshyAPIKey)

            generationStatus = "Creating task..."
            let taskID = try await service.createMultiImageTo3D(request: request)
            lastTaskID = taskID

            // Poll for completion
            let result = try await service.pollUntilComplete(
                endpoint: "/multi-image-to-3d",
                taskID: taskID,
                onProgress: { response in
                    DispatchQueue.main.async {
                        self.generationStatus = response.status.rawValue
                        self.generationProgress = response.progress
                    }
                }
            )

            generationStatus = "Downloading..."
            try await downloadResults(response: result, characterSlug: character?.owpSlug ?? "unknown")

            generationStatus = "Complete"
            generationProgress = 100

            // Refresh balance
            Task { await checkBalance() }

        } catch let error as MeshyService.ServiceError {
            lastError = error.localizedDescription
            generationStatus = "Failed"
        } catch {
            lastError = error.localizedDescription
            generationStatus = "Failed"
        }

        isGenerating = false
    }

    private func downloadResults(response: MeshyTaskResponse, characterSlug: String) async throws {
        guard let projectURL = store.owpURL else {
            throw MeshyService.ServiceError.downloadFailed("No project open")
        }

        let assetDir = ProjectPaths(root: projectURL)
            .character3DModelsDirectory(slug: characterSlug)
            .appendingPathComponent(response.id)

        // Download each requested format
        if let modelURLs = response.modelURLs {
            for (format, urlString) in modelURLs {
                guard let url = URL(string: urlString) else { continue }
                let fileName = "model.\(format)"
                let destination = assetDir.appendingPathComponent(fileName)
                let service = MeshyService(apiKey: store.meshyAPIKey)
                try await service.downloadAsset(from: url, to: destination)
            }
        }

        // Download thumbnail
        if let thumbnailURLString = response.thumbnailURL,
           let thumbnailURL = URL(string: thumbnailURLString) {
            let destination = assetDir.appendingPathComponent("thumbnail.png")
            let service = MeshyService(apiKey: store.meshyAPIKey)
            try await service.downloadAsset(from: thumbnailURL, to: destination)
        }

        // Save metadata
        let metadataPath = assetDir.appendingPathComponent("metadata.json")
        let metadata = MeshyTaskMetadata(
            taskID: response.id,
            status: response.status.rawValue,
            modelURLs: response.modelURLs ?? [:],
            thumbnailURL: response.thumbnailURL,
            createdAt: response.createdAt,
            finishedAt: response.finishedAt
        )
        let metadataData = try JSONEncoder().encode(metadata)
        try metadataData.write(to: metadataPath)

        // Add to character's models3D array
        if let characterIndex = store.characters.firstIndex(where: { $0.id == characterID }) {
            let costumeName = character?.costumeReferenceSets.first?.name ?? "default"
            for format in targetFormats {
                let modelFileName = "model.\(format)"
                let modelPath = assetDir.appendingPathComponent(modelFileName)
                if FileManager.default.fileExists(atPath: modelPath.path) {
                    let model = Character3DModel(
                        costumeName: costumeName,
                        modelFileName: modelFileName,
                        modelFormat: format,
                        notes: "Generated by Meshy (task \(response.id))"
                    )
                    store.characters[characterIndex].models3D.append(model)
                }
            }
        }
    }
}

// MARK: - Format Toggle

@available(macOS 26.0, *)
private struct FormatToggle: View {
    let format: String
    @Binding var selectedFormats: [String]

    private var isSelected: Bool {
        selectedFormats.contains(format)
    }

    var body: some View {
        Button {
            if isSelected {
                selectedFormats.removeAll { $0 == format }
            } else {
                selectedFormats.append(format)
            }
        } label: {
            Text(format.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color(nsColor: .quaternaryLabelColor).opacity(0.2))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Supporting Types

@available(macOS 26.0, *)
private struct MeshyTaskMetadata: Codable {
    let taskID: String
    let status: String
    let modelURLs: [String: String]
    let thumbnailURL: String?
    let createdAt: Int
    let finishedAt: Int
}

// MARK: - CharacterReferencePose Display Name

extension CharacterReferencePose {
    var displayName: String {
        switch self {
        case .frontNeutral: return "Front"
        case .leftProfile: return "Left"
        case .rightProfile: return "Right"
        case .back: return "Back"
        case .quarterLeft: return "3/4 Left"
        case .quarterRight: return "3/4 Right"
        }
    }
}

private extension NSImage {
    func resizedJPEGData(maxDimension: Int, quality: Float) -> Data? {
        guard let tiff = tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let currentW = rep.pixelsWide
        let currentH = rep.pixelsHigh
        var newW = currentW
        var newH = currentH
        if max(currentW, currentH) > maxDimension {
            let ratio = Double(maxDimension) / Double(max(currentW, currentH))
            newW = Int(Double(currentW) * ratio)
            newH = Int(Double(currentH) * ratio)
        }
        guard let resized = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(1, newW),
            pixelsHigh: max(1, newH),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
        draw(in: NSRect(x: 0, y: 0, width: newW, height: newH),
             from: .zero,
             operation: .copy,
             fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return resized.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
