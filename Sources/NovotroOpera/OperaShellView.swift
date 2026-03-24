import AppKit
import SwiftUI
import NovotroAnimateUI
import NovotroProjectKit
import NovotroScoreUI
import NovotroWriteUI
import UniformTypeIdentifiers

@available(macOS 26.0, *)
enum OperaMode: String, CaseIterable, Identifiable {
    case write
    case score
    case animate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .write: return "Write"
        case .score: return "Score"
        case .animate: return "Animate"
        }
    }

    var subtitle: String {
        switch self {
        case .write: return "Libretto and scene drafting"
        case .score: return "Playback, orchestration, and export"
        case .animate: return "Characters, staging, and timeline"
        }
    }

    var systemImage: String {
        switch self {
        case .write: return "text.book.closed"
        case .score: return "music.note.list"
        case .animate: return "sparkles.tv"
        }
    }
}

enum OperaShellSignals {
    static let openProjectFromDisk = Notification.Name("novotro.opera.openProjectFromDisk")
    static let openProjectFromURL = Notification.Name("novotro.opera.openProjectFromURL")
    static let openRecentProjects = Notification.Name("novotro.opera.openRecentProjects")
    static let saveProject = Notification.Name("novotro.opera.saveProject")
}

private enum OperaRecentProjectsStore {
    private static let storageKey = "novotro.opera.recentProjectPaths"
    private static let legacyStorageKeys = [
        "recentProjectPaths"
    ]
    private static let maxProjects = 12
    private static let controlFileCandidates = [
        "Metadata/project.json",
        "project.json"
    ]

    static func recentProjects(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> [URL] {
        let primaryPaths = userDefaults.array(forKey: storageKey) as? [String] ?? []
        let legacyPaths = legacyStorageKeys.flatMap { key in
            userDefaults.array(forKey: key) as? [String] ?? []
        }
        let storedPaths = primaryPaths + legacyPaths
        var seen: Set<String> = []
        var urls: [URL] = []

        for path in storedPaths {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            guard isSupportedProjectURL(url, fileManager: fileManager) else { continue }
            urls.append(url)
        }

        let normalizedPaths = urls.map(\.path)
        if normalizedPaths != primaryPaths {
            userDefaults.set(urls.map(\.path), forKey: storageKey)
        }

        return urls
    }

    @discardableResult
    static func noteProject(
        _ url: URL,
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) -> [URL] {
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL
        guard isSupportedProjectURL(normalized, fileManager: fileManager) else {
            return recentProjects(userDefaults: userDefaults, fileManager: fileManager)
        }
        var urls = recentProjects(userDefaults: userDefaults)
        urls.removeAll { $0.path == normalized.path }
        urls.insert(normalized, at: 0)
        let trimmed = Array(urls.prefix(maxProjects))
        userDefaults.set(trimmed.map(\.path), forKey: storageKey)
        return trimmed
    }

    private static func isSupportedProjectURL(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return controlFileCandidates.contains { candidate in
            fileManager.fileExists(atPath: url.appendingPathComponent(candidate).path)
        }
    }
}

@available(macOS 26.0, *)
private enum OperaModal: String, Identifiable {
    case recentProjects

    var id: String { rawValue }
}

@available(macOS 26.0, *)
private enum OperaLoadState: Equatable {
    case idle
    case loading(mode: OperaMode, projectName: String, projectPath: String)

    var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}

@available(macOS 26.0, *)
private enum OperaModeLoadResult {
    case success
    case failure(String)
    case timedOut
}

@available(macOS 26.0, *)
struct OperaShellView: View {
    @Binding var selectedMode: OperaMode
    @StateObject private var progressCenter = NovotroProjectOpenProgressCenter.shared
    @StateObject private var writeController = NovotroWriteWorkspaceController()
    @StateObject private var scoreController = NovotroScoreWorkspaceController()
    @StateObject private var animateController = NovotroAnimateWorkspaceController()
    @State private var activeProjectURL: URL?
    @State private var activeProjectTitle: String?
    @State private var renderedMode: OperaMode = .write
    @State private var activeModal: OperaModal?
    @State private var loadState: OperaLoadState = .idle
    @State private var recentProjects: [URL] = []
    @State private var activeProjectLoadError: String?
    @State private var isOpeningFromPanel = false
    @State private var didInitialize = false
    @State private var modeSwitchTask: Task<Void, Never>?
    private static let controlFileCandidates = [
        "Metadata/project.json",
        "project.json"
    ]

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.leading, 78)
                .padding(.trailing, 12)

