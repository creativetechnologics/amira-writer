import AppKit
import Foundation
import Metal
import MetalKit

@available(macOS 26.0, *)
@MainActor
final class MouthSpriteAtlas {

    private let device: MTLDevice
    private let textureLoader: MTKTextureLoader
    private var cache: [String: [FaceAngle: [PrestonBlairViseme: MTLTexture]]] = [:]

    init(device: MTLDevice) {
        self.device = device
        self.textureLoader = MTKTextureLoader(device: device)
    }

    // MARK: - Public API

    func loadSprites(
        characterSlug: String,
        folderURL: URL
    ) -> [FaceAngle: [PrestonBlairViseme: MTLTexture]]? {
        guard FileManager.default.fileExists(atPath: folderURL.path) else { return nil }

        var sprites: [FaceAngle: [PrestonBlairViseme: MTLTexture]] = [:]

        for angle in FaceAngle.allCases {
            var angleMap: [PrestonBlairViseme: MTLTexture] = [:]

            for viseme in PrestonBlairViseme.allCases {
                if let url = findSpriteFile(
                    folderURL: folderURL,
                    viseme: viseme,
                    angle: angle
                ), let texture = loadSingleTexture(url: url) {
                    angleMap[viseme] = texture
                }
            }

            if !angleMap.isEmpty {
                sprites[angle] = angleMap
            }
        }

        guard !sprites.isEmpty else { return nil }
        cache[characterSlug] = sprites
        return sprites
    }

    func texture(
        characterSlug: String,
        viseme: PrestonBlairViseme,
        angle: FaceAngle
    ) -> MTLTexture? {
        guard let angleMap = cache[characterSlug] else { return nil }

        if let tex = angleMap[angle]?[viseme] { return tex }

        if angle != .front, let frontTex = angleMap[.front]?[viseme] {
            return frontTex
        }

        for fallbackAngle in FaceAngle.allCases {
            if let tex = angleMap[fallbackAngle]?[viseme] { return tex }
        }

        if viseme != .rest {
            for fallbackAngle in FaceAngle.allCases {
                if let tex = angleMap[fallbackAngle]?[.rest] { return tex }
            }
        }

        return nil
    }

    @discardableResult
    func preloadAll(tracks: [CharacterSyncTrack]) -> Int {
        var loaded = 0
        for track in tracks {
            if loadSprites(
                characterSlug: track.characterSlug,
                folderURL: track.mouthSpriteFolderURL
            ) != nil {
                loaded += 1
            }
        }
        return loaded
    }

    func clearCache() {
        cache.removeAll()
    }

    // MARK: - Private

    private func loadSingleTexture(url: URL) -> MTLTexture? {
        let options: [MTKTextureLoader.Option: Any] = [
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
            .textureStorageMode: MTLStorageMode.private.rawValue,
            .SRGB: false
        ]
        return try? textureLoader.newTexture(URL: url, options: options)
    }

    private func findSpriteFile(
        folderURL: URL,
        viseme: PrestonBlairViseme,
        angle: FaceAngle
    ) -> URL? {
        let token = viseme.token

        if let subfolder = angle.subfolderName {
            let angleFile = folderURL.appendingPathComponent(subfolder)
                .appendingPathComponent("\(token).png")
            if FileManager.default.fileExists(atPath: angleFile.path) {
                return angleFile
            }
        }

        let rootFile = folderURL.appendingPathComponent("\(token).png")
        if FileManager.default.fileExists(atPath: rootFile.path) {
            return rootFile
        }

        if viseme != .rest {
            let restFile = folderURL.appendingPathComponent("rest.png")
            if FileManager.default.fileExists(atPath: restFile.path) {
                return restFile
            }
        }

        return nil
    }
}
