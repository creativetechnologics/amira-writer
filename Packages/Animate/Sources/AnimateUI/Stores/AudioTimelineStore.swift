import Foundation

@available(macOS 26.0, *)
@MainActor
final class AudioTimelineStore {
    unowned let parent: AnimateStore
    init(parent: AnimateStore) { self.parent = parent }

    func loadSceneAudio() {
        guard let audioURL = parent.suggestedExportAudioURL() else {
            parent.audioPlayer.unload()
            return
        }
        parent.audioPlayer.load(url: audioURL)
    }

    func syncAudioToCurrentFrame() {
        parent.audioPlayer.syncToFrame(parent.currentFrame)
    }
}
