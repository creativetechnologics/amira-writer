import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import simd
import Vision

@available(macOS 26.0, *)
struct VideoFaceTrackingService: Sendable {

    enum TrackingError: LocalizedError, Sendable {
        case sourceVideoNotFound
        case cannotOpenAsset(String)
        case noVideoTrack
        case readerFailed(String)
        case noFacesDetected
        case cancelled

        var errorDescription: String? {
            switch self {
            case .sourceVideoNotFound: "Source video file not found."
            case .cannotOpenAsset(let msg): "Cannot open video: \(msg)"
            case .noVideoTrack: "No video track found."
            case .readerFailed(let msg): "Video reader failed: \(msg)"
            case .noFacesDetected: "No faces detected in any frame."
            case .cancelled: "Cancelled."
            }
        }
    }

    // MARK: - Public API

    static func trackFaces(
        in videoURL: URL,
        targetFPS: Double? = nil,
        onProgress: @Sendable (Int, Int) -> Void,
        cancellation: @Sendable () -> Bool
    ) async throws -> FaceTrackingSession {
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            throw TrackingError.sourceVideoNotFound
        }

        let asset = AVURLAsset(url: videoURL)

        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw TrackingError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let sourceSize = SIMD2<Int>(Int(naturalSize.width), Int(naturalSize.height))

        let fps: Double
        if let targetFPS {
            fps = targetFPS
        } else {
            let nominalFPS = try await videoTrack.load(.nominalFrameRate)
            fps = nominalFPS > 0 ? Double(nominalFPS) : 24.0
        }

