import Foundation
import CryptoKit
import ImageIO

/// Helpers for inspecting image files locally (hash, dimensions, etc.)
@available(macOS 26.0, *)
public enum ImageAssetInspector {

    /// Compute SHA-256 hash of file contents.
    public static func computeContentHash(path: String) throws -> String? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }

        var hasher = SHA256()
        let chunkSize = 256 * 1024

        while true {
            guard let chunk = try fileHandle.read(upToCount: chunkSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }

        let hash = hasher.finalize()
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Get file size in bytes.
    public static func fileSizeBytes(path: String) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return nil }
        return size
    }

    /// Get image dimensions and MIME type via ImageIO.
    public static func imageProperties(path: String) -> (width: Int, height: Int, mimeType: String?)? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }

        // Determine MIME type from UTI
        var mimeType: String?
        if let uti = CGImageSourceGetType(source) {
            mimeType = utiToMimeType(uti as String)
        }

        return (width: width, height: height, mimeType: mimeType)
    }

    /// Comprehensive inspection result.
    public struct InspectionResult {
        public let path: String
        public let contentHashSHA256: String?
        public let fileSizeBytes: Int?
        public let width: Int?
        public let height: Int?
        public let mimeType: String?
        public let isReadable: Bool

        public var aspectRatio: Double? {
            guard let w = width, let h = height, h > 0 else { return nil }
            return Double(w) / Double(h)
        }
    }

    /// Perform full inspection of an image file.
    public static func inspect(path: String) -> InspectionResult {
        let fileManager = FileManager.default
        let exists = fileManager.fileExists(atPath: path)
        let isReadable = exists && fileManager.isReadableFile(atPath: path)

        var contentHash: String?
        var fileSize: Int?
        var width: Int?
        var height: Int?
        var mimeType: String?

        if isReadable {
            contentHash = try? computeContentHash(path: path)
            fileSize = fileSizeBytes(path: path)
            if let props = imageProperties(path: path) {
                width = props.width
                height = props.height
                mimeType = props.mimeType
            }
        }

        return InspectionResult(
            path: path,
            contentHashSHA256: contentHash,
            fileSizeBytes: fileSize,
            width: width,
            height: height,
            mimeType: mimeType,
            isReadable: isReadable
        )
    }

    // MARK: - Private

    private static func utiToMimeType(_ uti: String) -> String? {
        // Common image UTIs to MIME types
        let mapping: [String: String] = [
            "public.png": "image/png",
            "public.jpeg": "image/jpeg",
            "public.tiff": "image/tiff",
            "com.compuserve.gif": "image/gif",
            "public.heic": "image/heic",
            "public.heif": "image/heif",
            "public.webp": "image/webp",
            "com.adobe.pdf": "application/pdf"
        ]
        return mapping[uti]
    }
}
