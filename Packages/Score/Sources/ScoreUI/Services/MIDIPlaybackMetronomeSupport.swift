@preconcurrency import AVFoundation
import Foundation

enum MIDIPlaybackMetronomeSupport {
    /// Generate a short sine-wave click buffer for the metronome.
    /// Attack: 2ms, sustain+decay: remaining duration. Mono Float32.
    static func makeClickBuffer(frequency: Double, duration: Double, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return nil }
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let data = buffer.floatChannelData?[0] else { return nil }
        let twoPi = 2.0 * Double.pi
        let attackFrames = Int(sampleRate * 0.002)
        let totalFrames = Int(frameCount)

        for i in 0..<totalFrames {
            let phase = sin(twoPi * frequency * Double(i) / sampleRate)
            let envelope: Double
            if i < attackFrames {
                envelope = Double(i) / Double(attackFrames)
            } else {
                let decaySpan = totalFrames - attackFrames
                let decayProgress = decaySpan > 0 ? Double(i - attackFrames) / Double(decaySpan) : 1.0
                envelope = max(0, 1.0 - decayProgress) * exp(-3.0 * decayProgress)
            }
            data[i] = Float(phase * envelope * 0.8)
        }
        return buffer
    }

    /// Returns the number of beats per bar for the time signature active at `tick`.
    static func activeBeatsPerBar(atTick tick: Int, timeSignatures: [TimeSignatureEvent]) -> Int {
        var activeSig: TimeSignatureEvent? = nil
        for sig in timeSignatures where sig.tick <= tick {
            activeSig = sig
        }
        guard let sig = activeSig else { return 4 }
        let beatsPerBar = sig.numerator * 4 / max(1, sig.denominator)
        return max(1, beatsPerBar)
    }

    /// Returns the tick of the most recent bar start at or before `tick`.
    static func barStartTickBefore(_ tick: Int, timeSignatures: [TimeSignatureEvent], ticksPerQuarter tpq: Int) -> Int {
        var activeSig = TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)
        for sig in timeSignatures where sig.tick <= tick {
            activeSig = sig
        }
        let beatsPerBar = activeBeatsPerBar(atTick: tick, timeSignatures: timeSignatures)
        let ticksPerBar = beatsPerBar * tpq
        let ticksSinceSigStart = tick - activeSig.tick
        let barsElapsed = ticksSinceSigStart / ticksPerBar
        return activeSig.tick + barsElapsed * ticksPerBar
    }
}
