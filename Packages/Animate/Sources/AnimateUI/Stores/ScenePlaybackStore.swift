import Foundation

@available(macOS 26.0, *)
@MainActor
final class ScenePlaybackStore {
    unowned let parent: AnimateStore
    init(parent: AnimateStore) { self.parent = parent }

    func advanceFrame() {
        parent.currentFrame = min(parent.totalFrames - 1, parent.currentFrame + 1)
    }

    func stepFrame(delta: Int) {
        parent.currentFrame = max(0, min(parent.totalFrames - 1, parent.currentFrame + delta))
    }
}
