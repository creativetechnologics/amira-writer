import AVFoundation
import Accelerate

/// Handles tempo alignment between Suno audio and MIDI timeline.
@available(macOS 26.0, *)
enum SunoAligner {

    /// Mode 1: Stretch audio to match MIDI timeline.
    static func stretchAudioToMIDI(
        audioPath: String,
        targetDurationSeconds: Double,
        outputPath: String
    ) async throws -> String {
        let audioURL = URL(fileURLWithPath: audioPath)
        let audioFile = try AVAudioFile(forReading: audioURL)
        let sourceDuration = Double(audioFile.length) / audioFile.processingFormat.sampleRate

        let stretchFactor = computeStretchFactor(
            sourceDuration: sourceDuration,
            targetDuration: targetDurationSeconds
        )

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()

        timePitch.rate = Float(1.0 / stretchFactor)
        timePitch.pitch = 0

        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: audioFile.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: audioFile.processingFormat)

        let outputURL = URL(fileURLWithPath: outputPath)
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: audioFile.processingFormat.settings
        )

        try engine.enableManualRenderingMode(
            .offline,
            format: audioFile.processingFormat,
            maximumFrameCount: 4096
        )
        try engine.start()
        await player.scheduleFile(audioFile, at: nil)
        player.play()

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else {
            throw NSError(domain: "SunoAligner", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create render buffer"])
        }

        let targetFrames = Int64(targetDurationSeconds * audioFile.processingFormat.sampleRate)
        var isDrained = false
        while engine.manualRenderingSampleTime < targetFrames && !isDrained {
            let status = try engine.renderOffline(
                engine.manualRenderingMaximumFrameCount, to: buffer
            )
            switch status {
            case .success:
                try outputFile.write(from: buffer)
            case .insufficientDataFromInputNode:
                isDrained = true
            case .cannotDoInCurrentContext:
                break
            case .error:
                throw NSError(
                    domain: "SunoAligner", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Render error"]
                )
            @unknown default:
                break
            }
        }

        engine.stop()
        return outputPath
    }

    /// Mode 2: Extract a tempo map from audio using onset detection.
    static func extractTempoMap(
        audioPath: String,
        ticksPerQuarter: Int
    ) async throws -> [TempoPoint] {
        let onsets = try await detectOnsets(audioPath: audioPath)

        guard onsets.count >= 2 else {
            let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
            let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
            let estimatedBPM = max(40.0, min(Double(onsets.count) / duration * 60.0, 240.0))
            return [TempoPoint(tick: 0, bpm: estimatedBPM)]
        }

        var tempoEvents: [TempoPoint] = []
        var accumulatedTick: Double = 0
        for i in 0..<(onsets.count - 1) {
            let beatDuration = onsets[i + 1] - onsets[i]
            let bpm = 60.0 / beatDuration
            tempoEvents.append(TempoPoint(tick: Int(accumulatedTick), bpm: bpm))
            accumulatedTick += Double(ticksPerQuarter)  // one beat = one quarter note
        }
        return tempoEvents
    }

    static func computeStretchFactor(sourceDuration: Double, targetDuration: Double) -> Double {
        guard sourceDuration > 0 else { return 1.0 }
        return targetDuration / sourceDuration
    }

    // MARK: - Onset Detection

    private static func detectOnsets(audioPath: String) async throws -> [Double] {
        let audioFile = try AVAudioFile(forReading: URL(fileURLWithPath: audioPath))
        let format = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return []
        }
        try audioFile.read(into: buffer)

        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        let sampleRate = format.sampleRate

        let windowSize = Int(sampleRate * 0.01) // 10ms windows
        let hopSize = windowSize / 2
        var energies: [Float] = []

        for start in stride(from: 0, to: Int(frameCount) - windowSize, by: hopSize) {
            var sumSq: Float = 0
            vDSP_svesq(channelData + start, 1, &sumSq, vDSP_Length(windowSize))
            energies.append(sqrt(sumSq / Float(windowSize)))
        }

        var onsets: [Double] = []
        let threshold: Float = 0.05
        for i in 1..<energies.count {
            let diff = energies[i] - energies[i - 1]
            if diff > threshold {
                let time = Double(i * hopSize) / sampleRate
                if onsets.isEmpty || (time - onsets.last!) > 0.1 {
                    onsets.append(time)
                }
            }
        }
        return onsets
    }
}
