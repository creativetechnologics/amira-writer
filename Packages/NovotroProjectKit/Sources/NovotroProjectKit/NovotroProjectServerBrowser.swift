#if canImport(SwiftUI)
import Foundation
import SwiftUI

@MainActor
public final class NovotroProjectServerBrowserModel: ObservableObject {
    @Published public private(set) var projects: [NPProjectServerRegistration] = []
    @Published public var selectedProjectID: UUID?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isMutating = false
    @Published public private(set) var isOpeningProject = false
    @Published public private(set) var openingProjectID: UUID?
    @Published public private(set) var hasLoaded = false
    @Published public var errorMessage: String?
    @Published public var statusMessage: String?

    private let userDefaults: UserDefaults
    private let lastOpenedProjectKey: String
    private let fileManager: FileManager

    public init(
        lastOpenedProjectKey: String,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.lastOpenedProjectKey = lastOpenedProjectKey
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        if let storedID = userDefaults.string(forKey: lastOpenedProjectKey),
           let parsedID = UUID(uuidString: storedID) {
            selectedProjectID = parsedID
        }
    }

    public var selectedProject: NPProjectServerRegistration? {
        guard let selectedProjectID else { return nil }
        return projects.first(where: { $0.id == selectedProjectID })
    }

    public var hasRememberedSelection: Bool {
        userDefaults.string(forKey: lastOpenedProjectKey) != nil
    }

    public func ensureLoaded() async {
        guard !isLoading else { return }
        guard !hasLoaded || projects.isEmpty || errorMessage != nil else { return }
        await refresh()
    }

    public func refresh(selectStoredSelection: Bool = true) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        statusMessage = "Connecting to Novotro Project Server…"
        defer { isLoading = false }

