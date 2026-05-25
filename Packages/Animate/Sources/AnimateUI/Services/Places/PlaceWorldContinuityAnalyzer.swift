import AppKit
import Foundation
import Vision
import ImageIO

@available(macOS 26.0, *)
struct PlaceWorldContinuityAnalysis: Sendable {
    var comparedNodeIDs: [UUID]
    var comparedImagePaths: [String]
    var similarityScore: Double
    var histogramScore: Double
    var metadataScore: Double
    var overallScore: Double
    var flags: [PlaceQAFlag]
}

@available(macOS 26.0, *)
final class PlaceWorldContinuityAnalyzer {
    struct NeighborInput: Sendable {
        var nodeID: UUID
        var imagePath: String
        var imageURL: URL
        var pose: WorldCameraPose?
        var mapPoint: WorldMapPoint?
    }

    private var featurePrintCache: [String: VNFeaturePrintObservation] = [:]
    private var histogramCache: [String: [Double]] = [:]

    func analyze(
        candidateURL: URL,
        candidatePath: String,
        candidatePose: WorldCameraPose,
        candidatePoint: WorldMapPoint,
        expectedLandmarkTitles: [String],
        forbiddenLandmarkTitles: [String],
        neighbors: [NeighborInput]
    ) async -> PlaceWorldContinuityAnalysis {
        guard !neighbors.isEmpty else {
            return PlaceWorldContinuityAnalysis(
                comparedNodeIDs: [],
                comparedImagePaths: [],
                similarityScore: 0,
                histogramScore: 0,
                metadataScore: 0,
                overallScore: 0,
                flags: [
                    PlaceQAFlag(
                        code: "no_neighbors",
                        message: "No neighboring canon images were available to validate this node.",
                        severity: .warning
                    )
                ]
            )
        }

        var similarityScores: [Double] = []
        var histogramScores: [Double] = []
        var metadataScores: [Double] = []
        var flags: [PlaceQAFlag] = []

        for neighbor in neighbors {
            let featureScore = featureSimilarity(candidateURL: candidateURL, neighborURL: neighbor.imageURL)
            let histogramScore = histogramSimilarity(candidateURL: candidateURL, neighborURL: neighbor.imageURL)
            let metadataScore = metadataAlignment(
                candidatePose: candidatePose,
                neighborPose: neighbor.pose,
                candidatePoint: candidatePoint,
                neighborPoint: neighbor.mapPoint
            )

            similarityScores.append(featureScore)
            histogramScores.append(histogramScore)
            metadataScores.append(metadataScore)

            if featureScore < 0.50 && histogramScore < 0.60 {
                flags.append(
                    PlaceQAFlag(
                        code: "low_overlap",
                        message: "This image diverges strongly from a neighboring node and likely breaks continuity.",
                        severity: .critical
                    )
                )
            } else if featureScore < 0.62 || histogramScore < 0.68 {
                flags.append(
                    PlaceQAFlag(
                        code: "weak_overlap",
                        message: "This image looks noticeably different from a neighboring node and should be reviewed.",
                        severity: .warning
                    )
                )
            }

            if metadataScore < 0.45 {
                flags.append(
                    PlaceQAFlag(
                        code: "pose_mismatch",
                        message: "Camera heading, focal length, or map spacing is inconsistent with a neighboring node.",
                        severity: .warning
                    )
                )
            }
        }

        if !expectedLandmarkTitles.isEmpty {
            let expectedList = expectedLandmarkTitles.joined(separator: ", ")
            flags.append(
                PlaceQAFlag(
                    code: "expected_landmarks",
                    message: "Expected landmarks for this node: \(expectedList).",
                    severity: .info
                )
            )
        }
        if !forbiddenLandmarkTitles.isEmpty {
            let forbiddenList = forbiddenLandmarkTitles.joined(separator: ", ")
            flags.append(
                PlaceQAFlag(
                    code: "forbidden_landmarks",
                    message: "Forbidden landmarks for this node: \(forbiddenList).",
                    severity: .info
                )
            )
        }

        let similarityScore = similarityScores.isEmpty ? 0 : similarityScores.reduce(0, +) / Double(similarityScores.count)
        let histogramScore = histogramScores.isEmpty ? 0 : histogramScores.reduce(0, +) / Double(histogramScores.count)
        let metadataScore = metadataScores.isEmpty ? 0 : metadataScores.reduce(0, +) / Double(metadataScores.count)
        let overallScore = (similarityScore * 0.5) + (histogramScore * 0.3) + (metadataScore * 0.2)

        return PlaceWorldContinuityAnalysis(
            comparedNodeIDs: neighbors.map(\.nodeID),
            comparedImagePaths: neighbors.map(\.imagePath),
            similarityScore: similarityScore,
            histogramScore: histogramScore,
            metadataScore: metadataScore,
            overallScore: overallScore,
            flags: deduplicatedFlags(flags)
        )
    }

