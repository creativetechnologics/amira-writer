import Foundation

// MARK: - AnimateStore + Storyboard helpers

@available(macOS 26.0, *)
extension AnimateStore {

    /// Finds the scene ID and shot for the given shot UUID.
    /// Returns `(sceneID, shot)` or `nil` if not found.
    func findShot(by shotID: UUID?) -> (sceneID: UUID, shot: AnimationSceneShot)? {
        guard let shotID else { return nil }
        for scene in scenes {
            if let shot = scene.shots.first(where: { $0.id == shotID }) {
                return (scene.id, shot)
            }
        }
        return nil
    }

    /// Updates `notes` on the shot with the given ID. Returns `true` if the shot was found.
    @discardableResult
    func updateShotNotes(shotID: UUID, notes: String) -> Bool {
        for sceneIndex in scenes.indices {
            if let shotIndex = scenes[sceneIndex].shots.firstIndex(where: { $0.id == shotID }) {
                scenes[sceneIndex].shots[shotIndex].notes = notes
                save()
                return true
            }
        }
        return false
    }
}
