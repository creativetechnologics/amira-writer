import SwiftUI
import SceneKit
import ModelIO
import AppKit

// MARK: - Render Mode

@available(macOS 26.0, *)
enum ModelRenderMode: String, CaseIterable {
    case wireframe = "Wireframe"
    case textured  = "Textured"
    case celShaded = "Cel-Shaded"
}

// MARK: - Model Stats

@available(macOS 26.0, *)
struct ModelStats {
    var polyCount:    Int = 0
    var vertexCount:  Int = 0
    var textureCount: Int = 0
}

// MARK: - SCNView wrapper

@available(macOS 26.0, *)
private struct SceneKitView: NSViewRepresentable {
    let scene: SCNScene
    let renderMode: ModelRenderMode
    let isFullscreen: Bool

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl   = true
        view.autoenablesDefaultLighting = false
        view.backgroundColor = NSColor(white: 0.12, alpha: 1.0)
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if view.scene !== scene {
            view.scene = scene
        }
        applyRenderMode(to: view)
    }

    private func applyRenderMode(to view: SCNView) {
        guard let scene = view.scene else { return }

        switch renderMode {
        case .wireframe:
            view.debugOptions = [.renderAsWireframe]
            scene.rootNode.enumerateChildNodes { node, _ in
                node.geometry?.materials.forEach { mat in
                    mat.fillMode = .lines
                }
            }

        case .textured:
            view.debugOptions = []
            scene.rootNode.enumerateChildNodes { node, _ in
                node.geometry?.materials.forEach { mat in
                    mat.fillMode = .fill
                    mat.lightingModel = .physicallyBased
                }
            }

        case .celShaded:
            view.debugOptions = []
            scene.rootNode.enumerateChildNodes { node, _ in
                node.geometry?.materials.forEach { mat in
                    mat.fillMode = .fill
                    mat.lightingModel = .blinn
                    // Cel effect: reduce diffuse, no specular shininess
                    mat.specular.contents  = NSColor.black
                    mat.shininess          = 0
                    mat.fresnelExponent    = 0
                }
            }
        }
    }
}

// MARK: - Character3DModelViewer

@available(macOS 26.0, *)
struct Character3DModelViewer: View {
    let modelURL: URL

