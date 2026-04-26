import SwiftUI
import ProjectKit

/// Displays the three iPad-drawn storyboard PNGs (begin / middle / end) for a
/// single shot as a horizontal strip. Read-only on Mac — drawing stays on iPad.
@available(macOS 26.0, *)
struct SceneStoryboardDrawingsStrip: View {
    let projectRoot: URL?
    let sceneID: UUID
    let shot: AnimationSceneShot?

    var body: some View {
        if let shot {
            VStack(alignment: .leading, spacing: 8) {
                Text("STORYBOARD DRAWINGS")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 10) {
                    ForEach(StoryboardFrame.allCases, id: \.self) { frame in
                        StoryboardFrameTile(
                            projectRoot: projectRoot,
                            sceneID: sceneID,
                            shotID: shot.id,
                            frame: frame
                        )
                    }
                }
            }
        }
    }
}

@available(macOS 26.0, *)
private struct StoryboardFrameTile: View {
    let projectRoot: URL?
    let sceneID: UUID
    let shotID: UUID
    let frame: StoryboardFrame

    /// Decoded thumbnail. Loaded once via .task(id:) when the URL changes,
    /// never re-decoded on subsequent body recomputes.
    @State private var image: NSImage?

    private var imageURL: URL? {
        guard let root = projectRoot else { return nil }
        return ProjectPaths(root: root).shotStoryboardImage(sceneID: sceneID, shotID: shotID, frame: frame)
    }

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let img = image {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(4/3, contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.07))
                        .aspectRatio(4/3, contentMode: .fit)
                        .overlay {
                            Image(systemName: "pencil.and.scribble")
                                .font(.caption)
                                .foregroundStyle(.quaternary)
                        }
                }
            }
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )

            Text(frame.rawValue.capitalized)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .task(id: imageURL) {
            // Keys the load on the URL; SwiftUI re-runs this when the user
            // selects a different shot/scene. Decode happens off the main
            // actor so big PNGs don't block the strip from rendering.
            guard let url = imageURL else {
                image = nil
                return
            }
            let loaded = await Task.detached(priority: .userInitiated) {
                NSImage(contentsOf: url)
            }.value
            image = loaded
        }
        // Tile is a drag source ONLY when there's an actual drawing on disk —
        // empty tiles shouldn't be draggable.
        .modifier(StoryboardTileDragModifier(imageURL: imageURL, hasImage: image != nil))
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
