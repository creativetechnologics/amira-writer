import Foundation

@available(macOS 26.0, *)
@MainActor
final class VersionManager {
    unowned let parent: ScoreStore

    init(parent: ScoreStore) { self.parent = parent }

    func selectPreviousMidi() {
        guard let current = parent.selectedMidiID, let idx = parent.midiAssets.firstIndex(where: { $0.id == current }), idx > 0 else { return }
        parent.setSelectedMidi(id: parent.midiAssets[idx - 1].id)
    }

    func selectNextMidi() {
        guard let current = parent.selectedMidiID, let idx = parent.midiAssets.firstIndex(where: { $0.id == current }), idx < parent.midiAssets.count - 1 else { return }
        parent.setSelectedMidi(id: parent.midiAssets[idx + 1].id)
    }

    func addSong(relativeTo referenceID: MidiAsset.ID?, position: SongInsertPosition) {}

    func deleteSong(midiID: MidiAsset.ID) {
        if let asset = parent.songAssets.first(where: { $0.id == midiID }) { parent.dirtySongPaths.remove(asset.relativePath) }
        parent.songAssets.removeAll { $0.id == midiID }
        parent.librettoFiles.removeAll { file in parent.songAssets.allSatisfy { $0.relativePath != file.relativePath } }
        if parent.selectedMidiID == midiID { parent.setSelectedMidi(id: parent.songAssets.first?.id) }
        parent.isDirty = true
    }

    func snapshotSongVersion(for midiID: MidiAsset.ID, label: String? = nil, saveType: VersionSaveType = .snapshot, markDirty: Bool = true) {
        guard let idx = parent.songAssets.firstIndex(where: { $0.id == midiID }) else { return }
        let songPath = parent.songAssets[idx].relativePath
        let playback: OWSPlaybackSnapshot? = midiID == parent.selectedMidiID ? parent.buildCurrentPlaybackSnapshot() : parent.songAssets[idx].document.activeVersion()?.playback
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let defaultLabel = label ?? "\(saveType == .autosave ? "Revision" : "Snapshot") \(formatter.string(from: Date()))"
        let lyrics = parent.librettoFiles.first(where: { $0.relativePath == songPath })?.content ?? ""
        let version = OWSVersionPayload(id: UUID(), label: defaultLabel, createdAt: Date(), updatedAt: Date(), lyrics: lyrics, saveType: saveType, userLabel: label, isBookmarked: false, playback: playback)
        parent.songAssets[idx].document.versions.insert(version, at: 0)
        parent.songAssets[idx].document.normalize()
        parent.dirtySongPaths.insert(songPath)
        if markDirty { parent.isDirty = true }
    }

    func versions(for midiID: MidiAsset.ID) -> [MidiAsset] { [] }

    func switchSongVersion(for midiID: MidiAsset.ID, to targetVersionID: MidiAsset.ID) {}

    func versionHistory(for songPath: String) -> [OWSVersionPayload] {
        guard let asset = parent.songAssets.first(where: { $0.relativePath == songPath }) else { return [] }
        return asset.document.versions.filter { $0.saveType != .autosave || $0.id == asset.document.activeVersionID }
    }

    func renameVersion(songPath: String, versionID: UUID, newLabel: String) {
        guard let songIdx = parent.songAssets.firstIndex(where: { $0.relativePath == songPath }),
              let vIdx = parent.songAssets[songIdx].document.versions.firstIndex(where: { $0.id == versionID }) else { return }
        parent.songAssets[songIdx].document.versions[vIdx].userLabel = newLabel
        parent.songAssets[songIdx].document.versions[vIdx].updatedAt = Date()
        parent.dirtySongPaths.insert(songPath)
        parent.isDirty = true
    }

    func toggleVersionBookmark(songPath: String, versionID: UUID) {
        guard let songIdx = parent.songAssets.firstIndex(where: { $0.relativePath == songPath }),
              let vIdx = parent.songAssets[songIdx].document.versions.firstIndex(where: { $0.id == versionID }) else { return }
        parent.songAssets[songIdx].document.versions[vIdx].isBookmarked.toggle()
        parent.dirtySongPaths.insert(songPath)
        parent.isDirty = true
    }

