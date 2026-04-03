import Foundation
import Metal
import SceneKit
import simd

// MARK: - Cel-Shading Settings

/// Parameters that control the cel-shading / toon-rendering appearance.
@available(macOS 26.0, *)
struct CelShadingSettings: Sendable {
    /// Master toggle.
    var enabled: Bool = true
    /// Thickness of ink outlines in texel units.
    var outlineWidth: Float = 1.5
    /// Outline ink colour (RGBA).
    var outlineColor: SIMD4<Float> = SIMD4(0, 0, 0, 1)
    /// Number of discrete luminance bands (2 = hard toon, 4+ = softer).
    var colorBands: Int = 3
    /// Luminance below this is pushed to shadow tone.
    var shadowThreshold: Float = 0.3
    /// Luminance above this is pushed to full bright.
    var highlightThreshold: Float = 0.7
    /// Whether ink-line edge detection is enabled.
    var inkLineEnabled: Bool = true

    static let `default` = CelShadingSettings()
}

// MARK: - SCNTechnique Builder

/// Builds and manages an `SCNTechnique` that applies anime-style cel shading
/// as a full-screen post-process over a SceneKit scene.
///
/// The technique uses a single `DRAW_QUAD` pass that reads the scene's colour
/// and depth buffers, quantises lighting into discrete bands, and draws Sobel-
/// based ink outlines -- all in one fragment shader invocation.
@available(macOS 26.0, *)
enum CelShadingTechnique {

    // MARK: Technique Creation

    /// Creates an `SCNTechnique` configured for cel-shaded rendering.
    ///
    /// Returns `nil` if SceneKit cannot construct the technique from
    /// the definition dictionary (e.g. Metal shaders are missing).
    static func makeTechnique(
        outlineWidth: Float = 1.5,
        outlineColor: SIMD4<Float> = SIMD4(0, 0, 0, 1),
        colorBands: Int = 3,
        shadowThreshold: Float = 0.3,
        highlightThreshold: Float = 0.7
    ) -> SCNTechnique? {
        let definition = techniqueDefinition()
        guard let technique = SCNTechnique(dictionary: definition) else {
            return nil
        }

        // Point the technique at the Metal library compiled into this
        // SPM module's bundle (the .metal file is compiled automatically
        // by SwiftPM into default.metallib inside Bundle.module).
        if let library = loadMetalLibrary() {
            technique.library = library
        }

        applyUniforms(
            to: technique,
            outlineWidth: outlineWidth,
            outlineColor: outlineColor,
            colorBands: colorBands,
            shadowThreshold: shadowThreshold,
            highlightThreshold: highlightThreshold
        )
        return technique
    }

    /// Creates an `SCNTechnique` from a `CelShadingSettings` value.
    static func makeTechnique(settings: CelShadingSettings) -> SCNTechnique? {
        guard settings.enabled else { return nil }
        return makeTechnique(
            outlineWidth: settings.inkLineEnabled ? settings.outlineWidth : 0,
            outlineColor: settings.outlineColor,
            colorBands: settings.colorBands,
            shadowThreshold: settings.shadowThreshold,
            highlightThreshold: settings.highlightThreshold
        )
    }

    // MARK: Apply / Remove

    /// Applies cel shading to an `SCNView`.
    ///
    /// If `settings.enabled` is `false`, any existing technique is removed.
    @MainActor
    static func apply(to view: SCNView, settings: CelShadingSettings = .default) {
        if settings.enabled, let technique = makeTechnique(settings: settings) {
            view.technique = technique
        } else {
            view.technique = nil
        }
    }

    /// Removes cel shading from an `SCNView`.
    @MainActor
    static func remove(from view: SCNView) {
        view.technique = nil
    }

    // MARK: Live Updates

    /// Updates uniform values on an already-applied technique without
    /// recreating it.  Cheaper than `apply(to:settings:)` for real-time
    /// slider adjustments.
    @MainActor
    static func updateUniforms(
        on view: SCNView,
        settings: CelShadingSettings
    ) {
        guard let technique = view.technique else { return }
        applyUniforms(
            to: technique,
            outlineWidth: settings.inkLineEnabled ? settings.outlineWidth : 0,
            outlineColor: settings.outlineColor,
            colorBands: settings.colorBands,
            shadowThreshold: settings.shadowThreshold,
            highlightThreshold: settings.highlightThreshold
        )
    }

