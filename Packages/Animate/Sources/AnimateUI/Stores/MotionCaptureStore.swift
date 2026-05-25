import AVFoundation
import AppKit
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
@MainActor
final class MotionCaptureStore {
    unowned let parent: AnimateStore
    init(parent: AnimateStore) { self.parent = parent }

    func startMocap() {
        guard !parent.mocapIsRunning else { return }
        parent.mocapErrorMessage = nil
        parent.mocapFrameCount = 0
        parent.mocapLatestPoseFrame = nil
        parent.mocapTemporalFilter.reset()

        let capture = CaptureSession()
        let tracker = VisionBodyTracker { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var finalFrame = frame
                if self.parent.mocapFilterEnabled, let joints = frame.bodyJoints {
                    let filtered = self.parent.mocapTemporalFilter.filter(joints: joints, timestamp: frame.timestamp)
                    finalFrame = UnifiedPoseFrame(timestamp: frame.timestamp, source: frame.source, bodyJoints: filtered, bodyConfidences: frame.bodyConfidences, leftHandJoints: frame.leftHandJoints, rightHandJoints: frame.rightHandJoints, faceBlendShapes: frame.faceBlendShapes, faceLandmarks: frame.faceLandmarks)
                }
                self.parent.mocapLatestPoseFrame = finalFrame
                self.parent.mocapFrameCount += 1
            }
        }

        capture.setPixelBufferHandler { [weak tracker] pixelBuffer, presentationTime in
            tracker?.processFrame(pixelBuffer, timestamp: CMTimeGetSeconds(presentationTime))
        }

        capture.onStateChange = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch newState {
                case .running: self.parent.mocapIsRunning = true; self.parent.mocapErrorMessage = nil
                case .failed: self.parent.mocapIsRunning = false; self.parent.mocapErrorMessage = "Camera failed to start. Check permissions or camera connection."
                case .stopped: self.parent.mocapIsRunning = false
                default: break
                }
            }
        }

        parent.mocapCaptureSession = capture
        parent.mocapBodyTracker = tracker
        capture.start(cameraID: parent.mocapCameraID)
    }

    func stopMocap() {
        parent.mocapCaptureSession?.stop()
        parent.mocapCaptureSession = nil
        parent.mocapBodyTracker = nil
        parent.mocapIsRunning = false
    }

    func startAudioLipSyncRecording() {
        guard !parent.isRecordingAudioLipSync else { return }
        let recorder = AudioLipSyncRecorder()
        do {
            try recorder.startRecording()
            parent._audioLipSyncRecorder = recorder
            parent.isRecordingAudioLipSync = true
        } catch {
            print("[AudioLipSync] Failed to start: \(error.localizedDescription)")
        }
    }

    func stopAudioLipSyncRecording() {
        guard parent.isRecordingAudioLipSync, let recorder = parent._audioLipSyncRecorder else { return }
        let clip = recorder.stopRecording()
        parent._audioLipSyncRecorder = nil
        parent.isRecordingAudioLipSync = false
        parent.addMotionClipToLipSyncTrack(clip)
    }

    func setTrackingMode(_ mode: CaptureTrackingMode) throws {
        parent.mocapTrackingMode = mode
        if mode == .enhanced && parent.mocapDWPoseTracker == nil {
            parent.mocapDWPoseTracker = try DWPoseTracker()
        }
    }
}
