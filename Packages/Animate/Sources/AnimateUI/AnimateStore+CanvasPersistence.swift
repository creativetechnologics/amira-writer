import Foundation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
extension AnimateStore {
    private var canvasDir: URL? {
        animateURL.map { ProjectPaths(root: $0.deletingLastPathComponent()).animateCanvasDir }
    }

    private var canvasIndexURL: URL? {
        animateURL.map { ProjectPaths(root: $0.deletingLastPathComponent()).animateCanvasIndexJSON }
    }

    /// Reads `_index.json` from the canvas directory and populates `canvasGenerations`.
    /// Called during project load. Silently skips if the file does not exist yet.
    func loadCanvasGenerations() {
        guard let indexURL = canvasIndexURL else {
            canvasGenerations = []
            return
        }
        let projectPath = fileOWPURL?.path
        canvasGenerations = []
        Task { [weak self, indexURL, projectPath] in
            let generations = await Task.detached(priority: .utility) { () -> [CanvasGeneration] in
                guard FileManager.default.fileExists(atPath: indexURL.path),
                      let data = try? Data(contentsOf: indexURL) else {
                    return []
                }
                return (try? JSONDecoder().decode([CanvasGeneration].self, from: data)) ?? []
            }.value

            guard let self else { return }
            guard self.fileOWPURL?.path == projectPath else { return }
            self.canvasGenerations = generations
        }
    }

    /// Appends a new generation record and rewrites `_index.json`.
    func appendCanvasGeneration(_ gen: CanvasGeneration) {
        canvasGenerations.append(gen)
        persistCanvasIndex()
        registerImageAsset(
            path: gen.imagePath,
            linkKind: .canvasGeneration,
            ownerID: gen.id.uuidString,
            context: [
                "prompt": gen.prompt,
                "model": gen.model.rawValue,
                "aspectRatio": gen.aspectRatio,
                "imageSize": gen.imageSize
            ],
            analysisMode: .immediate
        )
    }

    /// Removes a generation record by id, deletes the image file, and rewrites `_index.json`.
    func deleteCanvasGeneration(_ id: UUID) {
        guard let idx = canvasGenerations.firstIndex(where: { $0.id == id }) else { return }
        let gen = canvasGenerations[idx]
        canvasGenerations.remove(at: idx)
        let fm = FileManager.default
        if fm.fileExists(atPath: gen.imagePath) {
            try? fm.removeItem(atPath: gen.imagePath)
        }
        persistCanvasIndex()
    }

    private func persistCanvasIndex() {
        guard let dir = canvasDir, let indexURL = canvasIndexURL else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? JSONEncoder().encode(canvasGenerations) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
