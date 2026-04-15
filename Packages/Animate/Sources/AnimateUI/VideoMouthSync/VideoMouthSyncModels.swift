import CoreMedia
import Foundation
import simd

// MARK: - Configuration

@available(macOS 26.0, *)
struct VideoMouthSyncConfiguration: Sendable {
    var sourceVideoURL: URL
    var outputVideoURL: URL
    var format: VideoExporter.ExportFormat
    var resolution: VideoExporter.ExportResolution
    var fps: Int
    var characterTracks: [CharacterSyncTrack]
    var mixedAudioURL: URL?
    var smoothingStrength: Int
    var featherRadius: Float

    init(
        sourceVideoURL: URL,
        outputVideoURL: URL,
        format: VideoExporter.ExportFormat = .mp4,
        resolution: VideoExporter.ExportResolution = .hd1080,
        fps: Int = 24,
        characterTracks: [CharacterSyncTrack] = [],
        mixedAudioURL: URL? = nil,
        smoothingStrength: Int = 2,
        featherRadius: Float = 4.0
    ) {
        self.sourceVideoURL = sourceVideoURL
        self.outputVideoURL = outputVideoURL
        self.format = format
        self.resolution = resolution
        self.fps = fps
        self.characterTracks = characterTracks
        self.mixedAudioURL = mixedAudioURL
        self.smoothingStrength = max(0, min(5, smoothingStrength))
        self.featherRadius = max(0, featherRadius)
    }
}

@available(macOS 26.0, *)
struct CharacterSyncTrack: Sendable, Identifiable {
    var id: UUID
    var characterName: String
    var characterSlug: String
    var audioStemURL: URL
    var songData: OWSSongData?
    var dialogueText: String?
    var mouthSpriteFolderURL: URL

    init(
        id: UUID = UUID(),
        characterName: String,
        characterSlug: String,
        audioStemURL: URL,
        songData: OWSSongData? = nil,
        dialogueText: String? = nil,
        mouthSpriteFolderURL: URL
    ) {
        self.id = id
        self.characterName = characterName
        self.characterSlug = characterSlug
        self.audioStemURL = audioStemURL
        self.songData = songData
        self.dialogueText = dialogueText
        self.mouthSpriteFolderURL = mouthSpriteFolderURL
    }
}

// MARK: - Face Detection

@available(macOS 26.0, *)
struct DetectedFace: Sendable, Identifiable {
    var id: UUID
    var frameIndex: Int
    var boundingBox: CGRect
    var outerLips: [SIMD2<Float>]
    var innerLips: [SIMD2<Float>]
    var faceContour: [SIMD2<Float>]
    var leftEye: [SIMD2<Float>]
    var rightEye: [SIMD2<Float>]
    var confidence: Float
    var characterTrackID: UUID?

    init(
        id: UUID = UUID(),
        frameIndex: Int,
        boundingBox: CGRect,
        outerLips: [SIMD2<Float>] = [],
        innerLips: [SIMD2<Float>] = [],
        faceContour: [SIMD2<Float>] = [],
        leftEye: [SIMD2<Float>] = [],
        rightEye: [SIMD2<Float>] = [],
        confidence: Float,
        characterTrackID: UUID? = nil
    ) {
        self.id = id
        self.frameIndex = frameIndex
        self.boundingBox = boundingBox
        self.outerLips = outerLips
        self.innerLips = innerLips
        self.faceContour = faceContour
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.confidence = confidence
        self.characterTrackID = characterTrackID
    }

    func withCharacterTrackID(_ trackID: UUID?) -> DetectedFace {
        var copy = self
        copy.characterTrackID = trackID
        return copy
    }
}

@available(macOS 26.0, *)
struct FaceTrackingSession: Sendable {
    var videoURL: URL
    var fps: Double
    var totalFrames: Int
    var durationSeconds: Double
    var sourceSize: SIMD2<Int>
    var frameDetections: [Int: [DetectedFace]]
    var characterAssignments: [UUID: UUID]

