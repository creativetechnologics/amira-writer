#if os(macOS)
import SwiftUI
import NovotroProjectKit

@available(macOS 26.0, *)
private struct MiniMidiPreview: View {
    let notes: [PianoRollNote]
    let color: Color

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height

            guard !notes.isEmpty else { return }

            // Compute pitch range with ±2 padding
            var minPitch = 127
            var maxPitch = 0
            var maxTick = 0
            for note in notes {
                minPitch = min(minPitch, note.pitch)
                maxPitch = max(maxPitch, note.pitch)
                maxTick = max(maxTick, note.startTick + note.duration)
            }
            minPitch = max(0, minPitch - 2)
            maxPitch = min(127, maxPitch + 2)

            let pitchRange = CGFloat(max(1, maxPitch - minPitch))
            let totalTicks = CGFloat(max(1, maxTick))
            let noteH = max(1, h / pitchRange)

            // Resolve the SwiftUI Color to component values for velocity modulation
            let resolved = context.resolve(Text(" ").foregroundStyle(color))
            _ = resolved // just need the color below

            for note in notes {
                let nx = CGFloat(note.startTick) / totalTicks * w
                let nw = max(1, CGFloat(note.duration) / totalTicks * w)
                let pitchNorm = CGFloat(note.pitch - minPitch) / pitchRange
                let ny = h * (1.0 - pitchNorm) - noteH * 0.5

                let velFactor = 0.6 + 0.4 * (Double(note.velocity) / 127.0)
                let noteColor = color.opacity(velFactor)

                let rect = CGRect(x: nx, y: ny, width: nw, height: noteH)
                context.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(noteColor))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(0.30))
        )
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

@available(macOS 26.0, *)
private struct MiniVolumeKnob: View {
    @Binding var gainDB: Double
    let color: Color

    @GestureState private var dragStartDB: Double?

    private let minDB: Double = -24
    private let maxDB: Double = 12
    private let knobSize: CGFloat = 18

    private var normalized: Double {
        (gainDB - minDB) / (maxDB - minDB)
    }

    // Knob indicator angle: -135° (min) to +135° (max)
    private var angle: Angle {
        .degrees(-135 + normalized * 270)
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 1

            // Track arc (background)
            let trackPath = Path { p in
                p.addArc(center: center, radius: radius - 2,
                         startAngle: .degrees(135), endAngle: .degrees(45),
                         clockwise: false)
            }
            context.stroke(trackPath, with: .color(.white.opacity(0.15)), lineWidth: 2)

            // Value arc
            let valuePath = Path { p in
                p.addArc(center: center, radius: radius - 2,
                         startAngle: .degrees(135),
                         endAngle: .degrees(135 + normalized * 270),
                         clockwise: false)
            }
            context.stroke(valuePath, with: .color(color.opacity(0.8)), lineWidth: 2)

            // Indicator dot
            let dotAngle = angle + .degrees(180)  // offset for coordinate system
            let dotRadius: CGFloat = radius - 2
            let dotCenter = CGPoint(
                x: center.x + dotRadius * CGFloat(cos(dotAngle.radians)),
                y: center.y + dotRadius * CGFloat(sin(dotAngle.radians))
            )
            let dotRect = CGRect(x: dotCenter.x - 1.5, y: dotCenter.y - 1.5, width: 3, height: 3)
            context.fill(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.9)))
        }
        .frame(width: knobSize, height: knobSize)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .updating($dragStartDB) { _, state, _ in
                    if state == nil { state = gainDB }
                }
                .onChanged { value in
                    let start = dragStartDB ?? gainDB
                    let delta = -value.translation.height / 100.0 * (maxDB - minDB)
                    let newDB = min(maxDB, max(minDB, start + delta))
                    gainDB = (newDB * 2).rounded() / 2  // snap to 0.5 dB
                }
        )
        .help(String(format: "Volume: %.1f dB", gainDB))
    }
}

struct InstrumentMapEntry: Identifiable, Equatable {
    static func == (lhs: InstrumentMapEntry, rhs: InstrumentMapEntry) -> Bool {
        lhs.id == rhs.id
    }

    let id: String
    let primary: ProjectChannelProfile
    let profiles: [ProjectChannelProfile]
    let mappingKeys: [String]
    let soundFontPath: String?

    var title: String {
        if profiles.count > 1 {
            return "\(primary.displayName) +\(profiles.count - 1)"
        }
        return primary.displayName
    }

    var songCount: Int {
        Set(profiles.flatMap(\.songPaths)).count
    }

    var aliasSummary: [String] {
        Array(Set(profiles.flatMap(\.aliases))).sorted(by: {
            $0.localizedStandardCompare($1) == .orderedAscending
        })
    }
}

