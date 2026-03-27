import Observation
import SwiftUI
import NovotroProjectKit

@available(macOS 26.0, *)
@MainActor
public final class NovotroAnimateWorkspaceController: ObservableObject {
    let store = AnimateStore()
    private var loadedProjectPath: String?
    private var loadRequestID: UInt64 = 0
    @Published public private(set) var isLoadingProject = false
    @Published public private(set) var loadStatusMessage = "Ready"
    @Published public private(set) var saveIndicator: SaveIndicatorState = .idle
    @Published public private(set) var activeProjectPath: String?
    @Published public private(set) var selectedScenePath: String?
    @Published public private(set) var isSelectionRestorePending = false

    public init() {
        store.disableExternalFileWatch = true
        activeProjectPath = store.owpURL?.standardizedFileURL.path
        selectedScenePath = currentSelectionPath()
        saveIndicator = store.saveIndicator
        observeSaveIndicator()
        observeSelectionPath()
    }

    public func suspendBackgroundWork() {
        store.suspendBackgroundWork()
    }

    public func save() {
        store.save()
    }

    public func setSelectionRestorePending(_ isPending: Bool) {
        isSelectionRestorePending = isPending
    }

    @discardableResult
    public func applySelectionPath(_ relativePath: String?) -> Bool {
        guard let relativePath,
              let scene = store.scenes.first(where: { $0.owpSongPath == relativePath }) else {
            return false
        }
        if store.selectedSceneID != scene.id {
            store.selectedSceneID = scene.id
        }
        return true
    }

    public func ensureProjectLoaded(_ projectURL: URL) async -> String? {
        let normalizedURL = projectURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        loadRequestID &+= 1
        let requestID = loadRequestID
        if loadedProjectPath == normalizedPath,
           store.owpURL?.standardizedFileURL.path == normalizedPath,
           !store.isLoadingProject,
           store.loadErrorMessage == nil {
            activeProjectPath = normalizedPath
            store.resumeBackgroundWork()
            return nil
        }

        isLoadingProject = true
        loadStatusMessage = "Loading Animate workspace from disk…"
        defer {
            if requestID == loadRequestID {
                isLoadingProject = false
            }
        }

        if store.isLoadingProject,
           store.owpURL?.standardizedFileURL.path != normalizedPath {
            while store.isLoadingProject {
                guard requestID == loadRequestID else { return nil }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        await Task.yield()
        guard requestID == loadRequestID else { return nil }
        await store.openOWP(url: normalizedURL, preferService: false)
        while store.isLoadingProject {
            guard requestID == loadRequestID else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard requestID == loadRequestID else { return nil }
        loadStatusMessage = store.statusMessage

        if store.owpURL?.standardizedFileURL.path == normalizedPath,
           !store.isLoadingProject,
           store.loadErrorMessage == nil {
            loadedProjectPath = normalizedPath
            activeProjectPath = normalizedPath
            return nil
        }

        let message = store.loadErrorMessage ?? store.statusMessage
        loadedProjectPath = store.owpURL?.standardizedFileURL.path
        activeProjectPath = store.owpURL?.standardizedFileURL.path

        return message
    }

    public func currentSelectionPath() -> String? {
        store.selectedScene?.owpSongPath
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
public struct NovotroAnimateWorkspace: View {
    @ObservedObject private var controller: NovotroAnimateWorkspaceController

    public init(
        controller: NovotroAnimateWorkspaceController
    ) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            ContentView(
                store: controller.store,
                appName: "Amira Writer"
            )
            .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Animate" : "Refreshing Animate",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

@available(macOS 26.0, *)
private struct AnimateWorkspaceLoadOverlay: View {
    let title: String
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.14)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OperaChromeTheme.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(OperaChromeTheme.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
        }
    }
}