    init(
        videoURL: URL,
        fps: Double,
        totalFrames: Int,
        durationSeconds: Double,
        sourceSize: SIMD2<Int> = SIMD2<Int>(0, 0),
        frameDetections: [Int: [DetectedFace]] = [:],
        characterAssignments: [UUID: UUID] = [:]
    ) {
        self.videoURL = videoURL
        self.fps = fps
        self.totalFrames = totalFrames
        self.durationSeconds = durationSeconds
        self.sourceSize = sourceSize
        self.frameDetections = frameDetections
        self.characterAssignments = characterAssignments
    }

    var uniqueFaceIDs: [UUID] {
        let ids = frameDetections.values.flatMap { faces in faces.map(\.id) }
        return Array(Set(ids))
    }

    var detectedCharacterCount: Int {
        let assigned = frameDetections.values.flatMap { faces in
            faces.compactMap(\.characterTrackID)
        }
        return Set(assigned).count
    }
}

// MARK: - Mouth Overlay

@available(macOS 26.0, *)
struct MouthOverlay: Sendable {
    var faceID: UUID
    var characterTrackID: UUID
    var characterSlug: String
    var viseme: PrestonBlairViseme
    var mouthState: CharacterMouthState
    var transform: MouthSpriteTransform
    var featherRadius: Float

    var detectedOuterLips: [SIMD2<Float>] = []
    var detectedInnerLips: [SIMD2<Float>] = []
    var sourceSize: SIMD2<Int> = SIMD2<Int>(0, 0)
}

@available(macOS 26.0, *)
struct MouthSpriteTransform: Sendable {
    var centerPosition: SIMD2<Float>
    var size: SIMD2<Float>
    var rotation: Float
    var opacity: Float
    var faceAngle: FaceAngle

    init(
        centerPosition: SIMD2<Float>,
        size: SIMD2<Float>,
        rotation: Float = 0,
        opacity: Float = 1.0,
        faceAngle: FaceAngle = .front
    ) {
        self.centerPosition = centerPosition
        self.size = size
        self.rotation = rotation
        self.opacity = max(0, min(1, opacity))
        self.faceAngle = faceAngle
    }

    func boundingBox(in frameSize: SIMD2<Int>) -> CGRect {
        let halfW = CGFloat(size.x) / 2
        let halfH = CGFloat(size.y) / 2
        let cx = CGFloat(centerPosition.x)
        let cy = CGFloat(centerPosition.y)
        return CGRect(
            x: cx - halfW,
            y: cy - halfH,
            width: CGFloat(size.x),
            height: CGFloat(size.y)
        )
    }

    func clamped(to frameSize: SIMD2<Int>) -> MouthSpriteTransform {
        let fw = Float(frameSize.x)
        let fh = Float(frameSize.y)
        let halfW = size.x / 2
        let halfH = size.y / 2
        let cx = max(halfW, min(fw - halfW, centerPosition.x))
        let cy = max(halfH, min(fh - halfH, centerPosition.y))
        return MouthSpriteTransform(
            centerPosition: SIMD2<Float>(cx, cy),
            size: size,
            rotation: rotation,
            opacity: opacity,
            faceAngle: faceAngle
        )
    }
}

// MARK: - Face Angle

@available(macOS 26.0, *)
enum FaceAngle: String, Sendable, CaseIterable {
    case front
    case threeQuarterLeft
    case threeQuarterRight
    case profileLeft
    case profileRight

    var subfolderName: String? {
        switch self {
        case .front: return nil
        case .threeQuarterLeft: return "threeQuarterLeft"
        case .threeQuarterRight: return "threeQuarterRight"
        case .profileLeft: return "profileLeft"
        case .profileRight: return "profileRight"
        }
    }

    static func estimate(
        leftEye: [SIMD2<Float>],
        rightEye: [SIMD2<Float>],
        faceContour: [SIMD2<Float>]
    ) -> FaceAngle {
        guard !leftEye.isEmpty, !rightEye.isEmpty else { return .front }

        let leftCenter = leftEye.reduce(SIMD2<Float>(0, 0), +) / Float(leftEye.count)
        let rightCenter = rightEye.reduce(SIMD2<Float>(0, 0), +) / Float(rightEye.count)

        guard abs(rightCenter.x - leftCenter.x) > 0.001 else { return .front }

        let faceMidX = (leftCenter.x + rightCenter.x) / 2

        guard faceContour.count >= 4 else { return .front }

        let contourMinX = faceContour.map(\.x).min() ?? 0
        let contourMaxX = faceContour.map(\.x).max() ?? 1
        let leftMargin = faceMidX - contourMinX
        let rightMargin = contourMaxX - faceMidX
        let ratio = leftMargin / max(rightMargin, 0.001)

        if ratio < 0.6 { return .profileLeft }
        if ratio < 0.8 { return .threeQuarterLeft }
        if ratio > 1.5 { return .profileRight }
        if ratio > 1.2 { return .threeQuarterRight }
        return .front
    }
}

