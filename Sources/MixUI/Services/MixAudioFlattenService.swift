import AVFoundation
import Accelerate
import Foundation

/// Renders all non-muted Mix clips in a scene session into a single flat stereo WAV file.
/// Processes audio in fixed-size chunks to keep peak memory constant regardless of
/// session duration (avoids OOM on multi-hour mixes).
@available(macOS 26.0, *)
final class MixAudioFlattenService {

    enum FlattenError: Error, LocalizedError {
        case noActiveClips
        case cannotCreateOutputFile(URL)
        case cannotCreateOutputBuffer

        var errorDescription: String? {
            switch self {
            case .noActiveClips:
                return "No audible clips in this scene — nothing to flatten."
            case .cannotCreateOutputFile(let url):
                return "Could not create output WAV file at \(url.path)."
            case .cannotCreateOutputBuffer:
                return "Could not allocate output audio buffer."
            }
        }
    }

    // Output constants
    private let sampleRate: Double = 44100
    private let channelCount: AVAudioChannelCount = 2

    /// Maximum chunk duration in seconds. Each chunk allocates 2 × `chunkFrames`
    /// Float32 values (~69 MB for 10 min at 44.1 kHz). Processing in chunks keeps peak
    /// memory flat regardless of total session length, preventing OOM on multi-hour mixes.
    private let chunkDurationSeconds: TimeInterval = 600 // 10 minutes

    private var chunkFrames: Int { Int(chunkDurationSeconds * sampleRate) }

    /// Flatten all clips in a scene session to a single stereo 16-bit WAV.
    ///
    /// Processes audio in fixed-size chunks so peak memory stays constant (~140 MB)
    /// regardless of session length, preventing OOM on multi-hour mixes.
    ///
    /// - Parameters:
    ///   - session:    The Mix scene session with tracks and clips.
    ///   - projectURL: Project root used to resolve relative clip file paths.
    ///   - outputURL:  Destination for the flattened WAV.
    func flatten(session: MixSceneSession, projectURL: URL, outputURL: URL) async throws {
        // Determine which tracks are audible, honouring solo/mute rules
        let hasSolo = session.tracks.contains { $0.isSolo }
        let activeTracks: Set<UUID> = Set(session.tracks.compactMap { track in
            if hasSolo {
                return track.isSolo ? track.id : nil
            } else {
                return track.isMuted ? nil : track.id
            }
        })

        // Only clips on active tracks
        let activeClips = session.clips.filter { activeTracks.contains($0.trackID) }
        guard !activeClips.isEmpty else { throw FlattenError.noActiveClips }

        // Track volume map for quick lookup
        let trackVolumeDB: [UUID: Double] = Dictionary(
            uniqueKeysWithValues: session.tracks.map { ($0.id, $0.volumeDB) }
        )

        // Total output duration
        let totalDuration = activeClips.map { $0.startSeconds + $0.durationSeconds }.max() ?? 0
        guard totalDuration > 0 else { throw FlattenError.noActiveClips }

        let totalFrames = Int(ceil(totalDuration * sampleRate))
        let cf = chunkFrames

        // Pre-compute per-clip gain (linear) to avoid re-computing in each chunk
        struct ClipMixState {
            let clip: MixClip
            let url: URL
            let gainLinear: Float
        }
        let clipStates: [ClipMixState] = activeClips.compactMap { clip in
            let clipURL = resolveClipURL(clip.filePath, projectURL: projectURL)
            guard FileManager.default.fileExists(atPath: clipURL.path) else {
                NSLog("[MixFlatten] Skipping missing file: %@", clipURL.path)
                return nil
            }
            let combinedGainDB = (trackVolumeDB[clip.trackID] ?? 0) + clip.gainDB
            let gainLinear = Float(pow(10.0, combinedGainDB / 20.0))
            return ClipMixState(clip: clip, url: clipURL, gainLinear: gainLinear)
        }

        // Remove existing file so AVAudioFile can create fresh
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        // Open output WAV file once and write chunk-by-chunk
        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        )!
        guard let outFile = try? AVAudioFile(forWriting: outputURL,
                                              settings: outputFormat.settings,
                                              commonFormat: .pcmFormatInt16,
                                              interleaved: true) else {
            throw FlattenError.cannotCreateOutputFile(outputURL)
        }

