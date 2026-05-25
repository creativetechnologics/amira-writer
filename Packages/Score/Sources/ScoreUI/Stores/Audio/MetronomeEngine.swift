import AVFoundation

/// Handles metronome click generation and scheduling for MIDIPlaybackEngine.
/// Owns all metronome state and provides a clean API for the parent engine to call.
final class MetronomeEngine {
    unowned let parent: MIDIPlaybackEngine

    // MARK: - Metronome
    private var metronomeNode: AVAudioPlayerNode?
    private var metronomeDownbeatBuffer: AVAudioPCMBuffer?
    private var metronomeUpbeatBuffer: AVAudioPCMBuffer?
    private var metronomeEnabled: Bool = false
    private var metronomeVolume: Float = 0.7
    private var metronomeCountInBars: Int = 0
    /// Time signatures for metronome accent pattern. Set by ScoreStore before playback.
    nonisolated(unsafe) var metronomeTimeSignatures: [TimeSignatureEvent] = []

    init(parent: MIDIPlaybackEngine) {
        self.parent = parent
    }

    // MARK: - Metronome API

    /// Configure metronome settings. Called from ScoreStore when user changes metronome state.
    func configureMetronome(enabled: Bool, volume: Float, countInBars: Int) {
        parent.audioQueue.async { [weak self] in
            guard let self else { return }
            self.metronomeEnabled = enabled
            self.metronomeVolume = min(max(volume, 0), 1)
            self.metronomeCountInBars = min(max(countInBars, 0), 4)

            if enabled && self.metronomeDownbeatBuffer == nil {
                self.metronomeDownbeatBuffer = MIDIPlaybackMetronomeSupport.makeClickBuffer(frequency: 1000, duration: 0.04, sampleRate: 44100)
                self.metronomeUpbeatBuffer = MIDIPlaybackMetronomeSupport.makeClickBuffer(frequency: 800, duration: 0.04, sampleRate: 44100)
            }
        }
    }

    /// Update metronome volume during playback (real-time safe).
    func setMetronomeVolume(_ volume: Float) {
        let clamped = min(max(volume, 0), Float(1))
        parent.audioQueue.async { [weak self] in
            guard let self else { return }
            self.metronomeVolume = clamped
            self.metronomeNode?.volume = clamped
        }
    }

    // MARK: - Metronome Implementation

    /// Setup metronome player node and connect to main mixer.
    /// Must be called on audioQueue after engine is running.
    func setupMetronomeNodeOnAudioQueue() {
        guard metronomeEnabled else { return }

        let outputRate = parent.engine.outputNode.outputFormat(forBus: 0).sampleRate
        let clickRate = outputRate > 0 ? outputRate : 44100.0

        if metronomeDownbeatBuffer == nil || metronomeDownbeatBuffer?.format.sampleRate != clickRate {
            metronomeDownbeatBuffer = MIDIPlaybackMetronomeSupport.makeClickBuffer(frequency: 1000, duration: 0.04, sampleRate: clickRate)
        }
        if metronomeUpbeatBuffer == nil || metronomeUpbeatBuffer?.format.sampleRate != clickRate {
            metronomeUpbeatBuffer = MIDIPlaybackMetronomeSupport.makeClickBuffer(frequency: 800, duration: 0.04, sampleRate: clickRate)
        }

        let node = AVAudioPlayerNode()
        parent.engine.attach(node)
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clickRate, channels: 1, interleaved: false)
        parent.engine.connect(node, to: parent.engine.mainMixerNode, format: monoFormat)
        node.volume = metronomeVolume
        node.play()
        metronomeNode = node
    }

    /// Schedule metronome clicks for all beats from startTick to lengthTicks.
    func scheduleMetronomeClicks(
        startTick: Int,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int,
        lengthTicks: Int,
        timeSignatures: [TimeSignatureEvent] = []
    ) {
        guard metronomeEnabled,
              let node = metronomeNode,
              let downbeatBuf = metronomeDownbeatBuffer,
              let upbeatBuf = metronomeUpbeatBuffer else { return }

        let tpq = max(1, ticksPerQuarter)
        let startSeconds = parent.seconds(atTick: startTick, tempoMap: tempoMap, ticksPerQuarter: tpq)

        let sortedTimeSigs = timeSignatures.sorted { $0.tick < $1.tick }

        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }

        let sampleRate = playerTime.sampleRate
        let hostSampleTime = playerTime.sampleTime

        var beatTick = startTick - (startTick % tpq)
        if beatTick < startTick { beatTick += tpq }

        while beatTick < lengthTicks {
            let beatSeconds = parent.seconds(atTick: beatTick, tempoMap: tempoMap, ticksPerQuarter: tpq)
            let offsetSeconds = beatSeconds - startSeconds
            guard offsetSeconds >= 0 else {
                beatTick += tpq
                continue
            }

            let sampleOffset = AVAudioFramePosition(offsetSeconds * sampleRate)
            let scheduledTime = AVAudioTime(sampleTime: hostSampleTime + sampleOffset, atRate: sampleRate)

            let beatsPerBar = MIDIPlaybackMetronomeSupport.activeBeatsPerBar(atTick: beatTick, timeSignatures: sortedTimeSigs)

            let barStartTick = MIDIPlaybackMetronomeSupport.barStartTickBefore(beatTick, timeSignatures: sortedTimeSigs, ticksPerQuarter: tpq)
            let beatsFromBarStart = (beatTick - barStartTick) / tpq
            let isDownbeat = beatsFromBarStart % beatsPerBar == 0
            let buffer = isDownbeat ? downbeatBuf : upbeatBuf

            node.scheduleBuffer(buffer, at: scheduledTime, options: [], completionHandler: nil)
            beatTick += tpq
        }
    }

    /// Tear down metronome node.
    func tearDownMetronomeOnAudioQueue() {
        if let node = metronomeNode {
            node.stop()
            parent.withEnginePaused {
                parent.engine.disconnectNodeOutput(node)
                parent.engine.detach(node)
            }
            metronomeNode = nil
        }
    }
}
