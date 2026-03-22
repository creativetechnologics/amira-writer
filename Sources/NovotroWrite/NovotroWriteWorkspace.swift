import SwiftUI

@available(macOS 26.0, *)
@MainActor
public final class NovotroWriteWorkspaceController: ObservableObject {
    let store = ScriptStore()
    private var loadedProjectPath: String?
    @Published public private(set) var isLoadingProject = false
    @Published public private(set) var loadStatusMessage = "Ready"

    public init() {}

    public func ensureProjectLoaded(_ projectURL: URL) async -> String? {
        let normalizedURL = projectURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        if loadedProjectPath == normalizedPath,
           store.projectURL?.standardizedFileURL.path == normalizedPath,
           store.presentedLoadError == nil {
            return nil
        }

        isLoadingProject = true
        loadStatusMessage = "Loading Write workspace from disk…"
        let previousURL = store.projectURL?.standardizedFileURL
        await Task.yield()
        await store.loadProject(url: normalizedURL, preferService: false)
        loadStatusMessage = store.statusMessage
        defer { isLoadingProject = false }

        if store.projectURL?.standardizedFileURL.path == normalizedPath,
           store.presentedLoadError == nil {
            loadedProjectPath = normalizedPath
            return nil
        }

        let message = store.presentedLoadError ?? store.statusMessage

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
public struct NovotroWriteWorkspace: View {
    let controller: NovotroWriteWorkspaceController

    public init(
        controller: NovotroWriteWorkspaceController
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