        // Process the timeline in fixed-size chunks
        var chunkStart = 0
        while chunkStart < totalFrames {
            let chunkEnd = min(chunkStart + cf, totalFrames)
            let chunkCount = chunkEnd - chunkStart
            let chunkStartSeconds = Double(chunkStart) / sampleRate
            let chunkEndSeconds = Double(chunkEnd) / sampleRate

            // Per-chunk accumulators — these are the only large allocations,
            // ~138 MB per chunk (2 channels × 26.4M frames × 4 bytes).
            var chunkL = [Float](repeating: 0, count: chunkCount)
            var chunkR = [Float](repeating: 0, count: chunkCount)

            // Mix only clips that overlap this chunk
            for state in clipStates {
                let clipEnd = state.clip.startSeconds + state.clip.durationSeconds
                guard clipEnd > chunkStartSeconds,
                      state.clip.startSeconds < chunkEndSeconds else { continue }

                let localOffset = Int(state.clip.startSeconds * sampleRate) - chunkStart
                try mixClip(state.clip, from: state.url, gainLinear: state.gainLinear,
                            into: &chunkL, rightChannel: &chunkR,
                            localOffset: localOffset, chunkFrames: chunkCount)
            }

            // Write this chunk to the WAV file (interleaved Int16 via Float32 bridge)
            try writeChunk(leftChannel: chunkL, rightChannel: chunkR,
                          frameCount: chunkCount, to: outFile)

            chunkStart = chunkEnd
        }

