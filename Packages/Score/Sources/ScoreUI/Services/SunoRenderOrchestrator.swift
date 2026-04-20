import Foundation

/// Orchestrates the full Suno render pipeline for a song.
@available(macOS 26.0, *)
actor SunoRenderOrchestrator {
    private let store: ScoreStore
    private(set) var session: SunoRenderSession
    private var isCancelled = false

    var onProgress: (@Sendable (Int, Int, String) -> Void)?
    var onChunkError: (@Sendable (SunoChunkSpec, Error) -> Void)?

    init(store: ScoreStore, session: SunoRenderSession) {
        self.store = store
        self.session = session
    }

    func setProgressCallback(_ callback: @escaping @Sendable (Int, Int, String) -> Void) {
        onProgress = callback
    }

    func setErrorCallback(_ callback: @escaping @Sendable (SunoChunkSpec, Error) -> Void) {
        onChunkError = callback
    }

    func execute() async throws -> SunoRenderSession {
        // Step 1: Export WAVs
        session.status = .exporting
        for i in 0..<session.plan.chunks.count where !isCancelled {
            guard session.plan.chunks[i].status == .planned else { continue }
            session.plan.chunks[i].status = .exporting
            do {
                let wavPath = try await exportChunkWAV(session.plan.chunks[i])
                session.plan.chunks[i].renderedWAVPath = wavPath
                session.plan.chunks[i].status = .exported
            } catch {
                session.plan.chunks[i].status = .failed
                onChunkError?(session.plan.chunks[i], error)
            }
        }

        // Step 2: Generate via Suno
        session.status = .generating
        for i in 0..<session.plan.chunks.count where !isCancelled {
            guard session.plan.chunks[i].status == .exported else { continue }
            session.plan.chunks[i].status = .generating
            do {
                let takes = try await generateTakes(for: session.plan.chunks[i])
                session.plan.chunks[i].takes = takes
                session.plan.chunks[i].status = .downloaded
                onProgress?(i + 1, session.plan.chunks.count, "Generated chunk \(i + 1)")
            } catch {
                session.plan.chunks[i].status = .failed
                onChunkError?(session.plan.chunks[i], error)
            }

            // Rate limit delay between chunks
            if i < session.plan.chunks.count - 1 {
                try await Task.sleep(for: .seconds(10))
            }
        }

        // Step 3: Auto-select if QC mode is .auto
        if session.qcMode == .auto {
            for i in 0..<session.plan.chunks.count {
                guard session.plan.chunks[i].status == .downloaded else { continue }
                session.plan.chunks[i].selectedTakeIndex = autoSelectBestTake(
                    chunk: session.plan.chunks[i]
                )
                session.plan.chunks[i].status = .selected
            }
        }

        session.status = session.qcMode == .auto ? .assembling : .reviewing
        return session
    }

    func cancel() { isCancelled = true }

    // MARK: - Alignment

    /// Align all downloaded chunks based on session's alignment mode.
    func alignChunks() async throws {
        for i in 0..<session.plan.chunks.count {
            guard session.plan.chunks[i].status == .downloaded ||
                  session.plan.chunks[i].status == .selected,
                  let takeIdx = session.plan.chunks[i].selectedTakeIndex,
                  takeIdx < session.plan.chunks[i].takes.count,
                  let takePath = session.plan.chunks[i].takes[takeIdx].downloadedFilePath
            else { continue }

            session.plan.chunks[i].status = .aligning
            let targetDuration = session.plan.chunks[i].timeEnd - session.plan.chunks[i].timeStart

            switch session.alignmentMode {
            case .stretchAudioToMIDI:
                let outputPath = takePath.replacingOccurrences(of: ".mp3", with: "-aligned.wav")
                let aligned = try await SunoAligner.stretchAudioToMIDI(
                    audioPath: takePath,
                    targetDurationSeconds: targetDuration,
                    outputPath: outputPath
                )
                session.plan.chunks[i].takes[takeIdx].alignedFilePath = aligned

            case .adaptMIDIToAudio:
                let extractedTempo = try await SunoAligner.extractTempoMap(
                    audioPath: takePath,
                    ticksPerQuarter: 480
                )
                // Accumulate tempo map across chunks
                var accumulated = session.extractedTempoMap ?? []
                accumulated.append(contentsOf: extractedTempo)
                session.extractedTempoMap = accumulated
                session.plan.chunks[i].takes[takeIdx].alignedFilePath = takePath
            }

            session.plan.chunks[i].status = .aligned
        }
    }

    // MARK: - Private

    private func exportChunkWAV(_ chunk: SunoChunkSpec) async throws -> String {
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("suno-exports/\(session.id.uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputURL = outputDir.appendingPathComponent("\(chunk.id.uuidString).wav")

        // Use the store's existing offline renderer
        // Filter notes to only those in this chunk's tick range and not muted
        let allNotes = await MainActor.run { store.pianoRollNotes }
        let chunkNotes = allNotes.filter { note in
            note.startTick >= chunk.tickStart && note.startTick < chunk.tickEnd && !note.muted
        }

        try await store.renderChunkToWav(
            notes: chunkNotes,
            startTick: chunk.tickStart,
            endTick: chunk.tickEnd,
            outputURL: outputURL
        )
        return outputURL.path
    }

    private func generateTakes(for chunk: SunoChunkSpec) async throws -> [SunoTake] {
        guard let wavPath = chunk.renderedWAVPath else { return [] }
        let cli = await MainActor.run { store.sunoCLI }

        var retries = 0
        let maxRetries = 3
        var localRetryDelay: UInt64 = 30

        while retries < maxRetries {
            do {
                let gen = try await cli.generateCover(
                    source: wavPath,
                    style: session.plan.styleTemplate,
                    title: nil,
                    lyrics: nil,
                    excludeStyles: nil,
                    wait: true
                )
                let capturedIDs = Array(gen.songIDs.prefix(session.plan.config.takesPerChunk))
                guard !capturedIDs.isEmpty else {
                    throw SunoCLIError.runtime(message: "Suno generate cover returned no song IDs.")
                }

                let downloadDir = FileManager.default.temporaryDirectory.appendingPathComponent("suno-takes")
                try? FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)

                var takes: [SunoTake] = []
                for songID in capturedIDs {
                    var take = SunoTake()
                    take.sunoTrackID = songID
                    let dl = try await cli.downloadSong(songID: songID, format: "mp3", out: downloadDir.path)
                    take.downloadedFilePath = dl.path
                    if let sourcePath = chunk.renderedWAVPath, let takePath = take.downloadedFilePath {
                        take.similarityScore = try? MFCCSimilarity.compareFiles(fileA: sourcePath, fileB: takePath)
                    }
                    takes.append(take)
                }
                return takes
            } catch let error where isRateLimitError(error) {
                retries += 1
                if retries >= maxRetries { throw error }
                NSLog("[SunoOrchestrator] Rate limited, backing off %ds (retry %d/%d)", localRetryDelay, retries, maxRetries)
                try await Task.sleep(for: .seconds(localRetryDelay))
                localRetryDelay = min(localRetryDelay * 2, 300)
            }
        }
        return []
    }

    private func isRateLimitError(_ error: Error) -> Bool {
        if case SunoCLIError.runtime(let msg) = error {
            let l = msg.lowercased()
            return l.contains("429") || l.contains("rate") || l.contains("too many")
        }
        return false
    }

    private func autoSelectBestTake(chunk: SunoChunkSpec) -> Int? {
        guard !chunk.takes.isEmpty else { return nil }
        let scored = chunk.takes.enumerated()
            .compactMap { (i, take) -> (Int, Double)? in
                guard let score = take.similarityScore else { return nil }
                return (i, score)
            }
            .filter { $0.1 >= 0.1 }
            .sorted { $0.1 > $1.1 }
        return scored.first?.0
    }

    // MARK: - Assembly

    /// Assemble all selected takes into a single contiguous WAV file.
    func assemble() async throws {
        session.status = .assembling
        let outputDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("suno-assembled/\(session.id.uuidString)")
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        let outputPath = outputDir.appendingPathComponent("assembled.wav").path

        _ = try SunoAssembler.assemble(session: session, outputPath: outputPath)
        session.status = .complete
    }
}
