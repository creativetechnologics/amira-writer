import SwiftUI
import NovotroProjectKit

@available(macOS 26.0, *)
@MainActor
public final class NovotroScoreWorkspaceController: ObservableObject {
    let store = ScoreStore()
    private var loadedProjectPath: String?
    private var didStartAPIServer = false
    @Published public private(set) var isLoadingProject = false
    @Published public private(set) var loadStatusMessage = "Ready"

    public var saveIndicator: SaveIndicatorState { store.saveIndicator }
    private var isAPIServerDisabled: Bool {
        ProcessInfo.processInfo.environment["NOVOTRO_DISABLE_SCORE_API_SERVER"] == "1"
    }

    public init() {}

    public func suspendBackgroundWork() {
        store.suspendBackgroundWork()
    }

    public func save() {
        store.save()
    }

    public func ensureProjectLoaded(_ projectURL: URL) async -> String? {
        let normalizedURL = projectURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        if loadedProjectPath == normalizedPath,
           store.projectURL?.standardizedFileURL.path == normalizedPath {
            store.resumeBackgroundWork()
            return nil
        }

        isLoadingProject = true
        loadStatusMessage = "Loading Score workspace from disk…"
        let previousURL = store.projectURL?.standardizedFileURL
        await Task.yield()
        await store.loadProject(url: normalizedURL, preferService: false)
        if !didStartAPIServer, !isAPIServerDisabled {
            store.startAPIServer()
            didStartAPIServer = true
        }
        loadStatusMessage = store.statusMessage
        defer { isLoadingProject = false }

        if store.projectURL?.standardizedFileURL.path == normalizedPath {
            loadedProjectPath = normalizedPath
            return nil
        }

        let message = store.statusMessage

        if let previousURL, previousURL.path != normalizedPath {
            await store.loadProject(url: previousURL, preferService: false)
            loadedProjectPath = store.projectURL?.standardizedFileURL.path
        } else if previousURL == nil {
            loadedProjectPath = nil
        }

        return message
    }
}

@available(macOS 26.0, *)
public struct NovotroScoreWorkspace: View {
    let controller: NovotroScoreWorkspaceController


    public init(
        controller: NovotroScoreWorkspaceController
    ) {
        self.controller = controller
    }

    public var body: some View {
        ContentView(
            store: controller.store,
            appName: "Novotro Opera"
        )
    }
}