    func deleteVersion(songPath: String, versionID: UUID) {
        guard let songIdx = parent.songAssets.firstIndex(where: { $0.relativePath == songPath }) else { return }
        let wasActive = parent.songAssets[songIdx].document.activeVersionID == versionID
        let isSelectedSong = parent.songAssets[songIdx].id == parent.selectedMidiID
        if wasActive {
            let others = parent.songAssets[songIdx].document.versions.filter { $0.id != versionID }
            if let nextActive = others.first { parent.songAssets[songIdx].document.activeVersionID = nextActive.id }
        }
        parent.songAssets[songIdx].document.versions.removeAll { $0.id == versionID }
        parent.songAssets[songIdx].document.normalize()
        if wasActive && isSelectedSong {
            if let newActiveID = parent.songAssets[songIdx].document.activeVersionID { rollbackToVersion(songPath: songPath, versionID: newActiveID) }
            else { parent.pianoRollNotes.removeAll(); parent.pianoRollTrackNames.removeAll() }
        }
        parent.dirtySongPaths.insert(songPath)
        parent.isDirty = true
    }

    func rollbackToVersion(songPath: String, versionID: UUID) {
        guard let songIdx = parent.songAssets.firstIndex(where: { $0.relativePath == songPath }),
              let version = parent.songAssets[songIdx].document.versions.first(where: { $0.id == versionID }),
              let playback = version.playback else { return }
        if parent.songAssets[songIdx].id == parent.selectedMidiID {
            if parent.isPlaying { parent.stopPlayback() }
            parent.pianoRollNotes = playback.notes
            parent.pianoRollTrackNames = playback.trackNames
            parent.pianoRollChannelPrograms = playback.channelPrograms
            parent.pianoRollTrackChannelPrograms = playback.trackChannelPrograms
            parent.pianoRollLyricCues = playback.lyricCues
            parent.pianoRollLyricAlignments = playback.lyricAlignments ?? []
            parent.pianoRollAudioClips = playback.audioClips
            parent.pianoRollTempoEvents = playback.tempoEvents
            parent.ticksPerQuarter = max(1, playback.ticksPerQuarter)
            parent.pianoRollLengthTicks = max(playback.lengthTicks, parent.ticksPerQuarter * 8)
            parent.tempoBPM = parent.pianoRollTempoEvents.first?.bpm ?? 112
            parent.pianoRollTimeSignatures = playback.timeSignatureEvents ?? [TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)]
            parent.pianoRollKeySignatures = playback.keySignatureEvents ?? [KeySignatureEvent(tick: 0, sharpsFlats: 0, isMinor: false)]
            parent.pianoRollMarkers = playback.markers ?? []
            parent.channelPan = playback.channelPan ?? [:]
            parent.pianoRollAutomation = playback.automationData ?? PianoRollAutomationData()
            parent.scoreAnnotations = playback.scoreAnnotations ?? []
            if let libIdx = parent.librettoFiles.firstIndex(where: { $0.relativePath == songPath }) { parent.librettoFiles[libIdx].content = version.lyrics }
            parent.songAssets[songIdx].document.activeVersionID = versionID
            parent.dirtySongPaths.insert(songPath)
            parent.isDirty = true
        }
    }

    var hasPreviousVersionForSelectedSong: Bool {
        guard let path = parent.selectedMidiAsset?.relativePath else { return false }
        return versionHistory(for: path).count > 1
    }

    func restorePreviousVersionForSelectedSong() {
        guard let path = parent.selectedMidiAsset?.relativePath else { return }
        let versions = versionHistory(for: path)
        guard versions.count > 1 else { return }
        rollbackToVersion(songPath: path, versionID: versions[1].id)
    }

    var selectedSongVersionLabel: String? {
        guard let path = parent.selectedMidiAsset?.relativePath,
              let songAsset = parent.songAssets.first(where: { $0.relativePath == path }),
              let activeID = songAsset.document.activeVersionID,
              let version = songAsset.document.versions.first(where: { $0.id == activeID }) else { return nil }
        return version.displayName
    }

    func removeAllAutosaves(for midiID: MidiAsset.ID) {
        guard let idx = parent.songAssets.firstIndex(where: { $0.id == midiID }) else { return }
        parent.songAssets[idx].document.versions.removeAll { $0.saveType == .autosave }
        parent.songAssets[idx].document.normalize()
        parent.dirtySongPaths.insert(parent.songAssets[idx].relativePath)
        parent.isDirty = true
    }
}
