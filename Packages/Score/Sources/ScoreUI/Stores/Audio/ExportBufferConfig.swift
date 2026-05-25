import AVFoundation

/// Manages audio buffer size adjustments for WAV export mode.
/// Raises the tap bufferSize and maximumFramesToRender during export to
/// prevent dropout glitches under heavy AU load.
final class ExportBufferConfig {
    unowned let parent: MIDIPlaybackEngine

    private var priorPlaybackBufferFrames: UInt32 = 0

    init(parent: MIDIPlaybackEngine) {
        self.parent = parent
    }

    func enterExportMode() {
        parent.audioQueue.async { [weak self] in
            self?.enterExportModeOnAudioQueue()
        }
    }

    func leaveExportMode() {
        parent.audioQueue.sync { [weak self] in
            self?.leaveExportModeOnAudioQueue()
        }
    }

    private func enterExportModeOnAudioQueue() {
        let exportFrames: UInt32 = 4096
        priorPlaybackBufferFrames = parent.preferredBufferFrames
        parent.preferredBufferFrames = exportFrames
        parent.exportTapBufferFrames = AVAudioFrameCount(exportFrames)
        parent.applyRenderBufferSettingsOnAudioQueue()
    }

    private func leaveExportModeOnAudioQueue() {
        if parent.muteHardwareOutput {
            parent.restoreHardwareOutputAfterExport()
        }
        let restored = priorPlaybackBufferFrames > 0 ? priorPlaybackBufferFrames : 512
        parent.preferredBufferFrames = restored
        parent.exportTapBufferFrames = 0
        parent.applyRenderBufferSettingsOnAudioQueue()
    }
}
