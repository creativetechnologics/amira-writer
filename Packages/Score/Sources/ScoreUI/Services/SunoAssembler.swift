import AVFoundation
import Accelerate

/// Assembles selected Suno takes into a single contiguous WAV file.
@available(macOS 26.0, *)
enum SunoAssembler {

    static func assemble(
        session: SunoRenderSession,
        sampleRate: Double = 44100,
        outputPath: String
    ) throws -> String {
        let outputURL = URL(fileURLWithPath: outputPath)
        let chunks = session.plan.chunks.sorted { $0.timeStart < $1.timeStart }

        guard let lastChunk = chunks.last else {
            throw NSError(domain: "SunoAssembler", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No chunks to assemble"])
        }
        let totalDuration = lastChunk.timeEnd
        let totalFrames = Int(totalDuration * sampleRate)

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(totalFrames)) else {
            throw NSError(domain: "SunoAssembler", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to create output buffer"])
        }
        outputBuffer.frameLength = AVAudioFrameCount(totalFrames)

        // Zero-fill
        if let left = outputBuffer.floatChannelData?[0],
           let right = outputBuffer.floatChannelData?[1] {
            memset(left, 0, totalFrames * MemoryLayout<Float>.size)
            memset(right, 0, totalFrames * MemoryLayout<Float>.size)
        }

        let maxCrossfade = Int(0.05 * sampleRate)

        for chunk in chunks {
            guard let takeIdx = chunk.selectedTakeIndex,
                  takeIdx < chunk.takes.count,
                  let filePath = chunk.takes[takeIdx].alignedFilePath ?? chunk.takes[takeIdx].downloadedFilePath
            else { continue }

            let chunkFile = try AVAudioFile(forReading: URL(fileURLWithPath: filePath))
            let chunkFrames = AVAudioFrameCount(chunkFile.length)
            guard let chunkBuffer = AVAudioPCMBuffer(pcmFormat: chunkFile.processingFormat,
                                                      frameCapacity: chunkFrames) else { continue }
            try chunkFile.read(into: chunkBuffer)

            let startFrame = Int(chunk.timeStart * sampleRate)
            guard startFrame >= 0 else { continue }
            let framesToCopy = min(Int(chunkFrames), totalFrames - startFrame)
            guard framesToCopy > 0 else { continue }

            // Clamp crossfade to at most half the chunk length
            let crossfadeSamples = min(maxCrossfade, framesToCopy / 2)

            // Mix into output with crossfade
            // Uses Accelerate (vDSP) vectorized operations instead of per-sample
            // scalar loops — ~4-8x faster on modern Mac CPUs.
            for ch in 0..<min(Int(chunkBuffer.format.channelCount), 2) {
                guard let outData = outputBuffer.floatChannelData?[ch],
                      let chunkData = chunkBuffer.floatChannelData?[ch] else { continue }

                if crossfadeSamples > 0 {
                    // Build triangular crossfade envelope using vDSP_vgen
                    var env = [Float](repeating: 1.0, count: framesToCopy)
                    // Fade-in: ramp 0→1 over crossfadeSamples
                    if crossfadeSamples > 0 {
                        var fadeInEndpoints: [Float] = [0, 1]
                        vDSP_vgen(&fadeInEndpoints, 1, &env, 1,
                                  vDSP_Length(crossfadeSamples), 1, 1)
                    }
                    // Fade-out: ramp 1→0 over last crossfadeSamples
                    let fadeOutPos = framesToCopy - crossfadeSamples
                    if fadeOutPos >= 0 {
                        var fadeOutEndpoints: [Float] = [1, 0]
                        var fadeOutEnv = [Float](repeating: 0, count: crossfadeSamples)
                        vDSP_vgen(&fadeOutEndpoints, 1, &fadeOutEnv, 1,
                                  vDSP_Length(crossfadeSamples), 1, 1)
                        for j in 0..<crossfadeSamples {
                            env[fadeOutPos + j] = fadeOutEnv[j]
                        }
                    }
                    // Apply envelope: scaled = chunkData * env
                    var scaled = [Float](repeating: 0, count: framesToCopy)
                    vDSP_vmul(chunkData, 1, env, 1, &scaled, 1, vDSP_Length(framesToCopy))
                    // Mix: outData += scaled
                    vDSP_vadd(outData.advanced(by: startFrame), 1, scaled, 1,
                              outData.advanced(by: startFrame), 1, vDSP_Length(framesToCopy))
                } else {
                    // No crossfade — direct vector add
                    vDSP_vadd(outData.advanced(by: startFrame), 1, chunkData, 1,
                              outData.advanced(by: startFrame), 1, vDSP_Length(framesToCopy))
                }
            }
        }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        try outputFile.write(from: outputBuffer)
        return outputPath
    }
}
