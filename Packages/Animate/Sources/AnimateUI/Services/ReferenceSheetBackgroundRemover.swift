import AppKit
import CoreImage
import Foundation
import Vision

/// Full-resolution background removal that writes a transparent PNG back to
/// the same path. Used by the "Re-remove Backgrounds" buttons on master
/// sheets, head-turnaround variants, and costume full-body variants — re-runs
/// Vision foreground extraction on the existing crops to drop white
/// backgrounds and any spillover content the crop pipeline left behind.
@available(macOS 26.0, *)
enum ReferenceSheetBackgroundRemover {

    enum RemovalError: Error, LocalizedError {
        case imageDecodeFailed(URL)
        case visionRequestFailed(URL, Error)
        case visionReturnedNoForeground(URL)
        case maskApplyFailed(URL)
        case pngEncodeFailed(URL)
        case writeFailed(URL, Error)

        var errorDescription: String? {
            switch self {
            case .imageDecodeFailed(let url):
                return "Could not decode image at \(url.lastPathComponent)."
            case .visionRequestFailed(let url, let error):
                return "Vision foreground request failed for \(url.lastPathComponent): \(error.localizedDescription)"
            case .visionReturnedNoForeground(let url):
                return "Vision could not find a foreground in \(url.lastPathComponent)."
            case .maskApplyFailed(let url):
                return "Could not apply the foreground mask to \(url.lastPathComponent)."
            case .pngEncodeFailed(let url):
                return "Could not encode the masked image as PNG for \(url.lastPathComponent)."
            case .writeFailed(let url, let error):
                return "Could not save the transparent PNG to \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Run foreground extraction on the image at `url` and overwrite it
    /// in-place with a transparent-background PNG. Atomic write via a temp
    /// file + replaceItemAt so a partial failure can't corrupt the source.
    static func removeBackgroundInPlace(at url: URL) throws {
        guard let ciImage = CIImage(contentsOf: url) else {
            throw RemovalError.imageDecodeFailed(url)
        }

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            throw RemovalError.visionRequestFailed(url, error)
        }
        guard let observation = request.results?.first else {
            throw RemovalError.visionReturnedNoForeground(url)
        }

        let maskBuffer: CVPixelBuffer
        do {
            maskBuffer = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
        } catch {
            throw RemovalError.visionRequestFailed(url, error)
        }

        let maskCI = CIImage(cvPixelBuffer: maskBuffer)
        guard let blend = CIFilter(name: "CIBlendWithMask") else {
            throw RemovalError.maskApplyFailed(url)
        }
        blend.setValue(ciImage, forKey: kCIInputImageKey)
        blend.setValue(CIImage.empty(), forKey: kCIInputBackgroundImageKey)
        blend.setValue(maskCI, forKey: kCIInputMaskImageKey)

        let context = CIContext()
        guard let output = blend.outputImage,
              let cgImage = context.createCGImage(output, from: ciImage.extent) else {
            throw RemovalError.maskApplyFailed(url)
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw RemovalError.pngEncodeFailed(url)
        }

        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).bgremove.tmp")
        do {
            try pngData.write(to: tempURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw RemovalError.writeFailed(url, error)
        }
    }

    /// Apply background removal to many URLs in sequence. Errors are
    /// collected per-URL so one bad slot doesn't abort the whole sweep.
    /// Returns the count of successful removals plus the per-URL errors.
    @discardableResult
    static func removeBackgrounds(at urls: [URL]) -> (succeeded: Int, errors: [(URL, Error)]) {
        var succeeded = 0
        var errors: [(URL, Error)] = []
        for url in urls {
            do {
                try removeBackgroundInPlace(at: url)
                succeeded += 1
            } catch {
                errors.append((url, error))
            }
        }
        return (succeeded, errors)
    }
}
