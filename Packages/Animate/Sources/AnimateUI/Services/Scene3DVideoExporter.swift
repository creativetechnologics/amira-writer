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

        // Add audio track if provided
        if let audioURL = settings.audioURL,
           FileManager.default.fileExists(atPath: audioURL.path) {
            await addAudioTrack(writer: writer, audioURL: audioURL, fps: settings.fps, startFrame: settings.startFrame, endFrame: settings.endFrame)
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

    private func addAudioTrack(
        writer: AVAssetWriter,
        audioURL: URL,
        fps: Int,
        startFrame: Int,
        endFrame: Int
    ) async {
        // Audio mixing for 3D export deferred — use the existing 2D VideoExporter.addAudioTrack
        // as the reference implementation when ready.
        _ = writer; _ = audioURL; _ = fps; _ = startFrame; _ = endFrame
    }
}
