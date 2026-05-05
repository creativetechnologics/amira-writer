import SwiftUI
import ProjectKit

private let storyboardFramePollIntervalNanoseconds: UInt64 = 30 * 1_000_000_000

/// Displays the three iPad-drawn storyboard PNGs (begin / middle / end) for a
/// single shot as a horizontal strip. Read-only on Mac — drawing stays on iPad.
@available(macOS 26.0, *)
struct SceneStoryboardDrawingsStrip: View {
    let projectRoot: URL?
    let sceneID: UUID
    let shot: AnimationSceneShot?

    var body: some View {
        if let shot {
            GeometryReader { proxy in
                let titleHeight: CGFloat = 16
                let labelHeight: CGFloat = 16
                let verticalSpacing: CGFloat = 8
                let verticalPadding: CGFloat = 2
                let availableTileHeight = max(
                    48,
                    proxy.size.height - titleHeight - labelHeight - verticalSpacing - verticalPadding
                )
                VStack(alignment: .leading, spacing: verticalSpacing) {
                    Text("STORYBOARD DRAWINGS")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(.tertiary)
                        .frame(height: titleHeight, alignment: .bottom)

                    let spacing: CGFloat = 10
                    let availableWidth = max(0, proxy.size.width - spacing * 2)
                    let tileWidth = max(96, min(220, availableWidth / 3))
                    let imageHeight = max(48, min(tileWidth * 0.75, availableTileHeight))

                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(StoryboardFrame.allCases, id: \.self) { frame in
                            StoryboardFrameTile(
                                projectRoot: projectRoot,
                                sceneID: sceneID,
                                shotID: shot.id,
                                frame: frame,
                                tileWidth: tileWidth,
                                imageHeight: imageHeight
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipped()
        }
    }
}

@available(macOS 26.0, *)
private struct StoryboardFrameTile: View {
    let projectRoot: URL?
    let sceneID: UUID
    let shotID: UUID
    let frame: StoryboardFrame
    let tileWidth: CGFloat
    let imageHeight: CGFloat

    /// Decoded thumbnail. Loaded once via .task(id:) when the URL changes,
    /// never re-decoded on subsequent body recomputes.
    @State private var image: NSImage?
    @State private var imageSignature: StoryboardFrameFileSignature?
    @ObservedObject private var storyboardStatus = StoryboardServerStatusModel.shared

    private var imageURL: URL? {
        guard let root = projectRoot else { return nil }
        return ProjectPaths(root: root).shotStoryboardImage(sceneID: sceneID, shotID: shotID, frame: frame)
    }

    private var pollTaskID: String {
        [
            imageURL?.path ?? "",
            String(storyboardStatus.lastSaveToken),
            String(storyboardStatus.lastRecoveryToken)
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(4/3, contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.07))
                        .overlay {
                            Image(systemName: "pencil.and.scribble")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                        }
                }
            }
            .frame(width: tileWidth, height: imageHeight)
            .clipped()
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )

            Text(frame.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: tileWidth)
        .task(id: pollTaskID) {
            await pollImageURL()
        }
        // Tile is a drag source ONLY when there's an actual drawing on disk —
        // empty tiles shouldn't be draggable.
        .modifier(StoryboardTileDragModifier(imageURL: imageURL, hasImage: image != nil))
    }

    private func pollImageURL() async {
        guard let url = imageURL else {
            imageSignature = nil
            image = nil
            return
        }

        while !Task.isCancelled {
            let signature = await Task.detached(priority: .utility) {
                StoryboardFrameFileSignature.read(from: url)
            }.value

            if Task.isCancelled { return }

            if signature != imageSignature {
                imageSignature = signature
                if signature.exists {
                    image = await Task.detached(priority: .userInitiated) {
                        NSImage(contentsOf: url)
                    }.value
                } else {
                    image = nil
                }
            }

            do {
                try await Task.sleep(nanoseconds: storyboardFramePollIntervalNanoseconds)
            } catch {
                return
            }
        }
    }
}

private struct StoryboardFrameFileSignature: Equatable, Sendable {
    var exists: Bool
    var modifiedAt: Date?
    var size: Int?

    static func read(from url: URL) -> StoryboardFrameFileSignature {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true || FileManager.default.fileExists(atPath: url.path) else {
            return StoryboardFrameFileSignature(exists: false, modifiedAt: nil, size: nil)
        }
        return StoryboardFrameFileSignature(
            exists: true,
            modifiedAt: values.contentModificationDate,
            size: values.fileSize
        )
    }
}

@available(macOS 26.0, *)
private struct StoryboardTileDragModifier: ViewModifier {
    let imageURL: URL?
    let hasImage: Bool

    func body(content: Content) -> some View {
        if let imageURL, hasImage {
            content.draggable(imageURL) {
                if let nsImage = NSImage(contentsOf: imageURL) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .frame(width: 96, height: 72)
                        .cornerRadius(6)
                } else {
                    Image(systemName: "pencil.and.scribble")
                        .frame(width: 48, height: 36)
                }
            }
        } else {
            content
        }
    }
}