@available(macOS 26.0, *)
private enum ActiveSheet: Identifiable {
    case audioUnitBrowser(targetKeys: [String])
    case expressionMapEditor
    case fxChain(channelKey: String)
    case trackColor(TrackColorTarget)
    case rename(TrackRenameTarget)

    var id: String {
        switch self {
        case .audioUnitBrowser: return "audioUnitBrowser"
        case .expressionMapEditor: return "expressionMapEditor"
        case .fxChain: return "fxChain"
        case .trackColor(let t): return "trackColor-\(t.id)"
        case .rename(let t): return "rename-\(t.id)"
        }
    }
}

@available(macOS 26.0, *)
struct InstrumentMappingPanel: View {
    @Bindable var store: ScoreStore
    @Binding var selectedTrackFilter: Set<Int>

    @State private var selectedEntryID: String?
    @State private var draggingEntry: InstrumentMapEntry?
    @State private var hasChangedLocation = false
    @AppStorage("operawriter.sidebar.trackSettingsExpanded") private var isMappingEditorExpanded = false
    @State private var activeSheet: ActiveSheet?
    @State private var customTrackColorDraft: Color = Color(red: 0.26, green: 0.68, blue: 0.97)
    @State private var renameDraft: String = ""

    private let presetTrackColors: [Color] = [
        Color(red: 0.92, green: 0.25, blue: 0.27),
        Color(red: 0.97, green: 0.42, blue: 0.20),
        Color(red: 0.99, green: 0.63, blue: 0.18),
        Color(red: 0.98, green: 0.83, blue: 0.20),
        Color(red: 0.70, green: 0.86, blue: 0.18),
        Color(red: 0.40, green: 0.80, blue: 0.25),
        Color(red: 0.20, green: 0.79, blue: 0.46),
        Color(red: 0.19, green: 0.83, blue: 0.68),
        Color(red: 0.20, green: 0.76, blue: 0.88),
        Color(red: 0.18, green: 0.60, blue: 0.92),
        Color(red: 0.24, green: 0.47, blue: 0.94),
        Color(red: 0.40, green: 0.43, blue: 0.96),
        Color(red: 0.55, green: 0.41, blue: 0.96),
        Color(red: 0.73, green: 0.39, blue: 0.95),
        Color(red: 0.86, green: 0.35, blue: 0.90),
        Color(red: 0.95, green: 0.36, blue: 0.72),
        Color(red: 0.95, green: 0.49, blue: 0.56),
        Color(red: 0.63, green: 0.50, blue: 0.38),
        Color(red: 0.54, green: 0.60, blue: 0.67),
        Color(red: 0.78, green: 0.78, blue: 0.78)
    ]

    private var selectedSongPath: String? {
        store.selectedMidiAsset?.relativePath
    }

    private var sourceProfiles: [ProjectChannelProfile] {
        store.channelProfiles(scope: InstrumentProfileScope.allSongs, forSongPath: selectedSongPath)
    }

    private var entries: [InstrumentMapEntry] {
        buildEntries(from: sourceProfiles)
    }

    private var masterToggleHelp: String {
        let total = store.instrumentMappings.count
        let pinned = store.instrumentMappings.values.filter { $0.pinnedSource != nil }.count
        let switchable = total - pinned
        return "\(switchable)/\(total) tracks will switch (\(pinned) pinned)"
    }

    private var selectedEntry: InstrumentMapEntry? {
        guard let selectedEntryID else { return nil }
        return entries.first(where: { $0.id == selectedEntryID })
    }