            OperaChromeDivider()

            ZStack {
                mainContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(OperaChromeTheme.workspaceBackground)

                if case let .loading(mode, projectName, _) = loadState {
                    loadingOverlay(mode: mode, projectName: projectName)
                }
            }
        }
        .background(OperaChromeTheme.windowBackground)
        .ignoresSafeArea(.container, edges: .top)
        .background(OperaWindowAccessor())
        .task {
            await initializeShellIfNeeded()
        }
        .task {
            // File-based remote control for diagnostics via SSH
            let commandPath = "/tmp/novotro-command.txt"
            let fm = FileManager.default
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard fm.fileExists(atPath: commandPath),
                      let data = fm.contents(atPath: commandPath),
                      let command = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !command.isEmpty else { continue }
                try? fm.removeItem(atPath: commandPath)
                await MainActor.run {
                    switch command.lowercased() {
                    case "write":  selectedMode = .write
                    case "score":  selectedMode = .score
                    case "animate": selectedMode = .animate
                    default: break
                    }
                }
            }
        }
        .onChange(of: selectedMode) { _, newMode in
            modeSwitchTask?.cancel()
            modeSwitchTask = Task {
                await handleModeSelectionChange(newMode)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: OperaShellSignals.openProjectFromDisk)) { _ in
            Task {
                await openProjectFromDisk()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: OperaShellSignals.openProjectFromURL)) { note in
            guard let rawURL = note.userInfo?["url"] as? URL else { return }
            Task {
                _ = await openProject(rawURL)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: OperaShellSignals.openRecentProjects)) { _ in
            recentProjects = OperaRecentProjectsStore.recentProjects()
            activeModal = .recentProjects
        }
        .onReceive(NotificationCenter.default.publisher(for: OperaShellSignals.saveProject)) { _ in
            saveActiveWorkspace()
        }
        .alert("Couldn't Open Project", isPresented: Binding(
            get: { activeProjectLoadError != nil },
            set: { isPresented in
                if !isPresented {
                    activeProjectLoadError = nil
                }
            }
        )) {
            Button("OK") {
                activeProjectLoadError = nil
            }
        } message: {
            Text(activeProjectLoadError ?? "The project could not be opened.")
        }
        .sheet(item: $activeModal) { modal in
            switch modal {
            case .recentProjects:
                recentProjectsSheet
            }
        }
    }

    private var activeSaveIndicator: SaveIndicatorState {
        switch renderedMode {
        case .write: return writeController.saveIndicator
        case .score: return scoreController.saveIndicator
        case .animate: return animateController.saveIndicator
        }
    }

    private var tabBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Text("Novotro Opera")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                OperaChromeCompactSaveIndicator(state: activeSaveIndicator)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(OperaMode.allCases) { mode in
                    OperaModeButton(
                        mode: mode,
                        isSelected: selectedMode == mode
                    ) {
                        selectedMode = mode
                    }
                }
            }
        }
        .frame(height: 36)
        .background(OperaChromeTheme.headerBackground)
    }

    @ViewBuilder
    private var mainContent: some View {
        if activeProjectURL == nil {
            OperaChromeEmptyState(
                systemImage: "music.quarternote.3",
                title: "Choose A Project To Begin",
                message: "Use the File menu or Recent Projects to open a local OWP project folder."
            )
        } else {
            activeWorkspace
        }
    }

    @ViewBuilder
    private var activeWorkspace: some View {
        switch renderedMode {
        case .write:
            NovotroWriteWorkspace(controller: writeController)
        case .score:
            NovotroScoreWorkspace(controller: scoreController)
        case .animate:
            NovotroAnimateWorkspace(controller: animateController)
        }
    }

    private var recentProjectsSheet: some View {
        OperaRecentProjectsSheet(
            recentProjects: recentProjects,
            activeProjectURL: activeProjectURL,
            isLoading: loadState.isLoading,
            openingProjectPath: activeLoadingProjectPath,
            loadingProjectName: activeLoadingProjectName,
            loadingStatusMessage: activeLoadDetail,
            loadingSnapshot: activeLoadSnapshot
        ) { url in
            Task {
                _ = await openProject(url)
            }
        }
        .interactiveDismissDisabled(loadState.isLoading)
    }

    @ViewBuilder
    private func loadingOverlay(mode: OperaMode, projectName: String) -> some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            OperaProjectLoadingPanel(
                title: "Opening \(projectName)",
                message: activeLoadDetail(for: mode),
                accent: modeAccent(for: mode),
                snapshot: activeLoadSnapshot
            )
            .padding(.horizontal, 64)
        }
    }

    @MainActor
    private func initializeShellIfNeeded() async {
        guard !didInitialize else { return }
        didInitialize = true
        renderedMode = selectedMode
        recentProjects = OperaRecentProjectsStore.recentProjects()
        if activeProjectURL == nil,
           let mostRecentProject = recentProjects.first {
            let opened = await openProject(mostRecentProject)
            if !opened {
                recentProjects = OperaRecentProjectsStore.recentProjects()
                activeModal = .recentProjects
            }
        } else if activeProjectURL == nil {
            activeModal = .recentProjects
        }
    }

    @MainActor
    private func resolveProjectURL(for url: URL) throws -> URL {
        let normalizedURL = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalizedURL.path, isDirectory: &isDirectory) else {
            throw RuntimeError.projectNotFound
        }
        guard isDirectory.boolValue else {
            throw RuntimeError.unsupportedSelection
        }
        guard Self.hasControlFile(at: normalizedURL) else {
            throw RuntimeError.missingControlFile
        }
        return normalizedURL
    }

    @MainActor
    private func openProject(_ url: URL) async -> Bool {
        let normalizedURL: URL
        do {
            normalizedURL = try resolveProjectURL(for: url)
        } catch {
            activeProjectLoadError = error.localizedDescription
            return false
        }
        return await openProject(normalizedURL, displayName: displayName(for: normalizedURL))
    }

    @MainActor
    private func openProject(_ url: URL, displayName: String) async -> Bool {
        let normalizedURL = url.standardizedFileURL
        loadState = .loading(mode: selectedMode, projectName: displayName, projectPath: normalizedURL.path)
        progressCenter.start(
            projectURL: normalizedURL,
            phaseTitle: "Preparing Project Open",
            detail: "Starting the \(selectedMode.title) workspace for \(displayName)."
        )
        activeProjectLoadError = nil
        await Task.yield()

        let error = await load(mode: selectedMode, projectURL: normalizedURL)
        guard error == nil else {
            activeProjectLoadError = error
            progressCenter.finish(projectURL: normalizedURL)
            loadState = .idle
            return false
        }

        activeProjectURL = normalizedURL
        activeProjectTitle = displayName
        renderedMode = selectedMode
        activeModal = nil
        recentProjects = OperaRecentProjectsStore.noteProject(normalizedURL)
        progressCenter.finish(projectURL: normalizedURL)
        loadState = .idle
        return true
    }

    @MainActor
    private func handleModeSelectionChange(_ newMode: OperaMode) async {
        guard didInitialize else { return }
        guard let activeProjectURL else {
            renderedMode = newMode
            return
        }
        guard newMode != renderedMode else { return }

        // Suspend background watchers on the mode we're leaving so they don't
        // contend with the incoming mode's database and file-system access.
        switch renderedMode {
        case .write: writeController.suspendBackgroundWork()
        case .score: scoreController.suspendBackgroundWork()
        case .animate: animateController.suspendBackgroundWork()
        }

        let projectName = activeProjectTitle ?? displayName(for: activeProjectURL)
        loadState = .loading(mode: newMode, projectName: projectName, projectPath: activeProjectURL.path)
        progressCenter.start(
            projectURL: activeProjectURL,
            phaseTitle: "Switching Workspace",
            detail: "Preparing the \(newMode.title) tools for \(projectName)."
        )
        activeProjectLoadError = nil
        await Task.yield()
        guard !Task.isCancelled else {
            progressCenter.finish(projectURL: activeProjectURL)
            loadState = .idle
            return
        }

        switch await loadForModeSwitch(mode: newMode, projectURL: activeProjectURL) {
        case .success:
            guard !Task.isCancelled else { break }
            renderedMode = newMode
        case let .failure(error):
            guard !Task.isCancelled else { break }
            activeProjectLoadError = error
            selectedMode = renderedMode
        case .timedOut:
            guard !Task.isCancelled else { break }
            renderedMode = newMode
            progressCenter.update(
                projectURL: activeProjectURL,
                phaseTitle: "Switching Workspace",
                detail: "Animate is still indexing local files. Showing the workspace now and applying updates when indexing completes."
            )
        }

        progressCenter.finish(projectURL: activeProjectURL)
        loadState = .idle
    }

    @MainActor
    private func load(mode: OperaMode, projectURL: URL) async -> String? {
        switch mode {
        case .write:
            return await writeController.ensureProjectLoaded(projectURL)
        case .score:
            return await scoreController.ensureProjectLoaded(projectURL)
        case .animate:
            return await animateController.ensureProjectLoaded(projectURL)
        }
    }

    @MainActor
    private func loadForModeSwitch(mode: OperaMode, projectURL: URL) async -> OperaModeLoadResult {
        guard mode == .animate else {
            if let error = await load(mode: mode, projectURL: projectURL) {
                return .failure(error)
            }
            return .success
        }

        let animateLoadTask = Task { await animateController.ensureProjectLoaded(projectURL) }
        let timeoutNanoseconds: UInt64 = 8_000_000_000

        let result = await withTaskGroup(of: OperaModeLoadResult.self, returning: OperaModeLoadResult.self) { group in
            group.addTask {
                if let error = await animateLoadTask.value {
                    return .failure(error)
                }
                return .success
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return .timedOut
            }

            let first = await group.next() ?? .success
            group.cancelAll()
            return first
        }

        if case .timedOut = result {
            Task {
                _ = await animateLoadTask.value
            }
        }

        return result
    }

    private func openProjectFromDisk() async {
        guard !isOpeningFromPanel else { return }
        isOpeningFromPanel = true
        defer { isOpeningFromPanel = false }

        let panel = NSOpenPanel()
        panel.title = "Open Project Folder"
        panel.message = "Choose a local Amira project folder."
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = defaultProjectDirectory()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.folder]

        if panel.runModal() == .OK,
           let url = panel.url {
            _ = await openProject(url)
        }
    }

    private func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }

    private static func hasControlFile(at projectURL: URL) -> Bool {
        controlFileCandidates.contains { candidate in
            FileManager.default.fileExists(atPath: projectURL.appendingPathComponent(candidate).path)
        }
    }

    private func defaultProjectDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        let candidateProjectRoots: [URL] = [
            documents?.appendingPathComponent("Amira - A Modern Opera", isDirectory: true).appendingPathComponent("Amira", isDirectory: true),
            documents?.appendingPathComponent("Amira - A Modern Opera", isDirectory: true),
            documents?.appendingPathComponent("Amira", isDirectory: true)
        ].compactMap { $0 }

        if let exactMatch = candidateProjectRoots.first(where: { candidate in
            FileManager.default.fileExists(atPath: candidate.path) && Self.hasControlFile(at: candidate)
        }) {
            return exactMatch
        }

        if let existsCandidate = candidateProjectRoots.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return existsCandidate
        }
        return documents ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private var activeLoadingProjectPath: String? {
        guard case let .loading(_, _, projectPath) = loadState else { return nil }
        return projectPath
    }

    private var activeLoadingProjectName: String? {
        guard case let .loading(_, projectName, _) = loadState else { return nil }
        return projectName
    }

    private var activeLoadDetail: String? {
        guard case let .loading(mode, _, _) = loadState else { return nil }
        return activeLoadDetail(for: mode)
    }

    private var activeLoadSnapshot: NovotroProjectOpenProgressCenter.Snapshot? {
        progressCenter.snapshot(for: activeLoadingProjectPath)
    }

    private func activeLoadDetail(for mode: OperaMode) -> String {
        if let detail = activeLoadSnapshot?.detail,
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return detail
        }

        let message = loadStatusMessage(for: mode)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty, message != "Ready" {
            return message
        }

        switch mode {
        case .write:
            return "Opening the libretto workspace from local files."
        case .score:
            return "Loading playback and orchestration data from local files."
        case .animate:
            return "Loading scene, character, and timeline data from local files."
        }
    }

    private func loadStatusMessage(for mode: OperaMode) -> String {
        switch mode {
        case .write:
            return writeController.loadStatusMessage
        case .score:
            return scoreController.loadStatusMessage
        case .animate:
            return animateController.loadStatusMessage
        }
    }

    private func modeAccent(for mode: OperaMode) -> Color {
        switch mode {
        case .write:
            return OperaChromeTheme.accent
        case .score:
            return Color(red: 0.72, green: 0.78, blue: 0.46)
        case .animate:
            return Color(red: 0.72, green: 0.58, blue: 0.82)
        }
    }

    private func saveActiveWorkspace() {
        guard activeProjectURL != nil else { return }

        switch renderedMode {
        case .write:
            writeController.save()
        case .score:
            scoreController.save()
        case .animate:
            animateController.save()
        }
    }
}

