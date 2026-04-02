import Foundation
import AVFoundation

/// Frame-accurate audio playback for animation preview
@available(macOS 26.0, *)
@MainActor
final class AnimationAudioPlayer: ObservableObject {

    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isLoaded: Bool = false
    @Published var loadError: String?

    private var audioPlayer: AVAudioPlayer?
    private var audioURL: URL?
    private let fps: Int

    init(fps: Int = 24) {
        self.fps = fps
    }

    // MARK: - Loading

    /// Load an audio file for playback
    func load(url: URL) {
        stop()
        audioURL = url
        loadError = nil

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.enableRate = true  // Allow rate adjustment for sync
            self.audioPlayer = player
            self.duration = player.duration
            self.isLoaded = true
        } catch {
            loadError = "Failed to load audio: \(error.localizedDescription)"
            isLoaded = false
        }
    }

    /// Unload current audio
    func unload() {
        stop()
        audioPlayer = nil
        audioURL = nil
        duration = 0
        currentTime = 0
        isLoaded = false
        loadError = nil
    }

    // MARK: - Playback Control

    /// Start or resume playback
    func play() {
        guard let player = audioPlayer, isLoaded else { return }
        player.play()
        isPlaying = true
    }

    /// Pause playback
    func pause() {
        audioPlayer?.pause()
        isPlaying = false
    }

    /// Stop and reset to beginning
    func stop() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        currentTime = 0
    }

    // MARK: - Frame Sync

    /// Seek to a specific animation frame
    func seekToFrame(_ frame: Int) {
        let time = Double(frame) / Double(fps)
        seek(to: time)
    }

    /// Seek to a specific time
    func seek(to time: TimeInterval) {
        guard let player = audioPlayer else { return }
        let clampedTime = max(0, min(duration, time))
        player.currentTime = clampedTime
        currentTime = clampedTime
    }

    /// Sync audio position to match the current animation frame.
    /// Call this from the display link callback to keep audio in sync.
    func syncToFrame(_ frame: Int) {
        guard let player = audioPlayer, isLoaded else { return }
        let expectedTime = Double(frame) / Double(fps)
        currentTime = player.currentTime

        // If audio drifts more than 0.1 seconds from expected position, resync
        let drift = abs(player.currentTime - expectedTime)
        if drift > 0.1 {
            player.currentTime = expectedTime
            currentTime = expectedTime
        }
    }

    /// Get the current frame number based on audio position
    var currentFrame: Int {
        Int(currentTime * Double(fps))
    }

    // MARK: - Info

    /// Total number of frames for the loaded audio
    var totalFrames: Int {
        Int(duration * Double(fps))
    }

    /// Formatted time string (MM:SS)
    var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