        let totalFrames = Int(ceil(totalSeconds * fps))

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let trackOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: outputSettings
        )
        trackOutput.alwaysCopiesSampleData = false
        reader.add(trackOutput)

        guard reader.startReading() else {
            throw TrackingError.readerFailed(
                reader.error?.localizedDescription ?? "Unknown"
            )
        }

        var frameDetections: [Int: [DetectedFace]] = [:]
        var previousFaces: [DetectedFace] = []
        var anyFaceSeen = false

        let frameDuration = 1.0 / fps
        var nextTargetTime: Double = 0
        var framesProcessed = 0

        while let sampleBuffer = trackOutput.copyNextSampleBuffer() {
            if cancellation() { throw TrackingError.cancelled }

            let presentationTime = CMTimeGetSeconds(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            )

            guard presentationTime >= nextTargetTime else { continue }
            nextTargetTime = presentationTime + frameDuration

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }

            let detected = detectFaces(in: pixelBuffer, frameIndex: framesProcessed)
            let tracked = assignPersistentIDs(
                currentFaces: detected,
                previousFaces: previousFaces
            )

            if !tracked.isEmpty { anyFaceSeen = true }

            frameDetections[framesProcessed] = tracked
            previousFaces = tracked
            framesProcessed += 1

            onProgress(framesProcessed, totalFrames)
        }

        if reader.status == .failed {
            throw TrackingError.readerFailed(
                reader.error?.localizedDescription ?? "Unknown"
            )
        }

        guard anyFaceSeen else { throw TrackingError.noFacesDetected }

        return FaceTrackingSession(
            videoURL: videoURL,
            fps: fps,
            totalFrames: totalFrames,
            durationSeconds: totalSeconds,
            sourceSize: sourceSize,
            frameDetections: frameDetections
        )
    }

    // MARK: - Per-Frame Detection

    private static func detectFaces(
        in pixelBuffer: CVPixelBuffer,
        frameIndex: Int
    ) -> [DetectedFace] {
        var results: [DetectedFace] = []

        let request = VNDetectFaceLandmarksRequest { req, error in
            guard error == nil,
                  let observations = req.results as? [VNFaceObservation]
            else { return }

            for observation in observations {
                guard let landmarks = observation.landmarks else { continue }
                let box = observation.boundingBox

                results.append(DetectedFace(
                    frameIndex: frameIndex,
                    boundingBox: box,
                    outerLips: extractPoints(from: landmarks.outerLips, in: box),
                    innerLips: extractPoints(from: landmarks.innerLips, in: box),
                    faceContour: extractPoints(from: landmarks.faceContour, in: box),
                    leftEye: extractPoints(from: landmarks.leftEye, in: box),
                    rightEye: extractPoints(from: landmarks.rightEye, in: box),
                    confidence: observation.confidence
                ))
            }
        }

        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            options: [:]
        )
        try? handler.perform([request])
        return results
    }

    private static func extractPoints(
        from region: VNFaceLandmarkRegion2D?,
        in boundingBox: CGRect
    ) -> [SIMD2<Float>] {
        guard let region else { return [] }
        let count = region.pointCount
        guard count > 0 else { return [] }
        let buffer = region.normalizedPoints
        return (0..<count).map { i in
            let p = buffer[i]
            let imageX = Float(boundingBox.origin.x) + Float(p.x) * Float(boundingBox.width)
            let imageY = Float(boundingBox.origin.y) + Float(p.y) * Float(boundingBox.height)
            return SIMD2<Float>(imageX, imageY)
        }
    }

    // MARK: - IoU Identity Tracking

    static func assignPersistentIDs(
        currentFaces: [DetectedFace],
        previousFaces: [DetectedFace],
        iouThreshold: Float = 0.3
    ) -> [DetectedFace] {
        if previousFaces.isEmpty { return currentFaces }

        var result = currentFaces
        var matchedPrevious = Set<Int>()

        for i in result.indices {
            var bestIoU: Float = 0
            var bestPrevIdx: Int? = nil

            for (j, prev) in previousFaces.enumerated() {
                guard !matchedPrevious.contains(j) else { continue }
                let score = iou(result[i].boundingBox, prev.boundingBox)
                if score > bestIoU {
                    bestIoU = score
                    bestPrevIdx = j
                }
            }

            guard bestIoU >= iouThreshold, let j = bestPrevIdx else { continue }

            let previous = previousFaces[j]
            let smoothedBox = interpolate(result[i].boundingBox, previous.boundingBox, currentWeight: 0.8)

            result[i] = DetectedFace(
                id: previous.id,
                frameIndex: result[i].frameIndex,
                boundingBox: smoothedBox,
                outerLips: interpolate(result[i].outerLips, previous.outerLips, currentWeight: 0.8),
                innerLips: interpolate(result[i].innerLips, previous.innerLips, currentWeight: 0.8),
                faceContour: interpolate(result[i].faceContour, previous.faceContour, currentWeight: 0.85),
                leftEye: interpolate(result[i].leftEye, previous.leftEye, currentWeight: 0.85),
                rightEye: interpolate(result[i].rightEye, previous.rightEye, currentWeight: 0.85),
                confidence: result[i].confidence,
                characterTrackID: previous.characterTrackID
            )
            matchedPrevious.insert(j)
        }

        return result
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }

        let interArea = Float(inter.width * inter.height)
        let areaA = Float(a.width * a.height)
        let areaB = Float(b.width * b.height)
        let union = areaA + areaB - interArea
        guard union > 0 else { return 0 }
        return interArea / union
    }

    private static func interpolate(
        _ current: [SIMD2<Float>],
        _ previous: [SIMD2<Float>],
        currentWeight: Float
    ) -> [SIMD2<Float>] {
        guard current.count == previous.count, !current.isEmpty else { return current }
        let previousWeight = 1.0 - currentWeight
        return zip(current, previous).map { currentPoint, previousPoint in
            currentPoint * currentWeight + previousPoint * previousWeight
        }
    }

    private static func interpolate(
        _ current: CGRect,
        _ previous: CGRect,
        currentWeight: CGFloat
    ) -> CGRect {
        let previousWeight = 1.0 - currentWeight
        return CGRect(
            x: current.origin.x * currentWeight + previous.origin.x * previousWeight,
            y: current.origin.y * currentWeight + previous.origin.y * previousWeight,
            width: current.size.width * currentWeight + previous.size.width * previousWeight,
            height: current.size.height * currentWeight + previous.size.height * previousWeight
        )
    }

    // MARK: - Face Angle

    static func estimateFaceAngle(_ face: DetectedFace) -> FaceAngle {
        FaceAngle.estimate(
            leftEye: face.leftEye,
            rightEye: face.rightEye,
            faceContour: face.faceContour
        )
    }

    // MARK: - Auto Character Assignment

    static func autoAssignCharacters(
        faces: [DetectedFace],
        tracks: [CharacterSyncTrack]
    ) -> [UUID: UUID] {
        let uniqueIDs = Set(faces.map(\.id))
        let faceArray = Array(uniqueIDs)

        guard faceArray.count == tracks.count, !faceArray.isEmpty else { return [:] }

        let faceAvgX: [(id: UUID, avgX: CGFloat)] = faceArray.map { faceID in
            let instances = faces.filter { $0.id == faceID }
            let avgX = instances
                .map(\.boundingBox.midX)
                .reduce(0, +) / CGFloat(instances.count)
            return (faceID, avgX)
        }
        let sortedFaces = faceAvgX.sorted { $0.avgX < $1.avgX }

        let sortedTracks = tracks.sorted {
            $0.characterName.localizedStandardCompare($1.characterName)
                == .orderedAscending
        }

        var assignments: [UUID: UUID] = [:]
        for (faceEntry, track) in zip(sortedFaces, sortedTracks) {
            assignments[faceEntry.id] = track.id
        }
        return assignments
    }
}
