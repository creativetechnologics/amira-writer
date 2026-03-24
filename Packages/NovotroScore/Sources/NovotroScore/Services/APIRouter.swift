import AudioToolbox
import Foundation

// MARK: - APIRouter

/// Routes HTTP requests to handler functions that operate on ScoreStore.
/// All handlers run on @MainActor to safely access the store.
@available(macOS 26.0, *)
@MainActor
final class APIRouter {
    private weak var store: ScoreStore?

    init(store: ScoreStore) {
        self.store = store
    }

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        let method = request.method.uppercased()
        let path = request.path

        // Handle CORS preflight requests
        if method == "OPTIONS" {
            var resp = HTTPResponse.ok("{}")
            resp.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
            resp.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"
            resp.headers["Access-Control-Max-Age"] = "3600"
            return resp
        }

        switch (method, path) {
        // Read endpoints
        case ("GET", "/api/status"):         return getStatus(request)
        case ("GET", "/api/songs"):          return getSongs(request)
        case ("GET", "/api/song/notes"):     return getNotes(request)
        case ("GET", "/api/song/tracks"):    return getTracks(request)
        case ("GET", "/api/song/instruments"): return getInstruments(request)
        case ("GET", "/api/song/tempo"):     return getTempo(request)
        case ("GET", "/api/song/lyrics"):    return getLyrics(request)
        case ("GET", "/api/song/markers"):   return getMarkers(request)
        case ("GET", "/api/song/annotations"):       return getAnnotations(request)
        case ("POST", "/api/song/annotations/add"):  return addAnnotation(request)
        case ("POST", "/api/song/annotations/delete"): return deleteAnnotation(request)
        case ("GET", "/api/song/audio-clips"): return getAudioClips(request)
        case ("GET", "/api/song/suno-splits"): return getSunoSplits(request)
        case ("GET", "/api/song/versions"):  return getVersions(request)
        case ("GET", "/api/soundfonts"):     return getSoundfonts(request)
        case ("GET", "/api/audio-units"):    return getAudioUnits(request)
        case ("GET", "/api/audio-units/state"): return await getAudioUnitState(request)

        // Write endpoints
        case ("POST", "/api/song/notes/add"):         return addNotes(request)
        case ("POST", "/api/song/notes/delete"):      return deleteNotes(request)
        case ("POST", "/api/song/notes/update"):      return updateNotes(request)
        case ("POST", "/api/song/notes/replace-all"): return replaceAllNotes(request)
        case ("POST", "/api/song/tracks/rename"):     return renameTrack(request)
        case ("POST", "/api/song/instruments/set"):   return setInstrument(request)
        case ("POST", "/api/song/tempo/set"):         return setTempo(request)
        case ("POST", "/api/song/suno-splits/set"):   return setSunoSplits(request)
        case ("POST", "/api/song/select"):            return selectSong(request)
        case ("POST", "/api/song/undo"):               return undoAction(request)
        case ("POST", "/api/song/redo"):               return redoAction(request)
        case ("POST", "/api/song/notes/quantize"):     return quantizeNotes(request)

        // Action endpoints
        case ("POST", "/api/playback/play"):  return playbackPlay(request)
        case ("POST", "/api/playback/stop"):  return playbackStop(request)
        case ("POST", "/api/playback/seek"):  return playbackSeek(request)
        case ("POST", "/api/playback/continuous-play"): return playbackSetContinuousPlay(request)
        case ("GET",  "/api/playback/continuous-play"): return playbackGetContinuousPlay(request)
        case ("POST", "/api/playback/loop"): return playbackSetLoop(request)
        case ("GET",  "/api/playback/loop"): return playbackGetLoop(request)
        case ("POST", "/api/playback/practice-tempo"): return playbackSetPracticeTempo(request)
        case ("GET",  "/api/playback/practice-tempo"): return playbackGetPracticeTempo(request)
        case ("POST", "/api/song/markers/add"):          return addRehearsalMarker(request)
        case ("POST", "/api/song/markers/delete"):       return deleteRehearsalMarker(request)
        case ("POST", "/api/playback/jump-to-marker"):   return jumpToMarker(request)
        case ("GET",  "/api/playback/meter"):           return await playbackGetMeter(request)
        case ("POST", "/api/export/wav"):     return await exportWav(request)
        case ("POST", "/api/export/rehearsal"): return await exportRehearsalTrack(request)
        case ("POST", "/api/export/stems"):    return await exportStems(request)
        case ("POST", "/api/export/suno-chunks"): return await exportSunoChunks(request)
        case ("POST", "/api/import/musicxml"): return importMusicXML(request)
        case ("POST", "/api/project/save"):   return projectSave(request)
        case ("POST", "/api/project/open"):   return await projectOpen(request)

        // Version endpoints
        case ("POST", "/api/song/versions/snapshot"): return snapshotVersion(request)
        case ("POST", "/api/song/versions/rollback"): return rollbackVersion(request)
        case ("POST", "/api/song/versions/delete"):   return deleteVersion(request)
        case ("POST", "/api/song/versions/rename"):   return renameVersion(request)
        case ("POST", "/api/audio-units/set"):        return setAudioUnit(request)

        // Mixer endpoints
        case ("POST", "/api/song/tracks/mute"):    return trackMute(request)
        case ("POST", "/api/song/tracks/solo"):    return trackSolo(request)
        case ("POST", "/api/song/tracks/clear-solo"): return trackClearSolo(request)
        case ("POST", "/api/song/tracks/pan"):     return trackPan(request)
        case ("POST", "/api/playback/volume"):     return setMasterVolume(request)
        case ("GET",  "/api/playback/volume"):     return getMasterVolume(request)

        // Song management
        case ("POST", "/api/song/delete"):         return deleteSong(request)

        // Instrument mode endpoints
        case ("GET",  "/api/instruments/mode"):      return getInstrumentMode(request)
        case ("POST", "/api/instruments/mode"):      return setInstrumentMode(request)

        // Debug endpoints
        case ("GET",  "/api/debug/playback-state"): return debugPlaybackState(request)
        case ("POST", "/api/debug/try-play"):        return debugTryPlay(request)

        default:
            return .error(404, "Unknown endpoint: \(method) \(path)")
        }
    }

    // MARK: - Guard Helpers

    private func requireStore() -> ScoreStore? {
        guard let store else {
            return nil
        }
        return store
    }

    private func requireSong() -> (ScoreStore, String)? {
        guard let store = requireStore() else { return nil }
        guard let path = store.selectedMidiAsset?.relativePath else { return nil }
        return (store, path)
    }

    /// Extend `pianoRollLengthTicks` to cover all notes plus a 2-bar tail.
    /// Uses overflow-safe arithmetic; caps at 40,000,000 consistent with OWSPlaybackSnapshot deserialization.
    private func extendLengthIfNeeded(_ store: ScoreStore) {
        let maxEnd = store.pianoRollNotes.compactMap { note -> Int? in
            let (end, overflow) = note.startTick.addingReportingOverflow(note.duration)
            return overflow ? nil : end
        }.max()
        guard let maxEnd else { return }
        let tail = store.ticksPerQuarter * 8  // 2 bars of 4/4
        let (needed, overflow) = maxEnd.addingReportingOverflow(tail)
        let capped = overflow ? 40_000_000 : min(needed, 40_000_000)
        if capped > store.pianoRollLengthTicks {
            store.pianoRollLengthTicks = capped
        }
    }

    /// Validate MIDI note input bounds. Returns an error response if invalid, nil if OK.
    private func validateNoteInput(_ n: APINewNote, index: Int) -> HTTPResponse? {
        if n.pitch < 0 || n.pitch > 127 {
            return .error(400, "Note[\(index)]: pitch \(n.pitch) out of range 0-127")
        }
        if n.velocity < 0 || n.velocity > 127 {
            return .error(400, "Note[\(index)]: velocity \(n.velocity) out of range 0-127")
        }
        if n.channel < 0 || n.channel > 15 {
            return .error(400, "Note[\(index)]: channel \(n.channel) out of range 0-15")
        }
        if n.duration < 1 {
            return .error(400, "Note[\(index)]: duration must be >= 1")
        }
        if n.startTick < 0 {
            return .error(400, "Note[\(index)]: startTick must be >= 0")
        }
        if n.trackIndex < 0 {
            return .error(400, "Note[\(index)]: trackIndex must be >= 0")
        }
        return nil
    }

    // MARK: - Read Endpoints

    private func getStatus(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let resp = APIStatusResponse(
            app: "Novotro Score",
            version: "1.0",
            apiPort: store.apiServer?.port ?? 19847,
            projectPath: store.projectURL?.path,
            projectName: store.metadata.name,
            selectedSongPath: store.selectedMidiAsset?.relativePath,
            selectedSongTitle: store.selectedMidiAsset?.displayName,
            isPlaying: store.isPlaying,
            songCount: store.songAssets.count
        )
        return .ok(resp)
    }

    private func getSongs(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let songs = store.songAssets.map { asset in
            let version = asset.document.activeVersion()
            let noteCount = version?.playback?.notes.count ?? 0
            let trackCount = Set((version?.playback?.notes ?? []).map(\.trackIndex)).count
            let hasLyrics = !(version?.lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return APISongSummary(
                id: asset.id.uuidString,
                relativePath: asset.relativePath,
                title: asset.displayName,
                noteCount: noteCount,
                trackCount: trackCount,
                versionCount: asset.document.versions.count,
                hasLyrics: hasLyrics
            )
        }
        return .ok(APISongListResponse(songs: songs))
    }

    private func getNotes(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        var notes = store.pianoRollNotes

        // Optional filters
        if let trackStr = req.queryParams["trackIndex"], let trackIndex = Int(trackStr) {
            notes = notes.filter { $0.trackIndex == trackIndex }
        }
        if let channelStr = req.queryParams["channel"], let channel = Int(channelStr) {
            notes = notes.filter { $0.channel == channel }
        }

        return .ok(APINotesResponse(notes: notes, totalCount: notes.count))
    }

    private func getTracks(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }

        var trackMap: [Int: (name: String?, channels: Set<Int>, noteCount: Int)] = [:]
        for note in store.pianoRollNotes {
            var entry = trackMap[note.trackIndex] ?? (name: nil, channels: [], noteCount: 0)
            entry.channels.insert(note.channel)
            entry.noteCount += 1
            entry.name = entry.name ?? store.pianoRollTrackNames[note.trackIndex]
            trackMap[note.trackIndex] = entry
        }
        // Include tracks with names but no notes
        for (idx, name) in store.pianoRollTrackNames {
            if trackMap[idx] == nil {
                trackMap[idx] = (name: name, channels: [], noteCount: 0)
            }
        }

        let tracks = trackMap.sorted(by: { $0.key < $1.key }).map { (idx, info) in
            APITrackInfo(
                trackIndex: idx,
                name: info.name,
                channels: info.channels.sorted(),
                noteCount: info.noteCount
            )
        }
        return .ok(APITracksResponse(tracks: tracks))
    }

    private func getInstruments(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        return .ok(APIInstrumentsResponse(
            mappings: store.instrumentMappings,
            channelKeyMap: store.pianoRollChannelKeyByTrackChannel
        ))
    }

    private func getTempo(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        return .ok(APITempoResponse(
            tempoBPM: store.tempoBPM,
            ticksPerQuarter: store.ticksPerQuarter,
            lengthTicks: store.pianoRollLengthTicks,
            tempoEvents: store.pianoRollTempoEvents,
            timeSignatures: store.pianoRollTimeSignatures,
            keySignatures: store.pianoRollKeySignatures
        ))
    }

    private func getLyrics(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        return .ok(APILyricsResponse(
            lyricCues: store.pianoRollLyricCues,
            alignments: store.pianoRollLyricAlignments,
            librettoText: store.selectedLibrettoFile?.content
        ))
    }

    private func getMarkers(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        return .ok(APIMarkersResponse(markers: store.pianoRollMarkers))
    }

    private func getAudioClips(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        return .ok(APIAudioClipsResponse(clips: store.pianoRollAudioClips))
    }

    private func getSunoSplits(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let chunks = store.computeSunoChunks().map { chunk in
            APISunoChunkInfo(
                startTick: chunk.startTick,
                endTick: chunk.endTick,
                durationSeconds: store.ticksToSeconds(chunk.endTick) - store.ticksToSeconds(chunk.startTick)
            )
        }
        return .ok(APISunoSplitsResponse(splitTicks: store.sunoSplitTicks, chunks: chunks))
    }

    private func getVersions(_ req: HTTPRequest) -> HTTPResponse {
        guard let (store, songPath) = requireSong() else { return .error(400, "No song selected") }
        let versions = store.versionHistory(for: songPath)
        let activeID = store.songAssets.first(where: { $0.relativePath == songPath })?.document.activeVersionID
        let infos = versions.map { v in
            APIVersionInfo(
                id: v.id.uuidString,
                label: v.label,
                userLabel: v.userLabel,
                saveType: v.saveType.rawValue,
                isBookmarked: v.isBookmarked,
                createdAt: v.createdAt,
                updatedAt: v.updatedAt
            )
        }
        return .ok(APIVersionsResponse(versions: infos, activeVersionID: activeID?.uuidString))
    }

    private func getSoundfonts(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let entries = store.sampleBrowserEntries
            .filter { ["sf2", "sf3", "dls"].contains($0.fileExtension.lowercased()) }
            .map { APISoundfontEntry(relativePath: $0.relativePath, fileName: $0.fileName, fileSize: $0.fileSize) }
        return .ok(APISoundfontsResponse(entries: entries))
    }

    private func getAudioUnits(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let instruments = store.audioUnitManager.instruments.map { au in
            APIAudioUnitInfo(
                name: au.name,
                manufacturerName: au.manufacturerName,
                componentType: au.componentType,
                componentSubType: au.componentSubType,
                manufacturer: au.manufacturer
            )
        }
        return .ok(APIAudioUnitsResponse(
            isScanning: store.audioUnitManager.isScanning,
            audioUnits: instruments
        ))
    }

    private func getAudioUnitState(_ req: HTTPRequest) async -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        return await withCheckedContinuation { continuation in
            store.playbackEngine.dumpAudioUnitState { entries in
                let json: [[String: String]] = entries
                continuation.resume(returning: .ok(json))
            }
        }
    }

    private func setAudioUnit(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APISetAudioUnitRequest.self) else {
            return .error(400, "Invalid request body")
        }

        let desc = AudioComponentDescription(
            componentType: body.componentType,
            componentSubType: body.componentSubType,
            componentManufacturer: body.manufacturer,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        let keys = body.mappingKeys
        guard !keys.isEmpty else {
            return .error(400, "mappingKeys must not be empty")
        }
        store.setMappingAudioUnit(for: keys, description: desc, name: body.name)
        return .ok(["message": "Audio Unit set for \(keys.count) mapping(s)"])
    }

    // MARK: - Write Endpoints

    private func addNotes(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let result = req.decodeBodyWithError(APIAddNotesRequest.self)
        guard let body = result.value else {
            return .error(400, "Invalid request body: \(result.errorMessage ?? "unknown error")")
        }
        guard !body.notes.isEmpty else {
            return .error(400, "Notes array is empty")
        }

        // Validate MIDI bounds
        for (i, n) in body.notes.enumerated() {
            if let err = validateNoteInput(n, index: i) { return err }
        }

        store.pushUndoState(label: "Add Notes")
        var newIDs: [String] = []
        for n in body.notes {
            let note = PianoRollNote(
                trackIndex: n.trackIndex,
                channel: n.channel,
                pitch: n.pitch,
                velocity: n.velocity,
                startTick: n.startTick,
                duration: n.duration,
                muted: n.muted ?? false,
                lyricSyllable: n.lyricSyllable
            )
            store.pianoRollNotes.append(note)
            newIDs.append(note.id.uuidString)
        }
        store.isDirty = true
        extendLengthIfNeeded(store)
        return .ok(APINoteIDsResponse(noteIDs: newIDs))
    }

    private func deleteNotes(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIDeleteNotesRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"noteIDs\": [...]}")
        }

        let idsToRemove = Set(body.noteIDs.compactMap { UUID(uuidString: $0) })
        if idsToRemove.count < body.noteIDs.count {
            let invalidCount = body.noteIDs.count - idsToRemove.count
            return .error(400, "\(invalidCount) invalid UUID(s) in noteIDs")
        }
        guard !idsToRemove.isEmpty else {
            return .ok(APISuccessResponse("Deleted 0 notes"))
        }
        store.pushUndoState(label: "Delete Notes")
        let before = store.pianoRollNotes.count
        store.pianoRollNotes.removeAll { idsToRemove.contains($0.id) }
        let removed = before - store.pianoRollNotes.count
        if removed > 0 { store.isDirty = true }
        return .ok(APISuccessResponse("Deleted \(removed) notes"))
    }

    private func updateNotes(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let result = req.decodeBodyWithError(APIUpdateNotesRequest.self)
        guard let body = result.value else {
            return .error(400, "Invalid request body: \(result.errorMessage ?? "unknown error")")
        }

        // Pass 1: Validate all patches before mutating any state
        var skippedIDs: [String] = []
        for (i, patch) in body.updates.enumerated() {
            if UUID(uuidString: patch.id) == nil {
                return .error(400, "Update[\(i)]: invalid UUID '\(patch.id)'")
            }
            if let v = patch.pitch, (v < 0 || v > 127) {
                return .error(400, "Update[\(i)]: pitch \(v) out of range 0-127")
            }
            if let v = patch.velocity, (v < 0 || v > 127) {
                return .error(400, "Update[\(i)]: velocity \(v) out of range 0-127")
            }
            if let v = patch.channel, (v < 0 || v > 15) {
                return .error(400, "Update[\(i)]: channel \(v) out of range 0-15")
            }
            if let v = patch.duration, v < 1 {
                return .error(400, "Update[\(i)]: duration must be >= 1")
            }
            if let v = patch.startTick, v < 0 {
                return .error(400, "Update[\(i)]: startTick must be >= 0")
            }
            if let v = patch.trackIndex, v < 0 {
                return .error(400, "Update[\(i)]: trackIndex must be >= 0")
            }
        }

        // Pass 2: Apply mutations (all validation passed)
        // Defer undo push until we confirm at least one note matched
        var undoPushed = false
        var updated = 0
        for patch in body.updates {
            guard let uuid = UUID(uuidString: patch.id),
                  let idx = store.pianoRollNotes.firstIndex(where: { $0.id == uuid }) else {
                skippedIDs.append(patch.id)
                continue
            }
            if !undoPushed {
                store.pushUndoState(label: "Update Notes")
                undoPushed = true
            }
            if let v = patch.trackIndex { store.pianoRollNotes[idx].trackIndex = v }
            if let v = patch.channel { store.pianoRollNotes[idx].channel = v }
            if let v = patch.pitch { store.pianoRollNotes[idx].pitch = v }
            if let v = patch.velocity { store.pianoRollNotes[idx].velocity = v }
            if let v = patch.startTick { store.pianoRollNotes[idx].startTick = v }
            if let v = patch.duration { store.pianoRollNotes[idx].duration = max(1, v) }
            if let v = patch.muted { store.pianoRollNotes[idx].muted = v }
            if let v = patch.lyricSyllable { store.pianoRollNotes[idx].lyricSyllable = v }
            updated += 1
        }
        if updated > 0 {
            store.isDirty = true
            extendLengthIfNeeded(store)
        }
        var message = "Updated \(updated) notes"
        if !skippedIDs.isEmpty {
            message += " (skipped \(skippedIDs.count) unmatched IDs)"
        }
        return .ok(APISuccessResponse(message))
    }

    private func replaceAllNotes(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let result = req.decodeBodyWithError(APIReplaceAllNotesRequest.self)
        guard let body = result.value else {
            return .error(400, "Invalid request body: \(result.errorMessage ?? "unknown error")")
        }
        guard !body.notes.isEmpty else {
            return .error(400, "Notes array is empty. Use /api/song/notes/delete to remove notes.")
        }

        // Validate MIDI bounds for all notes
        for (i, n) in body.notes.enumerated() {
            if let err = validateNoteInput(n, index: i) { return err }
        }

        store.pushUndoState(label: "Replace All Notes")
        store.pianoRollNotes = body.notes.map { n in
            PianoRollNote(
                trackIndex: n.trackIndex,
                channel: n.channel,
                pitch: n.pitch,
                velocity: n.velocity,
                startTick: n.startTick,
                duration: n.duration,
                muted: n.muted ?? false,
                lyricSyllable: n.lyricSyllable
            )
        }
        store.isDirty = true
        extendLengthIfNeeded(store)
        return .ok(APISuccessResponse("Replaced all notes (\(store.pianoRollNotes.count) total)"))
    }

    private func renameTrack(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIRenameTrackRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"trackIndex\": N, \"name\": \"...\"}")
        }
        guard body.trackIndex >= 0 else {
            return .error(400, "trackIndex must be >= 0")
        }
        let name = String(body.name.prefix(256))
        store.pianoRollTrackNames[body.trackIndex] = name
        store.isDirty = true
        return .ok(APISuccessResponse("Renamed track \(body.trackIndex) to \(name)"))
    }

    private func setInstrument(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let result = req.decodeBodyWithError(APISetInstrumentRequest.self)
        guard let body = result.value else {
            return .error(400, "Invalid request body: \(result.errorMessage ?? "unknown error")")
        }

        var mapping = store.instrumentMappings[body.mappingKey] ?? InstrumentMapping(
            channelKey: body.mappingKey,
            displayName: body.displayName.map { String($0.prefix(256)) } ?? body.mappingKey
        )
        if let v = body.displayName { mapping.displayName = String(v.prefix(256)) }
        if let v = body.sf2Path {
            // Validate file extension
            let ext = (v as NSString).pathExtension.lowercased()
            guard ["sf2", "sf3", "dls"].contains(ext) else {
                return .error(400, "sf2Path must have .sf2, .sf3, or .dls extension")
            }
            guard !v.contains("..") else {
                return .error(400, "sf2Path must not contain '..' components")
            }
            let portable = store.portableSoundFontReference(for: v)
            mapping.sf2Path = portable.runtimePath
            mapping.sf2FileName = portable.fileName
            mapping.instrumentSourceType = .soundFont
            var sf = mapping.soundFont ?? SoundFontAssignment()
            sf.sf2RelativePath = portable.relativePath
            sf.sf2FileName = portable.fileName
            sf.resolvedPath = portable.runtimePath
            mapping.soundFont = sf
        }
        if let v = body.bankMSB { mapping.bankMSB = min(max(v, 0), 127) }
        if let v = body.bankLSB { mapping.bankLSB = min(max(v, 0), 127) }
        if let v = body.program { mapping.program = min(max(v, 0), 127) }
        // Sync flat SF2 fields → nested soundFont struct so both stay consistent
        if body.sf2Path != nil || body.bankMSB != nil || body.bankLSB != nil || body.program != nil {
            var sf = mapping.soundFont ?? SoundFontAssignment()
            if let p = mapping.sf2Path {
                if sf.sf2RelativePath == nil, !p.hasPrefix("/") {
                    sf.sf2RelativePath = p
                }
                sf.sf2FileName = mapping.sf2FileName ?? (p as NSString).lastPathComponent
                sf.resolvedPath = p
            }
            sf.bankMSB = mapping.bankMSB
            sf.bankLSB = mapping.bankLSB
            sf.program = mapping.program
            mapping.soundFont = sf
        }
        if let v = body.gainDB { mapping.gainDB = min(max(v, -24), 12) }
        if let v = body.muted { mapping.muted = v }
        if let v = body.trackRole { mapping.trackRole = TrackRole(rawValue: v) ?? .instrument }

        store.instrumentMappings[body.mappingKey] = mapping
        store.isDirty = true
        return .ok(APISuccessResponse("Set instrument for \(body.mappingKey)"))
    }

    private func setTempo(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let result = req.decodeBodyWithError(APISetTempoRequest.self)
        guard let body = result.value else {
            return .error(400, "Invalid request body: \(result.errorMessage ?? "unknown error")")
        }

        // Validate BPM ranges
        if let bpm = body.initialTempoBPM {
            guard bpm >= 10 && bpm <= 500 else {
                return .error(400, "initialTempoBPM must be between 10 and 500")
            }
        }
        if let events = body.tempoEvents {
            for (i, e) in events.enumerated() {
                guard e.bpm >= 10 && e.bpm <= 500 else {
                    return .error(400, "tempoEvents[\(i)]: BPM \(e.bpm) out of range 10-500")
                }
            }
        }
        // Validate time signature denominators (must be a power of 2, >= 1)
        if let ts = body.timeSignatures {
            for (i, t) in ts.enumerated() {
                guard t.denominator > 0 && (t.denominator & (t.denominator - 1)) == 0 else {
                    return .error(400, "timeSignatures[\(i)]: denominator \(t.denominator) must be a power of 2")
                }
                guard t.numerator > 0 else {
                    return .error(400, "timeSignatures[\(i)]: numerator must be > 0")
                }
            }
        }

        if let tpq = body.ticksPerQuarter {
            guard tpq >= 1 && tpq <= 960 else {
                return .error(400, "ticksPerQuarter must be between 1 and 960")
            }
        }

        // Validate key signatures
        if let ks = body.keySignatures {
            for (i, k) in ks.enumerated() {
                guard k.sharpsFlats >= -7 && k.sharpsFlats <= 7 else {
                    return .error(400, "keySignatures[\(i)]: sharpsFlats \(k.sharpsFlats) out of range -7..7")
                }
                guard k.tick >= 0 else {
                    return .error(400, "keySignatures[\(i)]: tick must be >= 0")
                }
            }
        }
        // Validate tempo event ticks
        if let events = body.tempoEvents {
            for (i, e) in events.enumerated() {
                guard e.tick >= 0 else {
                    return .error(400, "tempoEvents[\(i)]: tick must be >= 0")
                }
            }
        }

        var changed = false
        if let events = body.tempoEvents { store.pianoRollTempoEvents = events; changed = true }
        if let bpm = body.initialTempoBPM { store.tempoBPM = bpm; changed = true }
        if let tpq = body.ticksPerQuarter { store.ticksPerQuarter = tpq; changed = true }
        if let ts = body.timeSignatures { store.pianoRollTimeSignatures = ts; changed = true }
        if let ks = body.keySignatures { store.pianoRollKeySignatures = ks; changed = true }
        if changed { store.isDirty = true }
        return .ok(APISuccessResponse("Tempo updated"))
    }

    private func setSunoSplits(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APISetSunoSplitsRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"splitTicks\": [...]}")
        }
        if let negative = body.splitTicks.first(where: { $0 < 0 }) {
            return .error(400, "splitTicks must be >= 0, got \(negative)")
        }
        store.sunoSplitTicks = body.splitTicks.sorted()
        store.isDirty = true
        return .ok(APISuccessResponse("Set \(store.sunoSplitTicks.count) suno split points"))
    }

    private func selectSong(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APISelectSongRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"index\": N} or {\"relativePath\": \"...\"}")
        }

        guard body.index != nil || body.relativePath != nil else {
            return .error(400, "Must provide 'index' or 'relativePath'")
        }

        let assets = store.songAssets
        var targetID: UUID?

        if let idx = body.index {
            guard idx >= 0, idx < assets.count else {
                return .error(400, "Index \(idx) out of range (0..<\(assets.count))")
            }
            targetID = assets[idx].id
        } else if let path = body.relativePath {
            targetID = assets.first(where: { $0.relativePath == path })?.id
        }

        guard let id = targetID else {
            return .error(404, "Song not found")
        }

        store.setSelectedMidi(id: id)
        return .ok(APISuccessResponse("Selected song"))
    }

    private func quantizeNotes(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct QuantizeRequest: Codable { var gridTicks: Int?; var noteIDs: [String]? }
        let body = req.decodeBody(QuantizeRequest.self)
        let grid = body?.gridTicks ?? max(1, store.ticksPerQuarter / 4)
        guard grid > 0 else { return .error(400, "gridTicks must be > 0") }

        let targetIDs: Set<UUID>
        if let ids = body?.noteIDs {
            targetIDs = Set(ids.compactMap { UUID(uuidString: $0) })
        } else {
            targetIDs = Set(store.pianoRollNotes.map(\.id))
        }

        store.pushUndoState(label: "Quantize")
        var count = 0
        for i in store.pianoRollNotes.indices {
            guard targetIDs.contains(store.pianoRollNotes[i].id) else { continue }
            let tick = store.pianoRollNotes[i].startTick
            store.pianoRollNotes[i].startTick = max(0, ((tick + grid / 2) / grid) * grid)
            count += 1
        }
        if count > 0 { store.isDirty = true }
        return .ok(APISuccessResponse("Quantized \(count) notes to grid \(grid)"))
    }

    private func undoAction(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard store.canUndo else { return .error(400, "Nothing to undo") }
        store.undo()
        return .ok(APISuccessResponse("Undo successful"))
    }

    private func redoAction(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard store.canRedo else { return .error(400, "Nothing to redo") }
        store.redo()
        return .ok(APISuccessResponse("Redo successful"))
    }

    // MARK: - Action Endpoints

    private func playbackPlay(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let body = req.decodeBody(APIPlaybackPlayRequest.self)
        let startTick = max(0, body?.startTick ?? 0)
        store.playPianoRoll(startTick: startTick)
        return .ok(APISuccessResponse("Playback started"))
    }

    private func playbackStop(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        store.stopPlayback()
        return .ok(APISuccessResponse("Playback stopped"))
    }

    private func playbackSeek(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIPlaybackSeekRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"tick\": N}")
        }
        let tick = max(0, body.tick)
        store.seekPlayback(to: tick)
        return .ok(APISuccessResponse("Seeked to tick \(tick)"))
    }

    private func playbackGetContinuousPlay(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        return .ok(["enabled": store.continuousPlay])
    }

    private func playbackSetContinuousPlay(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APISetContinuousPlayRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"enabled\": true/false}")
        }
        store.continuousPlay = body.enabled
        return .ok(APISuccessResponse("Continuous play set to \(body.enabled)"))
    }

    private func playbackGetLoop(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct LoopResponse: Codable {
            let enabled: Bool
            let regionStartTick: Int?
            let regionEndTick: Int?
        }
        return .ok(LoopResponse(enabled: store.loopPlayback, regionStartTick: store.loopRegionStart, regionEndTick: store.loopRegionEnd))
    }

    private func playbackSetLoop(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APISetLoopRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"enabled\": true/false}")
        }
        store.loopPlayback = body.enabled
        // A/B loop region support
        if let start = body.regionStartTick, let end = body.regionEndTick, end > start {
            store.setLoopRegion(start: start, end: end)
        } else if body.regionStartTick == nil && body.regionEndTick == nil {
            // Clear region if neither is provided (loop full song)
        } else if body.clearRegion == true {
            store.setLoopRegion(start: nil, end: nil)
        }
        return .ok(APISuccessResponse("Loop playback set to \(body.enabled)"))
    }

    // MARK: - Marker Navigation

    private func addRehearsalMarker(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct Request: Codable { var tick: Int; var name: String?; var colorHex: String? }
        guard let body = req.decodeBody(Request.self) else {
            return .error(400, "Expected {\"tick\": <int>, \"name\": \"...\", \"colorHex\": \"...\"}")
        }
        let marker = MixMarker(tick: body.tick, name: body.name ?? "", colorHex: body.colorHex)
        store.pianoRollMarkers.append(marker)
        store.pianoRollMarkers.sort { $0.tick < $1.tick }
        store.isDirty = true
        return .ok(APISuccessResponse("Marker added at tick \(body.tick)"))
    }

    private func deleteRehearsalMarker(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct Request: Codable { var id: String }
        guard let body = req.decodeBody(Request.self), let uuid = UUID(uuidString: body.id) else {
            return .error(400, "Expected {\"id\": \"<uuid>\"}")
        }
        store.pianoRollMarkers.removeAll { $0.id == uuid }
        store.isDirty = true
        return .ok(APISuccessResponse("Marker deleted"))
    }

    // MARK: - Score Annotations

    private func getAnnotations(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        return .ok(APIAnnotationsResponse(annotations: store.scoreAnnotations))
    }

    private func addAnnotation(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIAddAnnotationRequest.self) else {
            return .error(400, "Expected {\"tick\": <int>, \"text\": \"...\", \"kind\": \"dynamic|tempo|expression|rehearsal\"}")
        }
        let kind = ScoreAnnotationKind(rawValue: body.kind ?? "expression") ?? .expression
        let annotation = ScoreAnnotation(tick: body.tick, text: body.text, kind: kind, trackIndex: body.trackIndex)
        store.scoreAnnotations.append(annotation)
        store.scoreAnnotations.sort(by: { $0.tick < $1.tick })
        store.isDirty = true
        return .ok(APISuccessResponse("Annotation added"))
    }

    private func deleteAnnotation(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIDeleteAnnotationRequest.self),
              let uuid = UUID(uuidString: body.annotationID) else {
            return .error(400, "Expected {\"annotationID\": \"<uuid>\"}")
        }
        store.scoreAnnotations.removeAll { $0.id == uuid }
        store.isDirty = true
        return .ok(APISuccessResponse("Annotation deleted"))
    }

    private func jumpToMarker(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct Request: Codable { var direction: String?; var tick: Int? }
        guard let body = req.decodeBody(Request.self) else {
            return .error(400, "Expected {\"direction\": \"next\"/\"previous\"} or {\"tick\": <int>}")
        }
        if let tick = body.tick {
            store.seekToMarkerTick(tick)
        } else if body.direction == "next" {
            store.jumpToNextMarker()
        } else if body.direction == "previous" {
            store.jumpToPreviousMarker()
        } else {
            return .error(400, "Provide direction (next/previous) or tick")
        }
        return .ok(APISuccessResponse("Jumped to marker"))
    }

    private func playbackGetPracticeTempo(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct Response: Codable { let scale: Double; let percent: Int }
        return .ok(Response(scale: store.practiceTempoScale, percent: Int(store.practiceTempoScale * 100)))
    }

    private func playbackSetPracticeTempo(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct Request: Codable { var scale: Double?; var percent: Int? }
        guard let body = req.decodeBody(Request.self) else {
            return .error(400, "Expected {\"scale\": 0.25-2.0} or {\"percent\": 25-200}")
        }
        let newScale: Double
        if let s = body.scale { newScale = s }
        else if let p = body.percent { newScale = Double(p) / 100.0 }
        else { return .error(400, "Provide scale or percent") }
        store.practiceTempoScale = max(0.25, min(2.0, newScale))
        return .ok(APISuccessResponse("Practice tempo set to \(Int(store.practiceTempoScale * 100))%"))
    }

    private func playbackGetMeter(_ req: HTTPRequest) async -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct MeterResponse: Codable {
            let isPlaying: Bool
            let masterPeakL: Float
            let masterPeakR: Float
            let masterRmsL: Float
            let masterRmsR: Float
            let hasSignal: Bool
        }
        let isPlaying = await MainActor.run { store.isPlaying }
        return await withCheckedContinuation { continuation in
            store.playbackEngine.getMeterLevels { _, master in
                let response = MeterResponse(
                    isPlaying: isPlaying,
                    masterPeakL: master.peakL,
                    masterPeakR: master.peakR,
                    masterRmsL:  master.rmsL,
                    masterRmsR:  master.rmsR,
                    hasSignal:   master.peakL > -60 || master.peakR > -60
                )
                continuation.resume(returning: .ok(response))
            }
        }
    }

    private func exportWav(_ req: HTTPRequest) async -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIExportWavRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"outputPath\": \"...\"}")
        }

        let notes = store.pianoRollNotes
        guard !notes.isEmpty else { return .error(400, "No notes to export") }

        let startTick = max(0, body.startTick ?? 0)
        let endTick = body.endTick ?? (notes.map { $0.startTick + $0.duration }.max() ?? 0)

        guard endTick > startTick else {
            return .error(400, "endTick (\(endTick)) must be greater than startTick (\(startTick))")
        }

        // Reject paths with traversal components for safety
        guard !body.outputPath.contains("..") else {
            return .error(400, "Path must not contain '..' components")
        }
        if let p = body.overrideSF2Path {
            let ext = (p as NSString).pathExtension.lowercased()
            guard ["sf2", "sf3", "dls"].contains(ext) else {
                return .error(400, "overrideSF2Path must have .sf2, .sf3, or .dls extension")
            }
            guard !p.contains("..") else {
                return .error(400, "overrideSF2Path must not contain '..' components")
            }
        }
        let outputURL = URL(fileURLWithPath: body.outputPath)

        // Ensure parent directory exists
        let parentDir = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        do {
            try await store.renderChunkToWav(
                notes: notes,
                startTick: startTick,
                endTick: endTick,
                outputURL: outputURL,
                overrideSF2Path: body.overrideSF2Path
            )
            return .ok(APISuccessResponse("Exported WAV to \(body.outputPath)"))
        } catch {
            return .error(500, "Export failed: \(error.localizedDescription)")
        }
    }

    private func exportRehearsalTrack(_ req: HTTPRequest) async -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIExportRehearsalRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"outputPath\": \"...\"}")
        }

        let notes = store.pianoRollNotes
        guard !notes.isEmpty else { return .error(400, "No notes to export") }

        guard !body.outputPath.contains("..") else {
            return .error(400, "Path must not contain '..' components")
        }
        let outputURL = URL(fileURLWithPath: body.outputPath)

        let parentDir = outputURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

        let attenuation = body.accompanimentAttenuationDB ?? -12.0

        do {
            await store.exportRehearsalTrack(outputURL: outputURL, accompanimentAttenuationDB: attenuation)
            if store.fullMixExportStatus.hasPrefix("Export failed") {
                return .error(500, store.fullMixExportStatus)
            }
            return .ok(APISuccessResponse("Rehearsal track exported to \(body.outputPath)"))
        }
    }

    private func exportStems(_ req: HTTPRequest) async -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIExportStemsRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"outputDir\": \"...\"}")
        }
        guard !body.outputDir.contains("..") else {
            return .error(400, "Path must not contain '..' components")
        }

        let notes = store.pianoRollNotes
        guard !notes.isEmpty else { return .error(400, "No notes to export") }

        let outputURL = URL(fileURLWithPath: body.outputDir)
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        await store.exportStems(outputDir: outputURL)
        if store.fullMixExportStatus.hasPrefix("Export failed") {
            return .error(500, store.fullMixExportStatus)
        }
        return .ok(APISuccessResponse(store.fullMixExportStatus))
    }

    private func exportSunoChunks(_ req: HTTPRequest) async -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        // Validate outputDir if provided (reject path traversal)
        if let body = req.decodeBody(APIExportSunoChunksRequest.self), let dir = body.outputDir {
            guard !dir.contains("..") else {
                return .error(400, "outputDir must not contain '..' components")
            }
            // Custom outputDir is not yet implemented — reject rather than silently ignore
            return .error(501, "Custom outputDir is not yet supported. Exports go to ~/Desktop.")
        }
        await store.exportSunoChunks()
        return .ok(APISuccessResponse("Suno chunk export complete"))
    }

    private func importMusicXML(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct Request: Codable { var filePath: String }
        guard let body = req.decodeBody(Request.self) else {
            return .error(400, "Expected {\"filePath\": \"/path/to/file.xml\"}")
        }
        guard !body.filePath.contains("..") else {
            return .error(400, "Path must not contain '..' components")
        }
        let url = URL(fileURLWithPath: body.filePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error(404, "File not found: \(body.filePath)")
        }
        store.importMusicXML(url: url)
        return .ok(APISuccessResponse("Imported MusicXML from \(url.lastPathComponent)"))
    }

    private func projectSave(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard store.projectURL != nil else {
            return .error(400, "No project is open")
        }
        store.save()
        return .ok(APISuccessResponse("Save initiated"))
    }

    private func projectOpen(_ req: HTTPRequest) async -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIOpenProjectRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"path\": \"...\"}")
        }
        guard !body.path.contains("..") else {
            return .error(400, "Path must not contain '..' components")
        }

        let url = URL(fileURLWithPath: body.path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .error(404, "File not found: \(body.path)")
        }

        await store.loadProject(url: url)
        return .ok(APISuccessResponse("Opened project: \(body.path)"))
    }

    // MARK: - Version Endpoints

    private func snapshotVersion(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let midiID = store.selectedMidiID else { return .error(400, "No song selected") }

        let body = req.decodeBody(APISnapshotVersionRequest.self)
        let label = body?.label.map { String($0.prefix(256)) }
        store.snapshotSongVersion(for: midiID, label: label)
        return .ok(APISuccessResponse("Version snapshot created"))
    }

    private func rollbackVersion(_ req: HTTPRequest) -> HTTPResponse {
        guard let (store, songPath) = requireSong() else { return .error(400, "No song selected") }
        guard let body = req.decodeBody(APIRollbackVersionRequest.self),
              let versionID = UUID(uuidString: body.versionID) else {
            return .error(400, "Invalid request body. Expected {\"versionID\": \"...\"}")
        }

        // Verify the version exists and has playback data
        let versions = store.versionHistory(for: songPath)
        guard let version = versions.first(where: { $0.id == versionID }) else {
            return .error(404, "Version not found: \(body.versionID)")
        }
        guard version.playback != nil else {
            return .error(400, "Version has no playback snapshot data to restore")
        }

        store.rollbackToVersion(songPath: songPath, versionID: versionID)
        return .ok(APISuccessResponse("Rolled back to version \(body.versionID)"))
    }

    private func deleteVersion(_ req: HTTPRequest) -> HTTPResponse {
        guard let (store, songPath) = requireSong() else { return .error(400, "No song selected") }
        guard let body = req.decodeBody(APIDeleteVersionRequest.self),
              let versionID = UUID(uuidString: body.versionID) else {
            return .error(400, "Invalid request body. Expected {\"versionID\": \"...\"}")
        }

        // Verify version exists
        let versions = store.versionHistory(for: songPath)
        guard versions.contains(where: { $0.id == versionID }) else {
            return .error(404, "Version not found: \(body.versionID)")
        }

        // Store handles active-version deletion gracefully (switches to next version + restores state)
        store.deleteVersion(songPath: songPath, versionID: versionID)
        return .ok(APISuccessResponse("Deleted version \(body.versionID)"))
    }

    private func renameVersion(_ req: HTTPRequest) -> HTTPResponse {
        guard let (store, songPath) = requireSong() else { return .error(400, "No song selected") }
        guard let body = req.decodeBody(APIRenameVersionRequest.self),
              let versionID = UUID(uuidString: body.versionID) else {
            return .error(400, "Invalid request body")
        }

        // Verify version exists
        let versions = store.versionHistory(for: songPath)
        guard versions.contains(where: { $0.id == versionID }) else {
            return .error(404, "Version not found: \(body.versionID)")
        }

        let newLabel = String(body.newLabel.prefix(256))
        store.renameVersion(songPath: songPath, versionID: versionID, newLabel: newLabel)
        return .ok(APISuccessResponse("Renamed version"))
    }

    // MARK: - Mixer Endpoints

    private func trackMute(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APITrackMuteRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"trackIndex\": N}")
        }
        guard body.trackIndex >= 0 else {
            return .error(400, "trackIndex must be >= 0")
        }
        store.toggleTrackMute(body.trackIndex)
        let muted = store.mutedTracks.contains(body.trackIndex)
        return .ok(APISuccessResponse("Track \(body.trackIndex) \(muted ? "muted" : "unmuted")"))
    }

    private func trackSolo(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APITrackSoloRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"trackIndex\": N}")
        }
        guard body.trackIndex >= 0 else {
            return .error(400, "trackIndex must be >= 0")
        }
        store.toggleTrackSolo(body.trackIndex)
        let soloed = store.soloedTracks.contains(body.trackIndex)
        return .ok(APISuccessResponse("Track \(body.trackIndex) \(soloed ? "soloed" : "unsoloed")"))
    }

    private func trackClearSolo(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        store.clearSolo()
        return .ok(APISuccessResponse("Solo cleared"))
    }

    private func trackPan(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APITrackPanRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"mappingKey\": \"...\", \"pan\": -1.0...1.0}")
        }
        let pan = min(max(body.pan, -1.0), 1.0)
        store.setChannelPan(key: body.mappingKey, pan: pan)
        return .ok(APISuccessResponse("Pan set to \(pan) for \(body.mappingKey)"))
    }

    private func setMasterVolume(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIMasterVolumeRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"volume\": 0.0...1.0}")
        }
        let volume = min(max(body.volume, 0.0), 1.0)
        store.setMasterVolume(volume)
        return .ok(APISuccessResponse("Volume set to \(volume)"))
    }

    private func getMasterVolume(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        return .ok(["volume": store.masterVolume])
    }

    // MARK: - Song Management

    private func deleteSong(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        guard let body = req.decodeBody(APIDeleteSongRequest.self) else {
            return .error(400, "Invalid request body. Expected {\"songID\": \"...\"}")
        }
        guard let songID = UUID(uuidString: body.songID) else {
            return .error(400, "Invalid songID format")
        }
        guard store.midiAssets.contains(where: { $0.id == songID }) else {
            return .error(404, "Song not found: \(body.songID)")
        }
        store.deleteSong(midiID: songID)
        store.isDirty = true
        return .ok(APISuccessResponse("Song deleted"))
    }

    // MARK: - Debug Endpoints

    // MARK: - Instrument Mode

    private func getInstrumentMode(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct ModeResponse: Encodable {
            var mode: String
            var mappingCount: Int
        }
        return .ok(ModeResponse(
            mode: store.masterInstrumentMode == .soundFont ? "soundFont" : "audioUnit",
            mappingCount: store.instrumentMappings.count
        ))
    }

    private func setInstrumentMode(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        struct ModeRequest: Decodable {
            var mode: String  // "soundFont" or "audioUnit"
        }
        guard let body = req.body,
              let parsed = try? JSONDecoder().decode(ModeRequest.self, from: body) else {
            return .error(400, "Expected JSON body with 'mode': 'soundFont' or 'audioUnit'")
        }
        let newMode: InstrumentSourceType
        switch parsed.mode.lowercased() {
        case "soundfont", "sf2", "lightweight":
            newMode = .soundFont
        case "audiounit", "au", "heavyweight":
            newMode = .audioUnit
        default:
            return .error(400, "Unknown mode '\(parsed.mode)'. Use 'soundFont' or 'audioUnit'.")
        }
        store.setMasterInstrumentMode(newMode)
        struct ModeResult: Encodable {
            var previousMode: String
            var newMode: String
            var mappingCount: Int
        }
        let prev = store.masterInstrumentMode == newMode ? parsed.mode : (newMode == .soundFont ? "audioUnit" : "soundFont")
        return .ok(ModeResult(
            previousMode: prev,
            newMode: parsed.mode,
            mappingCount: store.instrumentMappings.count
        ))
    }

    // MARK: - Debug

    private func debugPlaybackState(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        return .ok(store.playbackDiagnostics())
    }

    private func debugTryPlay(_ req: HTTPRequest) -> HTTPResponse {
        guard let store = requireStore() else { return .error(500, "Store unavailable") }
        let before = store.playbackDiagnostics()
        store.playPianoRoll(startTick: 0, trackFilter: nil)
        let after = store.playbackDiagnostics()
        struct TryPlayResult: Encodable {
            var before: ScoreStore.PlaybackDiagnostics
            var after: ScoreStore.PlaybackDiagnostics
        }
        return .ok(TryPlayResult(before: before, after: after))
    }
}
