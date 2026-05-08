import AppKit
import Foundation
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct Previs3DContainerView: View {
    @Bindable var store: AnimateStore
    let sceneID: UUID
    let shotID: UUID

    @State private var activeMode: PrevisMode = .select
    @State private var activeKeyframe: PrevisKeyframeLabel = .beginning
    @State private var isGeneratingLayout: Bool = false
    @State private var layoutError: String? = nil
    @State private var cachedSceneJSON: String = ""
    @State private var cachedGLBPaths: [(slug: String, path: String)] = []

    private var scene: AnimationScene? {
        store.scenes.first(where: { $0.id == sceneID })
    }

    private var shot: AnimationSceneShot? {
        scene?.shots.first(where: { $0.id == shotID })
    }

    var body: some View {
        ZStack {
            Previs3DView(
                sceneJSON: cachedSceneJSON,
                characterGLBPaths: cachedGLBPaths,
                onCaptureResult: { label, data in
                    saveCapture(label: label, data: data)
                },
                onCaptureError: { msg in
                    store.statusMessage = "Capture error: \(msg)"
                }
            )

            VStack {
                Spacer()
                VStack(spacing: 8) {
                    if isGeneratingLayout {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Generating layout...").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    } else if let error = layoutError {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                            Text(error).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            Button("Dismiss") { layoutError = nil }
                                .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }

                    Previs3DToolbar(
                        activeMode: $activeMode,
                        activeKeyframe: $activeKeyframe,
                        onCapture: { triggerCapture() },
                        onGenerateLayout: { Task { await generateLayout() } },
                        isGeneratingLayout: isGeneratingLayout,
                        canGenerateLayout: !store.openAIAPIKey.isEmpty
                    )
                }
                .padding(.bottom, 16)
            }
        }
        .onAppear {
            refreshCache()
        }
        .onChange(of: shotID) { _, _ in
            refreshCache()
        }
    }

    private func refreshCache() {
        guard let shot = shot else {
            cachedSceneJSON = ""
            cachedGLBPaths = []
            return
        }

        if let state = shot.previs3DState,
           let data = try? JSONEncoder().encode(state) {
            cachedSceneJSON = String(data: data, encoding: .utf8) ?? ""
        } else {
            cachedSceneJSON = ""
        }

        cachedGLBPaths = resolveCharacterGLBs(shot: shot)
    }

    private func resolveCharacterGLBs(shot: AnimationSceneShot) -> [(slug: String, path: String)] {
        guard let scene = scene, let projectURL = store.owpURL else { return [] }

        var slugs: Set<String> = []
        if let focus = shot.focusCharacterSlug { slugs.insert(focus) }
        for slug in scene.characterSlugs { slugs.insert(slug) }

        var result: [(slug: String, path: String)] = []
        for slug in slugs {
            if let character = store.characters.first(where: { $0.owpSlug == slug }),
               let glb = character.models3D.first(where: { $0.modelFormat == "glb" }) {
                let dir = ProjectPaths(root: projectURL).character3DModelsDirectory(slug: slug)
                let path = dir.appendingPathComponent(glb.modelFileName).path
                if FileManager.default.fileExists(atPath: path) {
                    result.append((slug: slug, path: path))
                }
            }
        }
        return result
    }

    private func triggerCapture() {}

    private func generateLayout() async {
        guard let scene = scene, let shot = shot else { return }
        isGeneratingLayout = true
        layoutError = nil

        do {
            let service = PrevisScenePromptService(store: store)
            let layout = try await service.generateLayout(scene: scene, shot: shot)

            if let shotIndex = scene.shots.firstIndex(where: { $0.id == shot.id }) {
                var updatedScene = scene
                updatedScene.shots[shotIndex].previs3DState = layout
                if let sceneIndex = store.scenes.firstIndex(where: { $0.id == scene.id }) {
                    store.scenes[sceneIndex] = updatedScene
                }
            }

            refreshCache()
            store.statusMessage = "Layout generated"
        } catch {
            layoutError = error.localizedDescription
            store.statusMessage = "Layout generation failed"
        }

        isGeneratingLayout = false
    }

    private func saveCapture(label: String, data: Data) {
        guard let projectURL = store.owpURL,
              let sceneID = scene?.id,
              let shot = shot
        else { return }

        let paths = ProjectPaths(root: projectURL)
        let shotDir = paths.shotStoryboardDir(sceneID: sceneID, shotID: shot.id)
        let frameLabel = matchFrameLabel(label)
        let imageURL = shotDir.appendingPathComponent("\(frameLabel).jpg")

        try? FileManager.default.createDirectory(at: shotDir, withIntermediateDirectories: true)
        try? data.write(to: imageURL)

        store.statusMessage = "Captured \(label) frame"
    }

    private func matchFrameLabel(_ label: String) -> String {
        if label == "beginning" { return "beginning" }
        if label == "end" { return "end" }
        return "middle"
    }
}
