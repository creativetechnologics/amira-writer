import Observation
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
@MainActor
public final class MixWorkspaceController: ObservableObject {
    let store = MixStore()
    private var loadedProjectPath: String?
    private var loadRequestID: UInt64 = 0
    @Published public private(set) var isLoadingProject = false
    @Published public private(set) var loadStatusMessage = "Ready"
    @Published public private(set) var saveIndicator: SaveIndicatorState = .idle
    @Published public private(set) var activeProjectPath: String?
    @Published public private(set) var selectedScenePath: String?
    @Published public private(set) var isSelectionRestorePending = false

    public init() {
        activeProjectPath = store.projectURL?.standardizedFileURL.path
        selectedScenePath = currentSelectionPath()
        saveIndicator = store.saveIndicator
        observeSaveIndicator()
        observeSelectionPath()
    }

    public var isDirty: Bool { store.saveIndicator == .unsavedChanges }

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
              let scene = store.scenes.first(where: { $0.relativePath == relativePath }) else {
            return false
        }
        if store.selectedSceneID != scene.id {
            store.selectScene(scene.id)
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

        loadRequestID &+= 1
        let requestID = loadRequestID
        isLoadingProject = true
        loadStatusMessage = "Loading Mix workspace from disk..."
        await Task.yield()
        let message = await store.ensureProjectLoaded(normalizedURL)
        guard requestID == loadRequestID else { return message }
        loadStatusMessage = store.statusMessage
        isLoadingProject = false

        if message == nil {
            loadedProjectPath = normalizedPath
            activeProjectPath = normalizedPath
        }
        return message
    }

    public func currentSelectionPath() -> String? {
        store.selectedScene?.relativePath
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
public struct MixWorkspace: View {
    @ObservedObject private var controller: MixWorkspaceController

    public init(controller: MixWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            MixWorkspaceContentView(
                store: controller.store,
                appName: "Amira Writer",
                isLoadingProject: controller.isLoadingProject,
                loadStatusMessage: controller.loadStatusMessage,
                isInteractionLocked: controller.isSelectionRestorePending
            )
            .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                MixWorkspaceLoadOverlay(
                    title: controller.store.projectURL == nil ? "Opening Mix" : "Refreshing Mix",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

@available(macOS 26.0, *)
private struct MixWorkspaceLoadOverlay: View {
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
