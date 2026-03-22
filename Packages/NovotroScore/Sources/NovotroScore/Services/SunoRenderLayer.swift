import AVFoundation
import Observation

/// Manages Suno render audio playback as a dedicated bus in the audio graph.
@available(macOS 26.0, *)
@Observable
class SunoRenderLayer {
    @ObservationIgnored private let engine: AVAudioEngine
    private(set) var playerNodes: [UUID: AVAudioPlayerNode] = [:]
    @ObservationIgnored private(set) var submixNode: AVAudioMixerNode
    @ObservationIgnored private var audioFiles: [UUID: AVAudioFile] = [:]

    enum PlaybackMode: String, CaseIterable, Sendable {
        case midiOnly
        case sunoOnly
        case blended
    }

    var playbackMode: PlaybackMode = .midiOnly {
        didSet { applyPlaybackMode() }
    }

    var gain: Float = 1.0 {
        didSet { applyPlaybackMode() }
    }

    var isMuted: Bool = false {
        didSet { applyPlaybackMode() }
    }

    init(engine: AVAudioEngine) {
        self.engine = engine
        self.submixNode = AVAudioMixerNode()
        engine.attach(submixNode)
        engine.connect(submixNode, to: engine.mainMixerNode,
                      format: engine.mainMixerNode.outputFormat(forBus: 0))
    }

    func loadRender(id: UUID, filePath: String) throws {
        let url = URL(fileURLWithPath: filePath)
        let audioFile = try AVAudioFile(forReading: url)
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: submixNode, format: audioFile.processingFormat)
        playerNodes[id] = player
        audioFiles[id] = audioFile
    }

    func unloadRender(id: UUID) {
        if let player = playerNodes[id] {
            player.stop()
            engine.detach(player)
        }
        playerNodes.removeValue(forKey: id)
        audioFiles.removeValue(forKey: id)
    }

    func play(at sampleOffset: AVAudioFramePosition = 0) {
        for (id, player) in playerNodes {
            guard let file = audioFiles[id] else { continue }
            let remaining = file.length - sampleOffset
            guard remaining > 0 else { continue }
            player.scheduleSegment(file, startingFrame: sampleOffset,
                                  frameCount: AVAudioFrameCount(remaining), at: nil)
            player.play()
        }
    }

    func stop() {
        for player in playerNodes.values { player.stop() }
    }

    var currentTime: Double {
        guard let (_, player) = playerNodes.first,
              let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime)
        else { return 0 }
        return Double(playerTime.sampleTime) / playerTime.sampleRate
    }

    private func applyPlaybackMode() {
        switch playbackMode {
        case .sunoOnly, .blended:
            submixNode.outputVolume = isMuted ? 0 : gain
        case .midiOnly:
            submixNode.outputVolume = 0
        }
    }

    func teardown() {
        stop()
        for player in playerNodes.values { engine.detach(player) }
        playerNodes.removeAll()
        audioFiles.removeAll()
        engine.detach(submixNode)
    }
}