    @State private var scene: SCNScene?
    @State private var loadError: String?
    @State private var isLoading: Bool = true
    @State private var renderMode: ModelRenderMode = .textured
    @State private var stats: ModelStats = ModelStats()
    @State private var isFullscreen: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                // Render mode picker
                Picker("Render Mode", selection: $renderMode) {
                    ForEach(ModelRenderMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)

                Spacer()

                // Stats
                if !isLoading && loadError == nil {
                    HStack(spacing: 12) {
                        statLabel(icon: "triangle.fill",     value: stats.polyCount,    label: "polys")
                        statLabel(icon: "point.3.filled.connected.trianglepath.dotted", value: stats.vertexCount,  label: "verts")
                        statLabel(icon: "photo.fill",        value: stats.textureCount, label: "tex")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                // Fullscreen toggle
                Button {
                    isFullscreen.toggle()
                } label: {
                    Image(systemName: isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(isFullscreen ? "Exit fullscreen" : "Fullscreen")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor(white: 0.10, alpha: 1.0)))

            // 3D view
            ZStack {
                Color(NSColor(white: 0.12, alpha: 1.0))

                if isLoading {
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(.white)
                } else if let error = loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if let scene {
                    SceneKitView(scene: scene, renderMode: renderMode, isFullscreen: isFullscreen)
                }
            }
            .frame(height: isFullscreen ? 600 : 320)
            .clipShape(RoundedRectangle(cornerRadius: 0, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .task(id: modelURL) {
            await loadModel(from: modelURL)
        }
    }

    // MARK: - Private helpers

    @ViewBuilder
    private func statLabel(icon: String, value: Int, label: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text("\(value) \(label)")
        }
    }

    private func loadModel(from url: URL) async {
        isLoading  = true
        loadError  = nil
        scene      = nil

        let ext = url.pathExtension.lowercased()

        do {
            let loadedScene: SCNScene

            switch ext {
            case "usdz", "scn":
                loadedScene = try SCNScene(url: url, options: nil)

            case "glb", "obj", "fbx", "dae":
                let asset = MDLAsset(url: url)
                asset.loadTextures()
                loadedScene = try SCNScene(mdlAsset: asset)

            default:
                // Try SCNScene first, fall back to MDLAsset
                if let s = try? SCNScene(url: url, options: nil) {
                    loadedScene = s
                } else {
                    let asset = MDLAsset(url: url)
                    asset.loadTextures()
                    loadedScene = try SCNScene(mdlAsset: asset)
                }
            }

            addThreePointLighting(to: loadedScene)
            let computedStats = computeStats(for: loadedScene)

            await MainActor.run {
                self.scene   = loadedScene
                self.stats   = computedStats
                self.isLoading = false
            }

        } catch {
            await MainActor.run {
                self.loadError  = error.localizedDescription
                self.isLoading  = false
            }
        }
    }

    private func addThreePointLighting(to scene: SCNScene) {
        // Key light
        let keyNode  = SCNNode()
        keyNode.light = SCNLight()
        keyNode.light!.type      = .directional
        keyNode.light!.intensity = 1200
        keyNode.light!.color     = NSColor(white: 1.0, alpha: 1.0)
        keyNode.position         = SCNVector3(5, 8, 5)
        keyNode.eulerAngles      = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(keyNode)

        // Fill light (softer, from opposite side)
        let fillNode  = SCNNode()
        fillNode.light = SCNLight()
        fillNode.light!.type      = .directional
        fillNode.light!.intensity = 500
        fillNode.light!.color     = NSColor(red: 0.8, green: 0.85, blue: 1.0, alpha: 1.0)
        fillNode.position         = SCNVector3(-5, 4, 3)
        fillNode.eulerAngles      = SCNVector3(-Float.pi / 6, -Float.pi / 4, 0)
        scene.rootNode.addChildNode(fillNode)

        // Rim light (backlight)
        let rimNode  = SCNNode()
        rimNode.light = SCNLight()
        rimNode.light!.type      = .directional
        rimNode.light!.intensity = 700
        rimNode.light!.color     = NSColor(red: 1.0, green: 0.95, blue: 0.8, alpha: 1.0)
        rimNode.position         = SCNVector3(0, 3, -8)
        rimNode.eulerAngles      = SCNVector3(Float.pi / 6, Float.pi, 0)
        scene.rootNode.addChildNode(rimNode)

        // Ambient fill
        let ambNode  = SCNNode()
        ambNode.light = SCNLight()
        ambNode.light!.type      = .ambient
        ambNode.light!.intensity = 200
        ambNode.light!.color     = NSColor(white: 0.4, alpha: 1.0)
        scene.rootNode.addChildNode(ambNode)
    }

    private func computeStats(for scene: SCNScene) -> ModelStats {
        var polys    = 0
        var verts    = 0
        var textures = 0

        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }

            for source in geometry.sources {
                if source.semantic == .vertex {
                    verts += source.vectorCount
                }
            }

            for element in geometry.elements {
                switch element.primitiveType {
                case .triangles:
                    polys += element.primitiveCount
                case .triangleStrip:
                    polys += max(0, element.primitiveCount - 2)
                default:
                    polys += element.primitiveCount
                }
            }

            for material in geometry.materials {
                let props: [SCNMaterialProperty] = [
                    material.diffuse,
                    material.normal,
                    material.roughness,
                    material.metalness,
                    material.emission
                ]
                for prop in props {
                    // CGImage is a CF bridged type — check via NSImage and URL-backed textures
                    if prop.contents is NSImage
                        || prop.contents is NSURL
                        || prop.contents is String {
                        textures += 1
                    }
                }
            }
        }

        return ModelStats(polyCount: polys, vertexCount: verts, textureCount: textures)
    }
}
