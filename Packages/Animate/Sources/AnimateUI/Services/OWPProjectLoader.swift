import Foundation

/// Loads OWP project packages and extracts data relevant for animation:
/// characters, song list, lyric alignment, and tempo data.
struct OWPProjectLoader: Sendable {

    struct LoadResult: Sendable {
        var characters: [OPWCharacter]
        var songs: [OWPSongStub]
        var indexFile: OWPIndexFile?
        var instrumentMappings: [OWPInstrumentMapping]
    }

    func load(from url: URL) async throws -> LoadResult {
        let fm = FileManager.default

        // Load characters.json
        let characters = try loadCharacters(from: url, fm: fm)

        // Load index.json
        let indexFile = try loadIndex(from: url, fm: fm)
        let instrumentMappings = indexFile?.instrumentMappings ?? []

        // Discover .ows song files
        let songs = try discoverSongs(in: url, fm: fm)

        return LoadResult(
            characters: characters,
            songs: songs,
            indexFile: indexFile,
            instrumentMappings: instrumentMappings
        )
    }

    /// Load full song data from an OWS file for lip sync and timing.
    func loadSongData(from owsURL: URL) async throws -> OWSSongData {
        let data = try Data(contentsOf: owsURL)

        // OWS files are JSON with versioned payloads
        // Try to decode the relevant fields
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        var songData = OWSSongData()
        songData.title = owsURL.deletingPathExtension().lastPathComponent

        // Extract from the latest version's playback snapshot
        if let versions = json?["versions"] as? [[String: Any]],
           let latest = versions.last,
           let snapshot = latest["playbackSnapshot"] as? [String: Any] {

            if let tpq = snapshot["ticksPerQuarter"] as? Int {
                songData.ticksPerQuarter = tpq
            }

            // Decode tempo events
            if let tempoData = try? JSONSerialization.data(withJSONObject: snapshot["tempoEvents"] ?? []),
               let tempoEvents = try? JSONDecoder().decode([OWPTempoPoint].self, from: tempoData) {
                songData.tempoEvents = tempoEvents
            }

            // Decode notes (for timing reference)
            if let notesData = try? JSONSerialization.data(withJSONObject: snapshot["notes"] ?? []),
               let notes = try? JSONDecoder().decode([OWPNote].self, from: notesData) {
                songData.notes = notes
                if let maxEnd = notes.map({ $0.startTick + $0.duration }).max() {
                    songData.lengthTicks = maxEnd
                }
            }

            // Decode track names
            if let trackNamesRaw = snapshot["trackNames"] as? [String: String] {
                for (key, value) in trackNamesRaw {
                    if let intKey = Int(key) {
                        songData.trackNames[intKey] = value
                    }
                }
            }

            // Decode lyric alignments
            if let alignData = try? JSONSerialization.data(withJSONObject: snapshot["lyricAlignments"] ?? []),
               let alignments = try? JSONDecoder().decode([OWPLyricAlignment].self, from: alignData) {
                songData.lyricAlignments = alignments
            }

            // Try to extract stored lyrics text (various possible field names)
            if let lyrics = snapshot["lyrics"] as? String {
                songData.lyricsText = lyrics
            } else if let lyrics = snapshot["librettoText"] as? String {
                songData.lyricsText = lyrics
            } else if let lyricsLines = snapshot["lyricsLines"] as? [String] {
                songData.lyricsText = lyricsLines.joined(separator: "\n")
            }
        }

        // Also check at version level for lyrics
        if songData.lyricsText == nil,
           let versions = json?["versions"] as? [[String: Any]],
           let latest = versions.last {
            if let lyrics = latest["lyrics"] as? String {
                songData.lyricsText = lyrics
            } else if let lyrics = latest["librettoText"] as? String {
                songData.lyricsText = lyrics
            }
        }

        return songData
    }

    // MARK: - Private

    private func loadCharacters(from projectURL: URL, fm: FileManager) throws -> [OPWCharacter] {
        let candidatePaths = ["Characters/characters.json", "characters.json"]
        for candidatePath in candidatePaths {
            let charactersURL = projectURL.appendingPathComponent(candidatePath)
            guard fm.fileExists(atPath: charactersURL.path) else { continue }
            let data = try Data(contentsOf: charactersURL)
            let file = try JSONDecoder().decode(OPWCharactersFile.self, from: data)
            return file.characters
        }
        return []
    }

    private func loadIndex(from projectURL: URL, fm: FileManager) throws -> OWPIndexFile? {
        let indexURL = projectURL.appendingPathComponent("index.json")
        guard fm.fileExists(atPath: indexURL.path) else { return nil }
        let data = try Data(contentsOf: indexURL)
        return try JSONDecoder().decode(OWPIndexFile.self, from: data)
    }

    private func discoverSongs(in projectURL: URL, fm: FileManager) throws -> [OWPSongStub] {
        var songs: [OWPSongStub] = []
        
        // Only look in the Songs directory (same behavior as Score workspace)
        let songsURL = projectURL.appendingPathComponent("Songs")
        guard fm.fileExists(atPath: songsURL.path) else { return [] }

        let enumerator = fm.enumerator(
            at: songsURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "ows" else { continue }
            // Skip SyncThing conflict files — matches Score, Write, and Mix behavior
            if fileURL.lastPathComponent.contains(".sync-conflict-") { continue }

            let relativePath = "Songs/" + fileURL.path.replacingOccurrences(
                of: songsURL.path + "/",
                with: ""
            )

            let displayName = fileURL.deletingPathExtension().lastPathComponent
            songs.append(OWPSongStub(
                id: UUID(),
                title: displayName.toTitleCase(),
                owsPath: relativePath,
                durationTicks: nil
            ))
        }

        return songs.sorted { $0.owsPath < $1.owsPath }
    }
}

// MARK: - String Helper

extension String {
    func toTitleCase() -> String {
        let words = self.split(separator: " ")
        return words.map { word in
            let s = String(word)
            if s.allSatisfy(\.isNumber) { return s }
            return s.prefix(1).uppercased() + s.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
