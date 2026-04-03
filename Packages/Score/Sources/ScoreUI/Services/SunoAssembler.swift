import AVFoundation

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
            for ch in 0..<min(Int(chunkBuffer.format.channelCount), 2) {
                guard let outData = outputBuffer.floatChannelData?[ch],
                      let chunkData = chunkBuffer.floatChannelData?[ch] else { continue }
                for i in 0..<framesToCopy {
                    var gain: Float = 1.0
                    if crossfadeSamples > 0 {
                        if i < crossfadeSamples {
                            gain = Float(i) / Float(crossfadeSamples)
                        } else if i > framesToCopy - crossfadeSamples {
                            gain = Float(framesToCopy - i) / Float(crossfadeSamples)
                        }
                    }
                    outData[startFrame + i] += chunkData[i] * gain
                }
            }
        }

        let outputFile = try AVAudioFile(forWriting: outputURL, settings: format.settings)
        try outputFile.write(from: outputBuffer)
        return outputPath
    }
}
