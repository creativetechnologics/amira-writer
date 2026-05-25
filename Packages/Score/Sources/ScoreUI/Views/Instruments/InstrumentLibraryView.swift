import SwiftUI
import AudioToolbox

/// Unified instrument library browser: SF2 presets + Audio Unit instruments in one searchable panel.
@available(macOS 26.0, *)
struct InstrumentLibraryView: View {
    @Bindable var store: ScoreStore
    let channelKey: String
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var selectedTab: InstrumentTab = .soundfonts
    @State private var favoriteIDs: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "instrumentLibrary.favorites") ?? [])
    }()

    enum InstrumentTab: String, CaseIterable {
        case favorites = "Favorites"
        case soundfonts = "SoundFonts"
        case audioUnits = "Audio Units"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Instrument Library")
                    .font(.headline)
                Spacer()
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button("Done") { dismiss() }
            }
            .padding()

            // Tab picker
            Picker("", selection: $selectedTab) {
                ForEach(InstrumentTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Divider().padding(.top, 8)

            // Content
            switch selectedTab {
            case .favorites:
                favoritesView
            case .soundfonts:
                soundfontListView
            case .audioUnits:
                audioUnitListView
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    // MARK: - Favorites

    private var favoritesView: some View {
        let favSF2 = allSF2Entries.filter { favoriteIDs.contains("sf2:\($0.file):\($0.preset.id)") }
        let favAU = store.audioUnitManager.instruments.filter { favoriteIDs.contains("au:\($0.id)") }

        return List {
            if favSF2.isEmpty && favAU.isEmpty {
                Text("No favorites yet. Star instruments to add them here.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            }
            Section("SoundFonts") {
                ForEach(favSF2, id: \.uniqueID) { entry in
                    sf2Row(entry: entry)
                }
            }
            Section("Audio Units") {
                ForEach(favAU) { au in
                    auRow(au: au)
                }
            }
        }
    }

    // MARK: - SoundFont List

    private struct SF2Entry {
        let file: String
        let preset: SF2Preset
        var uniqueID: String { "sf2:\(file):\(preset.id)" }
    }

    private var allSF2Entries: [SF2Entry] {
        store.sf2PresetCache.flatMap { (file, presets) in
            presets.map { SF2Entry(file: file, preset: $0) }
        }
    }

    private var filteredSF2: [SF2Entry] {
        let entries = allSF2Entries
        if searchText.isEmpty { return entries }
        let q = searchText.lowercased()
        return entries.filter {
            $0.preset.name.lowercased().contains(q) || $0.file.lowercased().contains(q)
        }
    }

    private var soundfontListView: some View {
        List {
            ForEach(filteredSF2, id: \.uniqueID) { entry in
                sf2Row(entry: entry)
            }
        }
    }

    private func sf2Row(entry: SF2Entry) -> some View {
        HStack {
            Button(action: { toggleFavorite("sf2:\(entry.file):\(entry.preset.id)") }) {
                Image(systemName: favoriteIDs.contains("sf2:\(entry.file):\(entry.preset.id)") ? "star.fill" : "star")
                    .foregroundStyle(favoriteIDs.contains("sf2:\(entry.file):\(entry.preset.id)") ? .yellow : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.preset.name)
                    .font(.body.weight(.medium))
                Text("\(entry.file) — \(entry.preset.bankDisplayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Load") {
                loadSF2(entry: entry)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func loadSF2(entry: SF2Entry) {
        // Find the full path for this SF2 file
        if let fullPath = store.sf2PresetCache.keys.first(where: { ($0 as NSString).lastPathComponent == entry.file || $0 == entry.file }) {
            store.setMappingSoundFontPath(for: [channelKey], path: fullPath)
            store.instrumentMappings[channelKey]?.bankMSB = entry.preset.bankMSB
            store.instrumentMappings[channelKey]?.bankLSB = entry.preset.bankLSB
            store.instrumentMappings[channelKey]?.program = entry.preset.program
            store.isDirty = true
        }
        dismiss()
    }

    // MARK: - Audio Unit List

    private var filteredAU: [AudioUnitManager.AUInstrumentInfo] {
        let all = store.audioUnitManager.instruments
        if searchText.isEmpty { return all }
        let q = searchText.lowercased()
        return all.filter {
            $0.name.lowercased().contains(q) || $0.manufacturerName.lowercased().contains(q)
        }
    }

    private var audioUnitListView: some View {
        List {
            ForEach(filteredAU) { au in
                auRow(au: au)
            }
        }
    }

    private func auRow(au: AudioUnitManager.AUInstrumentInfo) -> some View {
        HStack {
            Button(action: { toggleFavorite("au:\(au.id)") }) {
                Image(systemName: favoriteIDs.contains("au:\(au.id)") ? "star.fill" : "star")
                    .foregroundStyle(favoriteIDs.contains("au:\(au.id)") ? .yellow : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(au.name)
                    .font(.body.weight(.medium))
                Text(au.manufacturerName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Load") {
                store.setMappingAudioUnit(
                    for: [channelKey],
                    description: au.audioComponentDescription,
                    name: au.name
                )
                dismiss()
                // Auto-open the AU plugin UI
                store.openAudioUnitUI(for: channelKey)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - Favorites

    private func toggleFavorite(_ id: String) {
        if favoriteIDs.contains(id) {
            favoriteIDs.remove(id)
        } else {
            favoriteIDs.insert(id)
        }
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "instrumentLibrary.favorites")
    }
}
