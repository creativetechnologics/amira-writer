import AVFoundation

/// Handles audio recording, main-mix capture, loop recording, and input monitoring
/// for MIDIPlaybackEngine. All persistent state stays on the parent engine; this
/// class provides the operational methods that mutate that state on the audioQueue.
final class RecordingEngine {
    unowned let parent: MIDIPlaybackEngine

    init(parent: MIDIPlaybackEngine) {
        self.parent = parent
    }

    // MARK: - Recording API

    func startRecording(trackID: UUID, outputURL: URL) {
        parent.audioQueue.async { [weak self] in
            guard let self else { return }
            self.startRecordingOnAudioQueue(trackID: trackID, outputURL: outputURL)
        }
    }

    func stopRecording() {
        parent.audioQueue.async { [weak self] in
            guard let self else { return }
            self.stopRecordingOnAudioQueue()
        }
    }

    func startMainMixRecording(outputURL: URL) {
        parent.audioQueue.async { [weak self] in
            guard let self else { return }
            self.startMainMixRecordingOnAudioQueue(outputURL: outputURL)
        }
    }

    func stopMainMixRecording() {
        parent.audioQueue.async { [weak self] in
            guard let self else { return }
            self.stopMainMixRecordingOnAudioQueue()
        }
    }

    func configureInputMonitoring(trackID: UUID, enabled: Bool) {
        parent.audioQueue.async { [weak self] in
            guard let self else { return }
            if enabled {
                self.enableInputMonitoringOnAudioQueue(trackID: trackID)
            } else {
                self.disableInputMonitoringOnAudioQueue(trackID: trackID)
            }
        }
    }

    func configureLoopRecording(
        enabled: Bool,
        loopStart: Int,
        loopEnd: Int,
        outputURLGenerator: @escaping @Sendable () -> URL
    ) {
        parent.audioQueue.async { [weak self] in
            guard let self else { return }
            self.parent.loopRecordingEnabled = enabled
            self.parent.loopStartTick = loopStart
            self.parent.loopEndTick = loopEnd
            self.parent.loopRecordingOutputGenerator = outputURLGenerator
        }
    }

    // MARK: - Recording Implementation

