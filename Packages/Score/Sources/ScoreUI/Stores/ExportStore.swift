import AppKit
import AVFoundation
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
@MainActor
final class ExportStore {
    unowned let parent: ScoreStore
    init(parent: ScoreStore) { self.parent = parent }

    // MARK: - Full Mix Export State
    var isExportingFullMix: Bool = false
    var isPresentingFullMixExportPanel: Bool = false
    var fullMixExportStatus: String = ""
    var fullMixExportDetailStatus: String = ""
    var fullMixExportProgress: Double = 0

    // MARK: - Batch Export State
    var isBatchExporting: Bool = false
    var batchExportStatus: String = ""
    var batchExportProgress: Double = 0

    static let didExportSongToMix = Notification.Name("amira.score.didExportSongToMix")

    // MARK: - Full Mix Export

    func exportFullMixToWavWithPanel() {
        guard !parent.pianoRollNotes.isEmpty else { fullMixExportStatus = "No notes to export."; return }
        guard !isExportingFullMix else { fullMixExportStatus = "Export already in progress."; return }
        guard !isPresentingFullMixExportPanel else { return }
        isPresentingFullMixExportPanel = true
        let panel = NSSavePanel()
        panel.title = "Export Full Mix to WAV"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = fullMixExportPanelDefaultFilename()
        panel.directoryURL = fullMixExportPanelDefaultDirectoryURL()
        panel.canCreateDirectories = true; panel.isExtensionHidden = false; panel.canSelectHiddenExtension = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            Task { @MainActor in
                guard let self else { return }
                self.isPresentingFullMixExportPanel = false
                guard response == .OK, let url = panel.url else { return }
                self.startFullMixWavExportAfterPanel(outputURL: url, instrumentalOnly: false)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    func exportInstrumentalMixToWavWithPanel() {
        guard !parent.pianoRollNotes.isEmpty else { fullMixExportStatus = "No notes to export."; return }
        guard !isExportingFullMix else { fullMixExportStatus = "Export already in progress."; return }
        guard !isPresentingFullMixExportPanel else { return }
        isPresentingFullMixExportPanel = true
        let panel = NSSavePanel()
        panel.title = "Export Instrumental Mix to WAV"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = instrumentalExportPanelDefaultFilename()
        panel.directoryURL = fullMixExportPanelDefaultDirectoryURL()
        panel.canCreateDirectories = true; panel.isExtensionHidden = false; panel.canSelectHiddenExtension = true
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, panel] response in
            Task { @MainActor in
                guard let self else { return }
                self.isPresentingFullMixExportPanel = false
                guard response == .OK, let url = panel.url else { return }
                self.startFullMixWavExportAfterPanel(outputURL: url, instrumentalOnly: true)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
        else { panel.begin(completionHandler: completion) }
    }

    func exportFullMixToWav(outputURL: URL) async { await exportSongWav(outputURL: outputURL, instrumentalOnly: false) }
    func exportInstrumentalMixToWav(outputURL: URL) async { await exportSongWav(outputURL: outputURL, instrumentalOnly: true) }

    // MARK: - Rehearsal Track Export

    func exportRehearsalTrackWithPanel() {
        guard !parent.pianoRollNotes.isEmpty else { fullMixExportStatus = "No notes to export."; return }
        guard !isExportingFullMix else { fullMixExportStatus = "Export already in progress."; return }
        let panel = NSSavePanel()
        panel.title = "Export Rehearsal Track"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = "\(parent.selectedMidiAsset?.displayName ?? "untitled") - Rehearsal.wav"
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in await self.exportRehearsalTrack(outputURL: url) }
        }
    }

    // MARK: - Stem Export