    @ViewBuilder
    private func trackColorSwatch(for entry: InstrumentMapEntry) -> some View {
        let swatchColor = resolvedTrackColor(for: entry)

        Button {
            activeSheet = .trackColor(TrackColorTarget(
                id: entry.id,
                title: displayName(for: entry),
                mappingKeys: entry.mappingKeys,
                currentColor: swatchColor
            ))
            customTrackColorDraft = swatchColor
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(swatchColor.opacity(0.94))
                .frame(width: 16, height: 16)
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.white.opacity(0.40), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Track color")
    }

    private func orderedTrackPairs() -> [(pairKey: String, trackIndex: Int, mappingKey: String)] {
        store.pianoRollChannelKeyByTrackChannel
            .compactMap { pairKey, mappingKey -> (String, Int, String)? in
                let parts = pairKey.split(separator: ":")
                guard parts.count == 2, let trackIndex = Int(parts[0]) else {
                    return nil
                }
                return (pairKey, trackIndex, mappingKey)
            }
            .sorted {
                if $0.trackIndex != $1.trackIndex {
                    return $0.trackIndex < $1.trackIndex
                }
                return $0.pairKey.localizedStandardCompare($1.pairKey) == .orderedAscending
            }
    }

    private func representativeMappingKey(for entry: InstrumentMapEntry) -> String? {
        let validKeys = Set(entry.mappingKeys)
        for pair in orderedTrackPairs() {
            if validKeys.contains(pair.mappingKey) {
                return pair.mappingKey
            }
        }
        return entry.mappingKeys.first
    }

    private func representativeTrackIndex(for entry: InstrumentMapEntry) -> Int? {
        let validKeys = Set(entry.mappingKeys)
        for pair in orderedTrackPairs() {
            if validKeys.contains(pair.mappingKey) {
                return pair.trackIndex
            }
        }
        return nil
    }

    private func resolvedMappingColor(mappingKey: String?) -> Color? {
        guard let mappingKey else { return nil }
        if let hex = store.instrumentMappings[mappingKey]?.colorHex,
           let color = ColorHex.color(from: hex) {
            return color
        }
        return nil
    }

    /// Fallback palette matching noteColorSIMD in PianoRollViewController exactly.
    private func fallbackTrackPaletteColor(trackIndex: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.98, green: 0.42, blue: 0.35), // coral
            Color(red: 0.98, green: 0.73, blue: 0.24), // amber
            Color(red: 0.58, green: 0.87, blue: 0.29), // lime
            Color(red: 0.23, green: 0.82, blue: 0.63), // mint
            Color(red: 0.25, green: 0.71, blue: 0.99), // sky
            Color(red: 0.55, green: 0.78, blue: 0.55), // sage green (FL Studio default)
            Color(red: 0.80, green: 0.48, blue: 0.97), // violet
            Color(red: 0.98, green: 0.45, blue: 0.73), // magenta
            Color(red: 0.95, green: 0.60, blue: 0.35), // orange
            Color(red: 0.71, green: 0.90, blue: 0.42), // spring
            Color(red: 0.38, green: 0.89, blue: 0.89), // cyan
            Color(red: 0.45, green: 0.78, blue: 1.00), // pale blue
            Color(red: 0.65, green: 0.69, blue: 0.99), // lavender
            Color(red: 0.91, green: 0.56, blue: 0.96), // pink violet
            Color(red: 0.98, green: 0.67, blue: 0.62), // rose
            Color(red: 0.85, green: 0.84, blue: 0.34), // yellow green
        ]
        let opacity = 0.90 - (Double(abs(trackIndex) % 4) * 0.08)
        return palette[abs(trackIndex) % palette.count].opacity(max(0.45, opacity))
    }

    private func resolvedTrackColor(for entry: InstrumentMapEntry) -> Color {
        if let mappingKey = representativeMappingKey(for: entry),
           let color = resolvedMappingColor(mappingKey: mappingKey) {
            return color
        }
        if let mappingColor = ColorHex.color(from: store.mapping(for: entry.primary).colorHex) {
            return mappingColor
        }
        if let trackIndex = representativeTrackIndex(for: entry) {
            return fallbackTrackPaletteColor(trackIndex: trackIndex)
        }
        return Color(red: 0.26, green: 0.68, blue: 0.97)
    }

    private func gainBinding(for entry: InstrumentMapEntry) -> Binding<Double> {
        Binding(
            get: { store.mapping(for: entry.primary).gainDB },
            set: { store.setMappingGain(for: entry.mappingKeys, gainDB: $0) }
        )
    }

    private func notesForEntry(_ entry: InstrumentMapEntry) -> [PianoRollNote] {
        let validKeys = Set(entry.mappingKeys)
        // Build set of (trackIndex, channel) pairs that map to this instrument
        var pairs = Set<String>()
        for (pairKey, channelKey) in store.pianoRollChannelKeyByTrackChannel {
            if validKeys.contains(channelKey) {
                pairs.insert(pairKey)
            }
        }
        guard !pairs.isEmpty else { return [] }
        return store.pianoRollNotes.filter { note in
            pairs.contains("\(note.trackIndex):\(note.channel)")
        }
    }

    private func baseDisplayName(for entry: InstrumentMapEntry) -> String {
        let mappingName = store.mapping(for: entry.primary).displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mappingName.isEmpty {
            return mappingName
        }
        return entry.primary.displayName
    }

    private func displayName(for entry: InstrumentMapEntry) -> String {
        let base = baseDisplayName(for: entry)
        if entry.profiles.count > 1 {
            return "\(base) +\(entry.profiles.count - 1)"
        }
        return base
    }

    private func beginRename(entry: InstrumentMapEntry) {
        renameDraft = baseDisplayName(for: entry)
        activeSheet = .rename(TrackRenameTarget(
            id: entry.id,
            title: baseDisplayName(for: entry),
            mappingKeys: entry.mappingKeys
        ))
    }

    private func applyRename() {
        guard case .rename(let target) = activeSheet else { return }
        store.setMappingDisplayName(for: target.mappingKeys, name: renameDraft)
        activeSheet = nil
    }

    private func addInstrumentBelow(entry: InstrumentMapEntry) {
        let currentEntries = entries
        guard let idx = currentEntries.firstIndex(where: { $0.id == entry.id }) else { return }

        // Generate a unique channel key
        var counter = store.instrumentMappings.count + 1
        var newKey = "custom-\(counter)"
        while store.instrumentMappings[newKey] != nil { counter += 1; newKey = "custom-\(counter)" }

        // Compute sort order: insert between current and next entry
        let currentOrder = store.instrumentMappings[entry.primary.baseKey]?.effectiveSortOrder ?? (idx * 10)
        let nextOrder: Int
        if idx + 1 < currentEntries.count {
            let nextEntry = currentEntries[idx + 1]
            nextOrder = store.instrumentMappings[nextEntry.primary.baseKey]?.effectiveSortOrder ?? ((idx + 1) * 10)
        } else {
            nextOrder = currentOrder + 10
        }
        let insertOrder = (currentOrder + nextOrder) / 2

        // Reassign contiguous sort orders to avoid fractional accumulation
        reassignSortOrders(inserting: newKey, at: idx + 1)

        var mapping = InstrumentMapping(
            channelKey: newKey,
            displayName: "New Instrument",
            sortOrder: insertOrder
        )
        mapping.sortOrder = insertOrder
        store.instrumentMappings[newKey] = mapping
        store.isDirty = true
        store.rebuildProjectChannelRegistry()
        selectedEntryID = "name:\(newKey)"
    }

    private func removeInstrument(entry: InstrumentMapEntry) {
        for key in entry.mappingKeys {
            store.instrumentMappings.removeValue(forKey: key)
        }
        store.isDirty = true
        store.rebuildProjectChannelRegistry()
        if selectedEntryID == entry.id {
            selectedEntryID = entries.first?.id
        }
    }

    private func reorderEntry(draggedID: String, beforeID: String) {
        var currentEntries = entries
        guard let draggedIdx = currentEntries.firstIndex(where: { $0.id == draggedID }),
              let targetIdx = currentEntries.firstIndex(where: { $0.id == beforeID }),
              draggedIdx != targetIdx else { return }
        let dragged = currentEntries.remove(at: draggedIdx)
        let insertIdx = draggedIdx < targetIdx ? targetIdx - 1 : targetIdx
        currentEntries.insert(dragged, at: min(insertIdx, currentEntries.count))
        // Reassign sort orders based on new order
        for (i, entry) in currentEntries.enumerated() {
            store.instrumentMappings[entry.primary.baseKey]?.sortOrder = i
        }
        store.isDirty = true
        store.rebuildProjectChannelRegistry()
    }

    private func performReorder(draggedID: String, toIndex: Int) {
        var currentEntries = entries
        guard let draggedIdx = currentEntries.firstIndex(where: { $0.id == draggedID }) else { return }
        let dragged = currentEntries.remove(at: draggedIdx)
        let insertAt = draggedIdx < toIndex ? min(toIndex - 1, currentEntries.count) : min(toIndex, currentEntries.count)
        currentEntries.insert(dragged, at: insertAt)
        for (i, entry) in currentEntries.enumerated() {
            store.instrumentMappings[entry.primary.baseKey]?.sortOrder = i
        }
        store.isDirty = true
        store.rebuildProjectChannelRegistry()
    }

    private func moveInstrument(entry: InstrumentMapEntry, direction: Int) {
        let currentEntries = entries
        guard let idx = currentEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        let targetIdx = idx + direction
        guard targetIdx >= 0, targetIdx < currentEntries.count else { return }

        // Swap sort orders between the two entries
        let entryKey = entry.primary.baseKey
        let targetKey = currentEntries[targetIdx].primary.baseKey

        let entryOrder = store.instrumentMappings[entryKey]?.effectiveSortOrder ?? (idx * 10)
        let targetOrder = store.instrumentMappings[targetKey]?.effectiveSortOrder ?? (targetIdx * 10)

        store.instrumentMappings[entryKey]?.sortOrder = targetOrder
        store.instrumentMappings[targetKey]?.sortOrder = entryOrder
        store.isDirty = true
        store.rebuildProjectChannelRegistry()
    }

    /// Reassigns contiguous sort orders (0, 1, 2, ...) to all mappings based on current entry order,
    /// inserting a gap for a new key at the specified index.
    private func reassignSortOrders(inserting newKey: String, at insertIndex: Int) {
        let currentEntries = entries
        var order = 0
        for (i, entry) in currentEntries.enumerated() {
            if i == insertIndex { order += 1 }  // leave a slot
            store.instrumentMappings[entry.primary.baseKey]?.sortOrder = order
            order += 1
        }
    }

    private func soundFontDisplayName(_ path: String?) -> String {
        guard let path, !path.isEmpty else {
            return "No SF2/SF3/DLS selected"
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }


    private func trackColorPickerSheet(for target: TrackColorTarget) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Track Color")
                .font(.headline)
            Text(target.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            let columns = Array(repeating: GridItem(.flexible(minimum: 26, maximum: 40), spacing: 8), count: 5)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(presetTrackColors.enumerated()), id: \.offset) { _, color in
                    Button {
                        store.setMappingColorHex(for: target.mappingKeys, colorHex: ColorHex.hex(from: color))
                        customTrackColorDraft = color
                    } label: {
                        Circle()
                            .fill(color)
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.45), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Apply color")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ColorPicker("Custom Color", selection: $customTrackColorDraft, supportsOpacity: false)
                    .labelsHidden()

                Button("Apply Custom Color") {
                    store.setMappingColorHex(
                        for: target.mappingKeys,
                        colorHex: ColorHex.hex(from: customTrackColorDraft)
                    )
                }
                .buttonStyle(.borderedProminent)
            }

            HStack {
                Button("Clear Color") {
                    store.setMappingColorHex(for: target.mappingKeys, colorHex: nil)
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Done") {
                    activeSheet = nil
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Playback Engine")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(OperaChromeTheme.textTertiary)

                    HStack(spacing: 6) {
                        OperaChromeActionButton(
                            title: "Lightweight",
                            systemImage: "leaf",
                            isSelected: store.masterInstrumentMode == .soundFont
                        ) {
                            store.setMasterInstrumentMode(.soundFont)
                        }
                        OperaChromeActionButton(
                            title: "Heavyweight",
                            systemImage: "waveform",
                            isSelected: store.masterInstrumentMode == .audioUnit
                        ) {
                            store.setMasterInstrumentMode(.audioUnit)
                        }
                    }
                    .help(masterToggleHelp)
                }
                .padding(.bottom, 6)

                VStack(spacing: 2) {
                    HStack(spacing: 6) {
                        // Placeholder for volume knob column
                        Image(systemName: "circle.grid.cross")
                            .foregroundStyle(Color.white.opacity(0.55))
                            .frame(width: 18)

                        Text("All Tracks")
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: 8)

                        // Placeholder for speaker icon column (matches instrument rows)
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.clear)
                            .padding(.leading, 4)
                            .padding(.trailing, 1)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedTrackFilter.isEmpty ? Color.white.opacity(0.10) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedTrackFilter.removeAll()
                        store.clearSolo()
                        selectedEntryID = nil
                    }

                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        let trackIndex = representativeTrackIndex(for: entry)
                        // "Selected" = clicked for visual focus (ghost notes). All notes still play.
                        let isSelected = !selectedTrackFilter.isEmpty && trackIndex.map(selectedTrackFilter.contains) == true
                        // "Soloed" = audio isolation. Only soloed track(s) play.
                        let isSoloed = !store.soloedTracks.isEmpty && trackIndex.map(store.soloedTracks.contains) == true

                        VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                MiniVolumeKnob(gainDB: gainBinding(for: entry), color: resolvedTrackColor(for: entry))

                                HStack(spacing: 4) {
                                    Text(displayName(for: entry))
                                        .font(.caption)
                                        .lineLimit(1)
                                    if entry.soundFontPath != nil {
                                        Image(systemName: "waveform.path.badge.plus")
                                            .font(.system(size: 8))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                let entryNotes = notesForEntry(entry)
                                let trackColor = resolvedTrackColor(for: entry)
                                MiniMidiPreview(notes: entryNotes, color: trackColor)
                                    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)

                                // Speaker icon column — to the right of the mini map
                                Group {
                                    if let ti = trackIndex {
                                        let isMuted = store.mutedTracks.contains(ti)
                                        // Track is effectively silent if explicitly muted OR soloed-out
                                        let isSoloedOut = !store.soloedTracks.isEmpty && !store.soloedTracks.contains(ti)
                                        let isEffectivelyMuted = isMuted || isSoloedOut

                                        Image(systemName: isMuted
                                            ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(isEffectivelyMuted
                                                ? .secondary : .primary)
                                            .contentShape(Rectangle())
                                            .onTapGesture {
                                                store.toggleTrackMute(ti)
                                            }
                                            .contextMenu {
                                                Button(isSoloed ? "Unsolo" : "Solo") {
                                                    store.toggleTrackSolo(ti)
                                                }
                                                Button(isMuted ? "Unmute" : "Mute") {
                                                    store.toggleTrackMute(ti)
                                                }
                                            }
                                            .help(isMuted ? "Unmute · Right-click to solo" : "Mute · Right-click to solo")
                                    } else {
                                        Image(systemName: "speaker.wave.2.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.clear)
                                    }
                                }
                                .padding(.leading, 4)
                                .padding(.trailing, 1)
                            }
                            .opacity({
                                guard let ti = trackIndex else { return 1.0 }
                                if store.mutedTracks.contains(ti) { return 0.5 }
                                // Dim non-soloed tracks when a solo is active (audio dimming)
                                if !store.soloedTracks.isEmpty && !store.soloedTracks.contains(ti) { return 0.5 }
                                return 1.0
                            }())
                            .padding(.vertical, 4)
                            .padding(.horizontal, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(isSelected ? Color.white.opacity(0.10) : (selectedEntryID == entry.id ? Color.white.opacity(0.05) : Color.clear))
                            )
                            .opacity(hasChangedLocation && draggingEntry?.id == entry.id ? 0.5 : 1.0)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedEntryID = entry.id
                            if let trackIndex {
                                selectedTrackFilter = [trackIndex]
                            } else {
                                selectedTrackFilter.removeAll()
                            }
                        }
                        .onDrag {
                            draggingEntry = entry
                            return NSItemProvider(object: entry.id as NSString)
                        }
                        .onDrop(of: [.plainText], delegate: TrackReorderDropDelegate(
                            targetEntry: entry,
                            store: store,
                            entries: entries,
                            draggingEntry: $draggingEntry,
                            hasChangedLocation: $hasChangedLocation
                        ))
                        .contextMenu {
                            if let trackIndex {
                                Button(isSoloed ? "Unsolo" : "Solo") {
                                    store.toggleTrackSolo(trackIndex)
                                }
                            }
                            Button("Rename") {
                                beginRename(entry: entry)
                            }
                            Button("Track Color…") {
                                activeSheet = .trackColor(TrackColorTarget(
                                    id: entry.id,
                                    title: displayName(for: entry),
                                    mappingKeys: entry.mappingKeys,
                                    currentColor: resolvedTrackColor(for: entry)
                                ))
                                customTrackColorDraft = resolvedTrackColor(for: entry)
                            }
                            Divider()
                            Button("Move Up") {
                                moveInstrument(entry: entry, direction: -1)
                            }
                            .disabled(idx == 0)
                            Button("Move Down") {
                                moveInstrument(entry: entry, direction: 1)
                            }
                            .disabled(idx == entries.count - 1)
                            Divider()
                            Button("Add Instrument Below") {
                                addInstrumentBelow(entry: entry)
                            }
                            Button("Remove Instrument") {
                                removeInstrument(entry: entry)
                            }
                            .disabled(entries.count <= 1)
                        }
                    }

                }
                .padding(.vertical, 2)
                .onDrop(of: [.plainText], delegate: TrackReorderOutsideDelegate(
                    draggingEntry: $draggingEntry,
                    hasChangedLocation: $hasChangedLocation
                ))

            // Quick action buttons
            HStack(spacing: 6) {
                Button(action: { activeSheet = .expressionMapEditor }) {
                    Label("Expr Map", systemImage: "music.note.list")
                }
                .controlSize(.small)

                if let entry = selectedEntry, let key = entry.mappingKeys.first {
                    Button(action: {
                        activeSheet = .fxChain(channelKey: key)
                    }) {
                        Label("FX", systemImage: "waveform.path.ecg")
                    }
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            if let selectedEntry {
                mappingEditor(entry: selectedEntry)
            } else {
                ContentUnavailableView("Select a track", systemImage: "slider.horizontal.3")
                    .frame(maxHeight: 150)
            }
            }
            .padding(.horizontal, 6)
        }
        .onAppear {
            if selectedEntryID == nil {
                selectedEntryID = entries.first?.id
            }
        }
        .onChange(of: entries.map(\.id)) { _, ids in
            guard let selectedEntryID, ids.contains(selectedEntryID) else {
                self.selectedEntryID = ids.first
                return
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .audioUnitBrowser(let targetKeys):
                AudioUnitBrowserSheet(
                    store: store,
                    targetKeys: targetKeys,
                    onDismiss: { activeSheet = nil }
                )
            case .expressionMapEditor:
                ExpressionMapEditorView(store: store)
            case .fxChain(let channelKey):
                FXChainView(store: store, channelKey: channelKey)
            case .trackColor(let target):
                trackColorPickerSheet(for: target)
            case .rename:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Rename Track")
                        .font(.headline)

                    TextField("Track name", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            applyRename()
                        }

                    HStack {
                        Spacer()
                        Button("Cancel") {
                            activeSheet = nil
                        }
                        Button("Apply") {
                            applyRename()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(16)
                .frame(width: 340)
            }
        }
    }

    private func buildEntries(from profiles: [ProjectChannelProfile]) -> [InstrumentMapEntry] {
        var grouped: [String: [ProjectChannelProfile]] = [:]
        for profile in profiles {
            grouped[profile.baseKey, default: []].append(profile)
        }

        let built = grouped.keys
            .compactMap { baseKey -> InstrumentMapEntry? in
                guard let groupedProfiles = grouped[baseKey], let primary = groupedProfiles.first else {
                    return nil
                }
                let sortedProfiles = groupedProfiles.sorted {
                    $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }

                let mappingKeys = store.mappingKeysForBaseKey(baseKey)
                let soundFontPath = store.mapping(for: primary).sf2Path?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nilIfEmpty

                return InstrumentMapEntry(
                    id: "name:\(baseKey)",
                    primary: sortedProfiles[0],
                    profiles: sortedProfiles,
                    mappingKeys: mappingKeys,
                    soundFontPath: soundFontPath
                )
            }

        return built.sorted {
            let aRole = (store.mapping(for: $0.primary).trackRole == .vocal) ? 0 : 1
            let bRole = (store.mapping(for: $1.primary).trackRole == .vocal) ? 0 : 1
            if aRole != bRole { return aRole < bRole }

            let a = store.mapping(for: $0.primary).effectiveSortOrder
            let b = store.mapping(for: $1.primary).effectiveSortOrder
            if a != b { return a < b }
            return baseDisplayName(for: $0).localizedStandardCompare(baseDisplayName(for: $1)) == .orderedAscending
        }
    }

    private func mappingEditor(entry: InstrumentMapEntry) -> some View {
        let profile = entry.primary
        let mapping = store.mapping(for: profile)
        let keyTargets = entry.mappingKeys

        return VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup(isExpanded: $isMappingEditorExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    Group {
                        Text("Track Name")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextField(
                            "Display name",
                            text: Binding(
                                get: { store.mapping(for: profile).displayName },
                                set: { store.setMappingDisplayName(for: keyTargets, name: $0) }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    Picker(
                        "Track Type",
                        selection: Binding(
                            get: { store.mapping(for: profile).trackRole },
                            set: { store.setMappingTrackRole(for: keyTargets, trackRole: $0) }
                        )
                    ) {
                        ForEach(TrackRole.allCases) { role in
                            Text(role.title).tag(role)
                        }
                    }
                    .pickerStyle(.segmented)

                    if store.mapping(for: profile).trackRole == .vocal {
                        voiceConfigSection(profile: profile, keyTargets: keyTargets)
                    }

                    instrumentSection(mapping: mapping, keyTargets: keyTargets)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Gain \(String(format: "%.1f", store.mapping(for: profile).gainDB)) dB")
                            .font(.caption)
                        Slider(
                            value: Binding(
                                get: { store.mapping(for: profile).gainDB },
                                set: { store.setMappingGain(for: keyTargets, gainDB: $0) }
                            ),
                            in: -24...12,
                            step: 0.5
                        )
                    }

                    Toggle(
                        "Mute Track Mapping",
                        isOn: Binding(
                            get: { store.mapping(for: profile).muted },
                            set: { store.setMappingMuted(for: keyTargets, muted: $0) }
                        )
                    )
                    .font(.caption)

                }
                .padding(.top, 8)
            } label: {
                HStack {
                    Text("Track Settings")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }


    /// Resolve Audio Unit display name from component description.
    private func audioUnitDisplayName(for mapping: InstrumentMapping) -> String? {
        guard let desc = mapping.audioComponentDescription else { return nil }
        return store.audioUnitManager.instruments.first(where: {
            $0.componentSubType == desc.componentSubType &&
            $0.manufacturer == desc.componentManufacturer
        })?.name ?? mapping.displayName
    }

    /// Dual-slot instrument section: always-visible SoundFont + Audio Unit slots,
    /// active source toggle, and per-track pin override.
    private func instrumentSection(mapping: InstrumentMapping, keyTargets: [String]) -> some View {
        let isActive: (InstrumentSourceType) -> Bool = { $0 == mapping.effectiveSourceType }
        let hasSF2 = mapping.sf2Path != nil
        let hasAU = mapping.audioComponentDescription != nil
        let isIncomplete = (isActive(.soundFont) && !hasSF2) || (isActive(.audioUnit) && !hasAU)

        return VStack(alignment: .leading, spacing: 8) {
            // Header: Instrument + Pin toggle
            HStack {
                Text("Instrument")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Pin toggle
                Button {
                    let currentPinned = mapping.pinnedSource
                    if currentPinned != nil {
                        store.setMappingPinnedSource(for: keyTargets, pinned: nil)
                    } else {
                        store.setMappingPinnedSource(for: keyTargets, pinned: mapping.effectiveSourceType)
                    }
                } label: {
                    Image(systemName: mapping.pinnedSource != nil ? "pin.fill" : "pin")
                        .font(.caption)
                        .foregroundStyle(mapping.pinnedSource != nil ? .orange : .secondary)
                }
                .buttonStyle(.plain)
                .help(mapping.pinnedSource != nil
                    ? "Pinned — ignores master toggle. Click to unpin."
                    : "Pin this track — ignore master toggle")
            }

            // Active source toggle
            Picker("Active Source", selection: Binding<InstrumentSourceType>(
                get: { mapping.effectiveSourceType },
                set: { newType in
                    store.setMappingActiveSource(for: keyTargets, source: newType)
                }
            )) {
                Text("SoundFont").tag(InstrumentSourceType.soundFont)
                Text("Audio Unit").tag(InstrumentSourceType.audioUnit)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Incomplete badge
            if isIncomplete {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("Missing \(isActive(.soundFont) ? "SoundFont" : "Audio Unit") assignment")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            // Show only the active source's slot
            if isActive(.soundFont) {
                // SoundFont slot
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.zipper")
                            .font(.caption2)
                        Text("SoundFont")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    HStack {
                        if hasSF2 {
                            Text(soundFontDisplayName(mapping.sf2Path))
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                store.clearSoundFont(for: keyTargets)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove SoundFont")
                        } else {
                            Button("Choose SoundFont...") {
                                store.pickSoundFont(for: keyTargets)
                            }
                            .font(.caption)
                            .controlSize(.small)
                            Spacer()
                        }
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
            } else {
                // Audio Unit slot
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.caption2)
                        Text("Audio Unit")
                            .font(.caption)
                            .fontWeight(.medium)
                    }
                    HStack {
                        if hasAU, let auName = audioUnitDisplayName(for: mapping) {
                            Text(auName)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            if mapping.audioComponentDescription != nil {
                                Button {
                                    if let mappingKey = keyTargets.first {
                                        store.openAudioUnitUI(for: mappingKey)
                                    }
                                } label: {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Open Plugin UI")
                            }
                            Button {
                                store.clearAudioUnit(for: keyTargets)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove Audio Unit")
                        } else {
                            Button("Choose Audio Unit...") {
                                activeSheet = .audioUnitBrowser(targetKeys: keyTargets)
                            }
                            .font(.caption)
                            .controlSize(.small)
                            Spacer()
                        }
                    }
                }
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Voice Configuration (Vocal Tracks)

    @ViewBuilder
    private func voiceConfigSection(profile: ProjectChannelProfile, keyTargets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gender")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Gender", selection: Binding(
                    get: { store.mapping(for: profile).resolvedVocalGender },
                    set: { store.setMappingVocalGender(for: keyTargets, gender: $0) }
                )) {
                    ForEach(VocalGender.allCases) { gender in
                        Text(gender.title).tag(gender)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private struct TrackColorTarget: Identifiable {
    let id: String
    let title: String
    let mappingKeys: [String]
    let currentColor: Color
}

private struct TrackRenameTarget: Identifiable {
    let id: String
    let title: String
    let mappingKeys: [String]
}

// MARK: - Track Reorder Drop Delegates

@available(macOS 26.0, *)
struct TrackReorderDropDelegate: DropDelegate {
    let targetEntry: InstrumentMapEntry
    let store: ScoreStore
    let entries: [InstrumentMapEntry]
    @Binding var draggingEntry: InstrumentMapEntry?
    @Binding var hasChangedLocation: Bool

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingEntry,
              dragging.id != targetEntry.id,
              let fromIndex = entries.firstIndex(where: { $0.id == dragging.id }),
              let toIndex = entries.firstIndex(where: { $0.id == targetEntry.id })
        else { return }

        hasChangedLocation = true

        withAnimation(.default) {
            // Move the dragged entry to the target position by updating sort orders
            var reordered = entries
            reordered.move(fromOffsets: IndexSet(integer: fromIndex),
                          toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            for (i, entry) in reordered.enumerated() {
                store.instrumentMappings[entry.primary.baseKey]?.sortOrder = i
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        hasChangedLocation = false
        store.isDirty = true
        store.rebuildProjectChannelRegistry()
        draggingEntry = nil
        return true
    }

    func dropExited(info: DropInfo) {}

    func validateDrop(info: DropInfo) -> Bool {
        draggingEntry != nil
    }
}

@available(macOS 26.0, *)
struct TrackReorderOutsideDelegate: DropDelegate {
    @Binding var draggingEntry: InstrumentMapEntry?
    @Binding var hasChangedLocation: Bool

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        hasChangedLocation = false
        draggingEntry = nil
        return true
    }
}
#endif
