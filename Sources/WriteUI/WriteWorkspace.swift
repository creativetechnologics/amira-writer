import Observation
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
@MainActor
public final class WriteWorkspaceController: ObservableObject {
    let store = ScriptStore()
    private var loadedProjectPath: String?
    @Published public private(set) var isLoadingProject = false
    @Published public private(set) var loadStatusMessage = "Ready"
    @Published public private(set) var saveIndicator: SaveIndicatorState = .idle
    @Published public private(set) var activeProjectPath: String?
    @Published public private(set) var selectedScenePath: String?

    public init() {
        activeProjectPath = store.projectURL?.standardizedFileURL.path
        selectedScenePath = currentSelectionPath()
        saveIndicator = store.saveIndicator
        observeSaveIndicator()
        observeSelectionPath()
    }

    public var isDirty: Bool { store.isDirty }

    public func suspendBackgroundWork() {
        store.suspendBackgroundWork()
    }

    public func save() {
        store.save()
    }

    @discardableResult
    public func applySelectionPath(_ relativePath: String?) -> Bool {
        guard let relativePath else { return false }
        return store.selectScene(relativePath: relativePath)
    }

    public func ensureProjectLoaded(_ projectURL: URL) async -> String? {
        let normalizedURL = projectURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        if loadedProjectPath == normalizedPath,
           store.projectURL?.standardizedFileURL.path == normalizedPath,
           store.presentedLoadError == nil {
            activeProjectPath = normalizedPath
            store.resumeBackgroundWork()
            return nil
        }

        isLoadingProject = true
        loadStatusMessage = "Loading Write workspace from disk…"
        let previousURL = store.projectURL?.standardizedFileURL
        await Task.yield()
        await store.loadProject(url: normalizedURL)
        loadStatusMessage = store.statusMessage
        defer { isLoadingProject = false }

        if store.projectURL?.standardizedFileURL.path == normalizedPath,
           store.presentedLoadError == nil {
            loadedProjectPath = normalizedPath
            activeProjectPath = normalizedPath
            return nil
        }

        let message = store.presentedLoadError ?? store.statusMessage

        if let previousURL, previousURL.path != normalizedPath {
            await store.loadProject(url: previousURL)
            loadedProjectPath = store.projectURL?.standardizedFileURL.path
            activeProjectPath = store.projectURL?.standardizedFileURL.path
        } else if previousURL == nil {
            loadedProjectPath = nil
            activeProjectPath = nil
        }

        return message
    }

    public func currentSelectionPath() -> String? {
        store.scrollTarget ?? store.activeSongPath
    }

    private func observeSaveIndicator() {
        withObservationTracking {
            _ = store.saveIndicator
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.saveIndicator = self.store.saveIndicator
                self.observeSaveIndicator()
            }
        }

        saveIndicator = store.saveIndicator
    }

    private func observeSelectionPath() {
        withObservationTracking {
            _ = currentSelectionPath()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selectedScenePath = self.currentSelectionPath()
                self.observeSelectionPath()
            }
        }

        selectedScenePath = currentSelectionPath()
    }
}

@available(macOS 26.0, *)
public struct WriteWorkspace: View {
    let controller: WriteWorkspaceController

    public init(
        controller: WriteWorkspaceController
    ) {
        self.controller = controller
    }

    public var body: some View {
        ContentView(
            store: controller.store,
            appName: "Amira Writer"
        )
    }
}