private enum RuntimeError: LocalizedError {
    case projectNotFound
    case missingControlFile
    case unsupportedSelection

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "Could not find the selected project."
        case .missingControlFile:
            return "This folder does not look like an OWP project. Expected Metadata/project.json or project.json."
        case .unsupportedSelection:
            return "Please pick an OWP project folder."
        }
    }
}

@available(macOS 26.0, *)
private struct OperaModeButton: View {
    let mode: OperaMode
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(mode.title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
            }
            .foregroundStyle(isSelected ? OperaChromeTheme.textPrimary : OperaChromeTheme.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(mode.subtitle)
    }

    private var backgroundColor: Color {
        if isSelected {
            return OperaChromeTheme.selection
        }
        if isHovered {
            return OperaChromeTheme.hover
        }
        return .clear
    }

    private var borderColor: Color {
        isSelected ? OperaChromeTheme.accent.opacity(0.26) : Color.clear
    }
}

@available(macOS 26.0, *)
private struct OperaRecentProjectsSheet: View {
    let recentProjects: [URL]
    let activeProjectURL: URL?
    let isLoading: Bool
    let openingProjectPath: String?
    let loadingProjectName: String?
    let loadingStatusMessage: String?
    let loadingSnapshot: NovotroProjectOpenProgressCenter.Snapshot?
    let onOpenProject: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            OperaChromeTheme.workspaceBackground
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Projects")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                    Text("Pick a recent project to jump straight back in.")
                        .font(.system(size: 13))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }

                if isLoading, let loadingProjectName {
                    OperaProjectLoadingPanel(
                        title: "Opening \(loadingProjectName)",
                        message: loadingStatusMessage ?? "Opening from local disk.",
                        accent: OperaChromeTheme.accent,
                        snapshot: loadingSnapshot
                    )
                }

                if recentProjects.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                    Text("No recent projects yet.")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                        Text("Open a local OWP project folder from File > Open Project and it will appear here next time.")
                            .font(.system(size: 12))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(OperaChromeTheme.panelBackground)
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(recentProjects, id: \.path) { url in
                                Button {
                                    onOpenProject(url)
                                } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack(spacing: 8) {
                                            Image(systemName: rowSymbolName(for: url))
                                                .font(.system(size: 12, weight: .medium))
                                                .foregroundStyle(rowSymbolColor(for: url))
                                            Text(url.deletingPathExtension().lastPathComponent)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundStyle(OperaChromeTheme.textPrimary)
                                                .lineLimit(1)
                                        }
                                        Text(url.path)
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundStyle(OperaChromeTheme.textSecondary)
                                            .lineLimit(1)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(rowBackgroundColor(for: url))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(
                                                rowBorderColor(for: url),
                                                lineWidth: 1
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isLoading)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                }

                HStack {
                    Spacer()
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isLoading)
                }
            }
            .padding(24)
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private func rowSymbolName(for url: URL) -> String {
        if openingProjectPath == url.path {
            return "arrow.trianglehead.2.clockwise"
        }
        if activeProjectURL?.path == url.path {
            return "checkmark.circle.fill"
        }
        return "music.quarternote.3"
    }

    private func rowSymbolColor(for url: URL) -> Color {
        if openingProjectPath == url.path {
            return OperaChromeTheme.warning
        }
        if activeProjectURL?.path == url.path {
            return OperaChromeTheme.success
        }
        return OperaChromeTheme.textSecondary
    }

    private func rowBackgroundColor(for url: URL) -> Color {
        if openingProjectPath == url.path {
            return OperaChromeTheme.accentMuted
        }
        if activeProjectURL?.path == url.path {
            return OperaChromeTheme.selection
        }
        return OperaChromeTheme.panelBackground
    }

    private func rowBorderColor(for url: URL) -> Color {
        if openingProjectPath == url.path {
            return OperaChromeTheme.accent.opacity(0.32)
        }
        if activeProjectURL?.path == url.path {
            return OperaChromeTheme.accent.opacity(0.22)
        }
        return OperaChromeTheme.stroke
    }
}

