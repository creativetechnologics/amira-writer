import AVFoundation
import CoreVideo
import Foundation

@available(macOS 26.0, *)
typealias PixelBufferHandler = @Sendable (CVPixelBuffer, CMTime) -> Void

@available(macOS 26.0, *)
final class CaptureSession: NSObject, Sendable {

    enum State: String, Sendable {
        case idle
        case starting
        case running
        case stopped
        case failed
    }

    nonisolated(unsafe) private var session: AVCaptureSession?
    nonisolated(unsafe) private var videoOutput: AVCaptureVideoDataOutput?

    private let processingQueue = DispatchQueue(
        label: "com.amira.mocap.capture",
        qos: .userInteractive
    )

    private let _state = AtomicState(CaptureSession.State.idle)
    private let _pixelBufferHandler = AtomicBox<PixelBufferHandler?>(nil)

    var state: CaptureSession.State { _state.value }
    var captureSession: AVCaptureSession? { session }

    func setPixelBufferHandler(_ handler: @escaping PixelBufferHandler) {
        _pixelBufferHandler.value = handler
    }

    static func availableCameras() -> [(id: String, name: String)] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discoverySession.devices.map { ($0.uniqueID, $0.localizedName) }
    }

    func start(cameraID: String? = nil) {
        guard _state.value == .idle || _state.value == .stopped || _state.value == .failed else {
            return
        }
        _state.value = .starting

        processingQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureAndStart(cameraID: cameraID)
                self._state.value = .running
            } catch {
                print("[CaptureSession] Failed to start: \(error)")
                self._state.value = .failed
            }
        }
    }

    func stop() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.session?.stopRunning()
            self._state.value = .stopped
        }
    }

    private func configureAndStart(cameraID: String?) throws {
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .high

        let device: AVCaptureDevice?
        if let cameraID {
            device = AVCaptureDevice(uniqueID: cameraID)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }
        guard let camera = device else {
            throw CaptureSessionError.noCameraAvailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CaptureSessionError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: processingQueue)

        guard session.canAddOutput(output) else {
            throw CaptureSessionError.cannotAddOutput
        }
        session.addOutput(output)

        session.commitConfiguration()
        session.startRunning()

        self.session = session
        self.videoOutput = output
    }
}

@available(macOS 26.0, *)
extension CaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        _pixelBufferHandler.value?(pixelBuffer, timestamp)
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
    }
}

@available(macOS 26.0, *)
enum CaptureSessionError: LocalizedError {
    case noCameraAvailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable: "No camera found. Connect a webcam or enable the built-in camera."
        case .cannotAddInput: "Cannot add camera input to capture session."
        case .cannotAddOutput: "Cannot add video output to capture session."
        }
    }
}

@available(macOS 26.0, *)
final class AtomicState<T: Sendable>: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _value: T

    init(_ value: T) { _value = value }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}

@available(macOS 26.0, *)
final class AtomicBox<T: Sendable>: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _value: T

    init(_ value: T) { _value = value }

    var value: T {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}