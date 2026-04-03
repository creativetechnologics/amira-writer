import AVFoundation
import AppKit
import Metal

/// Exports animated scenes to video files using AVAssetWriter.
///
/// Renders each frame offline using the Metal compositor, then encodes
/// the frame sequence into H.264 MP4 or ProRes MOV format.
@available(macOS 26.0, *)
@MainActor
final class VideoExporter {

    // MARK: - Types

    enum ExportFormat: String, CaseIterable, Sendable {
        case mp4 = "MP4 (H.264)"
        case mov = "MOV (ProRes)"

        var fileExtension: String {
            switch self {
            case .mp4: "mp4"
            case .mov: "mov"
            }
        }

        var fileType: AVFileType {
            switch self {
            case .mp4: .mp4
            case .mov: .mov
            }
        }

        var videoCodec: AVVideoCodecType {
            switch self {
            case .mp4: .h264
            case .mov: .proRes422
            }
        }
    }

    enum ExportResolution: String, CaseIterable, Sendable {
        case hd720 = "720p"
        case hd1080 = "1080p"
        case uhd4k = "4K"

        var size: (width: Int, height: Int) {
            switch self {
            case .hd720: (1280, 720)
            case .hd1080: (1920, 1080)
            case .uhd4k: (3840, 2160)
            }
        }
    }

    struct ExportSettings {
        var format: ExportFormat = .mp4
        var resolution: ExportResolution = .hd1080
        var fps: Int = 24
        var startFrame: Int = 0
        var endFrame: Int = 0
        var audioURL: URL?
        var outputURL: URL
    }

    enum ExportError: LocalizedError {
        case noMetalDevice
        case writerSetupFailed(String)
        case renderFailed(Int)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .noMetalDevice: "No Metal GPU device available."
            case .writerSetupFailed(let msg): "Could not set up video writer: \(msg)"
            case .renderFailed(let frame): "Failed to render frame \(frame)."
            case .cancelled: "Export was cancelled."
            }
        }
    }

    // MARK: - Properties

    var progress: Double = 0
    var progressMessage: String = ""
    var isCancelled = false

    // MARK: - Export

    /// Export a range of frames to a video file.
    func export(
        settings: ExportSettings,
        renderer: AnimationRenderer,
        spriteBuilder: @MainActor (Int) -> [SpriteInstance]
    ) async throws {
        let width = settings.resolution.size.width
        let height = settings.resolution.size.height
        let totalFrames = settings.endFrame - settings.startFrame
        guard totalFrames > 0 else { return }

        // Set up AVAssetWriter
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: settings.outputURL, fileType: settings.format.fileType)
        } catch {
            throw ExportError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.format.videoCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttrs
        )

        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.fps))

        // Create a Metal texture for offline rendering
        let device = renderer.device

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]

        guard let offscreenTexture = device.makeTexture(descriptor: textureDescriptor) else {
            throw ExportError.writerSetupFailed("Could not create offscreen texture")
        }

        // Render each frame
        for frameOffset in 0..<totalFrames {
            guard !isCancelled else {
                writer.cancelWriting()
                throw ExportError.cancelled
            }

            let frame = settings.startFrame + frameOffset
            progress = Double(frameOffset) / Double(totalFrames)
            progressMessage = "Rendering frame \(frame) (\(frameOffset + 1)/\(totalFrames))"

            // Build sprites for this frame
            let sprites = spriteBuilder(frame)

            // Render to offscreen texture
            let viewportSize = SIMD2<Float>(Float(width), Float(height))
            renderer.render(to: offscreenTexture, viewportSize: viewportSize, sprites: sprites)

            // Read pixels from texture
            guard let pixelBuffer = createPixelBuffer(from: offscreenTexture, width: width, height: height) else {
                throw ExportError.renderFailed(frame)
            }

            // Wait for the input to be ready
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }

            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameOffset))
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }

        // Add audio track if provided
        if let audioURL = settings.audioURL {
            await addAudioTrack(to: writer, from: audioURL, duration: CMTimeMultiply(frameDuration, multiplier: Int32(totalFrames)))
        }

        videoInput.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        progress = 1.0
        progressMessage = "Export complete!"
    }

    func export(
        settings: ExportSettings,
        renderer: AnimationRenderer,
        drawItemBuilder: @MainActor (Int) -> [AnimationRenderer.DrawItem]
    ) async throws {
        let width = settings.resolution.size.width
        let height = settings.resolution.size.height
        let totalFrames = settings.endFrame - settings.startFrame
        guard totalFrames > 0 else { return }

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: settings.outputURL, fileType: settings.format.fileType)
        } catch {
            throw ExportError.writerSetupFailed(error.localizedDescription)
        }

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: settings.format.videoCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = false

        let pixelBufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: pixelBufferAttrs
        )

        writer.add(videoInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.fps))
        let device = renderer.device

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]

        guard let offscreenTexture = device.makeTexture(descriptor: textureDescriptor) else {
            throw ExportError.writerSetupFailed("Could not create offscreen texture")
        }

        for frameOffset in 0..<totalFrames {
            guard !isCancelled else {
                writer.cancelWriting()
                throw ExportError.cancelled
            }

            let frame = settings.startFrame + frameOffset
            progress = Double(frameOffset) / Double(totalFrames)
            progressMessage = "Rendering frame \(frame) (\(frameOffset + 1)/\(totalFrames))"

            let drawItems = drawItemBuilder(frame)
            let viewportSize = SIMD2<Float>(Float(width), Float(height))
            renderer.render(to: offscreenTexture, viewportSize: viewportSize, drawItems: drawItems)

            guard let pixelBuffer = createPixelBuffer(from: offscreenTexture, width: width, height: height) else {
                throw ExportError.renderFailed(frame)
            }

            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }

            let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameOffset))
            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
        }

        if let audioURL = settings.audioURL {
            await addAudioTrack(to: writer, from: audioURL, duration: CMTimeMultiply(frameDuration, multiplier: Int32(totalFrames)))
        }

        videoInput.markAsFinished()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting {
                continuation.resume()
            }
        }

        progress = 1.0
        progressMessage = "Export complete!"
    }

    // MARK: - Pixel Buffer from Metal Texture

    private func createPixelBuffer(from texture: MTLTexture, width: Int, height: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)

        let region = MTLRegion(origin: MTLOrigin(x: 0, y: 0, z: 0),
                               size: MTLSize(width: width, height: height, depth: 1))
        texture.getBytes(baseAddress, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)

        return buffer
    }

    // MARK: - Audio Track

    private func addAudioTrack(to writer: AVAssetWriter, from audioURL: URL, duration: CMTime) async {
        let asset = AVURLAsset(url: audioURL)
        guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else { return }

        guard let formatDescriptions = try? await audioTrack.load(.formatDescriptions),
              let formatDesc = formatDescriptions.first else { return }

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formatDesc)
        audioInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(audioInput) else { return }
        writer.add(audioInput)

        guard let reader = try? AVAssetReader(asset: asset) else { return }
        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        reader.add(readerOutput)
        reader.startReading()

        while let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            if audioInput.isReadyForMoreMediaData {
                audioInput.append(sampleBuffer)
            }
        }

        audioInput.markAsFinished()
    }
}
