import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Metal
import simd

@available(macOS 26.0, *)
@MainActor
final class VideoMouthSyncPipeline: ObservableObject {

    @Published var progress = VideoMouthSyncProgress()
    @Published var isRunning = false
    @Published var result: VideoMouthSyncResult?
    @Published var errorMessage: String?

    private let cancelFlag = MocapAtomicState<Bool>(false)

    func process(_ configuration: VideoMouthSyncConfiguration) async throws -> VideoMouthSyncResult {
        isRunning = true
        cancelFlag.value = false
        defer { isRunning = false }

        guard FileManager.default.fileExists(atPath: configuration.sourceVideoURL.path) else {
            throw VideoMouthSyncError.sourceVideoNotFound
        }

        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw VideoMouthSyncError.exportFailed("No Metal device available")
        }

        guard let composer = MouthSpriteComposer(
            device: metalDevice
        ) else {
            throw VideoMouthSyncError.exportFailed("Metal renderer creation failed")
        }

        // Stage 1: Face Tracking
        updateProgress(stage: .trackingFaces, message: "Detecting faces in video...")
        var faceSession = try await runFaceTracking(configuration: configuration)

        if faceSession.characterAssignments.isEmpty
            && !configuration.characterTracks.isEmpty {
            let firstFrameFaces = faceSession.frameDetections[0] ?? []
            let autoAssign = VideoFaceTrackingService.autoAssignCharacters(
                faces: firstFrameFaces,
                tracks: configuration.characterTracks
            )
            if !autoAssign.isEmpty {
                faceSession.characterAssignments = autoAssign
            }
        }

        guard !faceSession.characterAssignments.isEmpty else {
            throw VideoMouthSyncError.noFacesDetected
        }

        // Stage 2: Lip Sync Generation
        updateProgress(stage: .generatingLipSync, message: "Generating lip sync from audio...")
        let lipSyncData = try await generateLipSyncData(
            configuration: configuration
        )

        // Stage 3: Render Frames
        updateProgress(stage: .renderingFrames, message: "Rendering mouth overlays...")
        let (writer, totalFrames) = try await renderFrames(
            configuration: configuration,
            faceSession: faceSession,
            lipSyncData: lipSyncData,
            composer: composer
        )

        // Stage 4: Audio + Finalize
        updateProgress(stage: .mixingAudio, message: "Adding audio track...")
        let finalResult = try await finalizeVideo(
            writer: writer,
            configuration: configuration,
            totalFrames: totalFrames
        )