    // MARK: - Per-Material Fallback

    /// Fallback for environments where `SCNTechnique` with Metal post-
    /// processing is unavailable.  Applies a flat, toon-ish look to every
    /// material in the scene by switching to a physically-based model with
    /// full roughness and zero metalness.
    static func applyPerMaterialFallback(
        to scene: SCNScene,
        settings: CelShadingSettings = .default
    ) {
        guard settings.enabled else { return }
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                material.lightingModel = .physicallyBased
                material.metalness.contents = NSNumber(value: 0.0)
                material.roughness.contents = NSNumber(value: 1.0)
                material.ambient.contents = material.diffuse.contents
            }
        }
    }

    // MARK: - Private

    /// Loads the Metal library compiled from .metal files in this SPM target.
    private static func loadMetalLibrary() -> (any MTLLibrary)? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let bundle = SafeBundle.module else { return nil }
        return try? device.makeDefaultLibrary(bundle: bundle)
    }

    /// Builds the technique definition dictionary that SceneKit parses.
    ///
    /// Layout:
    ///   - Single `DRAW_QUAD` pass reading COLOR + DEPTH.
    ///   - Uniform symbols referenced as pass inputs so SCNTechnique packs
    ///     them into `buffer(0)` in declaration order for the fragment shader.
    ///   - Writes final composited colour back to COLOR.
    private static func techniqueDefinition() -> [String: Any] {
        [
            "passes": [
                "cel_shading_pass": [
                    "draw": "DRAW_QUAD",
                    // Required placeholder -- SCNTechnique needs this key
                    // even when Metal shaders are used exclusively.
                    "program": "doesntexist",
                    "metalVertexShader": "cel_vertex",
                    "metalFragmentShader": "cel_fragment",
                    "inputs": [
                        // Textures (bound to texture(0), texture(1))
                        "colorSampler": "COLOR",
                        "depthSampler": "DEPTH",
                        // Vertex semantic for the full-screen quad
                        "a_position": "vertexSymbol",
                        // Scalar uniforms packed into buffer(0) struct
                        "outlineWidth": "outlineWidthSymbol",
                        "colorBands": "colorBandsSymbol",
                        "shadowThreshold": "shadowThresholdSymbol",
                        "highlightThreshold": "highlightThresholdSymbol",
                        "outlineR": "outlineRSymbol",
                        "outlineG": "outlineGSymbol",
                        "outlineB": "outlineBSymbol",
                        "outlineA": "outlineASymbol"
                    ] as [String: Any],
                    "outputs": [
                        "color": "COLOR"
                    ]
                ] as [String: Any]
            ],
            "sequence": [
                "cel_shading_pass"
            ],
            "symbols": [
                "vertexSymbol": ["semantic": "vertex"],
                "outlineWidthSymbol": ["type": "float"],
                "colorBandsSymbol": ["type": "float"],
                "shadowThresholdSymbol": ["type": "float"],
                "highlightThresholdSymbol": ["type": "float"],
                "outlineRSymbol": ["type": "float"],
                "outlineGSymbol": ["type": "float"],
                "outlineBSymbol": ["type": "float"],
                "outlineASymbol": ["type": "float"]
            ]
        ]
    }

    /// Pushes uniform values into a live technique via KVC.
    private static func applyUniforms(
        to technique: SCNTechnique,
        outlineWidth: Float,
        outlineColor: SIMD4<Float>,
        colorBands: Int,
        shadowThreshold: Float,
        highlightThreshold: Float
    ) {
        technique.setValue(
            NSNumber(value: outlineWidth), forKeyPath: "outlineWidthSymbol")
        technique.setValue(
            NSNumber(value: Float(colorBands)), forKeyPath: "colorBandsSymbol")
        technique.setValue(
            NSNumber(value: shadowThreshold), forKeyPath: "shadowThresholdSymbol")
        technique.setValue(
            NSNumber(value: highlightThreshold), forKeyPath: "highlightThresholdSymbol")
        technique.setValue(
            NSNumber(value: outlineColor.x), forKeyPath: "outlineRSymbol")
        technique.setValue(
            NSNumber(value: outlineColor.y), forKeyPath: "outlineGSymbol")
        technique.setValue(
            NSNumber(value: outlineColor.z), forKeyPath: "outlineBSymbol")
        technique.setValue(
            NSNumber(value: outlineColor.w), forKeyPath: "outlineASymbol")
    }
}