    func exportStemsWithPanel() {
        guard !parent.pianoRollNotes.isEmpty else { fullMixExportStatus = "No notes to export."; return }
        guard !isExportingFullMix else { fullMixExportStatus = "Export already in progress."; return }
        let panel = NSOpenPanel()
        panel.title = "Choose Folder for Stems"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in await self.exportStems(outputDir: url) }
        }
    }

    // MARK: - Send-to-Mix / Batch Export

    func exportCurrentSongToMix() {
        guard let asset = parent.selectedMidiAsset else { fullMixExportStatus = "No song selected."; return }
        guard !parent.pianoRollNotes.isEmpty else { fullMixExportStatus = "No notes to export."; return }
        guard !isExportingFullMix else { fullMixExportStatus = "Export already in progress."; return }
        guard let outputURL = mixExportURL(for: asset) else { fullMixExportStatus = "No project open."; return }
        Task { @MainActor in
            do { try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true) }
            catch { fullMixExportStatus = "Could not create Mix/exports/: \(error.localizedDescription)"; return }
            await exportSongWav(outputURL: outputURL, instrumentalOnly: false)
            if fullMixExportStatus.hasPrefix("Exported") {
                NotificationCenter.default.post(name: Self.didExportSongToMix, object: nil, userInfo: ["wavURL": outputURL, "songRelativePath": asset.relativePath])
            }
        }
    }

    func exportAllSongsToWavsWithPanel() {
        guard !parent.midiAssets.isEmpty else { batchExportStatus = "No songs to export."; return }
        guard !isBatchExporting, !isExportingFullMix else { batchExportStatus = "An export is already in progress."; return }
        let panel = NSOpenPanel()
        panel.title = "Choose Folder for WAV Exports"; panel.prompt = "Export"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in self.startBatchWavExportAfterPanel(outputDir: url, instrumentalOnly: false) }
        }
    }

    func exportAllSongsToInstrumentalWavsWithPanel() {
        guard !parent.midiAssets.isEmpty else { batchExportStatus = "No songs to export."; return }
        guard !isBatchExporting, !isExportingFullMix else { batchExportStatus = "An export is already in progress."; return }
        let panel = NSOpenPanel()
        panel.title = "Choose Folder for Instrumental WAV Exports"; panel.prompt = "Export"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in self.startBatchWavExportAfterPanel(outputDir: url, instrumentalOnly: true) }
        }
    }

    // MARK: - Internal Orchestration

    private func startFullMixWavExportAfterPanel(outputURL: URL, instrumentalOnly: Bool) {
        guard !isExportingFullMix else { fullMixExportStatus = "Export already in progress."; return }
        isExportingFullMix = true; fullMixExportProgress = 0; fullMixExportDetailStatus = ""
        fullMixExportStatus = instrumentalOnly ? "Preparing instrumental WAV export..." : "Preparing WAV export..."
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield(); try? await Task.sleep(nanoseconds: 150_000_000)
            await self.exportSongWav(outputURL: outputURL, instrumentalOnly: instrumentalOnly, alreadyMarkedExporting: true)
        }
    }

    private func exportSongWav(outputURL: URL, instrumentalOnly: Bool, alreadyMarkedExporting: Bool = false) async {
        let allNotes = parent.pianoRollNotes
        guard !allNotes.isEmpty else { fullMixExportStatus = "No notes to export."; if alreadyMarkedExporting { isExportingFullMix = false; fullMixExportProgress = 0 }; return }
        let endTick = allNotes.map { $0.startTick + $0.duration }.max() ?? parent.pianoRollLengthTicks
        guard endTick > 0 else { fullMixExportStatus = "Song has zero length."; if alreadyMarkedExporting { isExportingFullMix = false; fullMixExportProgress = 0 }; return }
        let exportNotes = instrumentalOnly ? instrumentalNotes(from: allNotes) : allNotes
        guard !exportNotes.isEmpty else { fullMixExportStatus = instrumentalOnly ? "No instrument-track notes to export." : "No notes to export."; if alreadyMarkedExporting { isExportingFullMix = false; fullMixExportProgress = 0 }; return }
        if !alreadyMarkedExporting { isExportingFullMix = true; fullMixExportProgress = 0 }
        fullMixExportStatus = instrumentalOnly ? "Rendering instrumental mix..." : "Rendering full mix..."
        fullMixExportDetailStatus = ""
        let estimatedSeconds = Self.ticksToSeconds(endTick, ticksPerQuarter: parent.ticksPerQuarter, tempoEvents: Dictionary(uniqueKeysWithValues: parent.pianoRollTempoEvents.map { ($0.tick, $0.bpm) }))
        let exportStartTime = Date()
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            let shouldInvalidate = MainActor.assumeIsolated {
                guard let self, self.isExportingFullMix else { return true }
                let elapsed = Date().timeIntervalSince(exportStartTime)
                self.fullMixExportProgress = estimatedSeconds > 0 ? min(elapsed / (estimatedSeconds + 2), 0.99) : 0
                return false
            }
            if shouldInvalidate { timer.invalidate() }
        }
        do {
            try await performWavExport(plan: SongWavExportPlan(notes: exportNotes, endTick: endTick, instrumentalOnly: instrumentalOnly), outputURL: outputURL)
            fullMixExportProgress = 1.0
            fullMixExportStatus = instrumentalOnly ? "Exported instrumental mix to \(outputURL.lastPathComponent)" : "Exported to \(outputURL.lastPathComponent)"
            fullMixExportDetailStatus = ""
        } catch {
            fullMixExportStatus = "Export failed: \(error.localizedDescription)"
            fullMixExportDetailStatus = ""
        }
        progressTimer.invalidate(); isExportingFullMix = false; fullMixExportProgress = 0
    }

    private func performWavExport(plan: SongWavExportPlan, outputURL: URL, timeout: TimeInterval = 600) async throws {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled], reason: plan.instrumentalOnly ? "Instrumental WAV export" : "WAV export")
        ProcessInfo.processInfo.disableSuddenTermination()
        defer { ProcessInfo.processInfo.enableSuddenTermination(); ProcessInfo.processInfo.endActivity(activity) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in try await parent.renderChunkToWav(notes: plan.notes, startTick: 0, endTick: plan.endTick, outputURL: outputURL) }
            group.addTask { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)); throw ScoreStore.ChunkExportError.offlineRenderTimedOut(timeout) }
            do { try await group.next(); group.cancelAll() } catch { group.cancelAll(); throw error }
        }
    }

    func exportRehearsalTrack(outputURL: URL, accompanimentAttenuationDB: Double = -12.0) async {
        guard !parent.pianoRollNotes.isEmpty else { fullMixExportStatus = "No notes to export."; return }
        isExportingFullMix = true; fullMixExportStatus = "Rendering rehearsal track..."; fullMixExportDetailStatus = ""
        var gainOverrides: [String: Double] = [:]
        let resolvedMappings = parent.resolvedInstrumentMappings()
        for (key, mapping) in resolvedMappings {
            gainOverrides[key] = mapping.trackRole == .vocal ? mapping.gainDB : mapping.gainDB + accompanimentAttenuationDB
        }
        let endTick = parent.pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? parent.pianoRollLengthTicks
        guard endTick > 0 else { fullMixExportStatus = "Song has zero length."; isExportingFullMix = false; return }
        do {
            try await parent.renderChunkToWav(notes: parent.pianoRollNotes, startTick: 0, endTick: endTick, outputURL: outputURL, gainOverrides: gainOverrides)
            fullMixExportStatus = "Rehearsal track exported to \(outputURL.lastPathComponent)"
        } catch { fullMixExportStatus = "Export failed: \(error.localizedDescription)" }
        isExportingFullMix = false
    }

    func exportStems(outputDir: URL) async {
        guard !parent.pianoRollNotes.isEmpty else { fullMixExportStatus = "No notes to export."; return }
        isExportingFullMix = true; fullMixExportDetailStatus = ""
        let trackIndices = Set(parent.pianoRollNotes.map(\.trackIndex)).sorted()
        let endTick = parent.pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? parent.pianoRollLengthTicks
        guard endTick > 0 else { fullMixExportStatus = "Song has zero length."; isExportingFullMix = false; return }
        let baseName = parent.selectedMidiAsset?.displayName ?? "untitled"
        var exported = 0
        for trackIdx in trackIndices {
            let trackNotes = parent.pianoRollNotes.filter { $0.trackIndex == trackIdx }
            guard !trackNotes.isEmpty else { continue }
            let trackName = parent.pianoRollTrackNames[trackIdx] ?? "Track \(trackIdx)"
            let safeName = trackName.replacingOccurrences(of: "/", with: "-")
            let fileName = "\(baseName) - \(safeName).wav"
            let outputURL = outputDir.appendingPathComponent(fileName)
            fullMixExportStatus = "Rendering stem: \(trackName)..."
            do { try await parent.renderChunkToWav(notes: trackNotes, startTick: 0, endTick: endTick, outputURL: outputURL); exported += 1 }
            catch { NSLog("[Stems] Failed to export stem for %@: %@", trackName, error.localizedDescription) }
        }
        fullMixExportStatus = "Exported \(exported) stems to \(outputDir.lastPathComponent)/"; fullMixExportDetailStatus = ""
        isExportingFullMix = false
    }

    private func startBatchWavExportAfterPanel(outputDir: URL, instrumentalOnly: Bool) {
        guard !isBatchExporting, !isExportingFullMix else { batchExportStatus = "An export is already in progress."; return }
        isBatchExporting = true; batchExportProgress = 0
        batchExportStatus = instrumentalOnly ? "Preparing instrumental WAV batch export..." : "Preparing WAV batch export..."
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield(); try? await Task.sleep(nanoseconds: 150_000_000)
            await self.exportAllSongsToWavs(outputDir: outputDir, instrumentalOnly: instrumentalOnly, alreadyMarkedExporting: true)
        }
    }

    func exportAllSongsToWavs(outputDir: URL, instrumentalOnly: Bool, alreadyMarkedExporting: Bool = false) async {
        let assets = parent.midiAssets
        guard !assets.isEmpty else { batchExportStatus = "No songs to export."; if alreadyMarkedExporting { isBatchExporting = false; batchExportProgress = 0 }; return }
        if !alreadyMarkedExporting { guard !isBatchExporting, !isExportingFullMix else { batchExportStatus = "An export is already in progress."; return } }
        do { try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true) } catch { batchExportStatus = "Could not create export folder: \(error.localizedDescription)"; if alreadyMarkedExporting { isBatchExporting = false; batchExportProgress = 0 }; return }
        if !alreadyMarkedExporting { isBatchExporting = true; batchExportProgress = 0 }
        batchExportStatus = instrumentalOnly ? "Starting instrumental WAV batch export..." : "Starting WAV batch export..."
        var exported = 0; var skippedExisting = 0; var exportable = 0
        for (index, asset) in assets.enumerated() {
            let outputURL = wavExportURL(for: asset, in: outputDir, suffix: instrumentalOnly ? "Instrumental" : nil)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path), let size = (attrs[.size] as? NSNumber)?.intValue, size > 0 {
                do { _ = try await Task.detached(priority: .utility) { try ScoreStore.validateCompletedWavExport(at: outputURL, expectedDurationSeconds: nil, context: "existing batch WAV", finalizeForDelivery: false, requireDeliveryFormat: true) }.value
                    batchExportStatus = "Skipping \(asset.displayName) — existing WAV validated"
                    exportable += 1; exported += 1; skippedExisting += 1; batchExportProgress = Double(index + 1) / Double(assets.count); continue
                } catch { ScoreStore.removeIncompleteExportFile(at: outputURL); batchExportStatus = "Re-rendering \(asset.displayName) — existing WAV failed validation" }
            }
            batchExportStatus = "Hydrating \(asset.displayName)..."
            _ = await parent.hydrateSongPlaybackIfNeeded(id: asset.id)
            let savedSelectedID = parent.selectedMidiID
            if parent.selectedMidiID != asset.id { parent.setSelectedMidi(id: asset.id, stopPlaybackBeforeSelect: true); for _ in 0..<3 { await Task.yield() } }
            let allNotes = parent.pianoRollNotes
            guard !allNotes.isEmpty else { batchExportProgress = Double(index + 1) / Double(assets.count); if savedSelectedID != asset.id { parent.setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false) }; continue }
            let endTick = allNotes.map { $0.startTick + $0.duration }.max() ?? parent.pianoRollLengthTicks
            guard endTick > 0 else { batchExportProgress = Double(index + 1) / Double(assets.count); if savedSelectedID != asset.id { parent.setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false) }; continue }
            let exportNotes = instrumentalOnly ? instrumentalNotes(from: allNotes) : allNotes
            guard !exportNotes.isEmpty else { batchExportProgress = Double(index + 1) / Double(assets.count); if savedSelectedID != asset.id { parent.setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false) }; continue }
            exportable += 1
            batchExportStatus = instrumentalOnly ? "Rendering instrumental \(asset.displayName) (\(index + 1)/\(assets.count))..." : "Rendering \(asset.displayName) (\(index + 1)/\(assets.count))..."
            do {
                try await parent.renderChunkToWav(notes: exportNotes, startTick: 0, endTick: endTick, outputURL: outputURL)
                exported += 1
            } catch {
                let exists = FileManager.default.fileExists(atPath: outputURL.path)
                let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
                let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
                if exists && size < 1024 { try? FileManager.default.removeItem(at: outputURL) }
            }
            batchExportProgress = Double(index + 1) / Double(assets.count)
            if savedSelectedID != asset.id { parent.setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false); for _ in 0..<2 { await Task.yield() } }
        }
        batchExportProgress = 1.0
        let skipNote = skippedExisting > 0 ? " (\(skippedExisting) already on disk)" : ""
        batchExportStatus = instrumentalOnly ? "Instrumental WAV batch export done — \(exported)/\(exportable) songs\(skipNote)." : "WAV batch export done — \(exported)/\(exportable) songs\(skipNote)."
        isBatchExporting = false
    }

    func exportAllSongsToWavs(outputDir: URL) async { await exportAllSongsToWavs(outputDir: outputDir, instrumentalOnly: false) }
    func exportAllSongsToInstrumentalWavs(outputDir: URL) async { await exportAllSongsToWavs(outputDir: outputDir, instrumentalOnly: true) }

    func exportAllSongsToMix() async {
        guard let projectURL = parent.fileProjectURL else { batchExportStatus = "No project open."; return }
        guard !isBatchExporting, !isExportingFullMix else { batchExportStatus = "An export is already in progress."; return }
        let exportsDir = ProjectPaths(root: projectURL).mixExports
        do { try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true) } catch { batchExportStatus = "Could not create Mix/exports/: \(error.localizedDescription)"; return }
        isBatchExporting = true; batchExportProgress = 0; batchExportStatus = "Starting batch export..."
        let assets = parent.midiAssets; var exported = 0
        for (index, asset) in assets.enumerated() {
            batchExportStatus = "Hydrating \(asset.displayName)..."
            _ = await parent.hydrateSongPlaybackIfNeeded(id: asset.id)
            let savedSelectedID = parent.selectedMidiID
            if parent.selectedMidiID != asset.id { parent.setSelectedMidi(id: asset.id, stopPlaybackBeforeSelect: true); for _ in 0..<3 { await Task.yield() } }
            guard !parent.pianoRollNotes.isEmpty else { batchExportProgress = Double(index + 1) / Double(assets.count); if savedSelectedID != asset.id { parent.setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false) }; continue }
            guard let outputURL = mixExportURL(for: asset) else { continue }
            batchExportStatus = "Rendering \(asset.displayName) (\(index + 1)/\(assets.count))..."
            let endTick = parent.pianoRollNotes.map { $0.startTick + $0.duration }.max() ?? 0
            guard endTick > 0 else { batchExportProgress = Double(index + 1) / Double(assets.count); if savedSelectedID != asset.id { parent.setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false) }; continue }
            do {
                try await parent.renderChunkToWav(notes: parent.pianoRollNotes, startTick: 0, endTick: endTick, outputURL: outputURL)
                exported += 1
                let capturedPath = asset.relativePath
                NotificationCenter.default.post(name: Self.didExportSongToMix, object: nil, userInfo: ["wavURL": outputURL, "songRelativePath": capturedPath])
            } catch { NSLog("[BatchExport] Failed %@: %@", asset.displayName, error.localizedDescription) }
            batchExportProgress = Double(index + 1) / Double(assets.count)
            if savedSelectedID != asset.id { parent.setSelectedMidi(id: savedSelectedID, stopPlaybackBeforeSelect: false); for _ in 0..<2 { await Task.yield() } }
        }
        batchExportProgress = 1.0; batchExportStatus = "Batch export done — \(exported)/\(assets.count) songs exported."; isBatchExporting = false
    }

    // MARK: - Helpers

    private func instrumentalNotes(from notes: [PianoRollNote]) -> [PianoRollNote] {
        let channelKeyMap = parent.pianoRollChannelKeyByTrackChannel
        return notes.filter { note in
            let pairKey = "\(note.trackIndex):\(note.channel)"
            let mappingKey = channelKeyMap[pairKey] ?? "__default__"
            if let mapping = parent.instrumentMappings[mappingKey] { return mapping.trackRole != .vocal }
            return true
        }
    }

    private func fullMixExportPanelDefaultFilename() -> String { wavExportPanelDefaultFilename(suffix: nil) }
    private func instrumentalExportPanelDefaultFilename() -> String { wavExportPanelDefaultFilename(suffix: "Instrumental") }

    private func wavExportPanelDefaultFilename(suffix: String?) -> String {
        let rawName = parent.selectedMidiAsset?.displayName ?? parent.metadata.name
        let sanitized = rawName.components(separatedBy: Self.invalidExportFilenameCharacters).joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        var baseName = sanitized.isEmpty ? "untitled" : sanitized
        if baseName.lowercased().hasSuffix(".wav") { baseName = String(baseName.dropLast(4)) }
        let suffixPart = suffix.map { " - \($0.trimmingCharacters(in: .whitespacesAndNewlines))" } ?? ""
        return "\(baseName)\(suffixPart).wav"
    }

    private func fullMixExportPanelDefaultDirectoryURL() -> URL? {
        guard let projectRoot = parent.fileProjectURL else { return nil }
        let paths = ProjectPaths(root: projectRoot)
        do { try FileManager.default.createDirectory(at: paths.mixExports, withIntermediateDirectories: true); return paths.mixExports }
        catch { return FileManager.default.fileExists(atPath: paths.mix.path) ? paths.mix : projectRoot }
    }

    private static var invalidExportFilenameCharacters: CharacterSet {
        var chars = CharacterSet(charactersIn: "/\\?%*|\"<>:"); chars.formUnion(.newlines); chars.formUnion(.controlCharacters); return chars
    }

    private func wavExportURL(for asset: MidiAsset, in directory: URL, suffix: String? = nil) -> URL {
        let slug = asset.displayName.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        let suffixPart = suffix.map { "_\($0.replacingOccurrences(of: "[^A-Za-z0-9_-]+", with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_")))" } ?? ""
        return directory.appendingPathComponent("\(slug.isEmpty ? "untitled" : slug)\(suffixPart).wav")
    }

    private func mixExportURL(for asset: MidiAsset) -> URL? {
        guard let projectURL = parent.fileProjectURL else { return nil }
        return wavExportURL(for: asset, in: ProjectPaths(root: projectURL).mixExports)
    }

    private struct SongWavExportPlan {
        let notes: [PianoRollNote]; let endTick: Int; let instrumentalOnly: Bool
    }

    nonisolated static func ticksToSeconds(_ ticks: Int, ticksPerQuarter: Int, tempoEvents: [Int: Double]) -> Double {
        guard !tempoEvents.isEmpty, ticks > 0 else { return Double(ticks) / Double(max(1, ticksPerQuarter)) * 0.5 }
        let tpq = Double(max(1, ticksPerQuarter)); var total: Double = 0
        let sorted = tempoEvents.sorted { $0.key < $1.key }
        for (i, (tick, bpm)) in sorted.enumerated() {
            let nextTick = i + 1 < sorted.count ? sorted[i + 1].key : ticks
            if nextTick > tick { total += Double(nextTick - tick) * (60.0 / max(20, bpm)) / tpq }
        }
        return total
    }
}
