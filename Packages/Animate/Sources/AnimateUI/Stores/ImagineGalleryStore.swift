import Foundation

@available(macOS 26.0, *)
@MainActor
final class ImagineGalleryStore {
    unowned let parent: AnimateStore
    init(parent: AnimateStore) { self.parent = parent }

    func loadImagineGalleries() {
        guard let owpURL = parent.fileOWPURL else { return }
        let projectPath = owpURL.path
        parent.imagineSceneGalleries = [:]
        Task { [weak self, owpURL, projectPath] in
            let byScene = await Task.detached(priority: .utility) { () -> [UUID: [ImagineSceneShotGallery]] in
                let stored = ImagineProjectStorage.loadGalleries(owpURL: owpURL)
                var grouped: [UUID: [ImagineSceneShotGallery]] = [:]
                for gallery in stored { grouped[gallery.sceneID, default: []].append(gallery) }
                return grouped
            }.value
            guard let self, self.parent.fileOWPURL?.path == projectPath else { return }
            self.parent.imagineSceneGalleries = byScene
        }
    }

    func saveImagineGalleries() {
        guard let owpURL = parent.fileOWPURL else { return }
        let all = parent.imagineSceneGalleries.values.flatMap { $0 }
        try? ImagineProjectStorage.saveGalleries(Array(all), owpURL: owpURL)
    }
}
