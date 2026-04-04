import AVFoundation
import Accelerate
import Foundation

/// Renders all non-muted Mix clips in a scene session into a single flat stereo WAV file.
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

    /// Flatten all clips in a scene session to a single stereo 16-bit WAV.
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

        let totalFrames = AVAudioFrameCount(ceil(totalDuration * sampleRate))

        // Allocate Float32 stereo accumulation buffer (interleaved L/R frames)
        var accumL = [Float](repeating: 0, count: Int(totalFrames))
        var accumR = [Float](repeating: 0, count: Int(totalFrames))

        // Process each active clip
        for clip in activeClips {
            let clipURL = resolveClipURL(clip.filePath, projectURL: projectURL)
            guard FileManager.default.fileExists(atPath: clipURL.path) else {
                NSLog("[MixFlatten] Skipping missing file: %@", clipURL.path)
                continue
            }

            let combinedGainDB = (trackVolumeDB[clip.trackID] ?? 0) + clip.gainDB
            let gainLinear = Float(pow(10.0, combinedGainDB / 20.0))

            do {
                try mixClip(clip, from: clipURL, gainLinear: gainLinear,
                            into: &accumL, rightChannel: &accumR,
                            totalFrames: Int(totalFrames))
            } catch {
                NSLog("[MixFlatten] Error mixing clip '%@': %@", clip.name, error.localizedDescription)
            }
        }

        // Write to WAV
        try writeWAV(leftChannel: &accumL, rightChannel: &accumR,
                     frameCount: Int(totalFrames), to: outputURL)
    }

    // MARK: - Private helpers

    private func resolveClipURL(_ filePath: String, projectURL: URL) -> URL {
        if filePath.hasPrefix("/") {
            return URL(fileURLWithPath: filePath)
        }
        return projectURL.appendingPathComponent(filePath)
    }

    /// Read source clip audio into the accumulation buffers, applying gain and fades.
    private func mixClip(
        _ clip: MixClip,
        from url: URL,
        gainLinear: Float,
        into leftOut: inout [Float],
        rightChannel rightOut: inout [Float],
        totalFrames: Int
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

        // Get float channel pointers
        guard let channelData = sourceBuf.floatChannelData else { return }
        let srcChannels = Int(readFormat.channelCount)
        let leftSrc  = Array(UnsafeBufferPointer(start: channelData[0], count: srcFrames))
        let rightSrc: [Float]
        if srcChannels >= 2 {
            rightSrc = Array(UnsafeBufferPointer(start: channelData[1], count: srcFrames))
        } else {
            rightSrc = leftSrc  // mono — duplicate to both channels
        }

        // Resample to 44100 if needed (simple linear interpolation for speed)
        let ratio = sampleRate / sourceSampleRate
        let outFrameCount = Int(ceil(Double(srcFrames) * ratio))
        var resampledL = [Float](repeating: 0, count: outFrameCount)
        var resampledR = [Float](repeating: 0, count: outFrameCount)

        if abs(ratio - 1.0) < 0.0001 {
            // No resampling needed
            resampledL = leftSrc
            resampledR = rightSrc
        } else {
            // Linear resample
            for i in 0..<outFrameCount {
                let srcPos = Double(i) / ratio
                let srcIdx = Int(srcPos)
                let frac = Float(srcPos - Double(srcIdx))
                let next = min(srcIdx + 1, srcFrames - 1)
                resampledL[i] = leftSrc[srcIdx] + frac * (leftSrc[next] - leftSrc[srcIdx])
                resampledR[i] = rightSrc[srcIdx] + frac * (rightSrc[next] - rightSrc[srcIdx])
            }
        }

        // Destination offset in the accumulation buffer
        let destOffset = Int(clip.startSeconds * sampleRate)

        // Fade parameters
        let fadeInFrames  = Int(clip.fadeInSeconds * sampleRate)
        let fadeOutFrames = Int(clip.fadeOutSeconds * sampleRate)
        let actualOutFrames = resampledL.count

        // Mix with gain + fades into accumulation buffers
        for i in 0..<actualOutFrames {
            let destIdx = destOffset + i
            guard destIdx < totalFrames else { break }

            // Fade envelope
            var envGain: Float = 1.0
            if fadeInFrames > 0, i < fadeInFrames {
                envGain = Float(i) / Float(fadeInFrames)
            } else if fadeOutFrames > 0, i >= (actualOutFrames - fadeOutFrames) {
                let fadePos = i - (actualOutFrames - fadeOutFrames)
                envGain = 1.0 - Float(fadePos) / Float(fadeOutFrames)
            }

            let sample = gainLinear * envGain
            leftOut[destIdx]  += resampledL[i] * sample
            rightOut[destIdx] += resampledR[i] * sample
        }
    }

    /// Write two Float32 channel arrays into a 16-bit stereo WAV file.
    private func writeWAV(
        leftChannel: inout [Float],
        rightChannel: inout [Float],
        frameCount: Int,
        to outputURL: URL
    ) throws {
        // Clamp to [-1, 1]
        var one: Float = 1.0
        var negOne: Float = -1.0
        var clippedLeft  = [Float](repeating: 0, count: frameCount)
        var clippedRight = [Float](repeating: 0, count: frameCount)
        vDSP_vclip(&leftChannel,  1, &negOne, &one, &clippedLeft,  1, vDSP_Length(frameCount))
        vDSP_vclip(&rightChannel, 1, &negOne, &one, &clippedRight, 1, vDSP_Length(frameCount))
        leftChannel  = clippedLeft
        rightChannel = clippedRight

        let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: true
        )!

        // Remove existing file so AVAudioFile can create fresh
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let outFile = try? AVAudioFile(forWriting: outputURL,
                                              settings: outputFormat.settings,
                                              commonFormat: .pcmFormatInt16,
                                              interleaved: true) else {
            throw FlattenError.cannotCreateOutputFile(outputURL)
        }

        // Build an interleaved Int16 buffer via Float32 intermediate
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
        chanData[0].update(from: leftChannel,  count: frameCount)
        chanData[1].update(from: rightChannel, count: frameCount)

        try outFile.write(from: writeBuf)
        NSLog("[MixFlatten] Wrote %d frames to %@", frameCount, outputURL.path)
    }
}