    private func deduplicatedFlags(_ flags: [PlaceQAFlag]) -> [PlaceQAFlag] {
        var seen: Set<String> = []
        return flags.filter { flag in
            let key = "\(flag.code)|\(flag.message)|\(flag.severity.rawValue)"
            return seen.insert(key).inserted
        }
    }

    private func featureSimilarity(candidateURL: URL, neighborURL: URL) -> Double {
        guard let candidate = featurePrint(for: candidateURL),
              let neighbor = featurePrint(for: neighborURL) else {
            return 0
        }

        do {
            var distance: Float = 0
            try candidate.computeDistance(&distance, to: neighbor)
            return max(0, min(1, 1 - (Double(distance) / 25.0)))
        } catch {
            return 0
        }
    }

    private func metadataAlignment(
        candidatePose: WorldCameraPose,
        neighborPose: WorldCameraPose?,
        candidatePoint: WorldMapPoint,
        neighborPoint: WorldMapPoint?
    ) -> Double {
        guard let neighborPose, let neighborPoint else { return 0 }

        let headingDelta = angularDifference(candidatePose.yawDegrees, neighborPose.yawDegrees)
        let focalDelta = abs(candidatePose.focalLengthMM - neighborPose.focalLengthMM)
        let pointDistance = hypot(candidatePoint.x - neighborPoint.x, candidatePoint.y - neighborPoint.y)

        let headingScore = max(0, 1 - (headingDelta / 120))
        let focalScore = max(0, 1 - (focalDelta / 45))
        let pointScore = max(0, 1 - (pointDistance / 0.35))
        return (headingScore + focalScore + pointScore) / 3
    }

    private func angularDifference(_ lhs: Double, _ rhs: Double) -> Double {
        let delta = abs(lhs - rhs).truncatingRemainder(dividingBy: 360)
        return min(delta, 360 - delta)
    }

    private func featurePrint(for url: URL) -> VNFeaturePrintObservation? {
        if let cached = featurePrintCache[url.path] {
            return cached
        }
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
            let observation = request.results?.first as? VNFeaturePrintObservation
            if let observation {
                featurePrintCache[url.path] = observation
            }
            return observation
        } catch {
            return nil
        }
    }

    private func histogramSimilarity(candidateURL: URL, neighborURL: URL) -> Double {
        guard let lhs = grayscaleHistogram(for: candidateURL),
              let rhs = grayscaleHistogram(for: neighborURL) else {
            return 0
        }
        let dot = zip(lhs, rhs).reduce(0.0) { $0 + ($1.0 * $1.1) }
        let lhsMag = sqrt(lhs.reduce(0.0) { $0 + ($1 * $1) })
        let rhsMag = sqrt(rhs.reduce(0.0) { $0 + ($1 * $1) })
        guard lhsMag > 0, rhsMag > 0 else { return 0 }
        return max(0, min(1, dot / (lhsMag * rhsMag)))
    }

    private func grayscaleHistogram(for url: URL) -> [Double]? {
        if let cached = histogramCache[url.path] {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let width = 48
        let height = 48
        let bytesPerRow = width
        var data = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &data,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var histogram = [Double](repeating: 0, count: 16)
        for value in data {
            let bucket = min(15, Int(value) / 16)
            histogram[bucket] += 1
        }
        let total = histogram.reduce(0, +)
        guard total > 0 else { return nil }
        let normalized = histogram.map { $0 / total }
        histogramCache[url.path] = normalized
        return normalized
    }
}
