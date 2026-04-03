import Foundation
import SceneKit
import AVFoundation
import Metal
import CoreImage

/// Exports a 3D SceneKit scene to video using SCNRenderer for offscreen rendering.
///
/// Renders each frame of the production plan through the provided `ScenePreviewRenderer`,
/// captures via SCNRenderer to a Metal texture, then encodes with AVAssetWriter.
@available(macOS 26.0, *)
@MainActor
final class Scene3DVideoExporter {

    enum ExportError: LocalizedError {
        case metalDeviceUnavailable
        case writerSetupFailed(String)
        case renderFailed
        case encodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .metalDeviceUnavailable: return "No Metal device available for 3D export."
            case .writerSetupFailed(let msg): return "Export writer setup failed: \(msg)"
            case .renderFailed: return "Scene render failed."
            case .encodingFailed(let msg): return "Video encoding failed: \(msg)"
            }
        }
    }

    struct Settings {
        var outputURL: URL
        var width: Int = 1920
        var height: Int = 1080
        var fps: Int = 24
        var startFrame: Int = 0
        var endFrame: Int
        var audioURL: URL? = nil
        var format: ExportFormat = .mp4

        enum ExportFormat {
            case mp4
            case mov
            var avFileType: AVFileType { self == .mp4 ? .mp4 : .mov }
            var codecSettings: [String: Any] {
                self == .mp4
                    ? [AVVideoCodecKey: AVVideoCodecType.h264,
                       AVVideoWidthKey: 1920,
                       AVVideoHeightKey: 1080]
                    : [AVVideoCodecKey: AVVideoCodecType.proRes4444,
                       AVVideoWidthKey: 1920,
                       AVVideoHeightKey: 1080]
            }
        }
    }

    /// Progress callback: receives (currentFrame, totalFrames).
    var onProgress: ((Int, Int) -> Void)?

    /// Whether to apply cel shading during export (mirrors preview appearance).
    var applyCelShading: Bool = true

    /// Export the renderer's current scene to a video file.
    func export(
        renderer: ScenePreviewRenderer,
        settings: Settings
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ExportError.metalDeviceUnavailable
        }

        // Set up SCNRenderer for offscreen rendering
        let scnRenderer = SCNRenderer(device: device, options: nil)
        scnRenderer.scene = renderer.sceneKitScene
        scnRenderer.pointOfView = renderer.pointOfView
        scnRenderer.autoenablesDefaultLighting = false

        // Apply cel shading technique to the offscreen renderer so the export
        // matches the in-app preview appearance.
        if applyCelShading {
            let celSettings = renderer.celShadingSettings
            if let technique = CelShadingTechnique.makeTechnique(settings: celSettings) {
                scnRenderer.technique = technique
            } else {
                // Metal technique unavailable — apply per-material toon fallback.
                print("[Scene3DVideoExporter] Cel shading unavailable, using flat render")
                CelShadingTechnique.applyPerMaterialFallback(
                    to: renderer.sceneKitScene,
                    settings: celSettings
                )
            }
        }

        // Set up AVAssetWriter
        let writer = try AVAssetWriter(outputURL: settings.outputURL, fileType: settings.format.avFileType)
        var codecSettings = settings.format.codecSettings
        codecSettings[AVVideoWidthKey] = settings.width
        codecSettings[AVVideoHeightKey] = settings.height

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: codecSettings)
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: settings.width,
                kCVPixelBufferHeightKey as String: settings.height
            ]
        )
        guard writer.canAdd(videoInput) else {
            throw ExportError.writerSetupFailed("Cannot add video input to writer")
        }
        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Create Metal texture descriptor
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: settings.width,
            height: settings.height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        guard let renderTexture = device.makeTexture(descriptor: textureDescriptor) else {
            throw ExportError.renderFailed
        }

        let commandQueue = device.makeCommandQueue()!
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        let totalFrames = settings.endFrame - settings.startFrame + 1

        for i in 0..<totalFrames {
            let rawFrame = settings.startFrame + i
            renderer.renderFrame(rawFrame)

            // Render scene to Metal texture
            let commandBuffer = commandQueue.makeCommandBuffer()!
            let renderPassDescriptor = MTLRenderPassDescriptor()
            renderPassDescriptor.colorAttachments[0].texture = renderTexture
            renderPassDescriptor.colorAttachments[0].loadAction = .clear
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            renderPassDescriptor.colorAttachments[0].storeAction = .store

            let time = Double(rawFrame) / Double(settings.fps)
            scnRenderer.render(
                atTime: time,
                viewport: CGRect(x: 0, y: 0, width: settings.width, height: settings.height),
                commandBuffer: commandBuffer,
                passDescriptor: renderPassDescriptor
            )
            commandBuffer.commit()
            // waitUntilCompleted is unavailable in async contexts; use a continuation to bridge.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                commandBuffer.addCompletedHandler { _ in continuation.resume() }
            }

            // Convert Metal texture to pixel buffer
            guard let pixelBuffer = pixelBuffer(from: renderTexture, width: settings.width, height: settings.height) else {
                throw ExportError.renderFailed
            }

            // Wait for input readiness
            while !videoInput.isReadyForMoreMediaData {
                await Task.yield()
            }

            let pts = CMTimeMultiply(frameDuration, multiplier: Int32(i))
            adaptor.append(pixelBuffer, withPresentationTime: pts)
            onProgress?(i + 1, totalFrames)
        }

        videoInput.markAsFinished()

        // Add audio track if provided — mux after all video frames are written.
        if let audioURL = settings.audioURL,
           FileManager.default.fileExists(atPath: audioURL.path) {
            let totalFrames = settings.endFrame - settings.startFrame + 1
            let videoDuration = CMTime(
                value: CMTimeValue(totalFrames),
                timescale: CMTimeScale(settings.fps)
            )
            await addAudioTrack(
                writer: writer,
                audioURL: audioURL,
                videoDuration: videoDuration
            )
        }

        await writer.finishWriting()
        if let error = writer.error {
            throw ExportError.encodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Helpers

    private func pixelBuffer(from texture: MTLTexture, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                   kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let data = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let region = MTLRegion(origin: .init(x: 0, y: 0, z: 0),
                               size: .init(width: width, height: height, depth: 1))
        texture.getBytes(data, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
        return buffer
    }

    /// Muxes audio from `audioURL` into the already-started `AVAssetWriter`,
    /// trimmed to `videoDuration`.  Silently returns on any error so a missing
    /// or malformed audio file never aborts the video export.
    private func addAudioTrack(
        writer: AVAssetWriter,
        audioURL: URL,
        videoDuration: CMTime
    ) async {
        // Load source audio asset.
        let sourceAsset = AVURLAsset(url: audioURL)

        // Retrieve the first audio track (async, non-deprecated).
        guard let sourceTrack = try? await sourceAsset.loadTracks(withMediaType: .audio).first else {
            return
        }

        // Build a passthrough audio input so we avoid unnecessary re-encoding.
        let audioOutputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(audioInput) else { return }
        writer.add(audioInput)

        // Set up reader over the trimmed range [0, videoDuration).
        let timeRange = CMTimeRange(start: .zero, duration: videoDuration)
        guard let reader = try? AVAssetReader(asset: sourceAsset) else { return }
        reader.timeRange = timeRange

        let readerOutput = AVAssetReaderTrackOutput(
            track: sourceTrack,
            outputSettings: nil  // nil = passthrough compressed samples
        )
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { return }
        reader.add(readerOutput)
        guard reader.startReading() else { return }

        // Pump samples from reader → writer.
        while audioInput.isReadyForMoreMediaData {
            guard reader.status == .reading else { break }
            if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                audioInput.append(sampleBuffer)
            } else {
                // No more samples.
                break
            }
        }

        // Drain any remaining samples once the input is ready again.
        if reader.status == .reading {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                audioInput.requestMediaDataWhenReady(on: .global(qos: .utility)) {
                    while audioInput.isReadyForMoreMediaData {
                        guard reader.status == .reading else {
                            audioInput.markAsFinished()
                            continuation.resume()
                            return
                        }
                        if let sampleBuffer = readerOutput.copyNextSampleBuffer() {
                            audioInput.append(sampleBuffer)
                        } else {
                            audioInput.markAsFinished()
                            continuation.resume()
                            return
                        }
                    }
                }
            }
        } else {
            audioInput.markAsFinished()
        }

        reader.cancelReading()
    }
}
