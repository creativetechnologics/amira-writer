import Observation
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
@MainActor
public final class ScoreWorkspaceController: ObservableObject {
    let store = ScoreStore()
    private var loadedProjectPath: String?
    private var didStartAPIServer = false
    @Published public private(set) var isLoadingProject = false
    @Published public private(set) var loadStatusMessage = "Ready"
    @Published public private(set) var saveIndicator: SaveIndicatorState = .idle
    @Published public private(set) var activeProjectPath: String?
    @Published public private(set) var selectedScenePath: String?
    private var isAPIServerDisabled: Bool {
        ProcessInfo.processInfo.environment["NOVOTRO_DISABLE_SCORE_API_SERVER"] == "1"
    }

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
        guard let relativePath,
              let asset = store.midiAssets.first(where: { $0.relativePath == relativePath }) else {
            return false
        }
        if store.selectedMidiID != asset.id {
            store.setSelectedMidi(id: asset.id)
        }
        return true
    }

    public func ensureProjectLoaded(_ projectURL: URL) async -> String? {
        let normalizedURL = projectURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        if loadedProjectPath == normalizedPath,
           store.projectURL?.standardizedFileURL.path == normalizedPath {
            activeProjectPath = normalizedPath
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
            activeProjectPath = normalizedPath
            return nil
        }

        let message = store.statusMessage

        if let previousURL, previousURL.path != normalizedPath {
            await store.loadProject(url: previousURL, preferService: false)
            loadedProjectPath = store.projectURL?.standardizedFileURL.path
            activeProjectPath = store.projectURL?.standardizedFileURL.path
        } else if previousURL == nil {
            loadedProjectPath = nil
            activeProjectPath = nil
        }

        return message
    }

    public func currentSelectionPath() -> String? {
        store.selectedMidiAsset?.relativePath
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
public struct ScoreWorkspace: View {
    let controller: ScoreWorkspaceController


    public init(
        controller: ScoreWorkspaceController
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