@available(macOS 26.0, *)
private struct OperaProjectLoadingPanel: View {
    let title: String
    let message: String
    let accent: Color
    let snapshot: NovotroProjectOpenProgressCenter.Snapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                Text(snapshot?.phaseTitle ?? "Project Load In Progress")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .tracking(1.2)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let summary = snapshot?.progressSummary {
                Text(summary)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
            }

            OperaLoadBar(accent: accent, snapshot: snapshot)

            if let currentItemPath = snapshot?.currentItemPath {
                Text(currentItemPath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Text("The workspace will update as soon as local indexing finishes.")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textTertiary)

                Spacer()

                if let snapshot {
                    HStack(spacing: 8) {
                        if let fraction = snapshot.fractionCompleted {
                            Text(String(format: "%.0f%%", fraction * 100))
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(OperaChromeTheme.textPrimary)
                        }

                        TimelineView(.periodic(from: .now, by: 1)) { timeline in
                            Text(snapshot.elapsedDescription(referenceDate: timeline.date))
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(OperaChromeTheme.panelBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OperaChromeTheme.stroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 10, y: 5)
    }
}

@available(macOS 26.0, *)
private struct OperaLoadBar: View {
    let accent: Color
    let snapshot: NovotroProjectOpenProgressCenter.Snapshot?

    var body: some View {
        if let fraction = snapshot?.fractionCompleted {
            GeometryReader { geometry in
                let clamped = min(max(fraction, 0), 1)

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(OperaChromeTheme.stroke)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.35),
                                    accent.opacity(0.95),
                                    Color.white.opacity(0.45),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(geometry.size.width * clamped, 8))
                }
            }
            .frame(height: 8)
            .clipShape(Capsule(style: .continuous))
        } else {
            OperaIndeterminateLoadBar(accent: accent)
        }
    }
}

