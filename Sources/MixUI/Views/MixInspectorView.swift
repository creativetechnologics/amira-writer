import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
enum MixInspectorTab: String, CaseIterable, Identifiable {
    case browser
    case clip
    case fx
    case inputs
    case notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .browser: return "Browser"
        case .clip: return "Clip"
        case .fx: return "FX"
        case .inputs: return "Inputs"
        case .notes: return "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .browser: return "folder"
        case .clip: return "waveform"
        case .fx: return "slider.horizontal.3"
        case .inputs: return "mic"
        case .notes: return "note.text"
        }
    }
}

@available(macOS 26.0, *)
struct MixInspectorView: View {
    @Bindable var store: MixStore
    @AppStorage("novotro.mix.inspector.tab") private var rawTab: String = MixInspectorTab.browser.rawValue

    private var selectedTab: Binding<MixInspectorTab> {
        Binding(
            get: { MixInspectorTab(rawValue: rawTab) ?? .browser },
            set: { rawTab = $0.rawValue }
        )
    }

    var body: some View {
        OperaChromeInspectorTabs(
            selection: selectedTab,
            tabs: MixInspectorTab.allCases.map {
                OperaChromeTabItem(id: $0, title: $0.title, systemImage: $0.systemImage)
            }
        ) { tab in
            switch tab {
            case .browser:
                MixBrowserTab(store: store)
            case .clip:
                MixClipTab(store: store)
            case .fx:
                MixFXTab(store: store)
            case .inputs:
                MixInputsTab(store: store)
            case .notes:
                MixNotesTab(store: store)
            }
        }
        .onChange(of: store.selectedClip?.id) { _, newID in
            if newID != nil { rawTab = MixInspectorTab.clip.rawValue }
        }
    }
}

// MARK: - Browser Tab

@available(macOS 26.0, *)
struct MixBrowserTab: View {
    @Bindable var store: MixStore
    @AppStorage("novotro.mix.browser.expandedPaths") private var rawExpandedPaths: String = "[]"

