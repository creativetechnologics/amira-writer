import Foundation

@available(macOS 26.0, *)
@MainActor
extension ScoreStore {
    // MARK: - Audio Devices

    func setAudioBufferFrames(_ frames: UInt32) {
        selectedAudioBufferFrames = frames
        playbackEngine.setPreferredBufferFrames(frames)
    }
}