        do {
            let client = try await NovotroProjectServerClient.discover()
            let loadedProjects = try await NovotroProjectAsyncTimeout.withTimeout(
                seconds: 6,
                description: "loading the project list"
            ) {
                try await client.listProjects()
            }
            projects = loadedProjects

            if selectStoredSelection,
               let storedID = userDefaults.string(forKey: lastOpenedProjectKey).flatMap(UUID.init(uuidString:)),
               loadedProjects.contains(where: { $0.id == storedID }) {
                selectedProjectID = storedID
            } else if let selectedProjectID,
                      loadedProjects.contains(where: { $0.id == selectedProjectID }) {
                self.selectedProjectID = selectedProjectID
            } else {
                selectedProjectID = loadedProjects.first?.id
            }

            errorMessage = nil
            hasLoaded = true
            statusMessage = loadedProjects.isEmpty
                ? "No projects are on Novotro Project Server yet."
                : "Loaded \(loadedProjects.count) server project\(loadedProjects.count == 1 ? "" : "s")."
        } catch {
            hasLoaded = false
            errorMessage = error.localizedDescription
            statusMessage = "Unable to reach Novotro Project Server."
        }
    }

    @discardableResult
    public func createProject(named displayName: String) async -> NPProjectServerRegistration? {
        await mutate(
            progressMessage: "Creating \(displayName)…"
        ) {
            let client = try await NovotroProjectServerClient.discover()
            let created = try await client.createProject(named: displayName)
            let loadedProjects = try await client.listProjects()
            self.projects = loadedProjects
            self.selectedProjectID = created.id
            self.noteOpenedProject(created)
            self.statusMessage = "Created \(created.displayName)."
            return created
        }
    }

    @discardableResult
    public func renameSelectedProject(to displayName: String) async -> NPProjectServerRegistration? {
        guard let selectedProject else { return nil }
        return await mutate(
            progressMessage: "Renaming \(selectedProject.displayName)…"
        ) {
            let client = try await NovotroProjectServerClient.discover()
            let renamed = try await client.renameProject(id: selectedProject.id, to: displayName)
            let loadedProjects = try await client.listProjects()
            self.projects = loadedProjects
            self.selectedProjectID = renamed.id
            self.noteOpenedProject(renamed)
            self.statusMessage = "Renamed project to \(renamed.displayName)."
            return renamed
        }
    }

    public func removeSelectedProject(deleteManagedProject: Bool = true) async {
        guard let selectedProject else { return }
        _ = await mutate(
            progressMessage: "Removing \(selectedProject.displayName)…"
        ) { () -> Bool in
            let client = try await NovotroProjectServerClient.discover()
            try await client.removeProject(id: selectedProject.id, deleteManagedProject: deleteManagedProject)
            let loadedProjects = try await client.listProjects()
            self.projects = loadedProjects
            if self.userDefaults.string(forKey: self.lastOpenedProjectKey) == selectedProject.id.uuidString {
                self.userDefaults.removeObject(forKey: self.lastOpenedProjectKey)
            }
            self.selectedProjectID = loadedProjects.first?.id
            self.statusMessage = "Removed \(selectedProject.displayName) from Novotro Project Server."
            return true
        }
    }

    public func noteOpenedProject(_ project: NPProjectServerRegistration) {
        selectedProjectID = project.id
        userDefaults.set(project.id.uuidString, forKey: lastOpenedProjectKey)
    }

    public func preferredOpenURL(for project: NPProjectServerRegistration) -> URL {
        Self.preferredOpenURL(for: project, fileManager: fileManager)
    }

    public func preferredOpenURLForSelection() -> URL? {
        selectedProject.map(preferredOpenURL(for:))
    }

    public func beginOpeningProject(_ project: NPProjectServerRegistration, in appName: String) -> Bool {
        guard !isOpeningProject else { return false }
        isOpeningProject = true
        openingProjectID = project.id
        statusMessage = "Opening \(project.displayName) in \(appName)…"
        noteOpenedProject(project)
        errorMessage = nil
        return true
    }

    public func finishOpeningProject(statusMessage: String? = nil) {
        isOpeningProject = false
        openingProjectID = nil
        if let statusMessage {
            self.statusMessage = statusMessage
        }
    }

    public static func preferredOpenURL(
        for project: NPProjectServerRegistration,
        fileManager: FileManager = .default
    ) -> URL {
        var candidates: [URL] = []

        if let sourceProjectURL = project.sourceProjectURL {
            candidates.append(sourceProjectURL.resolvingSymlinksInPath().standardizedFileURL)
        }

        for alias in project.pathAliases {
            if let aliasURL = url(forAliasSignature: alias) {
                candidates.append(aliasURL)
            }
        }

        candidates.append(project.managedProjectURL.resolvingSymlinksInPath().standardizedFileURL)

        for candidate in candidates {
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return candidates.first ?? project.managedProjectURL
    }

    private func mutate<T>(
        progressMessage: String,
        operation: @escaping @MainActor () async throws -> T
    ) async -> T? {
        guard !isMutating else { return nil }
        isMutating = true
        statusMessage = progressMessage
        defer { isMutating = false }

        do {
            let result = try await operation()
            errorMessage = nil
            return result
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private static func url(forAliasSignature signature: String) -> URL? {
        if signature.hasPrefix("Programming/") {
            return URL(fileURLWithPath: "/Volumes").appendingPathComponent(signature)
        }

        if signature.hasPrefix("Documents/") {
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(signature)
        }

        return nil
    }
}

@available(macOS 26.0, *)
public struct NovotroProjectServerBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var model: NovotroProjectServerBrowserModel
    @StateObject private var progressCenter = NovotroProjectOpenProgressCenter.shared

    private let appName: String
    private let onOpenProject: @MainActor (URL) async -> Void

    @State private var activePrompt: ProjectNamePrompt?
    @State private var draftProjectName = ""
    public init(
        model: NovotroProjectServerBrowserModel,
        appName: String,
        onOpenProject: @escaping @MainActor (URL) async -> Void
    ) {
        self.model = model
        self.appName = appName
        self.onOpenProject = onOpenProject
    }

    public var body: some View {
        ZStack {
            OperaChromeTheme.workspaceBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                header
                projectGrid
                footer
            }
            .padding(28)
        }
        .task {
            await model.refresh()
        }
        .sheet(item: $activePrompt) { prompt in
            ProjectNamePromptView(
                title: prompt.title,
                actionTitle: prompt.actionTitle,
                initialValue: prompt.initialValue
            ) { submittedName in
                Task {
                    switch prompt.mode {
                    case .create:
                        _ = await model.createProject(named: submittedName)
                    case .rename:
                        _ = await model.renameSelectedProject(to: submittedName)
                    }
                }
            }
        }
        .alert("Project Server", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    model.errorMessage = nil
                }
            }
        )) {
            Button("OK") {
                model.errorMessage = nil
            }
        } message: {
            Text(model.errorMessage ?? "Something went wrong.")
        }
        .frame(
            minWidth: 1080,
            idealWidth: 1220,
            maxWidth: 1380,
            minHeight: 720,
            idealHeight: 820
        )
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Text(appName)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("Open server-backed projects here. Creation and rename stay available locally, while destructive removal now stays on the server side.")
                    .font(.system(size: 14, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.72))
                HStack(spacing: 10) {
                    statusPill(text: "\(model.projects.count) project\(model.projects.count == 1 ? "" : "s")", tint: .orange)
                    if model.isLoading || model.isMutating || model.isOpeningProject {
                        statusPill(text: "Syncing", tint: .blue)
                    }
                }
            }

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
            }
            .buttonStyle(.plain)
            .help("Close project browser")
        }
    }

    private var projectGrid: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                actionRow
                listPanel
            }
            .frame(minWidth: 460, idealWidth: 520, maxWidth: 580)

            detailsPanel
                .frame(minWidth: 360, idealWidth: 430, maxWidth: .infinity)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                draftProjectName = ""
                activePrompt = ProjectNamePrompt(
                    mode: .create,
                    title: "Create Server Project",
                    actionTitle: "Create",
                    initialValue: ""
                )
            } label: {
                Label("New Project", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.isLoading || model.isMutating || model.isOpeningProject)

            Button {
                guard let selectedProject = model.selectedProject else { return }
                activePrompt = ProjectNamePrompt(
                    mode: .rename,
                    title: "Rename Project",
                    actionTitle: "Rename",
                    initialValue: selectedProject.displayName
                )
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .disabled(model.selectedProject == nil || model.isLoading || model.isMutating || model.isOpeningProject)

            Spacer()

            Button {
                Task {
                    await model.refresh(selectStoredSelection: false)
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .help("Refresh projects from Novotro Project Server")
            .disabled(model.isLoading || model.isMutating || model.isOpeningProject)
        }
    }

    private var listPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

            if model.projects.isEmpty, !model.isLoading {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .font(.system(size: 32))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text("No Server Projects Yet")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                    Text("Create a new server project to get \(appName) moving.")
                        .font(.system(size: 13, weight: .regular, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
                .padding(24)
            } else {
                List(selection: $model.selectedProjectID) {
                    ForEach(model.projects) { project in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: project.sourceProjectURL == nil ? "shippingbox.circle.fill" : "server.rack")
                                .foregroundStyle(project.sourceProjectURL == nil ? .mint : OperaChromeTheme.accent)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Text(project.displayName)
                                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                                    if model.openingProjectID == project.id {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                                Text(project.sourceProjectURL == nil ? "Server-created project" : "Imported into server library")
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .tag(project.id)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var detailsPanel: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 20) {
                if let selectedProject = model.selectedProject {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(selectedProject.displayName)
                            .font(.system(size: 28, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text(selectedProject.sourceProjectURL == nil
                             ? "This project lives fully inside Novotro Project Server and can be opened from Write, Score, or Animate."
                             : "This project is mirrored into Novotro Project Server and stays available to the full Novotro suite.")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }

                    HStack(spacing: 12) {
                        infoCard(title: "Created", value: browserDateFormatter.string(from: selectedProject.createdAt))
                        infoCard(title: "Updated", value: browserDateFormatter.string(from: selectedProject.updatedAt))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Ready To Open")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(Color.white.opacity(0.46))
                        Text("The apps will connect to the server-backed project directly. No Finder path or package name is required.")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.68))
                    }

                    if model.openingProjectID == selectedProject.id {
                        loadingPanel(for: selectedProject)
                    }

                    HStack(spacing: 12) {
                        Button {
                            openSelectedProject()
                        } label: {
                            HStack(spacing: 10) {
                                if model.openingProjectID == selectedProject.id {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                                Label(
                                    model.openingProjectID == selectedProject.id ? "Opening \(appName)..." : "Open In \(appName)",
                                    systemImage: "arrow.up.forward.app"
                                )
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isLoading || model.isMutating || model.isOpeningProject)

                        Button {
                            Task {
                                await model.refresh(selectStoredSelection: false)
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isLoading || model.isMutating || model.isOpeningProject)
                    }

                    Spacer(minLength: 0)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Select A Server Project")
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                        Text("Pick a project from the left to open it in \(appName), or create a fresh one on the server.")
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.white.opacity(0.68))
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(28)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let statusMessage = model.statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    private func infoCard(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.45))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func loadingPanel(for project: NPProjectServerRegistration) -> some View {
        let snapshot = progressCenter.snapshot(for: model.preferredOpenURL(for: project).path)

        return VStack(alignment: .leading, spacing: 12) {
            Text(snapshot?.phaseTitle ?? "Opening Project")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(Color.white.opacity(0.46))
            Text(snapshot?.detail ?? "Loading \(project.displayName) from Novotro Project Server. This can take a moment for larger projects.")
                .font(.system(size: 13, weight: .regular, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.72))

            if let summary = snapshot?.progressSummary {
                Text(summary)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.78))
            }

            if let fraction = snapshot?.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(.blue)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.blue)
            }

            HStack(spacing: 10) {
                if let currentItemPath = snapshot?.currentItemPath {
                    Text(currentItemPath)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.52))
                        .lineLimit(1)
                }

                Spacer()

                if let snapshot {
                    HStack(spacing: 8) {
                        if let fraction = snapshot.fractionCompleted {
                            Text(String(format: "%.0f%%", fraction * 100))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.72))
                        }

                        TimelineView(.periodic(from: snapshot.startedAt, by: 1.0)) { context in
                            let elapsed = max(Int(context.date.timeIntervalSince(snapshot.startedAt)), 0)
                            Text(String(format: "%d:%02d elapsed", elapsed / 60, elapsed % 60))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.58))
                        }
                    }
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.blue.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.blue.opacity(0.24), lineWidth: 1)
        )
    }

    private func statusPill(text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(tint.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.16))
            )
    }

    private func openSelectedProject() {
        guard let selectedProject = model.selectedProject else { return }
        guard model.beginOpeningProject(selectedProject, in: appName) else { return }
            let url = model.preferredOpenURL(for: selectedProject)
        Task {
            await onOpenProject(url)
            if model.errorMessage == nil {
                model.finishOpeningProject(statusMessage: "Loaded \(selectedProject.displayName).")
            } else {
                model.finishOpeningProject()
            }
        }
    }
}

private struct ProjectNamePrompt: Identifiable {
    enum Mode {
        case create
        case rename
    }

    let mode: Mode
    let title: String
    let actionTitle: String
    let initialValue: String

    var id: String { title + actionTitle + initialValue }
}

private struct ProjectNamePromptView: View {
    @Environment(\.dismiss) private var dismiss

    let title: String
    let actionTitle: String
    let initialValue: String
    let onSubmit: (String) -> Void

    @State private var draftName: String

    init(
        title: String,
        actionTitle: String,
        initialValue: String,
        onSubmit: @escaping (String) -> Void
    ) {
        self.title = title
        self.actionTitle = actionTitle
        self.initialValue = initialValue
        self.onSubmit = onSubmit
        _draftName = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title3.weight(.semibold))
            TextField("Project name", text: $draftName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button(actionTitle) {
                    onSubmit(draftName)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 420)
    }
}

private let browserDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()
#endif
