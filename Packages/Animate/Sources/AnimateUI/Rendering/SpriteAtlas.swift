import AppKit
import Metal
import MetalKit

/// Manages loaded textures for characters and backgrounds.
/// Groups textures by character ID for efficient binding.
@available(macOS 26.0, *)
@MainActor
final class SpriteAtlas {

    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader

    /// Loaded textures keyed by file path.
    private var textureCache: [String: MTLTexture] = [:]

    /// Background texture for current scene.
    private(set) var backgroundTexture: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }

    // MARK: - Loading

    func loadTexture(from url: URL) -> MTLTexture? {
        let key = url.path
        if let cached = textureCache[key] {
            return cached
        }

        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]

        guard let texture = try? textureLoader.newTexture(URL: url, options: options) else {
            return nil
        }

        textureCache[key] = texture
        return texture
    }

    func loadTexture(from image: NSImage, key: String) -> MTLTexture? {
        if let cached = textureCache[key] {
            return cached
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]

        guard let texture = try? textureLoader.newTexture(cgImage: cgImage, options: options) else {
            return nil
        }

        textureCache[key] = texture
        return texture
    }

    /// Load and set the background texture for the current scene.
    func loadBackground(from url: URL) -> MTLTexture? {
        let texture = loadTexture(from: url)
        backgroundTexture = texture
        return texture
    }

    // MARK: - Cache Management

    func removeTexture(forKey key: String) {
        textureCache.removeValue(forKey: key)
    }

    func clearCache() {
        textureCache.removeAll()
        backgroundTexture = nil
    }

    var cachedTextureCount: Int {
        textureCache.count
    }
}
