import XCTest
@testable import AnimateUI
import AVFoundation
import CoreVideo
import Vision

@available(macOS 26.0, *)
final class FaceDetectionProbeTests: XCTestCase {

    func testProbeVideosForFaces() async throws {
        let testDir = URL(fileURLWithPath: "/tmp/mouth-sync-test")

        let videos: [(String, URL)] = [
            ("Sintel HQ 60s", testDir.appendingPathComponent("sintel_hq_60s.mp4")),
            ("BBB 60s", testDir.appendingPathComponent("bbb_60s.mp4")),
            ("OpenCV vtest", testDir.appendingPathComponent("face_video.mp4")),
            ("Pexels Person", testDir.appendingPathComponent("person_60s.mp4")),
            ("SampleLib 5s", testDir.appendingPathComponent("ted_sample.mp4")),
        ]

        for (name, url) in videos {
            guard FileManager.default.fileExists(atPath: url.path) else {
                print("[PROBE] \(name): file not found, skipping")
                continue
            }

            let asset = AVURLAsset(url: url)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
                print("[PROBE] \(name): no video track")
                continue
            }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            reader.add(output)
            guard reader.startReading() else {
                print("[PROBE] \(name): reader failed")
                continue
            }

            var faceCount = 0
            var framesChecked = 0
            let maxFrames = 50

            while let sample = output.copyNextSampleBuffer(), framesChecked < maxFrames {
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }

                var foundFaces = 0
                let req = VNDetectFaceLandmarksRequest { req, _ in
                    if let results = req.results as? [VNFaceObservation] {
                        foundFaces = results.count
                    }
                }
                let handler = VNImageRequestHandler(cvPixelBuffer: pb, options: [:])
                try? handler.perform([req])

                if foundFaces > 0 { faceCount += 1 }
                framesChecked += 1

                if framesChecked % 10 == 0 { _ = sample }
            }

            reader.cancelReading()
            print("[PROBE] \(name): \(faceCount)/\(framesChecked) frames had faces")
        }
    }
}