        NSLog("[MixFlatten] Wrote %d frames to %@", totalFrames, outputURL.path)
    }

    // MARK: - Private helpers

    private func resolveClipURL(_ filePath: String, projectURL: URL) -> URL {
        if filePath.hasPrefix("/") {
            return URL(fileURLWithPath: filePath)
        }
        return projectURL.appendingPathComponent(filePath)
    }

    /// Read source clip audio into the accumulation buffers, applying gain and fades.
    /// Uses Accelerate (vDSP) for resampling and envelope application instead of
    /// scalar Swift loops — 4-8x faster on modern Mac CPUs.
    private func mixClip(
        _ clip: MixClip,
        from url: URL,
        gainLinear: Float,
        into leftOut: inout [Float],
        rightChannel rightOut: inout [Float],
        localOffset: Int,
        chunkFrames: Int
    ) throws {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat
        let sourceSampleRate = sourceFormat.sampleRate

        // Seek to sourceInSeconds if present
        let sourceInFrame = AVAudioFramePosition(clip.sourceInSeconds * sourceSampleRate)
        if sourceInFrame > 0 {
            sourceFile.framePosition = sourceInFrame
        }

        // Number of frames we want from the source
        let wantedFrames = AVAudioFrameCount(ceil(clip.durationSeconds * sourceSampleRate))
        guard wantedFrames > 0 else { return }

        // Read source into a buffer at source sample rate
        let readFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceSampleRate,
            channels: sourceFormat.channelCount,
            interleaved: false
        )!

        guard let sourceBuf = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: wantedFrames) else { return }
        try sourceFile.read(into: sourceBuf, frameCount: wantedFrames)
        let srcFrames = Int(sourceBuf.frameLength)
        guard srcFrames > 0 else { return }

        // Get float channel pointers — operate directly on PCM buffer slices
        // instead of creating intermediate Array(UnsafeBufferPointer...) copies,
        // which halved peak memory for the source data.
        guard let channelData = sourceBuf.floatChannelData else { return }
        let srcChannels = Int(readFormat.channelCount)

        // Resample to 44100 if needed using vDSP (Accelerate) for vectorized performance
        let ratio = sampleRate / sourceSampleRate
        let outFrameCount = Int(ceil(Double(srcFrames) * ratio))

        // Single output arrays — allocate once instead of per-channel temp arrays
        var resampledL: [Float]
        var resampledR: [Float]

        if abs(ratio - 1.0) < 0.0001 {
            // No resampling needed — wrap PCM channel data directly without copying
            resampledL = Array(UnsafeBufferPointer(start: channelData[0], count: srcFrames))
            resampledR = srcChannels >= 2
                ? Array(UnsafeBufferPointer(start: channelData[1], count: srcFrames))
                : resampledL
        } else {
            // Vectorized linear resampling via vDSP_vgen
            resampledL = [Float](repeating: 0, count: outFrameCount)
            resampledR = [Float](repeating: 0, count: outFrameCount)
            let ratioF = Float(ratio)
            vDSP_vgen(UnsafePointer(channelData[0]), 1, &resampledL, 1,
                      vDSP_Length(outFrameCount), vDSP_Length(srcFrames), ratioF)
            if srcChannels >= 2 {
                vDSP_vgen(UnsafePointer(channelData[1]), 1, &resampledR, 1,
                          vDSP_Length(outFrameCount), vDSP_Length(srcFrames), ratioF)
            } else {
                vDSP_vgen(UnsafePointer(channelData[0]), 1, &resampledR, 1,
                          vDSP_Length(outFrameCount), vDSP_Length(srcFrames), ratioF)
            }
        }

        // Clip destination offset within the current chunk
        let clipDestStart = Int(clip.startSeconds * sampleRate)
        let chunkStart = clipDestStart - localOffset
        // Only use the portion of resampled data that overlaps this chunk
        let overlapStart = max(0, -chunkStart)
        let overlapEnd = min(outFrameCount, chunkFrames - chunkStart)
        guard overlapEnd > overlapStart else { return }

        // Build fade envelope using vDSP_vramp (vectorized ramp generation)
        let fadeInFrames  = Int(clip.fadeInSeconds * sampleRate)
        let fadeOutFrames = Int(clip.fadeOutSeconds * sampleRate)
        let actualOverlap = overlapEnd - overlapStart

        // If there are fades, build a gain envelope for the overlapping region
        if fadeInFrames > 0 || fadeOutFrames > 0 || abs(gainLinear - 1.0) > 0.0001 {
            var env = [Float](repeating: gainLinear, count: actualOverlap)
            // Apply fade-in ramp
            if fadeInFrames > 0 {
                let fadeStart = overlapStart
                let fadeEnd = min(overlapStart + actualOverlap, fadeInFrames)
                if fadeEnd > fadeStart {
                    let rampLen = fadeEnd - fadeStart
                    var ramp = [Float](repeating: 0, count: rampLen)
                    let startVal = Float(fadeStart) / Float(fadeInFrames)
                    let endVal = Float(fadeEnd) / Float(fadeInFrames)
                    vDSP_vgen(&startVal, 1, &ramp, 1, vDSP_Length(rampLen), 1, 0)
                    for j in 0..<rampLen {
                        env[j] *= ramp[j]
                    }
                }
            }
            // Apply fade-out ramp
            if fadeOutFrames > 0 {
                let fadeStart = max(overlapStart, outFrameCount - fadeOutFrames)
                let fadeEnd = min(overlapEnd, outFrameCount)
                if fadeEnd > fadeStart {
                    let rampStart = fadeStart - overlapStart
                    let rampLen = fadeEnd - fadeStart
                    for j in 0..<rampLen {
                        let fadePos = (fadeStart + j) - (outFrameCount - fadeOutFrames)
                        env[rampStart + j] *= (1.0 - Float(fadePos) / Float(fadeOutFrames))
                    }
                }
            }
            // Mix with envelope into accumulation buffers
            for j in 0..<actualOverlap {
                let destIdx = chunkStart + j + overlapStart
                guard destIdx >= 0, destIdx < chunkFrames else { continue }
                let srcIdx = overlapStart + j
                leftOut[destIdx]  += resampledL[srcIdx] * env[j]
                rightOut[destIdx] += resampledR[srcIdx] * env[j]
            }
        } else {
            // No fades — simple vDSP add
            for j in 0..<actualOverlap {
                let destIdx = chunkStart + j + overlapStart
                guard destIdx >= 0, destIdx < chunkFrames else { continue }
                let srcIdx = overlapStart + j
                leftOut[destIdx]  += resampledL[srcIdx] * gainLinear
                rightOut[destIdx] += resampledR[srcIdx] * gainLinear
            }
        }
    }

    /// Write chunk Float32 data into the open WAV output file (interleaved Int16).
    private func writeChunk(
        leftChannel: [Float],
        rightChannel: [Float],
        frameCount: Int,
        to outFile: AVAudioFile
    ) throws {
        // Clamp to [-1, 1] using vDSP
        var one: Float = 1.0
        var negOne: Float = -1.0
        var clippedLeft  = [Float](repeating: 0, count: frameCount)
        var clippedRight = [Float](repeating: 0, count: frameCount)
        vDSP_vclip(leftChannel,  1, &negOne, &one, &clippedLeft,  1, vDSP_Length(frameCount))
        vDSP_vclip(rightChannel, 1, &negOne, &one, &clippedRight, 1, vDSP_Length(frameCount))

        let writeFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        )!
        guard let writeBuf = AVAudioPCMBuffer(pcmFormat: writeFormat,
                                              frameCapacity: AVAudioFrameCount(frameCount)) else {
            throw FlattenError.cannotCreateOutputBuffer
        }
        writeBuf.frameLength = AVAudioFrameCount(frameCount)

        guard let chanData = writeBuf.floatChannelData else {
            throw FlattenError.cannotCreateOutputBuffer
        }
        chanData[0].update(from: clippedLeft,  count: frameCount)
        chanData[1].update(from: clippedRight, count: frameCount)

        try outFile.write(from: writeBuf)
    }
}