// MARK: - Pipeline Progress

@available(macOS 26.0, *)
enum VideoMouthSyncStage: String, Sendable, CaseIterable {
    case idle
    case trackingFaces
    case generatingLipSync
    case renderingFrames
    case mixingAudio
    case finalizing
    case completed
    case failed
}

@available(macOS 26.0, *)
struct VideoMouthSyncProgress: Sendable {
    var stage: VideoMouthSyncStage
    var stageFraction: Double
    var currentFrame: Int
    var totalFrames: Int
    var message: String

    init(
        stage: VideoMouthSyncStage = .idle,
        stageFraction: Double = 0,
        currentFrame: Int = 0,
        totalFrames: Int = 0,
        message: String = "Ready"
    ) {
        self.stage = stage
        self.stageFraction = max(0, min(1, stageFraction))
        self.currentFrame = currentFrame
        self.totalFrames = totalFrames
        self.message = message
    }

    static let stageOrder: [VideoMouthSyncStage] = [
        .trackingFaces, .generatingLipSync, .renderingFrames, .mixingAudio, .finalizing
    ]

    static let stageWeights: [VideoMouthSyncStage: Double] = [
        .trackingFaces: 0.2,
        .generatingLipSync: 0.1,
        .renderingFrames: 0.6,
        .mixingAudio: 0.05,
        .finalizing: 0.05
    ]

    var overallFraction: Double {
        var completed = 0.0
        for s in Self.stageOrder {
            if s == stage { break }
            completed += Self.stageWeights[s] ?? 0
        }
        let current = (Self.stageWeights[stage] ?? 0) * stageFraction
        return min(1.0, completed + current)
    }
}

// MARK: - Pipeline Result

@available(macOS 26.0, *)
struct VideoMouthSyncResult: Sendable {
    var outputURL: URL
    var totalFrames: Int
    var durationSeconds: Double
    var charactersSynced: Int
    var lipSyncSources: [String: AutoLipSyncService.LipSyncSource]
}

// MARK: - Errors

@available(macOS 26.0, *)
enum VideoMouthSyncError: LocalizedError, Sendable {
    case sourceVideoNotFound
    case cannotOpenSourceVideo(String)
    case noVideoTrack
    case faceDetectionFailed(String)
    case noFacesDetected
    case lipSyncGenerationFailed(characterName: String, reason: String)
    case spriteFolderNotFound(characterName: String)
    case spriteMissing(characterName: String, viseme: String)
    case writerSetupFailed(String)
    case renderFailed(frame: Int, reason: String)
    case cancelled
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .sourceVideoNotFound:
            "Source video file not found."
        case .cannotOpenSourceVideo(let msg):
            "Cannot open source video: \(msg)"
        case .noVideoTrack:
            "No video track found in source file."
        case .faceDetectionFailed(let msg):
            "Face detection failed: \(msg)"
        case .noFacesDetected:
            "No faces detected in any frame."
        case .lipSyncGenerationFailed(let char, let reason):
            "Lip sync failed for '\(char)': \(reason)"
        case .spriteFolderNotFound(let char):
            "Mouth sprite folder not found for '\(char)'."
        case .spriteMissing(let char, let viseme):
            "Missing sprite '\(viseme)' for '\(char)'."
        case .writerSetupFailed(let msg):
            "Writer setup failed: \(msg)"
        case .renderFailed(let frame, let reason):
            "Render failed at frame \(frame): \(reason)"
        case .cancelled:
            "Cancelled."
        case .exportFailed(let msg):
            "Export failed: \(msg)"
        }
    }
}