    private func startRecordingOnAudioQueue(trackID: UUID, outputURL: URL) {
        guard !parent.isRecordingAudio else { return }

        let inputNode = parent.engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard parent.configureAudioGraphIfNeeded() else {
            parent.reportError("Cannot start recording: audio engine failed to start.")
            return
        }

        do {
            let file = try AVAudioFile(
                forWriting: outputURL,
                settings: inputFormat.settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
            os_unfair_lock_lock(&parent.recordingLock)
            parent.recordingFile = file
            parent.isRecordingAudio = true
            os_unfair_lock_unlock(&parent.recordingLock)
            parent.recordingHadWriteError = false
            parent.recordingTrackID = trackID

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                os_unfair_lock_lock(&self.parent.recordingLock)
                let recording = self.parent.isRecordingAudio
                let file = self.parent.recordingFile
                os_unfair_lock_unlock(&self.parent.recordingLock)
                guard recording, let file else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    os_unfair_lock_lock(&self.parent.recordingLock)
                    self.parent.recordingHadWriteError = true
                    os_unfair_lock_unlock(&self.parent.recordingLock)
                }
            }
        } catch {
            parent.reportError("Failed to create recording file: \(error.localizedDescription)")
        }
    }

    private func stopRecordingOnAudioQueue() {
        guard parent.isRecordingAudio else { return }

        parent.engine.inputNode.removeTap(onBus: 0)

        os_unfair_lock_lock(&parent.recordingLock)
        let fileURL = parent.recordingFile?.url
        parent.recordingFile = nil
        parent.isRecordingAudio = false
        let hadError = parent.recordingHadWriteError
        parent.recordingHadWriteError = false
        os_unfair_lock_unlock(&parent.recordingLock)
        parent.recordingTrackID = nil

        if hadError {
            parent.reportError("Recording may be incomplete — disk write errors occurred during capture.")
        }
        if let url = fileURL {
            let callback = parent.onRecordingComplete
            DispatchQueue.main.async {
                callback?(url)
            }
        }
    }

    private func startMainMixRecordingOnAudioQueue(outputURL: URL) {
        guard !parent.isRecordingMainMix else { return }

        let mixFormat = parent.engine.mainMixerNode.outputFormat(forBus: 0)
        guard mixFormat.channelCount > 0, mixFormat.sampleRate > 0 else {
            parent.reportError("Cannot start mix export: invalid main mixer format.")
            return
        }

        do {
            let file = try AVAudioFile(
                forWriting: outputURL,
                settings: mixFormat.settings,
                commonFormat: mixFormat.commonFormat,
                interleaved: mixFormat.isInterleaved
            )
            os_unfair_lock_lock(&parent.mixdownRecordingLock)
            parent.mixdownRecordingFile = file
            parent.isRecordingMainMix = true
            os_unfair_lock_unlock(&parent.mixdownRecordingLock)
            parent.mixdownRecordingHadWriteError = false
            parent.phase0TapPrevSampleTime = -1
            parent.phase0TapTotalFrames = 0
            parent.phase0TapGapCount = 0
            parent.phase0TapLastHeartbeat = 0
        } catch {
            parent.reportError("Failed to create mix export file: \(error.localizedDescription)")
        }
    }

    private func stopMainMixRecordingOnAudioQueue() {
        guard parent.isRecordingMainMix else { return }

        os_unfair_lock_lock(&parent.mixdownRecordingLock)
        let fileURL = parent.mixdownRecordingFile?.url
        parent.mixdownRecordingFile = nil
        parent.isRecordingMainMix = false
        os_unfair_lock_unlock(&parent.mixdownRecordingLock)

        parent.mixdownWriteGroup.wait()

        let hadError = parent.mixdownRecordingHadWriteError
        parent.mixdownRecordingHadWriteError = false

        if hadError {
            parent.reportError("Mix export may be incomplete — disk write errors occurred during capture.")
        }
        if let url = fileURL {
            let callback = parent.onMainMixRecordingComplete
            DispatchQueue.main.async {
                callback?(url)
            }
        }
    }

    // MARK: - Loop Recording

    func startLoopRecordingTimer(
        startTick: Int,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int
    ) {
        parent.loopRecordingTimer?.cancel()
        guard parent.loopRecordingEnabled, parent.loopEndTick > parent.loopStartTick else { return }

        parent.lastLoopCheckTick = startTick

        let timer = DispatchSource.makeTimerSource(queue: parent.audioQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: .milliseconds(16), leeway: .milliseconds(4))
        let startTime = DispatchTime.now()
        let startSeconds = parent.seconds(atTick: startTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
        let loopEnd = parent.loopEndTick
        let loopStart = parent.loopStartTick

        timer.setEventHandler { [weak self] in
            guard let self, self.parent.isRecordingAudio, self.parent.loopRecordingEnabled else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
            let currentSeconds = startSeconds + elapsed
            let currentTick = parent.tickAtSeconds(currentSeconds, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)

            if self.parent.lastLoopCheckTick < loopEnd && currentTick >= loopEnd {
                self.splitRecordingForLoopPass()
            }
            else if currentTick < self.parent.lastLoopCheckTick - (loopEnd - loopStart) / 2 {
                self.splitRecordingForLoopPass()
            }
            self.parent.lastLoopCheckTick = currentTick
        }
        parent.loopRecordingTimer = timer
        timer.resume()
    }

    func stopLoopRecordingTimer() {
        parent.loopRecordingTimer?.cancel()
        parent.loopRecordingTimer = nil
        parent.loopRecordingEnabled = false
    }

    private func splitRecordingForLoopPass() {
        guard parent.isRecordingAudio, let currentFile = parent.recordingFile,
              let generator = parent.loopRecordingOutputGenerator else { return }

        let newURL = generator()
        let completedURL = currentFile.url

        let inputFormat = parent.engine.inputNode.outputFormat(forBus: 0)
        do {
            let newFile = try AVAudioFile(
                forWriting: newURL,
                settings: inputFormat.settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )

            os_unfair_lock_lock(&parent.recordingLock)
            parent.recordingFile = newFile
            os_unfair_lock_unlock(&parent.recordingLock)

            let callback = parent.onLoopPassComplete
            DispatchQueue.main.async {
                callback?(completedURL)
            }
        } catch {
            parent.reportError("Failed to create loop pass file: \(error.localizedDescription)")
        }
    }

    // MARK: - Input Monitoring

    private func enableInputMonitoringOnAudioQueue(trackID: UUID) {
        guard parent.inputMonitorNodes[trackID] == nil else { return }

        let inputNode = parent.engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let submix = parent.trackSubmixNodes[trackID] else { return }

        let monitorMixer = AVAudioMixerNode()
        parent.engine.attach(monitorMixer)
        parent.engine.connect(inputNode, to: monitorMixer, format: inputFormat)
        parent.engine.connect(monitorMixer, to: submix, format: inputFormat)
        monitorMixer.outputVolume = 0.8
        parent.inputMonitorNodes[trackID] = monitorMixer
    }

    private func disableInputMonitoringOnAudioQueue(trackID: UUID) {
        guard let monitorMixer = parent.inputMonitorNodes.removeValue(forKey: trackID) else { return }
        parent.engine.disconnectNodeInput(monitorMixer)
        parent.engine.detach(monitorMixer)
    }

    func removeAllInputMonitorNodes() {
        for (trackID, _) in parent.inputMonitorNodes {
            disableInputMonitoringOnAudioQueue(trackID: trackID)
        }
    }
}