        updateProgress(stage: .completed, message: "Done!")
        self.result = finalResult
        return finalResult
    }

    func cancel() {
        cancelFlag.value = true
    }

    // MARK: - Stage 1: Face Tracking

    private func runFaceTracking(
        configuration: VideoMouthSyncConfiguration
    ) async throws -> FaceTrackingSession {
        let flag = cancelFlag
        return try await VideoFaceTrackingService.trackFaces(
            in: configuration.sourceVideoURL,
            targetFPS: Double(configuration.fps),
            onProgress: { processed, total in
                Task { @MainActor in
                    self.updateProgress(
                        stage: .trackingFaces,
                        stageFraction: Double(processed) / Double(max(1, total)),
                        currentFrame: processed,
                        totalFrames: total,
                        message: "Tracking faces: \(processed)/\(total)"
                    )
                }
            },
            cancellation: { flag.value }
        )
    }

    // MARK: - Stage 2: Lip Sync Generation

    private func generateLipSyncData(
        configuration: VideoMouthSyncConfiguration
    ) async throws -> [UUID: [LipSyncEngine.VisemeKeyframe]] {
        var result: [UUID: [LipSyncEngine.VisemeKeyframe]] = [:]
        let tracks = configuration.characterTracks

        for (i, track) in tracks.enumerated() {
            if cancelFlag.value { throw VideoMouthSyncError.cancelled }

            updateProgress(
                stage: .generatingLipSync,
                stageFraction: Double(i) / Double(max(1, tracks.count)),
                message: "Generating lip sync for \(track.characterName)..."
            )

            let keyframes: [LipSyncEngine.VisemeKeyframe]

            if let songData = track.songData,
               let alignment = songData.lyricAlignments.first {
                keyframes = LipSyncEngine.generateFromOWPAlignment(
                    alignment: alignment,
                    notes: songData.notes,
                    songData: songData,
                    fps: configuration.fps
                )
            } else {
                do {
                    let lipSyncResult = try await AutoLipSyncService.generateFromAudio(
                        audioURL: track.audioStemURL,
                        dialogueText: track.dialogueText,
                        fps: configuration.fps
                    )
                    keyframes = lipSyncResult.visemeKeyframes
                } catch {
                    throw VideoMouthSyncError.lipSyncGenerationFailed(
                        characterName: track.characterName,
                        reason: error.localizedDescription
                    )
                }
            }

            result[track.id] = keyframes
        }

        return result
    }

    // MARK: - Stage 3: Frame Rendering

    private func renderFrames(
        configuration: VideoMouthSyncConfiguration,
        faceSession: FaceTrackingSession,
        lipSyncData: [UUID: [LipSyncEngine.VisemeKeyframe]],
        composer: MouthSpriteComposer
    ) async throws -> (AVAssetWriter, Int) {
        let sourceAsset = AVURLAsset(url: configuration.sourceVideoURL)
        let reader = try AVAssetReader(asset: sourceAsset)

        guard let videoTrack = try await sourceAsset.loadTracks(withMediaType: .video).first else {
            throw VideoMouthSyncError.noVideoTrack
        }

        let naturalSize = try await videoTrack.load(.naturalSize)
        let resSize = configuration.resolution.size
        let width = configuration.resolution == .source ? Int(naturalSize.width) : resSize.width
        let height = configuration.resolution == .source ? Int(naturalSize.height) : resSize.height

        let readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw VideoMouthSyncError.cannotOpenSourceVideo(
                reader.error?.localizedDescription ?? "Unknown"
            )
        }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(
                outputURL: configuration.outputVideoURL,
                fileType: configuration.format.fileType
            )
        } catch {
            throw VideoMouthSyncError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: configuration.format.videoCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: videoSettings
        )
        writerInput.expectsMediaDataInRealTime = false

        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: pixelBufferAttrs
        )

        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let smoother = TemporalSmoothingFilter(
            strength: configuration.smoothingStrength
        )
        var previousBuffer: CVPixelBuffer?
        let outputSize = SIMD2<Int>(width, height)
        let frameDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.fps)
        )

        let tracksByID = Dictionary(
            uniqueKeysWithValues: configuration.characterTracks.map { ($0.id, $0) }
        )
        let sourceSize = faceSession.sourceSize

        var frameIndex = 0
        let totalFrames = faceSession.totalFrames

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            if cancelFlag.value { throw VideoMouthSyncError.cancelled }

            guard let originalBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let faceDetections = faceSession.frameDetections[frameIndex] ?? []
            let overlays = overlaysForFrame(
                frameIndex: frameIndex,
                faceDetections: faceDetections,
                lipSyncData: lipSyncData,
                tracksByID: tracksByID,
                assignments: faceSession.characterAssignments,
                frameSize: outputSize,
                sourceSize: sourceSize,
                fps: configuration.fps
            )

            let composited: CVPixelBuffer
            if overlays.isEmpty {
                composited = originalBuffer
            } else {
                composited = composer.compositeWithMouthWarp(
                    originalBuffer: originalBuffer,
                    overlays: overlays,
                    outputSize: outputSize,
                    featherRadius: configuration.featherRadius
                ) ?? originalBuffer
            }

            let mouthRegions = overlays.map {
                $0.transform.boundingBox(in: outputSize)
            }
            let smoothed = smoother.smooth(
                current: composited,
                previous: previousBuffer,
                mouthRegions: mouthRegions
            )
            previousBuffer = smoothed

            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }

            let presentationTime = CMTimeMultiply(
                frameDuration,
                multiplier: Int32(frameIndex)
            )
            adaptor.append(smoothed, withPresentationTime: presentationTime)

            frameIndex += 1
            updateProgress(
                stage: .renderingFrames,
                stageFraction: Double(frameIndex) / Double(max(1, totalFrames)),
                currentFrame: frameIndex,
                totalFrames: totalFrames,
                message: "Rendering: \(frameIndex)/\(totalFrames)"
            )
        }

        writerInput.markAsFinished()

        if reader.status == .failed {
            throw VideoMouthSyncError.cannotOpenSourceVideo(
                reader.error?.localizedDescription ?? "Read error"
            )
        }

        return (writer, frameIndex)
    }

    // MARK: - Stage 4: Finalize

    private func finalizeVideo(
        writer: AVAssetWriter,
        configuration: VideoMouthSyncConfiguration,
        totalFrames: Int
    ) async throws -> VideoMouthSyncResult {
        if let audioURL = configuration.mixedAudioURL {
            updateProgress(stage: .mixingAudio, message: "Adding audio track...")
            await addAudioTrack(
                to: writer,
                from: audioURL,
                duration: CMTime(
                    value: CMTimeValue(totalFrames),
                    timescale: CMTimeScale(configuration.fps)
                )
            )
        }

        updateProgress(stage: .finalizing, message: "Finalizing video...")
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }

        guard writer.status == .completed else {
            throw VideoMouthSyncError.exportFailed(
                writer.error?.localizedDescription ?? "Unknown write error"
            )
        }

        let durationSeconds = Double(totalFrames) / Double(configuration.fps)
        let characterIDs = Set(configuration.characterTracks.map(\.id))

        return VideoMouthSyncResult(
            outputURL: configuration.outputVideoURL,
            totalFrames: totalFrames,
            durationSeconds: durationSeconds,
            charactersSynced: characterIDs.count,
            lipSyncSources: [:]
        )
    }

    // MARK: - Per-Frame Overlays

    private func overlaysForFrame(
        frameIndex: Int,
        faceDetections: [DetectedFace],
        lipSyncData: [UUID: [LipSyncEngine.VisemeKeyframe]],
        tracksByID: [UUID: CharacterSyncTrack],
        assignments: [UUID: UUID],
        frameSize: SIMD2<Int>,
        sourceSize: SIMD2<Int>,
        fps: Int
    ) -> [MouthOverlay] {
        var overlays: [MouthOverlay] = []

        for face in faceDetections {
            let trackID = face.characterTrackID ?? assignments[face.id]
            guard let trackID,
                  let track = tracksByID[trackID],
                  let keyframes = lipSyncData[trackID]
            else { continue }

            let (viseme, mouthState) = visemeAtFrame(
                frame: frameIndex,
                keyframes: keyframes,
                fps: fps
            )

            let transform = mouthTransform(face: face, frameSize: frameSize)

            overlays.append(MouthOverlay(
                faceID: face.id,
                characterTrackID: trackID,
                characterSlug: track.characterSlug,
                viseme: viseme,
                mouthState: mouthState,
                transform: transform,
                featherRadius: 0,
                detectedOuterLips: face.outerLips,
                detectedInnerLips: face.innerLips,
                sourceSize: sourceSize
            ))
        }

        return overlays.sorted {
            $0.transform.centerPosition.y < $1.transform.centerPosition.y
        }
    }

    private func visemeAtFrame(
        frame: Int,
        keyframes: [LipSyncEngine.VisemeKeyframe],
        fps: Int
    ) -> (PrestonBlairViseme, CharacterMouthState) {
        guard !keyframes.isEmpty else {
            return (.rest, .rest)
        }

        var matchedViseme: PrestonBlairViseme = .rest
        for kf in keyframes {
            if kf.frame <= frame && frame < kf.frame + kf.duration {
                matchedViseme = kf.viseme
                break
            }
            if kf.frame > frame { break }
        }

        let timedKeyframes = keyframes.map { kf in
            VisemeBlendEngine.TimedViseme(
                frame: kf.frame,
                viseme: kf.viseme,
                durationFrames: kf.duration
            )
        }
        let snapshot = VisemeBlendEngine.blendedState(
            at: frame,
            keyframes: timedKeyframes,
            fps: fps
        )

        let state = CharacterMouthState(
            cue: matchedViseme.token,
            viseme: matchedViseme,
            jawOpen: snapshot.jawOpen,
            mouthWidth: snapshot.mouthWidth,
            mouthHeight: snapshot.mouthHeight,
            pucker: snapshot.pucker,
            smileBlend: snapshot.smileBlend
        )

        return (matchedViseme, state)
    }

    private func mouthTransform(
        face: DetectedFace,
        frameSize: SIMD2<Int>
    ) -> MouthSpriteTransform {
        let fw = Float(frameSize.x)
        let fh = Float(frameSize.y)

        var outerCenter = SIMD2<Float>(0, 0)
        for p in face.outerLips { outerCenter = outerCenter + p }
        let count = max(1, face.outerLips.count)
        outerCenter = outerCenter / Float(count)

        let pixelCenter = SIMD2<Float>(
            outerCenter.x * fw,
            (1 - outerCenter.y) * fh
        )

        var mouthWidthNorm: Float = 0
        var mouthHeightNorm: Float = 0
        if !face.outerLips.isEmpty {
            let xs = face.outerLips.map(\.x)
            let ys = face.outerLips.map(\.y)
            mouthWidthNorm = (xs.max() ?? 0) - (xs.min() ?? 0)
            mouthHeightNorm = (ys.max() ?? 0) - (ys.min() ?? 0)
        }
        let pixelWidth = max(20, mouthWidthNorm * fw * 1.3)
        let pixelHeight = max(20, mouthHeightNorm * fh * 1.5)

        var rotation: Float = 0
        if face.outerLips.count >= 2 {
            let first = face.outerLips.first!
            let last = face.outerLips.last!
            let dx = last.x - first.x
            let dy = last.y - first.y
            rotation = atan2(dy, dx)
        }

        let angle = FaceAngle.estimate(
            leftEye: face.leftEye,
            rightEye: face.rightEye,
            faceContour: face.faceContour
        )

        return MouthSpriteTransform(
            centerPosition: pixelCenter,
            size: SIMD2<Float>(pixelWidth, pixelHeight),
            rotation: rotation,
            opacity: 1.0,
            faceAngle: angle
        )
    }

    // MARK: - Audio Track

    private func addAudioTrack(
        to writer: AVAssetWriter,
        from audioURL: URL,
        duration: CMTime
    ) async {
        let asset = AVURLAsset(url: audioURL)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
            return
        }
        guard let formatDescriptions = try? await audioTrack.load(.formatDescriptions),
              let formatDesc = formatDescriptions.first else { return }

        let audioInput = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: nil,
            sourceFormatHint: formatDesc
        )
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(audioInput) else { return }
        writer.add(audioInput)

        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let readerOutput = AVAssetReaderTrackOutput(
            track: audioTrack,
            outputSettings: nil
        )
        reader.add(readerOutput)
        reader.startReading()

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            if audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }

        audioInput.markAsFinished()
    }

    // MARK: - Progress

    private func updateProgress(
        stage: VideoMouthSyncStage,
        stageFraction: Double = 0,
        currentFrame: Int = 0,
        totalFrames: Int = 0,
        message: String
    ) {
        progress = VideoMouthSyncProgress(
            stage: stage,
            stageFraction: stageFraction,
            currentFrame: currentFrame,
            totalFrames: totalFrames,
            message: message
        )
    }
}
