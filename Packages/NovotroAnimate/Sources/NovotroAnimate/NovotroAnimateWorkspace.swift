import SwiftUI
import NovotroProjectKit

@available(macOS 26.0, *)
@MainActor
public final class NovotroAnimateWorkspaceController: ObservableObject {
    let store = AnimateStore()
    private var loadedProjectPath: String?
    @Published public private(set) var isLoadingProject = false
    @Published public private(set) var loadStatusMessage = "Ready"

    public var saveIndicator: SaveIndicatorState { store.saveIndicator }

    public init() {
        store.disableExternalFileWatch = true
    }

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
           store.owpURL?.standardizedFileURL.path == normalizedPath,
           store.loadErrorMessage == nil {
            store.resumeBackgroundWork()
            return nil
        }

        isLoadingProject = true
        loadStatusMessage = "Loading Animate workspace from disk…"
        let previousURL = store.owpURL?.standardizedFileURL
        await Task.yield()
        await store.openOWP(url: normalizedURL, preferService: false)
        loadStatusMessage = store.statusMessage
        defer { isLoadingProject = false }

        if store.owpURL?.standardizedFileURL.path == normalizedPath,
           store.loadErrorMessage == nil {
            loadedProjectPath = normalizedPath
            return nil
        }

        let message = store.loadErrorMessage ?? store.statusMessage

        if let previousURL, previousURL.path != normalizedPath {
            await store.openOWP(url: previousURL, preferService: false)
            loadedProjectPath = store.owpURL?.standardizedFileURL.path
        } else if previousURL == nil {
            loadedProjectPath = nil
        }

        return message
    }
}

@available(macOS 26.0, *)
public struct NovotroAnimateWorkspace: View {
    let controller: NovotroAnimateWorkspaceController

    public init(
        controller: NovotroAnimateWorkspaceController
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
