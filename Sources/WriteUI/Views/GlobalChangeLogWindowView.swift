import SwiftUI

@available(macOS 26.0, *)
struct GlobalChangeLogWindowView: View {
    static let windowID = "global-change-log"

    @Bindable var store: ScriptStore
    @State private var filter: ChangeLogFilter = .all
    @State private var searchText: String = ""

    private var projectTitle: String {
        if !store.metadata.name.isEmpty {
            return store.metadata.name
        }
        return store.projectURL?.deletingPathExtension().lastPathComponent ?? "No Project Open"
    }

    private var activityItems: [ChangeLogActivityItem] {
        Self.buildActivityItems(
            projectHistory: store.projectHistoryEntries,
            gitHistory: store.gitHistoryEntries,
            filter: filter,
            query: searchText
        )
    }

    private var touchedFiles: [TouchedFileSummary] {
        Self.touchedFiles(from: store.projectHistoryEntries)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black,
                    Color(red: 0.08, green: 0.06, blue: 0.04),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if store.projectURL == nil {
                unavailableState
            } else {
                content
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            controls
            summaryStrip

            HStack(alignment: .top, spacing: 18) {
                touchedFilesPanel
                    .frame(width: 280)

                timelinePanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Global Change Log")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Text(projectTitle)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.orange.opacity(0.85))

            if let projectURL = store.projectURL {
                Text(projectURL.path)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Filter", selection: $filter) {
                ForEach(ChangeLogFilter.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 310)

            TextField("Search scene names, paths, messages, or commits", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
        }
    }

    private var summaryStrip: some View {
        HStack(spacing: 12) {
            SummaryCardView(
                title: "App Events",
                value: "\(store.projectHistoryEntries.count)",
                caption: "revisions, reloads, and sync events",
                accent: .orange
            )
            SummaryCardView(
                title: "Git Commits",
                value: "\(store.gitHistoryEntries.count)",
                caption: "repo history tied to this show",
                accent: .green
            )
            SummaryCardView(
                title: "Touched Files",
                value: "\(touchedFiles.count)",
                caption: "scene files and synopsis references",
                accent: .blue
            )
            SummaryCardView(
                title: "Latest Activity",
                value: latestActivityLabel,
                caption: "most recent event across app and git",
                accent: .pink
            )
        }
    }

    private var touchedFilesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Touched Files", systemImage: "music.note.list")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if touchedFiles.isEmpty {
                Text("Whole-show scene activity will appear here as you edit, sync, or reload files.")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(touchedFiles) { file in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .center, spacing: 8) {
                                    Text(file.displayName)
                                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)

                                    Spacer()

                                    Text("\(file.count)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.orange)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule()
                                                .fill(Color.orange.opacity(0.14))
                                        )
                                }

                                Text(file.path)
                                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.45))
                                    .lineLimit(2)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(0.05))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(panelBackground)
    }

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Timeline", systemImage: "waveform.path.ecg.rectangle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if activityItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("No matching activity")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Try clearing the search field or switching the filter.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(activityItems) { item in
                            ChangeLogTimelineRow(item: item)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(panelBackground)
    }

    private var unavailableState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 42))
                .foregroundStyle(.tertiary)
            Text("Open a show to inspect its global change log.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("This window is read-only. It is meant for reviewing project-wide activity, not restoring anything.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(32)
        .background(panelBackground)
    }

    private var latestActivityLabel: String {
        let latestProject = store.projectHistoryEntries.map(\.recordedAt).max()
        let latestGit = store.gitHistoryEntries.map(\.committedAt).max()
        guard let latest = [latestProject, latestGit].compactMap({ $0 }).max() else {
            return "None"
        }
        return Self.relativeDateFormatter.localizedString(for: latest, relativeTo: Date())
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 18)
            .fill(Color.white.opacity(0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    static func buildActivityItems(
        projectHistory: [ProjectHistoryEntry],
        gitHistory: [GitCommitEntry],
        filter: ChangeLogFilter,
        query: String
    ) -> [ChangeLogActivityItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        let projectItems = projectHistory.map(ChangeLogActivityItem.init(projectEntry:))
        let gitItems = gitHistory.map(ChangeLogActivityItem.init(gitCommit:))

        return (projectItems + gitItems)
            .filter { item in
                switch filter {
                case .all:
                    return true
                case .app:
                    return item.source == .app
                case .git:
                    return item.source == .git
                }
            }
            .filter { item in
                guard !trimmedQuery.isEmpty else { return true }
                return item.matches(trimmedQuery)
            }
            .sorted { $0.timestamp > $1.timestamp }
    }

    static func touchedFiles(from entries: [ProjectHistoryEntry]) -> [TouchedFileSummary] {
        let ignored = Set(["__synopsis__"])
        let counts = entries
            .flatMap(\.relativePaths)
            .filter { !ignored.contains($0) }
            .reduce(into: [String: Int]()) { partialResult, path in
                partialResult[path, default: 0] += 1
            }

        return counts
            .map { TouchedFileSummary(path: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.path.localizedStandardCompare($1.path) == .orderedAscending
                }
                return $0.count > $1.count
            }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

@available(macOS 26.0, *)
enum ChangeLogFilter: String, CaseIterable, Identifiable {
    case all
    case app
    case git

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:
            return "All Activity"
        case .app:
            return "App Events"
        case .git:
            return "Git Commits"
        }
    }
}

@available(macOS 26.0, *)
struct TouchedFileSummary: Identifiable, Hashable {
    let path: String
    let count: Int

    var id: String { path }

    var displayName: String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}

@available(macOS 26.0, *)
struct ChangeLogActivityItem: Identifiable, Hashable {
    enum Source: String, Hashable {
        case app
        case git
    }

    let id: String
    let source: Source
    let timestamp: Date
    let title: String
    let subtitle: String
    let paths: [String]
    let badgeText: String
    let systemImage: String
    let accent: Color

    init(projectEntry entry: ProjectHistoryEntry) {
        id = entry.id.uuidString
        source = .app
        timestamp = entry.recordedAt
        title = entry.title
        subtitle = entry.message
        paths = entry.relativePaths

        switch entry.kind {
        case .autosave:
            badgeText = "Revision"
            systemImage = "clock.arrow.circlepath"
            accent = .orange
        case .manualSave:
            badgeText = "Save"
            systemImage = "square.and.arrow.down"
            accent = .green
        case .externalReload:
            badgeText = "External"
            systemImage = "arrow.trianglehead.2.clockwise.rotate.90"
            accent = .yellow
        case .openedWithExternalChanges:
            badgeText = "Launch"
            systemImage = "sparkles"
            accent = .blue
        case .agentSync:
            badgeText = "Agent"
            systemImage = "bolt.horizontal"
            accent = .pink
        }
    }

    init(gitCommit commit: GitCommitEntry) {
        id = commit.id
        source = .git
        timestamp = commit.committedAt
        title = commit.subject
        subtitle = "Commit \(commit.shortHash)"
        paths = []
        badgeText = "Git"
        systemImage = "point.3.connected.trianglepath.dotted"
        accent = .green
    }

    func matches(_ query: String) -> Bool {
        let lowered = query.localizedLowercase
        return title.localizedLowercase.contains(lowered)
            || subtitle.localizedLowercase.contains(lowered)
            || badgeText.localizedLowercase.contains(lowered)
            || paths.contains(where: { $0.localizedLowercase.contains(lowered) })
    }
}

@available(macOS 26.0, *)
private struct SummaryCardView: View {
    let title: String
    let value: String
    let caption: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.55))

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            Text(caption)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(accent.opacity(0.22), lineWidth: 1)
        )
    }
}

@available(macOS 26.0, *)
private struct ChangeLogTimelineRow: View {
    let item: ChangeLogActivityItem

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(item.accent.opacity(0.2))
                    .frame(width: 28, height: 28)

                Image(systemName: item.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(item.accent)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(item.badgeText)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(item.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(item.accent.opacity(0.14))
                        )

                    Spacer()

                    Text(Self.formatter.string(from: item.timestamp))
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.45))
                }

                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.7))

                if !item.paths.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(item.paths.prefix(4), id: \.self) { path in
                            Text(path)
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.45))
                        }
                        if item.paths.count > 4 {
                            Text("+\(item.paths.count - 4) more")
                                .font(.system(size: 10, weight: .regular, design: .monospaced))
                                .foregroundStyle(Color.white.opacity(0.35))
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }
}
