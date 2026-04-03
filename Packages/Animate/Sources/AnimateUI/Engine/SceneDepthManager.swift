import Foundation
import simd
import AppKit

// MARK: - Scene Depth Layer

/// A single depth layer in a parallax-composited scene.
///
/// Each layer sits at a fixed `zDepth` from the camera and moves at a
/// fraction of camera speed (`parallaxFactor`). Layers further from the
/// camera move more slowly, creating the classic multiplane parallax effect
/// used in traditional and anime cinematography.
@available(macOS 26.0, *)
struct SceneDepthLayer: Identifiable, Codable, Sendable, Hashable {
    var id: UUID = UUID()

    /// Human-readable layer name (e.g. "farBackground", "actionPlane").
    var name: String

    /// Distance from the camera in world units (metres).
    var zDepth: Double

    /// Parallax speed multiplier relative to the camera.
    /// 1.0 = moves with camera (action plane), < 1.0 = slower (far BG),
    /// > 1.0 = faster (foreground overshoot).
    var parallaxFactor: Double

    /// Atmospheric fog density: 0 = crystal clear, 1 = fully fogged out.
    var atmosphericDensity: Double

    /// Depth-of-field blur radius (0 = sharp). Computed from camera settings
    /// via `SceneDepthManager.updateBlurRadii(camera:)`.
    var blurRadius: Double
}

// MARK: - Scene Depth Manager

/// Manages layered depth planes for parallax scrolling, atmospheric
/// perspective, and depth-of-field blur.
///
/// Standard anime and Spider-Verse-style compositing uses 4-6 depth planes
/// stacked behind and in front of the action plane. This manager provides
/// the math to compute per-layer offsets, tinting, and blur so that the
/// renderer can composite them correctly.
@available(macOS 26.0, *)
struct SceneDepthManager: Sendable {

    var layers: [SceneDepthLayer] = []

    // MARK: Default Layers

    /// Standard anime-style depth layers, ordered back to front.
    static var defaultLayers: [SceneDepthLayer] {
        [
            SceneDepthLayer(
                name: "farBackground",
                zDepth: 50,
                parallaxFactor: 0.1,
                atmosphericDensity: 0.6,
                blurRadius: 0
            ),
            SceneDepthLayer(
                name: "midBackground",
                zDepth: 20,
                parallaxFactor: 0.3,
                atmosphericDensity: 0.3,
                blurRadius: 0
            ),
            SceneDepthLayer(
                name: "nearBackground",
                zDepth: 10,
                parallaxFactor: 0.6,
                atmosphericDensity: 0.1,
                blurRadius: 0
            ),
            SceneDepthLayer(
                name: "actionPlane",
                zDepth: 5,
                parallaxFactor: 1.0,
                atmosphericDensity: 0,
                blurRadius: 0
            ),
            SceneDepthLayer(
                name: "foreground",
                zDepth: 2,
                parallaxFactor: 1.5,
                atmosphericDensity: 0,
                blurRadius: 0
            ),
        ]
    }

    /// Creates a manager pre-populated with the standard anime depth layers.
    static var `default`: SceneDepthManager {
        SceneDepthManager(layers: defaultLayers)
    }

    // MARK: Parallax

    /// Computes the 2D parallax offset for a layer given a camera movement vector.
    ///
    /// Layers with `parallaxFactor < 1.0` lag behind the camera (far backgrounds),
    /// while layers with `parallaxFactor > 1.0` overshoot (foreground elements),
    /// creating depth through differential motion.
    ///
    /// - Parameters:
    ///   - layer: The depth layer to compute offset for.
    ///   - cameraMovement: Camera displacement in screen-space units (X, Y).
    /// - Returns: The layer's parallax offset in screen-space units.
    func parallaxOffset(
        for layer: SceneDepthLayer,
        cameraMovement: SIMD2<Double>
    ) -> SIMD2<Double> {
        cameraMovement * layer.parallaxFactor
    }

    // MARK: Atmospheric Perspective

    /// Computes the atmospheric colour tint for a layer by blending the base
    /// colour toward a fog colour based on the layer's atmospheric density.
    ///
    /// This simulates aerial perspective: distant layers appear more washed out
    /// and tinted toward the ambient sky/fog colour, while near layers retain
    /// their full saturation.
    ///
    /// - Parameters:
    ///   - layer: The depth layer.
    ///   - baseColor: The layer's untinted colour (RGB, 0...1).
    ///   - fogColor: The scene's atmospheric fog colour (RGB, 0...1).
    /// - Returns: The tinted colour (RGB, 0...1).
    func atmosphericTint(
        for layer: SceneDepthLayer,
        baseColor: SIMD3<Double>,
        fogColor: SIMD3<Double>
    ) -> SIMD3<Double> {
        let d = max(0, min(1, layer.atmosphericDensity))
        return simd_mix(baseColor, fogColor, SIMD3<Double>(repeating: d))
    }

    // MARK: Depth of Field

    /// Updates blur radii for all layers based on the current camera's
    /// depth-of-field settings.
    ///
    /// Uses `AnimationCamera.blurRadius(atDistance:)` to compute a physically
    /// motivated blur value for each layer's depth. Layers at the focus distance
    /// remain sharp while layers further away receive increasing blur.
    ///
    /// - Parameter camera: The current `AnimationCamera` state (from
    ///   `AnimationCameraSystem.swift`).
    mutating func updateBlurRadii(camera: AnimationCamera) {
        for i in layers.indices {
            layers[i].blurRadius = camera.blurRadius(atDistance: layers[i].zDepth)
        }
    }

    // MARK: Layer Queries

    /// Returns the layer closest to a given world-space depth, or `nil` if
    /// there are no layers.
    func nearestLayer(toDepth depth: Double) -> SceneDepthLayer? {
        layers.min(by: { abs($0.zDepth - depth) < abs($1.zDepth - depth) })
    }

    /// Returns layers sorted from furthest to nearest (back-to-front draw order).
    var backToFront: [SceneDepthLayer] {
        layers.sorted { $0.zDepth > $1.zDepth }
    }

    /// Returns layers sorted from nearest to furthest (front-to-back).
    var frontToBack: [SceneDepthLayer] {
        layers.sorted { $0.zDepth < $1.zDepth }
    }
}

// MARK: - Depth Estimation Cache

/// Actor-isolated cache of depth maps keyed by background image URL.
///
/// Used by the production preview view to run `DepthEstimationService` once per background
/// and expose the cached result for parallax compositing.
@available(macOS 26.0, *)
actor SceneDepthCache {

    // MARK: - Singleton

    static let shared = SceneDepthCache()

    // MARK: - Storage

    private var cache: [URL: DepthEstimationService.DepthMap] = [:]

    // MARK: - Public API

    /// Returns the cached depth map for a URL without triggering estimation.
    func depthMap(for url: URL) -> DepthEstimationService.DepthMap? {
        cache[url]
    }

    /// Runs `DepthEstimationService.estimateDepth(imageURL:)` if no cached result exists,
    /// stores the result, and returns it.
    ///
    /// Safe to call concurrently — the actor serialises access so each URL is estimated
    /// at most once even if multiple callers request it simultaneously.
    func estimateAndCacheDepth(for backgroundURL: URL) async {
        guard cache[backgroundURL] == nil else { return }
        guard let map = try? await DepthEstimationService.estimateDepth(imageURL: backgroundURL) else {
            return
        }
        cache[backgroundURL] = map
    }

    /// Clears all cached depth maps. Call when switching projects.
    func clearAll() {
        cache.removeAll()
    }
}
