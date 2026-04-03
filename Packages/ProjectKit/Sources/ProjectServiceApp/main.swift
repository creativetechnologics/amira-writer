import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ProjectKit

@main
struct ProjectServiceApp: App {
    @StateObject private var controller = ProjectServiceController()

    var body: some Scene {
        MenuBarExtra(
            "Project Service",
            systemImage: controller.isRunning ? "server.rack" : "server.rack.badge.xmark"
        ) {
            ServiceMenuView(controller: controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            EmptyView()
        }
    }
}

@MainActor
private final class ProjectServiceController: ObservableObject {
    @Published var isRunning = false
    @Published var isExternallyManaged = false
    @Published var port: UInt16 = ProjectServiceConfiguration.defaultPort
    @Published var connectionCount = 0
    @Published var projects: [ProjectServerRegistration] = []
    @Published var lastErrorMessage: String?

    let serverRootURL: URL

    private let registry: ProjectServerRegistry
    private let relay = ProjectServiceRelay()
    private var host: ProjectServiceHost?

    init(registry: ProjectServerRegistry = ProjectServerRegistry()) {
        self.registry = registry
        self.serverRootURL = registry.rootURL
        bootstrap()
    }

    var endpointDescription: String {
        "\(ProcessInfo.processInfo.hostName):\(port)"
    }

    var statusDescription: String {
        if isRunning, isExternallyManaged {
            return "Running (Background Service)"
        }
        return isRunning ? "Running" : "Stopped"
    }

    var primaryButtonTitle: String {
        if isExternallyManaged {
            return "Refresh Status"
        }
        return isRunning ? "Stop Server" : "Start Server"
    }

    func toggleServer() {
        if isExternallyManaged {
            Task { await attachToExistingServiceIfAvailable() }
            return
        }

        if isRunning {
            stopServer()
        } else {
            Task { await startServer() }
        }
    }

    func addProject() {
        let panel = NSOpenPanel()
        panel.title = "Add Project to Project Service"
        panel.message = "Choose a .owp project package to copy into the managed server folder."
        panel.prompt = "Add Project"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        if let projectType = UTType(filenameExtension: "owp") {
            panel.allowedContentTypes = [projectType]
        }

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return
        }

        guard selectedURL.pathExtension.lowercased() == "owp" else {
            showError("Project Service can only import .owp project packages.")
            return
        }

        do {
            _ = try registry.addProject(from: selectedURL)
            reloadProjects()
            lastErrorMessage = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func removeProject(_ project: ProjectServerRegistration) {
        guard relay.confirmRemoval(project.displayName) else {
            return
        }

        do {
            try registry.removeProject(id: project.id)
            reloadProjects()
            lastErrorMessage = nil
        } catch {
            showError(error.localizedDescription)
        }
    }

    func revealProject(_ project: ProjectServerRegistration) {
        relay.reveal(project.managedProjectURL)
    }

    func revealServerFolder() {
        relay.reveal(serverRootURL)
    }

    func copyEndpoint() {
        relay.copy(endpointDescription)
    }

    func copyManagedPath(_ project: ProjectServerRegistration) {
        relay.copy(project.managedProjectURL.path)
    }

    func reloadProjects() {
        do {
            try registry.ensureStorageDirectories()
            projects = try registry.listProjects()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func bootstrap() {
        reloadProjects()
        Task { await startServer() }
    }

    private func startServer() async {
        guard host == nil else { return }

        if await attachToExistingServiceIfAvailable() {
            return
        }

        do {
            let host = try ProjectServiceHost()
            host.stateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.isExternallyManaged = false
                        self.isRunning = true
                        self.port = self.host?.port ?? self.port
                        self.lastErrorMessage = nil
                    case let .failed(error):
                        self.isRunning = false
                        self.lastErrorMessage = error.localizedDescription
                    case .cancelled:
                        self.isRunning = false
                    default:
                        break
                    }
                }
            }
            host.connectionCountHandler = { [weak self] count in
                DispatchQueue.main.async {
                    self?.connectionCount = count
                }
            }
            self.host = host
            host.start()
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func stopServer() {
        host?.stop()
        host = nil
        isExternallyManaged = false
        isRunning = false
        connectionCount = 0
    }

    private func showError(_ message: String) {
        lastErrorMessage = message
        relay.presentError(message)
    }

    @discardableResult
    private func attachToExistingServiceIfAvailable() async -> Bool {
        do {
            let client = try await ProjectServerClient.discover()
            let remoteProjects = try await client.listProjects()
            projects = remoteProjects
            isExternallyManaged = true
            isRunning = true
            connectionCount = 0
            lastErrorMessage = nil
            return true
        } catch {
            return false
        }
    }
}

private struct ServiceMenuView: View {
    @ObservedObject var controller: ProjectServiceController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Project Service")
                    .font(.headline)
                Text(controller.statusDescription)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(controller.isRunning ? .green : .secondary)
                Text("Endpoint: \(controller.endpointDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(controller.connectionCount) connected clients")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(controller.projects.count) managed projects")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button(controller.primaryButtonTitle) {
                        controller.toggleServer()
                    }
                    Button("Add Project…") {
                        controller.addProject()
                    }
                }

                HStack(spacing: 8) {
                    Button("Reload Projects") {
                        controller.reloadProjects()
                    }
                    Button("Reveal Server Folder") {
                        controller.revealServerFolder()
                    }
                }

                HStack(spacing: 8) {
                    Button("Copy Endpoint") {
                        controller.copyEndpoint()
                    }
                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Managed Projects")
                    .font(.subheadline.weight(.semibold))
                Text(controller.serverRootURL.path)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }

            if controller.projects.isEmpty {
                Text("No projects have been added to this server yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(controller.projects) { project in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(project.displayName)
                                    .font(.subheadline.weight(.medium))
                                Text(project.managedProjectURL.path)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                HStack(spacing: 8) {
                                    Button("Reveal") {
                                        controller.revealProject(project)
                                    }
                                    Button("Copy Path") {
                                        controller.copyManagedPath(project)
                                    }
                                    Button("Remove") {
                                        controller.removeProject(project)
                                    }
                                    .tint(.red)
                                }
                                .buttonStyle(.bordered)
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            if let message = controller.lastErrorMessage, !message.isEmpty {
                Divider()
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if controller.isExternallyManaged {
                Divider()
                Text("This menu bar app is attached to the background Project Service already running on this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}

@MainActor
private final class ProjectServiceRelay {
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    func confirmRemoval(_ displayName: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove \(displayName) from Project Service?"
        alert.informativeText = "This only removes the managed project from the server registry. It does not delete the project package."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Project Service"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
