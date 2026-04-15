import SwiftUI
import AppKit

@available(macOS 26.0, *)
struct ActionImagesPane: View {
    @Bindable var store: AnimateStore
    let character: AnimationCharacter

    @State private var poses: [ActionImageService.ActionPose] = []
    @State private var existingImages: [String] = []
    @State private var isScanning = false
    @State private var isGeneratingPrompts = false
    @State private var selectedPoseID: UUID?
    @State private var thumbnailSize: CGFloat = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Controls
            HStack(spacing: 8) {
                Button {
                    scanFromScript()
                } label: {
                    Label("Scan Script", systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)
                .disabled(isScanning)

                Button {
                    generateAllPrompts()
                } label: {
                    Label("Auto-Prompt All", systemImage: "wand.and.stars")
                }
                .controlSize(.small)
                .disabled(isGeneratingPrompts || poses.isEmpty)

                Spacer()

                Text("\(poses.count) poses • \(existingImages.count) images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Pose list
            if poses.isEmpty && existingImages.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "figure.walk.motion")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text("No action poses yet. Click 'Scan Script' to auto-populate from the show's scenes.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                // Poses
                if !poses.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Poses from Script")
                            .font(.subheadline.weight(.semibold))

                        ForEach(poses) { pose in
                            HStack(spacing: 8) {
                                Image(systemName: pose.source == "script" ? "doc.text" : "hand.draw")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pose.description)
                                        .font(.caption)
                                        .lineLimit(2)
                                    Text(pose.sceneName)
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }

                                Spacer()

                                if pose.imagePath != nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                } else if !pose.prompt.isEmpty {
                                    Image(systemName: "text.bubble")
                                        .foregroundStyle(.blue)
                                        .font(.caption)
                                }
                            }
                            .padding(.vertical, 2)
                            .padding(.horizontal, 6)
                            .background(
                                selectedPoseID == pose.id
                                    ? Color.accentColor.opacity(0.1)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 4)
                            )
                            .onTapGesture { selectedPoseID = pose.id }
                        }
                    }
                }

                // Existing images gallery
                if !existingImages.isEmpty {
                    Divider()
                    Text("Generated Images")
                        .font(.subheadline.weight(.semibold))

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: thumbnailSize))], spacing: 6) {
                        ForEach(existingImages, id: \.self) { path in
                            AsyncImage(url: URL(fileURLWithPath: path)) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: thumbnailSize, height: thumbnailSize)
                                        .clipped()
                                default:
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.secondary.opacity(0.1))
                                        .frame(width: thumbnailSize, height: thumbnailSize)
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .contextMenu {
                                Button("Show in Finder") {
                                    ImagineProjectStorage.revealInFinder(path)
                                }
                                Button("Copy Image") {
                                    if let image = NSImage(contentsOfFile: path) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.writeObjects([image])
                                    }
                                }
                                if let char = store.selectedCharacter {
                                    Button("Set as Profile Pic") {
                                        store.prepareProfilePicCrop(from: path, for: char.id)
                                    }
                                }
                            }
                            .draggable(URL(fileURLWithPath: path))
                        }
                    }
                }
            }

            if isScanning {
                ProgressView("Scanning script…")
                    .controlSize(.small)
            }
            if isGeneratingPrompts {
                ProgressView("Generating prompts…")
                    .controlSize(.small)
            }
        }
        .onAppear { loadData() }
        .onChange(of: store.selectedCharacterID) { _, _ in loadData() }
    }

    private func loadData() {
        guard let animateURL = store.animateURL else { return }
        poses = ActionImageService.loadPoses(animateURL: animateURL, characterSlug: character.assetFolderSlug)
        existingImages = ActionImageService.scanExistingImages(animateURL: animateURL, characterSlug: character.assetFolderSlug)
    }

    private func scanFromScript() {
        isScanning = true
        let scanned = ActionImageService.scanPosesFromScript(for: character, scenes: store.scenes)
        // Merge with existing poses (don't lose manually added ones)
        var merged = poses.filter { $0.source == "manual" }
        merged.append(contentsOf: scanned)
        poses = merged
        if let animateURL = store.animateURL {
            try? ActionImageService.savePoses(poses, animateURL: animateURL, characterSlug: character.assetFolderSlug)
        }
        isScanning = false
    }

    private func generateAllPrompts() {
        isGeneratingPrompts = true
        let apiKey = store.miniMaxAPIKey
        Task {
            defer { isGeneratingPrompts = false }
            for i in poses.indices where poses[i].prompt.isEmpty {
                do {
                    poses[i].prompt = try await ActionImageService.generatePrompt(
                        for: poses[i],
                        character: character,
                        apiKey: apiKey
                    )
                } catch {
                    // Continue with next pose
                }
            }
            if let animateURL = store.animateURL {
                try? ActionImageService.savePoses(poses, animateURL: animateURL, characterSlug: character.assetFolderSlug)
            }
        }
    }

}
