import AVFoundation
import CoreImage
import Foundation
import simd

/// Extracts video frames from a file and processes them through the
/// body + face tracking pipeline to produce a MotionClip.
@available(macOS 26.0, *)
final class VideoMotionExtractor: Sendable {

    enum ExtractionError: LocalizedError {
        case cannotOpenAsset
        case noVideoTrack
        case readerFailed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .cannotOpenAsset: "Cannot open video file."
            case .noVideoTrack: "No video track found in file."
            case .readerFailed(let msg): "Video reader failed: \(msg)"
            case .cancelled: "Extraction was cancelled."
            }
        }
    }

    struct ExtractionProgress: Sendable {
        let framesProcessed: Int
        let totalFrames: Int
        let currentTime: Double
        let totalDuration: Double

        var fraction: Double {
            totalFrames > 0 ? Double(framesProcessed) / Double(totalFrames) : 0
        }
    }

    /// Extract motion from a video file by running body/face tracking on each frame.
    /// Produces a MotionClip with joint positions stored as simple quaternions (identity
    /// for body joint positions — full quaternion extraction requires additional IK pass).
    static func extract(
        from videoURL: URL,
        bodyTracker: VisionBodyTracker,
        faceTracker: VisionFaceTracker,
        fps: Double = 30,
        onProgress: @Sendable (ExtractionProgress) -> Void,
        cancellation: @Sendable () -> Bool = { false }
    ) async throws -> MotionClip {
        let asset = AVURLAsset(url: videoURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExtractionError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        let totalFrames = Int(ceil(totalSeconds * fps))

        // Configure reader for BGRA output
        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw ExtractionError.readerFailed(reader.error?.localizedDescription ?? "Unknown")
        }

        // Accumulate pose frames via the callback-based tracker
        nonisolated(unsafe) var collectedFrames: [UnifiedPoseFrame] = []
        collectedFrames.reserveCapacity(totalFrames)

        let accumTracker = VisionBodyTracker { frame in
            collectedFrames.append(frame)
        }

        let frameDuration = 1.0 / fps
        var nextTargetTime: Double = 0
        var framesProcessed = 0

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            if cancellation() { throw ExtractionError.cancelled }

            let presentationTime = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

            guard presentationTime >= nextTargetTime else { continue }
            nextTargetTime = presentationTime + frameDuration

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            // Run tracking synchronously (VisionBodyTracker.processFrame is synchronous)
            accumTracker.processFrame(pixelBuffer, timestamp: presentationTime)

            framesProcessed += 1
            onProgress(ExtractionProgress(
                framesProcessed: framesProcessed,
                totalFrames: totalFrames,
                currentTime: presentationTime,
                totalDuration: totalSeconds
            ))
        }

        if reader.status == .failed {
            throw ExtractionError.readerFailed(reader.error?.localizedDescription ?? "Unknown")
        }

        // Convert UnifiedPoseFrames to MotionClip storage format
        // Body joint positions -> stored as root position; no quaternion conversion here
        // (a full IK pass would be needed for true joint rotations)
        let frameCount = collectedFrames.count
        let intFPS = Int(fps.rounded())

        var rootPositions: [SIMD3<Float>] = []
        var jointRotations: [String: [SIMD4<Float>]] = [:]
        var blendShapeWeights: [String: [Float]] = [:]

        // Pre-allocate joint rotation arrays for all joint names
        let jointNames = JointName.allCases.map(\.rawValue)
        for jName in jointNames {
            jointRotations[jName] = Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: frameCount)
        }

        // Collect all blend shape names that appear
        var blendShapeNames: Set<String> = []
        for frame in collectedFrames {
            if let shapes = frame.faceBlendShapes {
                for name in shapes.keys { blendShapeNames.insert(name.rawValue) }
            }
        }
        for bsName in blendShapeNames {
            blendShapeWeights[bsName] = Array(repeating: 0, count: frameCount)
        }

        for (i, frame) in collectedFrames.enumerated() {
            // Root position from hips
            if let hips = frame.bodyJoints?[.hips] {
                rootPositions.append(hips)
            } else {
                rootPositions.append(.zero)
            }

            // Blend shapes
            if let shapes = frame.faceBlendShapes {
                for (shapeName, value) in shapes {
                    blendShapeWeights[shapeName.rawValue]?[i] = value
                }
            }
        }

        // Ensure rootPositions matches frameCount
        while rootPositions.count < frameCount {
            rootPositions.append(.zero)
        }

        return MotionClip(
            id: UUID(),
            name: videoURL.deletingPathExtension().lastPathComponent,
            source: .videoFileCapture(fileURL: videoURL.absoluteString),
            fps: intFPS,
            frameCount: frameCount,
            duration: totalSeconds,
            jointRotations: jointRotations,
            rootPositions: rootPositions,
            blendShapeWeights: blendShapeWeights,
            createdAt: Date()
        )
    }
}
