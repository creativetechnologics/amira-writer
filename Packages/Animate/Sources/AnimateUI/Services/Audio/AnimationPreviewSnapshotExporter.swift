import AppKit
import Foundation

@available(macOS 26.0, *)
public enum AnimationPreviewSnapshotMode: String, Sendable {
    case live
    case placeholder
}

@available(macOS 26.0, *)
@MainActor
public struct AnimationPreviewSnapshotExporter {
    public enum ExportError: LocalizedError {
        case sceneNotFound(String)
        case bitmapUnavailable
        case pngEncodingFailed

        public var errorDescription: String? {
            switch self {
            case .sceneNotFound(let scenePath):
                "Scene not found: \(scenePath)"
            case .bitmapUnavailable:
                "Could not create bitmap for preview snapshot."
            case .pngEncodingFailed:
                "Could not encode preview snapshot as PNG."
            }
        }
    }

    public static func export(
        projectURL: URL,
        scenePath: String,
        frame: Int,
        mode: AnimationPreviewSnapshotMode,
        size: CGSize,
        outputURL: URL
    ) async throws {
        let store = AnimateStore()
        store.disableExternalFileWatch = true
        await store.openOWP(url: projectURL)

        guard let scene = store.scenes.first(where: { $0.owpSongPath == scenePath }) else {
            throw ExportError.sceneNotFound(scenePath)
        }

        store.selectedSceneID = scene.id
        store.currentFrame = max(0, frame)
        await store.loadSongData(for: scene)

        guard let image = renderImage(
            store: store,
            scene: scene,
            frame: frame,
            mode: mode,
            size: size
        ) else {
            throw ExportError.bitmapUnavailable
        }

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ExportError.pngEncodingFailed
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: outputURL)
    }

    static func renderImage(
        store: AnimateStore,
        scene: AnimationScene,
        frame: Int,
        mode: AnimationPreviewSnapshotMode,
        size: CGSize
    ) -> NSImage? {
        store.selectedSceneID = scene.id
        store.currentFrame = max(0, frame)

        let view = AnimationCanvasView(frame: CGRect(origin: .zero, size: size))
        view.store = store
        view.previewMode = mode == .live ? .live : .placeholder
        view.layoutSubtreeIfNeeded()
        view.markDirty(.all)
        view.renderImmediatelyForSnapshot()

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return nil
        }

        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)

        guard let cgImage = bitmap.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
}