    private var isFilteringBrowser: Bool {
        store.browserSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @State private var expandedPathsCache: Set<String> = []

    private var expandedPaths: Binding<Set<String>> {
        $expandedPathsCache
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Filter files or folders", text: $store.browserSearchText)
                    .textFieldStyle(.roundedBorder)
                if store.isRefreshingBrowser {
                    ProgressView()
                        .controlSize(.small)
                }
                Button {
                    store.refreshBrowser()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            OperaChromeDivider()

            if let selectedNode = store.selectedBrowserNode, selectedNode.isDirectory == false {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Selected File")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text(selectedNode.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(OperaChromeTheme.textPrimary)
                        .lineLimit(1)
                    Text(selectedNode.path)
                        .font(.system(size: 10))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    HStack(spacing: 8) {
                        Button(store.previewingPath == selectedNode.path ? "Stop Preview" : "Preview") {
                            store.previewAudio(at: selectedNode.path)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(store.selectedTrack.map { "Add To \($0.name)" } ?? "Add To Timeline") {
                            // Use ensureTrackForImport's fallback chain (selected track → first track → create new)
                            // instead of UUID() which would create an orphan track ID.
                            let trackID = store.selectedTrack?.id ?? store.currentTracks.first?.id
                            store.addClip(
                                from: URL(fileURLWithPath: selectedNode.path),
                                to: trackID ?? UUID(),
                                at: store.selectedTrack.map { store.suggestedStartSeconds(for: $0.id) } ?? store.playheadSeconds
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Spacer(minLength: 0)

                        Button("Reveal") {
                            store.revealBrowserPath(selectedNode.path)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.03))
                )
                .onDrag {
                    NSItemProvider(object: URL(fileURLWithPath: selectedNode.path) as NSURL)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                OperaChromeDivider()
            }

            if store.visibleBrowserRoots.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "externaldrive.badge.questionmark")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                    Text(isFilteringBrowser ? "No files match this filter" : "No audio roots detected yet")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(
                        isFilteringBrowser
                        ? "Try a different search term or clear the current filter to see the indexed audio roots again."
                        : "Mix watches the project's suno folder, desktop export locations, and common project audio folders."
                    )
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)
                    if isFilteringBrowser {
                        Button("Clear Filter") {
                            store.browserSearchText = ""
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    Spacer()
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(store.visibleBrowserRoots) { root in
                            MixBrowserNodeView(
                                store: store,
                                node: root,
                                depth: 0,
                                ancestorPaths: [],
                                expandedPaths: expandedPaths
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            }
        }
        .onAppear {
            expandedPathsCache = decodeExpandedPaths(rawExpandedPaths)
            ensureBrowserDisclosureState()
        }
        .onChange(of: expandedPathsCache) { _, newValue in
            // Persist back to AppStorage — guard prevents re-encoding the same value
            let encoded = encodeExpandedPaths(newValue)
            if rawExpandedPaths != encoded {
                rawExpandedPaths = encoded
            }
        }
        .onChange(of: store.selectedBrowserPath) { _, _ in
            ensureBrowserDisclosureState()
        }
        .onChange(of: store.browserRoots) { _, _ in
            expandedPathsCache = decodeExpandedPaths(rawExpandedPaths)
            ensureBrowserDisclosureState()
        }
        .onChange(of: store.browserSearchText) { _, _ in
            ensureBrowserDisclosureState()
        }
    }

    private func decodeExpandedPaths(_ rawValue: String) -> Set<String> {
        guard let data = rawValue.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return Set(paths)
    }

    private func encodeExpandedPaths(_ paths: Set<String>) -> String {
        let sortedPaths = Array(paths).sorted()
        guard let data = try? JSONEncoder().encode(sortedPaths),
              let rawValue = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return rawValue
    }

    private func ensureBrowserDisclosureState() {
        let validDirectoryPaths = collectDirectoryPaths(in: store.browserRoots)
        var expanded = expandedPaths.wrappedValue.intersection(validDirectoryPaths)

        if expanded.isEmpty {
            expanded.formUnion(store.browserRoots.map(\.path))
        }

        if let selectedBrowserPath = store.selectedBrowserPath {
            expanded.formUnion(ancestorPaths(for: selectedBrowserPath, in: store.browserRoots))
        }

        if expanded != expandedPaths.wrappedValue {
            expandedPaths.wrappedValue = expanded
        }
    }

    private func collectDirectoryPaths(in nodes: [MixBrowserNode]) -> Set<String> {
        var result: Set<String> = []
        for node in nodes where node.isDirectory {
            result.insert(node.path)
            result.formUnion(collectDirectoryPaths(in: node.children))
        }
        return result
    }

    private func ancestorPaths(for path: String, in nodes: [MixBrowserNode]) -> Set<String> {
        for node in nodes {
            if node.path == path {
                return []
            }
            let childAncestors = ancestorPaths(for: path, in: node.children)
            if childAncestors.isEmpty == false || node.children.contains(where: { $0.path == path }) {
                return node.isDirectory ? childAncestors.union([node.path]) : childAncestors
            }
        }
        return []
    }
}

@available(macOS 26.0, *)
struct MixBrowserNodeView: View {
    @Bindable var store: MixStore
    let node: MixBrowserNode
    let depth: Int
    let ancestorPaths: [String]
    @Binding var expandedPaths: Set<String>

    private var isExpanded: Bool {
        expandedPaths.contains(node.path)
    }

    private var isSearchActive: Bool {
        store.browserSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private var isSelected: Bool {
        store.selectedBrowserPath == node.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row

            if node.isDirectory && (isExpanded || isSearchActive) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(node.children) { child in
                        MixBrowserNodeView(
                            store: store,
                            node: child,
                            depth: depth + 1,
                            ancestorPaths: ancestorPaths + [node.path],
                            expandedPaths: $expandedPaths
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var row: some View {
        if node.isDirectory {
            Button(action: toggleExpandedAndSelectDirectory) {
                baseRowContent
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(rowBackground)
            .contentShape(Rectangle())
            .contextMenu {
                Button("Reveal In Finder") { store.revealBrowserPath(node.path) }
            }
        } else {
            HStack(spacing: 8) {
                Button {
                    selectFile()
                } label: {
                    baseRowContent
                }
                .buttonStyle(.plain)

                Button {
                    selectFile()
                    store.previewAudio(at: node.path)
                } label: {
                    Image(systemName: store.previewingPath == node.path ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.previewingPath == node.path ? "Stop Preview \(node.name)" : "Preview \(node.name)")

                Button {
                    selectFile()
                    let trackID = store.selectedTrack?.id ?? store.currentTracks.first?.id
                    store.addClip(
                        from: URL(fileURLWithPath: node.path),
                        to: trackID ?? UUID(),
                        at: store.selectedTrack.map { store.suggestedStartSeconds(for: $0.id) } ?? store.playheadSeconds
                    )
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.selectedTrack.map { "Add \(node.name) To \($0.name)" } ?? "Add \(node.name) To Timeline")
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(rowBackground)
            .contentShape(Rectangle())
            .onDrag {
                selectFile()
                return NSItemProvider(object: URL(fileURLWithPath: node.path) as NSURL)
            }
            .contextMenu {
                Button("Reveal In Finder") {
                    selectFile()
                    store.revealBrowserPath(node.path)
                }
                Button("Preview") {
                    selectFile()
                    store.previewAudio(at: node.path)
                }
                Button(store.selectedTrack.map { "Add To \($0.name)" } ?? "Add To Timeline") {
                    selectFile()
                    let trackID = store.selectedTrack?.id ?? store.currentTracks.first?.id
                    store.addClip(
                        from: URL(fileURLWithPath: node.path),
                        to: trackID ?? UUID(),
                        at: store.selectedTrack.map { store.suggestedStartSeconds(for: $0.id) } ?? store.playheadSeconds
                    )
                }
            }
        }
    }

    private var baseRowContent: some View {
        HStack(spacing: 8) {
            if node.isDirectory {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                    .frame(width: 10, height: 10)
            } else {
                Spacer().frame(width: 10)
            }

            Image(systemName: iconName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(iconTint)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 11, weight: node.isDirectory ? .semibold : .medium))
                    .foregroundStyle(OperaChromeTheme.textPrimary)
                    .lineLimit(1)
                if node.isDirectory == false {
                    Text(node.path)
                        .font(.system(size: 9))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 6)

            if let fileSize = node.fileSize, node.isDirectory == false {
                Text(ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file))
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(
                isSelected
                    ? MixPalette.cyan.opacity(0.18)
                    : (node.isDirectory ? Color.clear : Color.white.opacity(0.025))
            )
    }

    private var iconName: String {
        switch node.kind {
        case .root:
            return "externaldrive"
        case .folder:
            return "folder"
        case .audio:
            return "waveform"
        }
    }

    private var iconTint: Color {
        switch node.kind {
        case .root:
            return MixPalette.gold
        case .folder:
            return MixPalette.lime
        case .audio:
            return MixPalette.cyan
        }
    }

    private func toggleExpanded() {
        if isExpanded {
            expandedPaths.remove(node.path)
        } else {
            expandedPaths.insert(node.path)
        }
    }

    private func toggleExpandedAndSelectDirectory() {
        store.selectBrowserPath(node.path)
        for path in ancestorPaths {
            expandedPaths.insert(path)
        }
        toggleExpanded()
    }

    private func selectFile() {
        store.selectBrowserPath(node.path)
        for path in ancestorPaths {
            expandedPaths.insert(path)
        }
    }
}

// MARK: - Clip Tab

@available(macOS 26.0, *)
struct MixClipTab: View {
    @Bindable var store: MixStore

    var body: some View {
        if let clip = store.selectedClip {
            clipDetail(clip)
        } else {
            OperaChromeEmptyState(
                systemImage: "waveform",
                title: "No Clip Selected",
                message: "Click a clip in the timeline to inspect and adjust its properties here."
            )
        }
    }

    @ViewBuilder
    private func clipDetail(_ clip: MixClip) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Clip name", text: Binding(
                        get: { store.selectedClip?.name ?? clip.name },
                        set: { store.updateClipName(clip.id, name: $0) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .semibold))

                    HStack(spacing: 8) {
                        Text(URL(fileURLWithPath: clip.filePath).lastPathComponent)
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button("Reveal") { store.revealBrowserPath(clip.filePath) }
                            .buttonStyle(.borderless)
                            .font(.system(size: 10.5))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)

                OperaChromeDivider()

                // Timing info
                VStack(alignment: .leading, spacing: 8) {
                    inspectorLabel("Timing")
                    HStack {
                        Text("Start")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                        Spacer(minLength: 8)
                        TextField("0.00", value: Binding(
                            get: { store.selectedClip?.startSeconds ?? clip.startSeconds },
                            set: { store.updateClipStartSeconds(clip.id, value: $0) }
                        ), format: .number.precision(.fractionLength(2)))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                    infoRow("Duration",  timecode(clip.durationSeconds))
                    infoRow("Source In", timecode(clip.sourceInSeconds))
                    infoRow("Track",     store.selectedClipTrackName ?? "–")
                    infoRow("Group",     clip.sourceGroup.isEmpty ? "–" : clip.sourceGroup)
                    if clip.isRecordedTake {
                        HStack(spacing: 4) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(MixPalette.recordArmed.opacity(0.8))
                            Text("Recorded Take")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(MixPalette.recordArmed.opacity(0.7))
                        }
                    }
                }
                .padding(.horizontal, 12)

                OperaChromeDivider()

                // Gain
                VStack(alignment: .leading, spacing: 8) {
                    inspectorLabel("Gain")
                    HStack(spacing: 8) {
                        Slider(value: Binding(
                            get: { store.selectedClip?.gainDB ?? clip.gainDB },
                            set: { store.updateClipGain(clip.id, value: $0) }
                        ), in: -24...12)
                        Text(String(format: "%+.1f dB", store.selectedClip?.gainDB ?? clip.gainDB))
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)

                OperaChromeDivider()

                // Fade
                // Always read duration from the live store value so that the slider
                // upper bound stays accurate after the user trims the clip.
                let liveDuration = store.selectedClip?.durationSeconds ?? clip.durationSeconds
                VStack(alignment: .leading, spacing: 10) {
                    inspectorLabel("Fades")
                    HStack(spacing: 8) {
                        Text("In")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .frame(width: 20, alignment: .leading)
                        Slider(value: Binding(
                            get: { store.selectedClip?.fadeInSeconds ?? clip.fadeInSeconds },
                            set: { store.updateClipFadeIn(clip.id, value: $0) }
                        ), in: 0...max(min(liveDuration * 0.45, 8), 0))
                        Text(String(format: "%.2fs", store.selectedClip?.fadeInSeconds ?? clip.fadeInSeconds))
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                    HStack(spacing: 8) {
                        Text("Out")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .frame(width: 20, alignment: .leading)
                        Slider(value: Binding(
                            get: { store.selectedClip?.fadeOutSeconds ?? clip.fadeOutSeconds },
                            set: { store.updateClipFadeOut(clip.id, value: $0) }
                        ), in: 0...max(min(liveDuration * 0.45, 8), 0))
                        Text(String(format: "%.2fs", store.selectedClip?.fadeOutSeconds ?? clip.fadeOutSeconds))
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
                .padding(.horizontal, 12)

                OperaChromeDivider()

                // Actions
                VStack(alignment: .leading, spacing: 8) {
                    inspectorLabel("Actions")
                    HStack(spacing: 8) {
                        Button(store.previewingPath == clip.filePath ? "Stop" : "Preview") {
                            store.previewAudio(at: clip.filePath)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Duplicate") { store.duplicateClip(clip.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                        Button("Seek Here") { store.seekToClip(clip.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                    HStack(spacing: 8) {
                        Button("Split At Playhead") { store.splitSelectedClipAtPlayhead() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(
                                store.playheadSeconds <= clip.startSeconds + 0.05
                                || store.playheadSeconds >= clip.startSeconds + clip.durationSeconds - 0.05
                            )

                        Spacer(minLength: 0)

                        Button("Remove", role: .destructive) { store.removeClip(clip.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private func inspectorLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(OperaChromeTheme.textTertiary)
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OperaChromeTheme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(OperaChromeTheme.textPrimary)
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        let cs = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", m, s, cs)
    }
}

// MARK: - FX Tab

@available(macOS 26.0, *)
struct MixFXTab: View {
    @Bindable var store: MixStore

    private var groupedPlugins: [(String, [MixPluginInfo])] {
        Dictionary(grouping: store.availablePlugins, by: \.manufacturerName)
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Audio Units")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Track FX and instrument choices discovered from the local AU registry.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }
                    Spacer()
                    if store.isScanningPlugins {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if let selectedTrack = store.selectedTrack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Selected Track")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(selectedTrack.name)
                            .font(.system(size: 12.5, weight: .semibold))
                        if selectedTrack.fxChainNames.isEmpty {
                            Text("No FX queued yet.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(OperaChromeTheme.textSecondary)
                        } else {
                            ForEach(selectedTrack.fxChainNames, id: \.self) { plugin in
                                HStack {
                                    Text(plugin)
                                        .font(.system(size: 11.5, weight: .medium))
                                    Spacer()
                                    Button("Remove") {
                                        store.removePlugin(plugin, from: selectedTrack.id)
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.white.opacity(0.03))
                                )
                            }
                        }
                    }
                }

                ForEach(groupedPlugins, id: \.0) { manufacturer, plugins in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(manufacturer)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textTertiary)

                        ForEach(plugins) { plugin in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plugin.name)
                                        .font(.system(size: 11.5, weight: .medium))
                                    Text(plugin.formatLabel + (plugin.hasCustomView ? " • custom UI" : ""))
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(OperaChromeTheme.textSecondary)
                                }
                                Spacer()
                                if let selectedTrack = store.selectedTrack {
                                    Button("Add") {
                                        store.assignPlugin(plugin.name, to: selectedTrack.id)
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.03))
                            )
                        }
                    }
                }
            }
            .padding(12)
        }
    }
}

// MARK: - Inputs Tab

@available(macOS 26.0, *)
struct MixInputsTab: View {
    @Bindable var store: MixStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recording Readiness")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Arm a track, choose an input, then use the main Record button to capture a vocal WAV into the project Audio/Vocals folder.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }

                HStack(spacing: 8) {
                    Text("Permission")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    Text(permissionLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(permissionTint.opacity(0.16))
                        )
                        .foregroundStyle(permissionTint)
                    Spacer()
                    if store.microphonePermission != .authorized {
                        Button("Request Access") {
                            store.requestMicrophoneAccess()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Inputs")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    if store.inputDevices.isEmpty {
                        Text("No audio inputs are visible yet.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    } else {
                        ForEach(store.inputDevices) { input in
                            HStack {
                                Image(systemName: input.isConnected ? "mic.fill" : "mic.slash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(input.isConnected ? MixPalette.cyan : MixPalette.warn)
                                Text(input.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.03))
                            )
                        }
                    }
                }

                if store.currentTracks.isEmpty == false {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Track Inputs")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textTertiary)

                        ForEach(store.currentTracks) { track in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(track.isRecordArmed ? MixPalette.recordArmed : Color.white.opacity(0.16))
                                    .frame(width: 8, height: 8)
                                Text(track.name)
                                    .font(.system(size: 11.5, weight: .medium))
                                Spacer()
                                Picker(
                                    "Input",
                                    selection: Binding(
                                        get: { track.inputName ?? "None" },
                                        set: { newValue in
                                            store.selectTrack(track.id, clearSelectedClip: false)
                                            store.setTrackInput(track.id, inputName: newValue == "None" ? nil : newValue)
                                        }
                                    )
                                ) {
                                    Text("None").tag("None")
                                    ForEach(store.inputDevices.map(\.name), id: \.self) { inputName in
                                        Text(inputName).tag(inputName)
                                    }
                                }
                                .pickerStyle(.menu)
                                .frame(width: 170)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.03))
                            )
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var permissionLabel: String {
        switch store.microphonePermission {
        case .authorized: return "Authorized"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not Determined"
        case .unknown: return "Unknown"
        }
    }

    private var permissionTint: Color {
        switch store.microphonePermission {
        case .authorized:
            return MixPalette.lime
        case .denied, .restricted:
            return MixPalette.warn
        case .notDetermined, .unknown:
            return MixPalette.gold
        }
    }
}

// MARK: - Notes Tab

@available(macOS 26.0, *)
struct MixNotesTab: View {
    @Bindable var store: MixStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.selectedScene?.displayTitle ?? "No scene")
                        .font(.system(size: 14, weight: .semibold))
                    if let scene = store.selectedScene {
                        Text(scene.relativePath)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Session Notes")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(OperaChromeTheme.textTertiary)
                    TextEditor(
                        text: Binding(
                            get: { store.currentSession?.notes ?? "" },
                            set: { store.updateSessionNotes($0) }
                        )
                    )
                    .font(.system(size: 12))
                    .frame(minHeight: 180)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.04))
                    )
                }

                if let selectedTrack = store.selectedTrack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selected Track")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        detailRow("Name", selectedTrack.name)
                        detailRow("Input", selectedTrack.inputName ?? "None")
                        detailRow("FX", selectedTrack.fxChainNames.isEmpty ? "None queued" : selectedTrack.fxChainNames.joined(separator: ", "))
                        TextEditor(
                            text: Binding(
                                get: { store.selectedTrack?.notes ?? selectedTrack.notes },
                                set: { store.updateTrackNotes(selectedTrack.id, notes: $0) }
                            )
                        )
                        .font(.system(size: 12))
                        .frame(minHeight: 110)
                        .padding(6)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                        )
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    )
                }

                if let clip = store.selectedClip {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Selected Clip")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        TextField(
                            "Clip Name",
                            text: Binding(
                                get: { store.selectedClip?.name ?? clip.name },
                                set: { store.updateClipName(clip.id, name: $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)

                        HStack(spacing: 8) {
                            Button(store.previewingPath == clip.filePath ? "Stop Preview" : "Preview") {
                                if store.previewingPath == clip.filePath {
                                    store.stopPreview()
                                } else {
                                    store.previewAudio(at: clip.filePath)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button("Duplicate") {
                                store.duplicateClip(clip.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Reveal") {
                                store.revealBrowserPath(clip.filePath)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Spacer(minLength: 0)

                            Button("Remove", role: .destructive) {
                                store.removeClip(clip.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        detailRow("Track", store.selectedClipTrackName ?? "Unknown")
                        detailRow("Source", clip.sourceGroup)
                        detailRow("Duration", format(seconds: clip.durationSeconds))
                        clipSlider(
                            title: "Start",
                            valueText: formatDetailedTime(store.selectedClip?.startSeconds ?? clip.startSeconds),
                            value: Binding(
                                get: { store.selectedClip?.startSeconds ?? clip.startSeconds },
                                set: { store.updateClipStartSeconds(clip.id, value: $0) }
                            ),
                            range: 0...max(store.activeSceneDurationSeconds, clip.startSeconds + clip.durationSeconds + 8),
                            step: 0.25
                        )
                        clipSlider(
                            title: "Gain",
                            valueText: String(format: "%+.1f dB", store.selectedClip?.gainDB ?? clip.gainDB),
                            value: Binding(
                                get: { store.selectedClip?.gainDB ?? clip.gainDB },
                                set: { store.updateClipGain(clip.id, value: $0) }
                            ),
                            range: -24...12,
                            step: 0.5
                        )
                        clipSlider(
                            title: "Fade In",
                            valueText: formatFade(store.selectedClip?.fadeInSeconds ?? clip.fadeInSeconds),
                            value: Binding(
                                get: { store.selectedClip?.fadeInSeconds ?? clip.fadeInSeconds },
                                set: { store.updateClipFadeIn(clip.id, value: $0) }
                            ),
                            range: 0...maxFade(for: store.selectedClip ?? clip),
                            step: 0.05
                        )
                        clipSlider(
                            title: "Fade Out",
                            valueText: formatFade(store.selectedClip?.fadeOutSeconds ?? clip.fadeOutSeconds),
                            value: Binding(
                                get: { store.selectedClip?.fadeOutSeconds ?? clip.fadeOutSeconds },
                                set: { store.updateClipFadeOut(clip.id, value: $0) }
                            ),
                            range: 0...maxFade(for: store.selectedClip ?? clip),
                            step: 0.05
                        )
                        detailRow("Path", clip.filePath)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.03))
                    )
                }
            }
            .padding(12)
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(OperaChromeTheme.textTertiary)
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textPrimary)
                .textSelection(.enabled)
        }
    }

    private func clipSlider(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textTertiary)
                Spacer()
                Text(valueText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private func format(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func formatFade(_ seconds: Double) -> String {
        String(format: "%.2fs", seconds)
    }

    private func formatDetailedTime(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainingSeconds = seconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%05.2f", minutes, remainingSeconds)
    }

    private func maxFade(for clip: MixClip) -> Double {
        max(min(clip.durationSeconds * 0.5, 8), 0.01)
    }
}
