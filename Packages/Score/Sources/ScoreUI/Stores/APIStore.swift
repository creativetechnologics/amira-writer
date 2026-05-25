import Foundation
import ProjectKit

@available(macOS 26.0, *)
@MainActor
final class APIStore {
    unowned let parent: ScoreStore
    init(parent: ScoreStore) { self.parent = parent }

    func startAPIServer() {
        AmiraLogger.log(.score, "startAPIServer: enabled=\(parent.apiServerEnabled) existing=\(parent.apiServer != nil) port=\(parent.apiServerPort)")
        guard parent.apiServerEnabled, parent.apiServer == nil else { return }
        do {
            let server = try APIServer(store: parent, port: parent.apiServerPort)
            server.logHandler = { method, path, status, _ in
                NSLog("[APIServer] %@ %@ → %d", method, path, status)
            }
            server.start()
            parent.apiServer = server
            AmiraLogger.log(.score, "startAPIServer: OK on port \(parent.apiServerPort)")
        } catch {
            AmiraLogger.log(.score, "startAPIServer: FAILED — \(error.localizedDescription)")
            parent.statusMessage = "API server failed to start: \(error.localizedDescription)"
        }
    }

    func stopAPIServer() {
        parent.apiServer?.stop()
        parent.apiServer = nil
    }

    struct PlaybackDiagnostics: Encodable {
        var selectedMidiID: String?
        var selectedMidiAssetPath: String?
        var pianoRollNotesCount: Int; var pianoRollAudioClipsCount: Int
        var isPlaying: Bool; var selectedSongHasPlayback: Bool
        var hydratedSongPaths: [String]; var deferredPlaybackAttempted: [String]
        var songAssetsCount: Int; var songAssetPlaybackStates: [String: SongAssetPlaybackState]
        var statusMessage: String
        struct SongAssetPlaybackState: Encodable { var hasPlayback: Bool; var noteCount: Int }
    }

    func playbackDiagnostics() -> PlaybackDiagnostics {
        let assetStates = Dictionary(uniqueKeysWithValues: parent.songAssets.map { asset in
            let pb = asset.document.activeVersion()?.playback
            return (asset.relativePath, PlaybackDiagnostics.SongAssetPlaybackState(hasPlayback: pb != nil, noteCount: pb?.notes.count ?? 0))
        })
        return PlaybackDiagnostics(
            selectedMidiID: parent.selectedMidiID?.uuidString,
            selectedMidiAssetPath: parent.selectedMidiAsset?.relativePath,
            pianoRollNotesCount: parent.pianoRollNotes.count,
            pianoRollAudioClipsCount: parent.pianoRollAudioClips.count,
            isPlaying: parent.isPlaying,
            selectedSongHasPlayback: parent.selectedMidiID.flatMap { id in parent.songAssets.first(where: { $0.id == id }) }?.document.activeVersion()?.playback != nil,
            hydratedSongPaths: Array(parent.hydratedSongPaths).sorted(),
            deferredPlaybackAttempted: parent.deferredPlaybackAttempted.map(\.uuidString).sorted(),
            songAssetsCount: parent.songAssets.count,
            songAssetPlaybackStates: assetStates,
            statusMessage: parent.statusMessage
        )
    }
}
