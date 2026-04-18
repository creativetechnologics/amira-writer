import Accelerate
import AVFoundation

/// MFCC-based audio similarity using Accelerate framework.
enum MFCCSimilarity {

    /// Compare two audio files by MFCC cosine similarity.
    /// Returns 0.0 (completely different) to 1.0 (identical).
    static func compareFiles(fileA: String, fileB: String) throws -> Double {
        let featuresA = try extractMFCC(filePath: fileA)
        let featuresB = try extractMFCC(filePath: fileB)
        return cosineSimilarity(a: featuresA, b: featuresB)
    }

    /// Extract MFCC feature vector from an audio file.
    static func extractMFCC(filePath: String, numCoefficients: Int = 13) throws -> [Float] {
        let url = URL(fileURLWithPath: filePath)
        let audioFile = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = audioFile.processingFormat
        let frameCount = UInt32(audioFile.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return Array(repeating: 0, count: numCoefficients)
        }
        try audioFile.read(into: buffer)
        guard let samples = buffer.floatChannelData?[0] else {
            return Array(repeating: 0, count: numCoefficients)
        }

        let sampleRate = Float(format.sampleRate)
        let fftSize = 2048
        let hopSize = 512

        var allCoeffs: [[Float]] = []
        for start in stride(from: 0, to: Int(frameCount) - fftSize, by: hopSize) {
            var windowed = [Float](repeating: 0, count: fftSize)
            for i in 0..<fftSize {
                let w = 0.54 - 0.46 * cos(2.0 * Float.pi * Float(i) / Float(fftSize - 1))
                windowed[i] = samples[start + i] * w
            }
            let magnitudes = fftMagnitude(windowed)
            let melEnergies = applyMelFilterbank(magnitudes, sampleRate: sampleRate,
                                                  numBands: 26, fftSize: fftSize)
            let logMel = melEnergies.map { log(max($0, 1e-10)) }
            let mfcc = dct(logMel, numCoefficients: numCoefficients)
            allCoeffs.append(mfcc)
        }

        guard !allCoeffs.isEmpty else {
            return Array(repeating: 0, count: numCoefficients)
        }
        var averaged = [Float](repeating: 0, count: numCoefficients)
        for coeffs in allCoeffs {
            for i in 0..<numCoefficients { averaged[i] += coeffs[i] }
        }
        let count = Float(allCoeffs.count)
        return averaged.map { $0 / count }
    }

    /// Cosine similarity between two vectors.
    static func cosineSimilarity(a: [Float], b: [Float]) -> Double {
        let minLen = min(a.count, b.count)
        guard minLen > 0 else { return 0 }
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(minLen))
        vDSP_svesq(a, 1, &normA, vDSP_Length(minLen))
        vDSP_svesq(b, 1, &normB, vDSP_Length(minLen))
        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }
        return Double(max(0, dotProduct / denominator))
    }

    // MARK: - Private DSP Helpers

    private static func fftMagnitude(_ input: [Float]) -> [Float] {
        let n = input.count
        guard n > 0 else { return [] }
        let log2n = vDSP_Length(log2(Float(n)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var realPart = [Float](repeating: 0, count: n / 2)
        var imagPart = [Float](repeating: 0, count: n / 2)

        let magnitudes: [Float] = realPart.withUnsafeMutableBufferPointer { realBuffer in
            imagPart.withUnsafeMutableBufferPointer { imagBuffer in
                var splitComplex = DSPSplitComplex(
                    realp: realBuffer.baseAddress!,
                    imagp: imagBuffer.baseAddress!
                )

                input.withUnsafeBufferPointer { ptr in
                    ptr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))

                var output = [Float](repeating: 0, count: n / 2)
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    vDSP_zvmags(&splitComplex, 1, outputBuffer.baseAddress!, 1, vDSP_Length(n / 2))
                }
                return output
            }
        }
        return magnitudes
    }

    private static func applyMelFilterbank(_ magnitudes: [Float], sampleRate: Float,
                                           numBands: Int, fftSize: Int) -> [Float] {
        let maxFreq = sampleRate / 2
        let melMax = 2595.0 * log10(1.0 + maxFreq / 700.0)
        let melMin: Float = 0

        let melPoints = (0...numBands + 1).map { i in
            melMin + (melMax - melMin) * Float(i) / Float(numBands + 1)
        }
        let freqPoints = melPoints.map { 700.0 * (pow(10.0, $0 / 2595.0) - 1.0) }
        let binPoints = freqPoints.map { Int($0 * Float(fftSize) / sampleRate) }

        var melEnergies = [Float](repeating: 0, count: numBands)
        for i in 0..<numBands {
            let start = binPoints[i]
            let center = binPoints[i + 1]
            let end = binPoints[i + 2]
            for j in start..<min(center, magnitudes.count) {
                let weight = Float(j - start) / max(Float(center - start), 1)
                melEnergies[i] += magnitudes[j] * weight
            }
            for j in center..<min(end, magnitudes.count) {
                let weight = Float(end - j) / max(Float(end - center), 1)
                melEnergies[i] += magnitudes[j] * weight
            }
        }
        return melEnergies
    }

    private static func dct(_ input: [Float], numCoefficients: Int) -> [Float] {
        let n = input.count
        var output = [Float](repeating: 0, count: numCoefficients)
        for k in 0..<numCoefficients {
            var sum: Float = 0
            for i in 0..<n {
                sum += input[i] * cos(Float.pi * Float(k) * (Float(i) + 0.5) / Float(n))
            }
            output[k] = sum
        }
        return output
    }
}