@available(macOS 26.0, *)
private struct OperaIndeterminateLoadBar: View {
    let accent: Color

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let width = max(geometry.size.width, 1)
                let cycle = timeline.date.timeIntervalSinceReferenceDate
                let progress = cycle.truncatingRemainder(dividingBy: 1.8) / 1.8
                let capsuleWidth = max(88, width * 0.28)
                let travel = width + capsuleWidth
                let offset = progress * travel - capsuleWidth

                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(OperaChromeTheme.stroke)

                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.22),
                                    accent.opacity(0.95),
                                    Color.white.opacity(0.55),
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: capsuleWidth)
                        .offset(x: offset)
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule(style: .continuous))
    }
}

private struct OperaWindowAccessor: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.attach(to: nsView)
    }

    @MainActor
    final class Coordinator {
        private weak var view: NSView?
        private weak var window: NSWindow?
        private var observers: [NSObjectProtocol] = []


        func attach(to view: NSView) {
            self.view = view
            Task { @MainActor [weak self] in
                self?.installIfPossible()
            }
        }

        private func installIfPossible() {
            guard let view else { return }
            guard let resolvedWindow = view.window else {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(20))
                    self?.installIfPossible()
                }
                return
            }
            guard window !== resolvedWindow else { return }

            window = resolvedWindow
            applyConfiguration()
            configureObservers(for: resolvedWindow)

            applyBurst()
        }

        private func applyConfiguration() {
            guard let window else { return }
            window.minSize = NSSize(width: 1220, height: 760)
            window.isOpaque = false
            window.backgroundColor = NSColor(calibratedWhite: 0.14, alpha: 0.96)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }

        private func configureObservers(for window: NSWindow) {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()

            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didEndSheetNotification
            ]

            for name in names {
                let observer = NotificationCenter.default.addObserver(
                    forName: name,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.applyConfiguration()
                        self?.applyBurst()
                    }
                }
                observers.append(observer)
            }
        }



        private func applyBurst() {
            for delay in [0.02, 0.08, 0.15, 0.30, 0.50] {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    self?.applyConfiguration()
                }
            }
        }
    }
}
