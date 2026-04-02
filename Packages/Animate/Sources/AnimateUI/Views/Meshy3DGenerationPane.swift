import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct Meshy3DGenerationPane: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter

    @State private var targetPolycount: Int = 100_000
    @State private var topology: String = "triangle"
    @State private var shouldTexture: Bool = true
    @State private var removeLighting: Bool = true
    @State private var enablePBR: Bool = false
    @State private var aiModel: String = "latest"
    @State private var symmetryMode: String = "auto"
    @State private var selectedFormats: Set<String> = ["glb", "usdz"]

    // Costume picker — index 0 = head turnaround (default), 1+ = costume sets
    @State private var selectedCostumeIndex: Int = 0

    // Batch generation state
    @State private var batchQueue: [BatchItem] = []
    @State private var currentBatchIndex: Int = 0
    @State private var isBatchGenerating: Bool = false

    private let allFormats = ["glb", "usdz", "fbx", "obj", "stl"]
    private let poseOrder: [CharacterReferencePose] = [.frontNeutral, .leftProfile, .rightProfile, .back]

    // MARK: - Computed

    /// All available image source options: "Default (Head)" + each costume.
    private var costumePickerOptions: [(index: Int, label: String)] {
        var opts: [(Int, String)] = [(0, "Default (Head Turnaround)")]
        for (i, costume) in character.costumeReferenceSets.enumerated() {
            opts.append((i + 1, costume.name))
        }
        return opts
    }

    /// The currently selected costume name, or nil when using head turnaround.
    private var selectedCostumeName: String? {
        guard selectedCostumeIndex > 0,
              selectedCostumeIndex - 1 < character.costumeReferenceSets.count
        else { return nil }
        return character.costumeReferenceSets[selectedCostumeIndex - 1].name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if store.meshyAPIKey.isEmpty {
                noAPIKeyBanner
            } else {
                imageSelectionSection
                Divider()
                configurationSection
                Divider()
                actionSection
                if !character.costumeReferenceSets.isEmpty {
                    Divider()
                    batchSection
                }
            }
        }
    }

    // MARK: - No API Key

    private var noAPIKeyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(.orange)
            Text("No Meshy API key configured. Open Settings (gear icon) to add one.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Image Selection

    private var imageSelectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reference Images")
                .font(.subheadline.weight(.semibold))

            // Costume picker — only shown when there are costume sets available
            if !character.costumeReferenceSets.isEmpty {
                HStack(spacing: 8) {
                    Text("Source")
                        .font(.callout)
                    Picker("", selection: $selectedCostumeIndex) {
                        ForEach(costumePickerOptions, id: \.index) { option in
                            Text(option.label).tag(option.index)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 220)
                }
            }

            let selectedImages = availablePoseImages()

            if selectedImages.isEmpty {
                Text("No approved pose images found. Approve poses in the Reference Workflow above first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                HStack(spacing: 12) {
                    ForEach(selectedImages, id: \.pose) { item in
                        VStack(spacing: 4) {
                            if let image = store.thumbnailImage(for: item.imagePath, maxSize: 120) {
                                Image(nsImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 80, height: 80)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary.opacity(0.2))
                                    .frame(width: 80, height: 80)
                            }
                            Text(item.pose.gridLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if item.pose == .frontNeutral {
                                Text("Primary")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                }

                Text("\(selectedImages.count) image\(selectedImages.count == 1 ? "" : "s") will be sent to Meshy")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Configuration

    private var configurationSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generation Settings")
                .font(.subheadline.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                GridRow {
                    Text("Polycount")
                        .font(.callout)
                    TextField("Polycount", value: $targetPolycount, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    Text("(100 – 300,000)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                GridRow {
                    Text("Topology")
                        .font(.callout)
                    Picker("", selection: $topology) {
                        Text("Triangle").tag("triangle")
                        Text("Quad").tag("quad")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    EmptyView()
                }

                GridRow {
                    Text("AI Model")
                        .font(.callout)
                    Picker("", selection: $aiModel) {
                        Text("Latest").tag("latest")
                        Text("Meshy-6").tag("meshy-6")
                        Text("Meshy-5").tag("meshy-5")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    EmptyView()
                }

                GridRow {
                    Text("Symmetry")
                        .font(.callout)
                    Picker("", selection: $symmetryMode) {
                        Text("Auto").tag("auto")
                        Text("On").tag("on")
                        Text("Off").tag("off")
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    EmptyView()
                }
            }

            HStack(spacing: 20) {
                Toggle("Texture", isOn: $shouldTexture)
                Toggle("Remove Lighting", isOn: $removeLighting)
                    .disabled(!shouldTexture)
                Toggle("PBR Maps", isOn: $enablePBR)
                    .disabled(!shouldTexture)
            }
            .font(.callout)

            VStack(alignment: .leading, spacing: 6) {
                Text("Output Formats")
                    .font(.callout)
                HStack(spacing: 12) {
                    ForEach(allFormats, id: \.self) { fmt in
                        Toggle(fmt.uppercased(), isOn: Binding(
                            get: { selectedFormats.contains(fmt) },
                            set: { isOn in
                                if isOn { selectedFormats.insert(fmt) }
                                else if selectedFormats.count > 1 { selectedFormats.remove(fmt) }
                            }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Action / Progress

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                let images = availablePoseImages()
                let request = buildRequest()

                Button {
                    Task {
                        let imageDataURLs = encodeImages(images)
                        let textureURL = imageDataURLs.first
                        await store.generateMeshy3DModel(
                            for: character.id,
                            imageURLs: imageDataURLs,
                            textureImageURL: shouldTexture ? textureURL : nil,
                            config: request
                        )
                    }
                } label: {
                    Label("Generate 3D Model", systemImage: "cube.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(images.isEmpty || store.isGeneratingMeshy3D)

                Text("Est. \(request.estimatedCredits) credits")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let balance = store.meshyBalance {
                    Text("(\(balance) available)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Progress
            if store.isGeneratingMeshy3D, store.meshyGeneratingCharacterID == character.id {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(statusLabel)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(store.meshyGenerationProgress), total: 100)
                        .progressViewStyle(.linear)
                }
                .padding(10)
                .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }

            // Error
            if let error = store.meshyGenerationError, store.meshyGeneratingCharacterID == character.id {
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

            // Success
            if store.meshyGenerationStatus == .succeeded, store.meshyGeneratingCharacterID == character.id, !store.isGeneratingMeshy3D {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("3D model generated and downloaded. Check the 3D Models section below.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Batch Generation

    private var batchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Batch Generation")
                .font(.subheadline.weight(.semibold))

            Text("Generate 3D models for all costume sets sequentially using the current settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Queue display
            if isBatchGenerating {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(batchQueue.enumerated()), id: \.offset) { index, item in
                        HStack(spacing: 8) {
                            if index < currentBatchIndex {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.caption)
                            } else if index == currentBatchIndex {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "circle")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            Text(item.costumeName)
                                .font(.callout)
                                .foregroundStyle(index < currentBatchIndex ? .secondary : .primary)
                        }
                    }

                    if currentBatchIndex < batchQueue.count {
                        Text("Generating \(currentBatchIndex + 1) of \(batchQueue.count)…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            } else if !batchQueue.isEmpty {
                // Show completed queue summary
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Batch complete — \(batchQueue.count) costume\(batchQueue.count == 1 ? "" : "s") generated.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.green.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }

            // Generate All button
            Button {
                Task { await runBatchGeneration() }
            } label: {
                Label("Generate All Costumes (\(character.costumeReferenceSets.count))", systemImage: "square.stack.3d.up.fill")
            }
            .buttonStyle(.bordered)
            .disabled(isBatchGenerating || store.isGeneratingMeshy3D || character.costumeReferenceSets.isEmpty)
        }
    }

    // MARK: - Helpers

    private struct PoseImage {
        let pose: CharacterReferencePose
        let imagePath: String
    }

    private struct BatchItem {
        let costumeName: String
        let images: [PoseImage]
    }

    /// Returns approved pose images for the currently selected source.
    /// - Index 0: head turnaround slots (original behavior)
    /// - Index 1+: the corresponding costume's fullBodySlots
    private func availablePoseImages() -> [PoseImage] {
        if selectedCostumeIndex == 0 {
            return headTurnaroundImages()
        }
        let costumeIndex = selectedCostumeIndex - 1
        guard costumeIndex < character.costumeReferenceSets.count else { return [] }
        return poseImages(from: character.costumeReferenceSets[costumeIndex].fullBodySlots)
    }

    private func headTurnaroundImages() -> [PoseImage] {
        var results: [PoseImage] = []
        for pose in poseOrder {
            if let slot = character.headTurnaroundSlots.first(where: { $0.pose == pose }),
               let variant = slot.approvedVariant {
                results.append(PoseImage(pose: pose, imagePath: variant.imagePath))
            }
        }
        return results
    }

    private func poseImages(from slots: [CharacterPoseSlot]) -> [PoseImage] {
        var results: [PoseImage] = []
        for pose in poseOrder {
            if let slot = slots.first(where: { $0.pose == pose }),
               let variant = slot.approvedVariant {
                results.append(PoseImage(pose: pose, imagePath: variant.imagePath))
            }
        }
        return results
    }

    private func buildRequest() -> MeshyMultiImageRequest {
        MeshyMultiImageRequest(
            imageURLs: [],  // filled at send time
            aiModel: aiModel,
            topology: topology,
            targetPolycount: max(100, min(300_000, targetPolycount)),
            shouldRemesh: true,
            shouldTexture: shouldTexture,
            enablePBR: enablePBR,
            removeLighting: removeLighting,
            targetFormats: Array(selectedFormats),
            symmetryMode: symmetryMode
        )
    }

    private func encodeImages(_ items: [PoseImage]) -> [String] {
        items.compactMap { item -> String? in
            guard let url = store.resolvedCharacterAssetURL(for: item.imagePath),
                  let data = try? Data(contentsOf: url) else { return nil }
            let ext = url.pathExtension.lowercased()
            let mime = ext == "png" ? "image/png" : "image/jpeg"
            return "data:\(mime);base64,\(data.base64EncodedString())"
        }
    }

    @MainActor
    private func runBatchGeneration() async {
        let costumes = character.costumeReferenceSets
        guard !costumes.isEmpty else { return }

        // Build queue from all costume sets that have at least one approved image
        let items: [BatchItem] = costumes.compactMap { costume in
            let images = poseImages(from: costume.fullBodySlots)
            guard !images.isEmpty else { return nil }
            return BatchItem(costumeName: costume.name, images: images)
        }
        guard !items.isEmpty else { return }

        batchQueue = items
        currentBatchIndex = 0
        isBatchGenerating = true

        for (index, item) in items.enumerated() {
            currentBatchIndex = index
            let request = buildRequest()
            let imageDataURLs = encodeImages(item.images)
            let textureURL = imageDataURLs.first
            await store.generateMeshy3DModel(
                for: character.id,
                imageURLs: imageDataURLs,
                textureImageURL: shouldTexture ? textureURL : nil,
                config: request
            )
        }

        currentBatchIndex = items.count
        isBatchGenerating = false
    }

    private var statusLabel: String {
        switch store.meshyGenerationStatus {
        case .pending: "Queued..."
        case .inProgress: "Generating... \(store.meshyGenerationProgress)%"
        case .succeeded: "Complete"
        case .failed: "Failed"
        case .canceled: "Cancelled"
        case nil: "Preparing..."
        }
    }
}
