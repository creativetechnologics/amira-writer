import Foundation
import ProjectKit
import simd

/// Records real-time audio viseme analysis into a MotionClip.
/// The resulting clip contains only blend shape data (no body joints)
/// and is intended for the dedicated "Lip Sync" NLA track.
@available(macOS 26.0, *)
@MainActor
final class AudioLipSyncRecorder {

    private var classifier: AudioVisemeClassifier?
    private var pendingWeights: [AudioVisemeClassifier.VisemeWeights] = []
    private var startTime: Date?
    private var isRecording = false
    private let fps: Double = 30

    // Accumulated frames at target fps
    private var accumulatedFrames: [(timestamp: Double, weights: [PrestonBlairViseme: Float])] = []
    private var lastFrameTimestamp: Double = 0

    /// Start recording audio lip sync.
    func startRecording() throws {
        accumulatedFrames = []
        pendingWeights = []
        lastFrameTimestamp = 0
        startTime = Date()
        isRecording = true

        classifier = AudioVisemeClassifier { [weak self] weights in
            Task { @MainActor [weak self] in
                self?.handleVisemeWeights(weights)
            }
        }
        try classifier?.start()
    }

    /// Stop recording and return the resulting MotionClip.
    func stopRecording() -> MotionClip {
        isRecording = false
        classifier?.stop()
        classifier = nil

        // Flush any remaining pending weights
        flushPendingWeights()

        let frameCount = accumulatedFrames.count
        let duration = accumulatedFrames.last?.timestamp ?? 0
        let intFPS = Int(fps.rounded())

        // Build blend shape weight arrays
        var blendShapeArrays: [String: [Float]] = [:]
        var allShapeNames: Set<String> = []

        for entry in accumulatedFrames {
            let shapes = VisemeToBlendShapeMapper.blendShapes(from: entry.weights)
            for name in shapes.keys { allShapeNames.insert(name.rawValue) }
        }

        for name in allShapeNames {
            blendShapeArrays[name] = Array(repeating: 0, count: frameCount)
        }

        for (i, entry) in accumulatedFrames.enumerated() {
            let shapes = VisemeToBlendShapeMapper.blendShapes(from: entry.weights)
            for (shapeName, value) in shapes {
                blendShapeArrays[shapeName.rawValue]?[i] = value
            }
        }

        let dateStr = AmiraDateFormatter.iso8601.string(from: startTime ?? Date())

        return MotionClip(
            id: UUID(),
            name: "Lip Sync \(dateStr)",
            source: .audioLipSync,
            fps: intFPS,
            frameCount: frameCount,
            duration: duration,
            jointRotations: [:],
            rootPositions: Array(repeating: .zero, count: frameCount),
            blendShapeWeights: blendShapeArrays,
            createdAt: Date()
        )
    }

    private func handleVisemeWeights(_ weights: AudioVisemeClassifier.VisemeWeights) {
        guard isRecording else { return }
        pendingWeights.append(weights)

        // Output at target fps
        let frameDuration = 1.0 / fps
        if weights.timestamp - lastFrameTimestamp >= frameDuration {
            flushPendingWeights()
        }
    }

    private func flushPendingWeights() {
        guard !pendingWeights.isEmpty else { return }

        // Average the accumulated weights
        var avgWeights: [PrestonBlairViseme: Float] = [:]
        let count = Float(pendingWeights.count)

        for pw in pendingWeights {
            for (viseme, weight) in pw.weights {
                avgWeights[viseme, default: 0] += weight / count
            }
        }

        let timestamp = pendingWeights.last?.timestamp ?? lastFrameTimestamp
        lastFrameTimestamp = timestamp

        accumulatedFrames.append((timestamp: timestamp, weights: avgWeights))
        pendingWeights = []
    }
}
