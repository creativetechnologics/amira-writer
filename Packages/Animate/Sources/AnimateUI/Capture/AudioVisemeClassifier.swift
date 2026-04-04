import AVFoundation
import Accelerate

/// Real-time audio analysis that produces per-frame viseme blend weights.
/// Uses spectral energy bands to approximate mouth shapes without a neural model.
@available(macOS 26.0, *)
final class AudioVisemeClassifier: @unchecked Sendable {

    struct VisemeWeights: Sendable {
        let timestamp: Double
        let weights: [PrestonBlairViseme: Float]

        /// The dominant viseme (highest weight).
        var dominant: PrestonBlairViseme {
            weights.max(by: { $0.value < $1.value })?.key ?? .rest
        }
    }

    private let audioEngine = AVAudioEngine()
    private let fftSize = 1024
    private nonisolated(unsafe) var isRunning = false

    // Callback for each analysis frame
    private let onVisemeWeights: @Sendable (VisemeWeights) -> Void
    private let sampleRate: Double

    init(
        sampleRate: Double = 44100,
        onVisemeWeights: @Sendable @escaping (VisemeWeights) -> Void
    ) {
        self.sampleRate = sampleRate
        self.onVisemeWeights = onVisemeWeights
    }

    /// Start capturing and analyzing microphone audio.
    func start() throws {
        guard !isRunning else { return }

        let inputNode = audioEngine.inputNode
        let format = inputNode.inputFormat(forBus: 0)

        // Install a tap to receive audio buffers
        inputNode.installTap(onBus: 0, bufferSize: UInt32(fftSize), format: format) { [weak self] buffer, time in
            guard let self else { return }
            let timestamp = Double(time.sampleTime) / format.sampleRate
            let weights = self.analyzeBuffer(buffer, sampleRate: format.sampleRate)
            self.onVisemeWeights(VisemeWeights(timestamp: timestamp, weights: weights))
        }

        audioEngine.prepare()
        try audioEngine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        isRunning = false
    }

    /// Analyze a single audio buffer and return viseme weights.
    ///
    /// Frequency band mapping (approximate vocal formants):
    /// - 200-500 Hz: F1 region (jaw opening) -> ai, o
    /// - 500-1500 Hz: F2 region (tongue position) -> e, u
    /// - 1500-3000 Hz: F3 region (lip rounding) -> o, u, wq
    /// - 3000-6000 Hz: sibilants -> consonant, fv
    /// - Overall energy: voice activity detection
    private func analyzeBuffer(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> [PrestonBlairViseme: Float] {
        guard let channelData = buffer.floatChannelData?[0] else {
            return [.rest: 1.0]
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount >= fftSize else { return [.rest: 1.0] }

        // Compute power spectrum using vDSP
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [.rest: 1.0]
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realPart = [Float](repeating: 0, count: fftSize / 2)
        var imagPart = [Float](repeating: 0, count: fftSize / 2)

        // Apply Hanning window
        var windowed = [Float](repeating: 0, count: fftSize)
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        vDSP_vmul(channelData, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        // Convert to split complex and compute FFT
        windowed.withUnsafeBufferPointer { ptr in
            ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                var splitComplex = DSPSplitComplex(realp: &realPart, imagp: &imagPart)
                vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))
            }
        }

        // Compute energy in frequency bands
        let binHz = Float(sampleRate) / Float(fftSize)
        func bandEnergy(lowHz: Float, highHz: Float) -> Float {
            let lowBin = max(0, Int(lowHz / binHz))
            let highBin = min(magnitudes.count - 1, Int(highHz / binHz))
            guard lowBin <= highBin else { return 0 }
            var sum: Float = 0
            vDSP_sve(Array(magnitudes[lowBin...highBin]), 1, &sum, vDSP_Length(highBin - lowBin + 1))
            return sum / Float(highBin - lowBin + 1)
        }

        let totalEnergy = bandEnergy(lowHz: 80, highHz: 8000)
        let f1 = bandEnergy(lowHz: 200, highHz: 500)    // jaw opening
        let f2 = bandEnergy(lowHz: 500, highHz: 1500)   // tongue front/back
        let f3 = bandEnergy(lowHz: 1500, highHz: 3000)  // lip rounding
        let highFreq = bandEnergy(lowHz: 3000, highHz: 6000) // sibilants

        // Silence threshold
        let silenceThreshold: Float = 0.01
        guard totalEnergy > silenceThreshold else {
            return [.rest: 1.0]
        }

        // Normalize energies
        let norm = max(totalEnergy, 0.001)
        let f1n = f1 / norm
        let f2n = f2 / norm
        let f3n = f3 / norm
        let hn  = highFreq / norm

        // Map to viseme weights
        var weights: [PrestonBlairViseme: Float] = [:]
        weights[.ai]       = f1n * 0.6 + f2n * 0.2
        weights[.e]        = f2n * 0.5 + f1n * 0.2
        weights[.o]        = f1n * 0.4 + f3n * 0.4
        weights[.u]        = f3n * 0.5 + f2n * 0.1
        weights[.consonant] = hn * 0.5 + f2n * 0.2
        weights[.fv]       = hn * 0.4 + f3n * 0.2
        weights[.mbp]      = max(0, 0.3 - totalEnergy * 5)
        weights[.l]        = f2n * 0.3 + f1n * 0.15
        weights[.wq]       = f3n * 0.4 + (1 - f1n) * 0.2
        weights[.rest]     = max(0, silenceThreshold * 2 - totalEnergy)

        // Normalize weights to sum to 1
        let total = weights.values.reduce(0, +)
        if total > 0 {
            for key in weights.keys {
                weights[key]! /= total
            }
        }

        return weights
    }
}
