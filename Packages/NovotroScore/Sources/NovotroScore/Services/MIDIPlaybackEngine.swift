import Accelerate
#if os(macOS)
import AppKit
#endif
@preconcurrency import AVFoundation
import AudioToolbox
import Foundation

final class MIDIPlaybackEngine: @unchecked Sendable {
    private final class AULoadResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var unit: AVAudioUnit?
        private var error: Error?

        func store(unit: AVAudioUnit?, error: Error?) {
            lock.lock()
            self.unit = unit
            self.error = error
            lock.unlock()
        }

        func snapshot() -> (AVAudioUnit?, Error?) {
            lock.lock()
            let result = (unit, error)
            lock.unlock()
            return result
        }
    }

    private struct SamplerPatchSignature: Equatable {
        let soundBankPath: String?
        let bankMSB: UInt8
        let bankLSB: UInt8
        let program: UInt8
        let gainDB: Double
        let auSubType: UInt32?
        let auManufacturer: UInt32?
    }

    private struct HostedMIDIEvent {
        let timeSeconds: Double
        let sortPriority: Int
        let mappingKey: String
        let bytes: [UInt8]
    }

    private struct PlaybackClockState {
        let startUptimeNanoseconds: UInt64
        let startSeconds: Double
        let tempoMap: [TempoPoint]
        let ticksPerQuarter: Int
        let lengthTicks: Int
        var isLooping: Bool
        let initialPassDurationSeconds: Double
        let loopDurationSeconds: Double
    }

    private enum PlaybackEndBehavior {
        case hostedMIDI
        case sequencer
    }

    private let audioQueue = DispatchQueue(label: "com.novotro.score.playback", qos: .userInitiated)
    private let engine = AVAudioEngine()
    /// Recreated for each playback session to guarantee clean tempo state.
    /// AVAudioSequencer can retain stale internal tempo maps across load() calls.
    private var sequencer: AVAudioSequencer?
    private var hostedMIDIEvents: [HostedMIDIEvent] = []
    private var hostedMIDILoopEvents: [HostedMIDIEvent] = []
    private var hostedMIDIEventIndex = 0
    private var hostedMIDIDeliveryWorkItem: DispatchWorkItem?
    private var hostedMIDICycleStartUptimeNanoseconds: UInt64 = 0
    private var hostedMIDILoopEnabled = false
    private let playbackClockLock = NSLock()
    private var playbackClockState: PlaybackClockState?

    private var samplerByMappingKey: [String: AVAudioUnitSampler] = [:]
    /// Audio Unit instrument instances keyed by mapping key (for AU-type mappings)
    private var auInstrumentByMappingKey: [String: AVAudioUnit] = [:]
    private var patchSignatureByMappingKey: [String: SamplerPatchSignature] = [:]
    private let previewSamplerKey = "__preview__"
    private var previewMapping: InstrumentMapping?
    private var useConservativeSequencerConfig = false
    private var preferredBufferFrames: UInt32 = 512
    private var masterOutputVolume: Float = 0.92
    private var playbackStopWorkItem: DispatchWorkItem?
    private var pendingAudioStartWorkItems: [UUID: DispatchWorkItem] = [:]
    private var audioPlayerNodes: [UUID: AVAudioPlayerNode] = [:]
    private var audioFileCache: [String: AVAudioFile] = [:]
    /// Per-clip AVAudioUnitTimePitch nodes for time stretching and pitch shifting.
    /// Only created for clips with stretchRatio != 1.0 or pitchCents != 0.
    private var clipTimePitchNodes: [UUID: AVAudioUnitTimePitch] = [:]
    /// Fade automation timers keyed by clip ID
    private var fadeTimers: [UUID: DispatchSourceTimer] = [:]
    /// Target (base) volume for each clip before fades (keyed by clip ID)
    private var clipBaseVolume: [UUID: Float] = [:]

    /// Per-track submix mixer nodes. Key = MixTrack.id (UUID).
    /// All clips on a track route through this node, enabling per-track volume/pan,
    /// metering taps, FX chains, and automation.
    private var trackSubmixNodes: [UUID: AVAudioMixerNode] = [:]

    /// Per-track FX chains: ordered array of AU effects inserted between submix and mainMixer.
    private var trackFXChains: [UUID: [AVAudioUnitEffect]] = [:]

    /// Per-send mixer nodes: a lightweight mixer node per send that scales volume for the send.
    /// Key = TrackSend.id
    private var sendMixerNodes: [UUID: AVAudioMixerNode] = [:]

    /// Audio metering: accumulated levels from tap callbacks, published at 30fps
    private var meterTapLevels: [UUID: MeterLevels] = [:]  // per-track raw levels from taps
    private var masterMeterRaw: MeterLevels = .zero
    private var meterPublishTimer: DispatchSourceTimer?
    private var meterTapsInstalled = false
    /// Held peak values (decay 24dB/sec)
    private var meterPeakHold: [UUID: (peakL: Float, peakR: Float)] = [:]
    private var masterPeakHold: (peakL: Float, peakR: Float) = (-160, -160)
    var onMeterUpdate: (([UUID: MeterLevels], MeterLevels) -> Void)?

    /// Automation playback: single 60Hz timer applying automation values to submix nodes
    private var automationTimer: DispatchSourceTimer?
    /// Snapshot of automation lanes per track, set before playback starts
    private var automationSnapshot: [UUID: [AutomationLane]] = [:]
    /// Base track volumes (before automation), used as scale factors
    private var automationTrackVolumes: [UUID: Float] = [:]
    /// Base track pans (before automation), used as scale factors
    private var automationTrackPans: [UUID: Float] = [:]

    // MARK: - Metronome
    private var metronomeNode: AVAudioPlayerNode?
    private var metronomeDownbeatBuffer: AVAudioPCMBuffer?
    private var metronomeUpbeatBuffer: AVAudioPCMBuffer?
    private var metronomeEnabled: Bool = false
    private var metronomeVolume: Float = 0.7
    private var metronomeCountInBars: Int = 0
    /// Time signatures for metronome accent pattern. Set by ScoreStore before playback.
    nonisolated(unsafe) var metronomeTimeSignatures: [TimeSignatureEvent] = []
    /// A/B loop region in ticks. When set, loop wraps within this range instead of the full song.
    nonisolated(unsafe) var loopRegionStartTick: Int? = nil
    nonisolated(unsafe) var loopRegionEndTick: Int? = nil

    // MARK: - Recording
    /// Lock protecting recordingFile and isRecordingAudio from concurrent access
    /// between audioQueue (writes) and the AVAudioEngine IOThread (reads in tap callback).
    private var recordingLock = os_unfair_lock()
    private var recordingFile: AVAudioFile?
    private var recordingTrackID: UUID?
    private(set) var isRecordingAudio: Bool = false
    private var recordingHadWriteError: Bool = false
    /// Separate lock/state for live main-mix capture used by WAV export previews.
    private var mixdownRecordingLock = os_unfair_lock()
    private var mixdownRecordingFile: AVAudioFile?
    private(set) var isRecordingMainMix: Bool = false
    private var mixdownRecordingHadWriteError: Bool = false
    private let mixdownWriterQueue = DispatchQueue(label: "NovotroScore.MixdownWriter")
    private let mixdownWriteGroup = DispatchGroup()
    private var inputMonitorNodes: [UUID: AVAudioMixerNode] = [:]
    /// Callback fired on main thread when recording stops, providing the output file URL
    var onRecordingComplete: ((URL) -> Void)?
    /// Callback fired on main thread when live main-mix capture finishes.
    var onMainMixRecordingComplete: ((URL) -> Void)?
    /// Callback fired on main thread each time a loop pass completes during loop recording
    var onLoopPassComplete: ((URL) -> Void)?

    // MARK: - Loop Recording
    private var loopRecordingTimer: DispatchSourceTimer?
    private var loopRecordingEnabled: Bool = false
    private var loopStartTick: Int = 0
    private var loopEndTick: Int = 0
    private var lastLoopCheckTick: Int = 0
    private var loopRecordingOutputGenerator: (() -> URL)?

    private(set) var isPlaying: Bool = false

    /// The sequencer's current position in beats, readable from any thread.
    /// Returns 0 when not playing. Used for accurate playhead synchronization.
    var currentPositionInBeats: Double {
        currentPlaybackPositionInBeats()
    }

    var onPlaybackStateChange: ((Bool) -> Void)?
    var onPlaybackError: ((String) -> Void)?
    /// Called when an AU disconnects; provides the mapping key so ScoreStore can reload it.
    var onAUDisconnected: ((String) -> Void)?
    /// Called when an AVAudioEngineConfigurationChange requires a full playback restart.
    /// The argument is the sequencer position in beats at the time of the change.
    /// The store should call playPianoRoll(startTick:) to restart from that position.
    var onNeedsPlaybackRestart: ((Double) -> Void)?

    /// Observers for AU out-of-process disconnection and engine resets
    private var engineConfigObserver: NSObjectProtocol?
    private var auObservations: [String: NSKeyValueObservation] = [:]
    private var healthCheckTimer: DispatchSourceTimer?
    private var systemWakeObserver: NSObjectProtocol?
    /// True while playback setup/teardown is in progress — health check should skip.
    private var isReconfiguring = false

    /// Clear `isReconfiguring` from outside (e.g. when the restart callback declines to restart).
    func clearReconfiguring() {
        audioQueue.async { [weak self] in
            self?.isReconfiguring = false
        }
    }
    /// Set to true just before we intentionally call engine.pause() so that
    /// handleEngineConfigurationChange() can distinguish our own pauses from
    /// real hardware-change events and avoid triggering spurious restarts.
    /// This is a counter, not a bool: each withEnginePaused / stopOnAudioQueue
    /// call that does engine.pause() increments it; each handleEngineConfigurationChange
    /// notification decrements it. Multiple withEnginePaused calls during setup
    /// produce multiple queued notifications — only the extras are real hardware events.
    private var engineStopIsOursDepth: Int = 0
    /// Monotonic identifier for play requests. Only the newest request is allowed to run.
    private let playRequestLock = NSLock()
    private var latestPlayRequestID: UInt64 = 0

    init() {
        // Observe audio engine configuration changes (device changes, AU disconnects, etc.)
        engineConfigObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [engineOwner = self] _ in
            // Apple docs: "the engine stops itself" before posting this notification.
            // Do NOT call engine.pause()/stop() on this internal queue — risks deadlock.
            // Dispatch recovery to audioQueue where we can safely manipulate state.
            engineOwner.audioQueue.async { [engineOwner] in
                engineOwner.handleEngineConfigurationChange()
            }
        }
        #if os(macOS)
        // Observe system wake to reset stale audio state. After sleep, the audio
        // hardware reinitializes and AVAudioUnitSampler render resources may be
        // invalid. Clearing SF2 signatures forces re-loading on next play.
        systemWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: nil
        ) { [engineOwner = self] _ in
            engineOwner.audioQueue.async { [engineOwner] in
                NSLog("[Engine] System wake — clearing SF2 patch signatures for fresh reload")
                engineOwner.fileLog("SYSTEM_WAKE: clearing SF2 sigs, engine.isRunning=\(engineOwner.engine.isRunning)")
                engineOwner.patchSignatureByMappingKey = engineOwner.patchSignatureByMappingKey.filter { $1.auSubType != nil }
                // If engine is in a zombie state (isRunning but not rendering), stop it
                // so configureAudioGraphIfNeeded() does a clean start on next play.
                if engineOwner.engine.isRunning && !engineOwner.isPlaying {
                    engineOwner.engine.stop()
                    engineOwner.fileLog("SYSTEM_WAKE: stopped idle engine for clean restart")
                }
            }
        }
        #endif
        startHealthCheckTimer()
    }

    deinit {
        healthCheckTimer?.cancel()
        meterPublishTimer?.cancel()
        automationTimer?.cancel()
        loopRecordingTimer?.cancel()
        playbackStopWorkItem?.cancel()
        hostedMIDIDeliveryWorkItem?.cancel()
        for timer in fadeTimers.values { timer.cancel() }
        auObservations.removeAll()
        audioFileCache.removeAll()
        if let obs = engineConfigObserver {
            NotificationCenter.default.removeObserver(obs)
        }
        #if os(macOS)
        if let obs = systemWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
        #endif
    }

    /// Periodic health check (every 1s) to detect dead out-of-process AUs
    /// and auto-recover when the engine stops unexpectedly during playback.
    private func startHealthCheckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.checkAUHealth()
        }
        timer.resume()
        healthCheckTimer = timer
    }

    private func checkAUHealth() {
        // Skip health check during playback setup/teardown
        guard !isReconfiguring else { return }

        // Auto-recover if the engine stopped unexpectedly during playback.
        // This catches device changes, config changes that didn't trigger our
        // notification handler, and any other unexpected engine stops.
        if !engine.isRunning && isPlaying {
            NSLog("[Engine] Health check: engine stopped during playback — restarting")
            reportError("[Engine] Auto-recovering: engine stopped unexpectedly")
            fileLog("HEALTH_CHECK: engine stopped during playback, triggering restart")

            // Check for dead AUs only when engine is already stopped — querying
            // renderResourcesAllocated during active rendering can return false
            // transiently and cause false positives that kill live AUs.
            var deadKeys: [String] = []
            for (key, auUnit) in auInstrumentByMappingKey {
                if !auUnit.auAudioUnit.renderResourcesAllocated {
                    deadKeys.append(key)
                }
            }
            for key in deadKeys {
                NSLog("[Engine] Health check: removing dead AU '%@'", key)
                removeDeadAU(mappingKey: key)
            }

            let savedPosition = currentPlaybackPositionInBeats()
            NSLog("[Engine] Health check: requesting full restart at beat %.2f", savedPosition)
            reportError("[Engine] Recovered — restarting playback")
            // Trigger a full restart via the store rather than restarting the sequencer
            // in-place. In-place restart (engine.start + seq.start) produces silent audio
            // when the sequencer's track connections are stale after an unexpected stop.
            //
            // Clear SF2 signatures so loadInstrument re-calls loadSoundBankInstrument on
            // restart. After an unexpected engine stop, AVAudioUnitSampler render resources
            // may be in an undefined state; re-loading the soundfont restores audio output.
            // AU signatures are preserved — AUs stay properly initialized through engine stops.
            patchSignatureByMappingKey = patchSignatureByMappingKey.filter { $1.auSubType != nil }
            fileLog("HEALTH_CHECK: cleared SF2 sigs, calling onNeedsPlaybackRestart at beat \(String(format: "%.2f", savedPosition))")
            onNeedsPlaybackRestart?(savedPosition)
            // Suppress further health check runs until the restart completes.
            // Without this, the 1s timer fires again before playOnAudioQueue() runs,
            // enqueuing a second restart that causes spurious advances or clean stops.
            isReconfiguring = true

            if !deadKeys.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    for key in deadKeys {
                        self?.onAUDisconnected?(key)
                    }
                }
            }
        } else if !engine.isRunning && !auInstrumentByMappingKey.isEmpty && !isPlaying {
            // Engine stopped and AUs loaded but not playing — check for dead AUs
            var deadKeys: [String] = []
            for (key, auUnit) in auInstrumentByMappingKey {
                if !auUnit.auAudioUnit.renderResourcesAllocated {
                    deadKeys.append(key)
                }
            }
            if !deadKeys.isEmpty {
                NSLog("[Engine] Health check: found %d dead AU(s) while idle", deadKeys.count)
                for key in deadKeys {
                    removeDeadAU(mappingKey: key)
                }
                do { try engine.start() } catch {
                    NSLog("[Engine] Health check: failed to restart engine after dead AU removal: %@", error.localizedDescription)
                    reportError("Engine restart failed after AU recovery: \(error.localizedDescription)")
                }
                DispatchQueue.main.async { [weak self] in
                    for key in deadKeys {
                        self?.onAUDisconnected?(key)
                    }
                }
            }
        }
    }

    private func nextPlayRequestID() -> UInt64 {
        playRequestLock.lock()
        latestPlayRequestID &+= 1
        let id = latestPlayRequestID
        playRequestLock.unlock()
        return id
    }

    private func invalidatePendingPlayRequests() {
        playRequestLock.lock()
        latestPlayRequestID &+= 1
        playRequestLock.unlock()
    }

    private func isPlayRequestCurrent(_ requestID: UInt64) -> Bool {
        playRequestLock.lock()
        let isCurrent = latestPlayRequestID == requestID
        playRequestLock.unlock()
        return isCurrent
    }

    /// Remove a dead AU node from the audio graph.
    private func removeDeadAU(mappingKey: String) {
        auObservations.removeValue(forKey: mappingKey)
        patchSignatureByMappingKey.removeValue(forKey: mappingKey)
        if let auUnit = auInstrumentByMappingKey.removeValue(forKey: mappingKey) {
            withEnginePaused {
                if let panMixer = panMixerByMappingKey.removeValue(forKey: mappingKey) {
                    engine.disconnectNodeOutput(panMixer)
                    engine.detach(panMixer)
                }
                // Clean up multi-output bus mixers if present
                if let busMixers = multiOutputMixersByMappingKey.removeValue(forKey: mappingKey) {
                    for m in busMixers {
                        engine.disconnectNodeOutput(m)
                        engine.detach(m)
                    }
                }
                engine.disconnectNodeOutput(auUnit)
                engine.detach(auUnit)
            }
        }
    }

    /// Called when the audio engine's configuration changes (e.g., device switch, AU disconnect).
    /// Transparently recover from an engine configuration change (device switch, AU crash, etc.).
    /// Apple docs: "the engine stops itself" before posting this notification. Nodes remain
    /// attached and connected. We restart the engine and resume the sequencer from where it was.
    /// Must be called on audioQueue.
    private func handleEngineConfigurationChange() {
        // If we caused this change (via engine.pause() in stopOnAudioQueue or
        // withEnginePaused), it is not a hardware event — skip the restart logic.
        // Uses a depth counter so multiple back-to-back withEnginePaused calls
        // (e.g., buffer setup + sampler attach during playOnAudioQueue) each queue
        // a notification; the counter consumes exactly one notification per pause.
        fileLog("CONFIG_CHANGE_ENTRY: depth=\(engineStopIsOursDepth) isReconfiguring=\(isReconfiguring) isPlaying=\(isPlaying)")

        // If we're in the middle of playback setup/teardown, all pending notifications
        // are from our own withEnginePaused calls — not real hardware events. Skip them.
        // isReconfiguring stays true until the deferred audioQueue.async clear runs,
        // which drains all pending notifications before allowing health checks.
        if isReconfiguring {
            fileLog("CONFIG_CHANGE: skipped — isReconfiguring=true (setup/teardown in progress)")
            return
        }

        // Fallback: depth counter absorbs stale notifications that arrive after
        // isReconfiguring was cleared but before the cleanup async runs.
        if engineStopIsOursDepth > 0 {
            engineStopIsOursDepth -= 1
            fileLog("CONFIG_CHANGE: consumed by depth counter (remaining=\(engineStopIsOursDepth))")
            return
        }

        isReconfiguring = true

        let wasPlaying = isPlaying
        let savedPosition = currentPlaybackPositionInBeats()
        NSLog("[Engine] Configuration change — wasPlaying=%d, pos=%.2f", wasPlaying ? 1 : 0, savedPosition)
        reportError("[Engine] Config change detected (wasPlaying=\(wasPlaying), beat=\(String(format: "%.1f", savedPosition)))")
        fileLog("CONFIG_CHANGE: wasPlaying=\(wasPlaying) pos=\(String(format: "%.2f", savedPosition))")

        // Scan for dead AU nodes and remove them (safe while engine is stopped)
        var deadKeys: [String] = []
        for (key, auUnit) in auInstrumentByMappingKey {
            if !auUnit.auAudioUnit.renderResourcesAllocated {
                deadKeys.append(key)
            }
        }
        for key in deadKeys {
            NSLog("[Engine] Removing dead AU node for '%@'", key)
            removeDeadAU(mappingKey: key)
        }

        // Clear SF2 signatures — after a real hardware stop AVAudioUnitSampler render
        // resources may be in an undefined state. Calling loadSoundBankInstrument again
        // restores audio output. Both happen on audioQueue so there is no race.
        // AU signatures are preserved — AUs stay properly initialized through engine stops.
        patchSignatureByMappingKey = patchSignatureByMappingKey.filter { $1.auSubType != nil }
        fileLog("CONFIG_CHANGE: cleared SF2 sigs (wasPlaying=\(wasPlaying))")

        if wasPlaying {
            // Request a full playback restart via the store — playOnAudioQueue will
            // restart the engine via configureAudioGraphIfNeeded(). Do NOT try engine.start()
            // here: if it fails we'd call setPlaying(false) with no recovery, and if it
            // succeeds the engine gets paused again immediately by stopOnAudioQueue inside
            // playOnAudioQueue anyway.
            //
            // Keep isReconfiguring = true so the 1s health check can't fire between now and
            // when playOnAudioQueue runs. playOnAudioQueue clears isReconfiguring at the end.
            NSLog("[Engine] Config change — cleared SF2 sigs, requesting full playback restart at beat %.2f", savedPosition)
            fileLog("CONFIG_CHANGE: calling onNeedsPlaybackRestart at beat \(String(format: "%.2f", savedPosition))")
            onNeedsPlaybackRestart?(savedPosition)
            // isReconfiguring intentionally left true — playOnAudioQueue will clear it.
        } else {
            // Not playing — leave engine stopped, clear the flag.
            // SF2 sigs already cleared above so the next play starts fresh.
            isReconfiguring = false
        }

        // Notify UI about dead AUs
        if !deadKeys.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for key in deadKeys {
                    self.onAUDisconnected?(key)
                }
                self.onPlaybackError?("Audio Unit crashed — reconnecting automatically...")
            }
        }
    }

    func play(
        notes: [PianoRollNote],
        lengthTicks: Int,
        ticksPerQuarter: Int,
        tempoBPM: Double,
        tempoEvents: [TempoPoint],
        loop: Bool,
        startTick: Int,
        trackChannelToMappingKey: [String: String],
        instrumentMappings: [String: InstrumentMapping],
        audioClips: [AudioClip],
        renderMode: PlaybackRenderMode,
        mutedTracks: Set<Int> = []
    ) {
        let requestID = nextPlayRequestID()
        audioQueue.async { [weak self] in
            guard let self else { return }
            guard self.isPlayRequestCurrent(requestID) else { return }
            self.playOnAudioQueue(
                notes: notes,
                lengthTicks: lengthTicks,
                ticksPerQuarter: ticksPerQuarter,
                tempoBPM: tempoBPM,
                tempoEvents: tempoEvents,
                loop: loop,
                startTick: startTick,
                trackChannelToMappingKey: trackChannelToMappingKey,
                instrumentMappings: instrumentMappings,
                audioClips: audioClips,
                renderMode: renderMode,
                mutedTracks: mutedTracks,
                requestID: requestID
            )
        }
    }

    func stop() {
        invalidatePendingPlayRequests()
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.stopOnAudioQueue(pauseEngine: false)
        }
    }

    func previewNote(pitch: Int, velocity: Int = 104, duration: Double = 0.20) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.previewOnAudioQueue(pitch: pitch, velocity: velocity, duration: duration)
        }
    }

    func setPreviewMapping(_ mapping: InstrumentMapping?) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.previewMapping = mapping
            // Force reload by clearing the cached patch signature so the next
            // preview call picks up the new soundfont / program / bank.
            self.patchSignatureByMappingKey[self.previewSamplerKey] = nil
        }
    }

    func setPreferredBufferFrames(_ frames: UInt32) {
        let clamped = min(max(frames, 64), 4096)
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.preferredBufferFrames = clamped
            self.applyRenderBufferSettingsOnAudioQueue()
        }
    }

    func setMasterVolume(_ value: Double) {
        let clamped = Float(min(max(value, 0), 1))
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.masterOutputVolume = clamped
            self.engine.mainMixerNode.outputVolume = clamped
        }
    }

    /// Set per-track volume on the submix node (real-time safe, called during playback).
    func setTrackVolume(trackID: UUID, volume: Double) {
        let clamped = Float(min(max(volume, 0), 1))
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.trackSubmixNodes[trackID]?.outputVolume = clamped
        }
    }

    /// Set per-track pan on the submix node (real-time safe, called during playback).
    func setTrackPan(trackID: UUID, pan: Double) {
        let clamped = Float(min(max(pan, -1), 1))
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.trackSubmixNodes[trackID]?.pan = clamped
        }
    }

    /// Per-mapping-key pan mixer nodes (inserted between sampler/AU and mainMixer).
    private var panMixerByMappingKey: [String: AVAudioMixerNode] = [:]

    /// Per-mapping-key multi-output bus mixers (for AUs with >1 output bus).
    private var multiOutputMixersByMappingKey: [String: [AVAudioMixerNode]] = [:]

    /// Set pan on a sampler/AU channel by mapping key (for channel strip pan).
    func setSamplerPan(mappingKey: String, pan: Double) {
        let clamped = Float(min(max(pan, -1), 1))
        audioQueue.async { [weak self] in
            guard let self else { return }
            if let sampler = self.samplerByMappingKey[mappingKey] {
                sampler.pan = clamped
            }
            self.panMixerByMappingKey[mappingKey]?.pan = clamped
        }
    }

    /// Retrieve the live AU instance for a mapping key (for plugin UI).
    /// Returns nil if no AU is loaded for this key. Must be called from audio queue.
    func getAudioUnit(for mappingKey: String, completion: @escaping @MainActor @Sendable (AUAudioUnit?) -> Void) {
        audioQueue.async { [weak self] in
            let au = self?.auInstrumentByMappingKey[mappingKey]?.auAudioUnit
            DispatchQueue.main.async { completion(au) }
        }
    }

    /// Ensure an Audio Unit is instantiated for the given mapping key, loading it on demand
    /// Force-reload an AU instrument (e.g. after an out-of-process crash).
    /// Clears the cached patch signature so loadAudioUnitIfNeeded will re-instantiate.
    func reloadAudioUnit(for mappingKey: String, mapping: InstrumentMapping) {
        audioQueue.async { [weak self] in
            guard let self, let desc = mapping.audioComponentDescription else { return }
            NSLog("[Engine] Reloading AU for '%@'", mappingKey)
            // Clear signature to force reload
            self.patchSignatureByMappingKey.removeValue(forKey: mappingKey)
            self.loadAudioUnitIfNeeded(mappingKey: mappingKey, mapping: mapping, description: desc)
            _ = self.configureAudioGraphIfNeeded()
            NSLog("[Engine] AU reload complete for '%@'", mappingKey)
        }
    }

    /// Reload all instruments based on current mappings.
    /// Call after master instrument toggle changes activeSource.
    func reloadAllInstruments(mappings: [String: InstrumentMapping]) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            NSLog("[Engine] reloadAllInstruments: tearing down %d samplers, %d AUs",
                  self.samplerByMappingKey.count, self.auInstrumentByMappingKey.count)

            // Clear all patch signatures to force reload
            self.patchSignatureByMappingKey.removeAll()

            // Rebuild graph with current mappings
            for (key, mapping) in mappings {
                if mapping.effectiveSourceType == .audioUnit,
                   let desc = mapping.audioComponentDescription {
                    self.loadAudioUnitIfNeeded(mappingKey: key, mapping: mapping, description: desc)
                } else {
                    let s = self.samplerByMappingKey[key] ?? {
                        let newSampler = AVAudioUnitSampler()
                        self.engine.attach(newSampler)
                        self.samplerByMappingKey[key] = newSampler
                        return newSampler
                    }()
                    self.loadInstrument(mapping, into: s, mappingKey: key)
                }
            }

            _ = self.configureAudioGraphIfNeeded()
            NSLog("[Engine] reloadAllInstruments complete")
        }
    }

    /// if it hasn't been loaded yet (e.g. before playback). Also starts the audio engine so the
    /// AU can produce sound immediately (e.g. when pressing keys in the plugin UI).
    func ensureAudioUnit(for mappingKey: String, mapping: InstrumentMapping, completion: @escaping @MainActor @Sendable (AUAudioUnit?) -> Void) {
        audioQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            // Already loaded — just ensure engine is running
            if let existing = self.auInstrumentByMappingKey[mappingKey]?.auAudioUnit {
                _ = self.configureAudioGraphIfNeeded()
                DispatchQueue.main.async { completion(existing) }
                return
            }
            // Not loaded yet — instantiate on demand
            guard let desc = mapping.audioComponentDescription else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            self.loadAudioUnitIfNeeded(mappingKey: mappingKey, mapping: mapping, description: desc)
            // Start the engine so the AU can produce audio immediately
            _ = self.configureAudioGraphIfNeeded()
            let au = self.auInstrumentByMappingKey[mappingKey]?.auAudioUnit
            DispatchQueue.main.async { completion(au) }
        }
    }

    /// Preload AU instruments while idle so playback transitions do not have to instantiate
    /// plugins on the render boundary.
    func prewarmAudioUnits(for mappings: [String: InstrumentMapping], completion: (@MainActor @Sendable () -> Void)? = nil) {
        let snapshot = mappings
        audioQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion?() }
                return
            }

            let orderedAUKeys = snapshot.keys
                .filter {
                    guard let mapping = snapshot[$0] else { return false }
                    return mapping.effectiveSourceType == .audioUnit && mapping.audioComponentDescription != nil
                }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

            guard !orderedAUKeys.isEmpty else {
                DispatchQueue.main.async { completion?() }
                return
            }

            // Only prewarm while transport is idle. Playback-start still has its own fallback path.
            guard !self.isPlaying else {
                DispatchQueue.main.async { completion?() }
                return
            }

            _ = self.configureAudioGraphIfNeeded()

            for mappingKey in orderedAUKeys {
                guard let mapping = snapshot[mappingKey],
                      let description = mapping.audioComponentDescription else { continue }
                self.loadAudioUnitIfNeeded(mappingKey: mappingKey, mapping: mapping, description: description)
            }

            DispatchQueue.main.async { completion?() }
        }
    }

    /// Diagnostic: dump the state of all loaded AU instruments and samplers.
    func dumpAudioUnitState(completion: @escaping @MainActor @Sendable ([[String: String]]) -> Void) {
        audioQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            var result: [[String: String]] = []
            for (key, au) in self.auInstrumentByMappingKey {
                let connected = self.engine.attachedNodes.contains(au)
                result.append([
                    "mappingKey": key,
                    "type": "audioUnit",
                    "name": au.name,
                    "attached": String(connected),
                    "hasPreset": String(au.auAudioUnit.fullState != nil),
                    "renderResourcesAllocated": String(au.auAudioUnit.renderResourcesAllocated),
                ])
            }
            for (key, sampler) in self.samplerByMappingKey {
                let connected = self.engine.attachedNodes.contains(sampler)
                result.append([
                    "mappingKey": key,
                    "type": "sampler",
                    "attached": String(connected),
                    "volume": String(format: "%.2f", sampler.volume),
                ])
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: - Metering API

    /// Get current meter levels for all tracks and master. Thread-safe snapshot.
    func getMeterLevels(completion: @escaping @Sendable ([UUID: MeterLevels], MeterLevels) -> Void) {
        audioQueue.async { [weak self] in
            guard let self else {
                completion([:], .zero)
                return
            }
            let tracks = self.meterTapLevels
            let master = self.masterMeterRaw
            completion(tracks, master)
        }
    }

    // MARK: - Metronome API

    /// Configure metronome settings. Called from ScoreStore when user changes metronome state.
    func configureMetronome(enabled: Bool, volume: Float, countInBars: Int) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.metronomeEnabled = enabled
            self.metronomeVolume = min(max(volume, 0), 1)
            self.metronomeCountInBars = min(max(countInBars, 0), 4)

            // Generate click buffers if needed
            if enabled && self.metronomeDownbeatBuffer == nil {
                self.metronomeDownbeatBuffer = self.generateClickBuffer(frequency: 1000, duration: 0.04, sampleRate: 44100)
                self.metronomeUpbeatBuffer = self.generateClickBuffer(frequency: 800, duration: 0.04, sampleRate: 44100)
            }
        }
    }

    /// Update metronome volume during playback (real-time safe).
    func setMetronomeVolume(_ volume: Float) {
        let clamped = min(max(volume, 0), Float(1))
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.metronomeVolume = clamped
            self.metronomeNode?.volume = clamped
        }
    }

    // MARK: - Recording API

    /// Start recording audio from the engine's input node to a WAV file.
    /// Must be called after the engine is running (i.e., during playback).
    func startRecording(trackID: UUID, outputURL: URL) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.startRecordingOnAudioQueue(trackID: trackID, outputURL: outputURL)
        }
    }

    /// Stop recording and return the output file URL via the onRecordingComplete callback.
    func stopRecording() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.stopRecordingOnAudioQueue()
        }
    }

    /// Start capturing the engine's main mix to a WAV file. Used for real-time export
    /// so third-party Audio Units render through the same path as live playback.
    func startMainMixRecording(outputURL: URL) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.startMainMixRecordingOnAudioQueue(outputURL: outputURL)
        }
    }

    /// Stop capturing the engine's main mix and finalize the WAV file.
    func stopMainMixRecording() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.stopMainMixRecordingOnAudioQueue()
        }
    }

    /// Configure input monitoring: route hardware input through a track's FX chain.
    func configureInputMonitoring(trackID: UUID, enabled: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            if enabled {
                self.enableInputMonitoringOnAudioQueue(trackID: trackID)
            } else {
                self.disableInputMonitoringOnAudioQueue(trackID: trackID)
            }
        }
    }

    // MARK: - Recording Implementation

    private func startRecordingOnAudioQueue(trackID: UUID, outputURL: URL) {
        guard !isRecordingAudio else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Ensure engine is running
        guard configureAudioGraphIfNeeded() else {
            reportError("Cannot start recording: audio engine failed to start.")
            return
        }

        // Create the output WAV file
        do {
            let file = try AVAudioFile(
                forWriting: outputURL,
                settings: inputFormat.settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
            os_unfair_lock_lock(&recordingLock)
            recordingFile = file
            isRecordingAudio = true
            os_unfair_lock_unlock(&recordingLock)
            recordingHadWriteError = false
            recordingTrackID = trackID

            // Install tap on input node to capture audio
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self else { return }
                // Lock protects recordingFile/isRecordingAudio from concurrent
                // writes on audioQueue while this tap fires on the IOThread.
                os_unfair_lock_lock(&self.recordingLock)
                let recording = self.isRecordingAudio
                let file = self.recordingFile
                os_unfair_lock_unlock(&self.recordingLock)
                guard recording, let file else { return }
                do {
                    try file.write(from: buffer)
                } catch {
                    // Flag the error — stopRecordingOnAudioQueue will report it.
                    // Cannot call reportError here (IOThread — no ObjC messaging).
                    self.recordingHadWriteError = true
                }
            }
        } catch {
            reportError("Failed to create recording file: \(error.localizedDescription)")
        }
    }

    private func stopRecordingOnAudioQueue() {
        guard isRecordingAudio else { return }

        // Remove the tap first — this synchronizes with the render thread,
        // ensuring no more tap callbacks will fire after this returns.
        engine.inputNode.removeTap(onBus: 0)

        // Now safe to clear recording state under the lock.
        os_unfair_lock_lock(&recordingLock)
        let fileURL = recordingFile?.url
        recordingFile = nil
        isRecordingAudio = false
        os_unfair_lock_unlock(&recordingLock)
        recordingTrackID = nil

        let hadError = recordingHadWriteError
        recordingHadWriteError = false

        if hadError {
            reportError("Recording may be incomplete — disk write errors occurred during capture.")
        }
        if let url = fileURL {
            let callback = onRecordingComplete
            DispatchQueue.main.async {
                callback?(url)
            }
        }
    }

    private func startMainMixRecordingOnAudioQueue(outputURL: URL) {
        guard !isRecordingMainMix else { return }

        let mixFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        guard mixFormat.channelCount > 0, mixFormat.sampleRate > 0 else {
            reportError("Cannot start mix export: invalid main mixer format.")
            return
        }

        do {
            let file = try AVAudioFile(
                forWriting: outputURL,
                settings: mixFormat.settings,
                commonFormat: mixFormat.commonFormat,
                interleaved: mixFormat.isInterleaved
            )
            os_unfair_lock_lock(&mixdownRecordingLock)
            mixdownRecordingFile = file
            isRecordingMainMix = true
            os_unfair_lock_unlock(&mixdownRecordingLock)
            mixdownRecordingHadWriteError = false
        } catch {
            reportError("Failed to create mix export file: \(error.localizedDescription)")
        }
    }

    private func stopMainMixRecordingOnAudioQueue() {
        guard isRecordingMainMix else { return }

        os_unfair_lock_lock(&mixdownRecordingLock)
        let fileURL = mixdownRecordingFile?.url
        mixdownRecordingFile = nil
        isRecordingMainMix = false
        os_unfair_lock_unlock(&mixdownRecordingLock)

        mixdownWriteGroup.wait()

        let hadError = mixdownRecordingHadWriteError
        mixdownRecordingHadWriteError = false

        if hadError {
            reportError("Mix export may be incomplete — disk write errors occurred during capture.")
        }
        if let url = fileURL {
            let callback = onMainMixRecordingComplete
            DispatchQueue.main.async {
                callback?(url)
            }
        }
    }

    // MARK: - Loop Recording

    /// Configure loop recording mode. When enabled, the engine will detect when
    /// the playhead crosses the loop boundary and split the recording into a new file.
    func configureLoopRecording(
        enabled: Bool,
        loopStart: Int,
        loopEnd: Int,
        outputURLGenerator: @escaping @Sendable () -> URL
    ) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.loopRecordingEnabled = enabled
            self.loopStartTick = loopStart
            self.loopEndTick = loopEnd
            self.loopRecordingOutputGenerator = outputURLGenerator
        }
    }

    /// Start the loop recording timer. Runs at 60Hz to detect loop boundary crossings.
    private func startLoopRecordingTimer(
        startTick: Int,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int
    ) {
        loopRecordingTimer?.cancel()
        guard loopRecordingEnabled, loopEndTick > loopStartTick else { return }

        lastLoopCheckTick = startTick

        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now() + 0.05, repeating: .milliseconds(16), leeway: .milliseconds(4))
        let startTime = DispatchTime.now()
        let startSeconds = seconds(atTick: startTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
        let loopEnd = loopEndTick
        let loopStart = loopStartTick

        timer.setEventHandler { [weak self] in
            guard let self, self.isRecordingAudio, self.loopRecordingEnabled else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
            let currentSeconds = startSeconds + elapsed
            let currentTick = self.tickAtSeconds(currentSeconds, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)

            // Detect loop boundary crossing: the playhead has wrapped from loopEnd back to loopStart
            if self.lastLoopCheckTick < loopEnd && currentTick >= loopEnd {
                self.splitRecordingForLoopPass()
            }
            // Also handle the case where audio engine loops back (currentTick < lastCheckTick by a lot)
            else if currentTick < self.lastLoopCheckTick - (loopEnd - loopStart) / 2 {
                self.splitRecordingForLoopPass()
            }
            self.lastLoopCheckTick = currentTick
        }
        loopRecordingTimer = timer
        timer.resume()
    }

    private func stopLoopRecordingTimer() {
        loopRecordingTimer?.cancel()
        loopRecordingTimer = nil
        loopRecordingEnabled = false
    }

    /// Atomically swap the recording file to a new one for the next loop pass.
    /// The old file is finalized and reported via onLoopPassComplete.
    private func splitRecordingForLoopPass() {
        guard isRecordingAudio, let currentFile = recordingFile,
              let generator = loopRecordingOutputGenerator else { return }

        // Get new output URL — generator is not @MainActor so safe to call on audioQueue.
        // Do NOT use DispatchQueue.main.sync here: audioQueue↔main deadlock risk.
        let newURL = generator()

        // Close current file (the tap will keep running, we just swap the file)
        let completedURL = currentFile.url

        // Create new file with same format
        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        do {
            let newFile = try AVAudioFile(
                forWriting: newURL,
                settings: inputFormat.settings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            )
            // Swap under lock: the tap callback reads recordingFile on the IOThread
            os_unfair_lock_lock(&recordingLock)
            recordingFile = newFile
            os_unfair_lock_unlock(&recordingLock)
        } catch {
            // If we can't create the new file, keep writing to the old one
            reportError("Loop recording: failed to create new pass file — \(error.localizedDescription)")
            return
        }

        // Notify about the completed pass
        let callback = onLoopPassComplete
        DispatchQueue.main.async {
            callback?(completedURL)
        }
    }

    private func enableInputMonitoringOnAudioQueue(trackID: UUID) {
        guard inputMonitorNodes[trackID] == nil else { return }

        // Ensure engine is running
        guard configureAudioGraphIfNeeded() else { return }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Create a monitor mixer node between input and track submix
        let monitorMixer = AVAudioMixerNode()

        // Must pause engine before graph mutations to avoid IOThread race
        withEnginePaused {
            engine.attach(monitorMixer)
            monitorMixer.outputVolume = 1.0

            // Route: inputNode → monitorMixer → trackSubmix → [FX chain] → mainMixer
            let submix = ensureTrackSubmix(trackID: trackID, format: nil)
            engine.connect(inputNode, to: monitorMixer, format: inputFormat)
            engine.connect(monitorMixer, to: submix, format: inputFormat)
        }

        inputMonitorNodes[trackID] = monitorMixer
    }

    private func disableInputMonitoringOnAudioQueue(trackID: UUID) {
        guard let monitorMixer = inputMonitorNodes.removeValue(forKey: trackID) else { return }
        withEnginePaused {
            engine.disconnectNodeOutput(monitorMixer)
            engine.disconnectNodeInput(monitorMixer)
            engine.detach(monitorMixer)
        }
    }

    /// Ensure a per-track submix mixer node exists. Creates one if needed.
    /// All clips on this track route through this node instead of directly to mainMixerNode.
    private func ensureTrackSubmix(trackID: UUID, format: AVAudioFormat?) -> AVAudioMixerNode {
        if let existing = trackSubmixNodes[trackID] { return existing }
        let mixer = AVAudioMixerNode()
        // Caller is responsible for pausing the engine if it's running.
        // When called from within a withEnginePaused block, this is safe.
        engine.attach(mixer)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        trackSubmixNodes[trackID] = mixer
        return mixer
    }

    /// Remove all per-track submix nodes. Call on project close or when tearing down the mix session.
    func tearDownTrackSubmixNodes() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.withEnginePaused {
                for node in self.trackSubmixNodes.values {
                    self.engine.disconnectNodeOutput(node)
                    self.engine.detach(node)
                }
            }
            self.trackSubmixNodes.removeAll()
        }
    }

    /// Set the FX chain for a track. Inserts effects in series between the submix node and mainMixerNode.
    /// Must be called from the audio queue or before playback starts.
    func setTrackFXChain(trackID: UUID, effects: [AVAudioUnitEffect]) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.rewireTrackFXChain(trackID: trackID, effects: effects)
        }
    }

    private func rewireTrackFXChain(trackID: UUID, effects: [AVAudioUnitEffect]) {
        guard let submix = trackSubmixNodes[trackID] else { return }

        withEnginePaused {
            // Remove old FX chain
            if let oldChain = trackFXChains[trackID] {
                for fx in oldChain {
                    engine.disconnectNodeOutput(fx)
                    engine.detach(fx)
                }
            }

            // Disconnect submix from its current destination
            engine.disconnectNodeOutput(submix)

            if effects.isEmpty {
                // No effects: connect submix directly to mainMixerNode
                engine.connect(submix, to: engine.mainMixerNode, format: nil)
                trackFXChains[trackID] = []
            } else {
                // Insert effects in series: submix → fx1 → fx2 → ... → mainMixer
                for fx in effects {
                    engine.attach(fx)
                }
                // submix → first effect
                engine.connect(submix, to: effects[0], format: nil)
                // chain effects together
                for i in 0..<(effects.count - 1) {
                    engine.connect(effects[i], to: effects[i + 1], format: nil)
                }
                // last effect → mainMixer
                guard let lastFX = effects.last else { return }
                engine.connect(lastFX, to: engine.mainMixerNode, format: nil)
                trackFXChains[trackID] = effects
            }
        }
    }

    /// Clear all FX chains (for project close).
    func clearTrackFXChains() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.withEnginePaused {
                for (_, chain) in self.trackFXChains {
                    for fx in chain {
                        self.engine.disconnectNodeOutput(fx)
                        self.engine.detach(fx)
                    }
                }
            }
            self.trackFXChains.removeAll()
        }
    }

    // MARK: - Send Routing

    /// Configure sends from source tracks to bus tracks.
    /// Sends are lightweight mixer nodes that connect a source track's output to a bus track's submix input.
    /// The send mixer controls send volume and pan.
    func configureSends(_ sends: [(sendID: UUID, sourceTrackID: UUID, destTrackID: UUID, volume: Float, pan: Float)]) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.withEnginePaused {
                // Remove existing send nodes
                for (_, node) in self.sendMixerNodes {
                    self.engine.disconnectNodeOutput(node)
                    self.engine.detach(node)
                }
                self.sendMixerNodes.removeAll()

                for send in sends {
                    guard let sourceSubmix = self.trackSubmixNodes[send.sourceTrackID],
                          let destSubmix = self.trackSubmixNodes[send.destTrackID] else { continue }

                    // Create a send mixer node
                    let sendMixer = AVAudioMixerNode()
                    self.engine.attach(sendMixer)
                    sendMixer.outputVolume = send.volume
                    sendMixer.pan = send.pan

                    // Connect: source submix → send mixer → dest bus submix
                    // The source submix already connects to mainMixer (or FX chain → mainMixer).
                    // AVAudioMixerNode supports multiple inputs, so dest submix can receive from multiple sends.
                    self.engine.connect(sourceSubmix, to: sendMixer, format: nil)
                    self.engine.connect(sendMixer, to: destSubmix, format: nil)
                    self.sendMixerNodes[send.sendID] = sendMixer
                }
            }
        }
    }

    /// Update a single send's volume.
    func setSendVolume(sendID: UUID, volume: Float) {
        audioQueue.async { [weak self] in
            self?.sendMixerNodes[sendID]?.outputVolume = volume
        }
    }

    /// Update a single send's pan.
    func setSendPan(sendID: UUID, pan: Float) {
        audioQueue.async { [weak self] in
            self?.sendMixerNodes[sendID]?.pan = pan
        }
    }

    /// Clear all send routing nodes.
    func clearSendRouting() {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.withEnginePaused {
                for (_, node) in self.sendMixerNodes {
                    self.engine.disconnectNodeOutput(node)
                    self.engine.detach(node)
                }
            }
            self.sendMixerNodes.removeAll()
        }
    }

    // MARK: - Metronome Implementation

    /// Generate a short sine-wave click buffer for the metronome.
    /// Attack: 2ms, sustain+decay: remaining duration. Mono Float32.
    private func generateClickBuffer(frequency: Double, duration: Double, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { return nil }
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount

        guard let data = buffer.floatChannelData?[0] else { return nil }
        let twoPi = 2.0 * Double.pi
        let attackFrames = Int(sampleRate * 0.002)  // 2ms attack
        let totalFrames = Int(frameCount)

        for i in 0..<totalFrames {
            let phase = sin(twoPi * frequency * Double(i) / sampleRate)
            let envelope: Double
            if i < attackFrames {
                // Linear attack
                envelope = Double(i) / Double(attackFrames)
            } else {
                // Exponential decay
                let decaySpan = totalFrames - attackFrames
                let decayProgress = decaySpan > 0 ? Double(i - attackFrames) / Double(decaySpan) : 1.0
                envelope = max(0, 1.0 - decayProgress) * exp(-3.0 * decayProgress)
            }
            data[i] = Float(phase * envelope * 0.8)  // 0.8 peak to avoid clipping
        }
        return buffer
    }

    /// Setup metronome player node and connect to main mixer.
    /// Must be called on audioQueue after engine is running.
    private func setupMetronomeNodeOnAudioQueue() {
        guard metronomeEnabled else { return }

        // Use the engine's actual output sample rate for click buffers
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let clickRate = outputRate > 0 ? outputRate : 44100.0

        // Generate click buffers if not yet created (or if sample rate changed)
        if metronomeDownbeatBuffer == nil || metronomeDownbeatBuffer?.format.sampleRate != clickRate {
            metronomeDownbeatBuffer = generateClickBuffer(frequency: 1000, duration: 0.04, sampleRate: clickRate)
        }
        if metronomeUpbeatBuffer == nil || metronomeUpbeatBuffer?.format.sampleRate != clickRate {
            metronomeUpbeatBuffer = generateClickBuffer(frequency: 800, duration: 0.04, sampleRate: clickRate)
        }

        let node = AVAudioPlayerNode()
        engine.attach(node)
        // Connect mono click to main mixer (engine auto-upmixes mono→stereo)
        let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: clickRate, channels: 1, interleaved: false)
        engine.connect(node, to: engine.mainMixerNode, format: monoFormat)
        node.volume = metronomeVolume
        node.play()
        metronomeNode = node
    }

    /// Schedule metronome clicks for all beats from startTick to lengthTicks.
    /// Uses the existing seconds(atTick:...) helper for tempo-map-aware positioning.
    private func scheduleMetronomeClicks(
        startTick: Int,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int,
        lengthTicks: Int,
        timeSignatures: [TimeSignatureEvent] = []
    ) {
        guard metronomeEnabled,
              let node = metronomeNode,
              let downbeatBuf = metronomeDownbeatBuffer,
              let upbeatBuf = metronomeUpbeatBuffer else { return }

        let tpq = max(1, ticksPerQuarter)
        let startSeconds = seconds(atTick: startTick, tempoMap: tempoMap, ticksPerQuarter: tpq)

        // Sort time signatures by tick for lookup
        let sortedTimeSigs = timeSignatures.sorted { $0.tick < $1.tick }

        // Get the render time of the player node's start
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else { return }

        let sampleRate = playerTime.sampleRate
        let hostSampleTime = playerTime.sampleTime

        // Schedule clicks at each beat position
        var beatTick = startTick - (startTick % tpq)  // Align to beat boundary
        if beatTick < startTick { beatTick += tpq }

        while beatTick < lengthTicks {
            let beatSeconds = seconds(atTick: beatTick, tempoMap: tempoMap, ticksPerQuarter: tpq)
            let offsetSeconds = beatSeconds - startSeconds
            guard offsetSeconds >= 0 else {
                beatTick += tpq
                continue
            }

            let sampleOffset = AVAudioFramePosition(offsetSeconds * sampleRate)
            let scheduledTime = AVAudioTime(sampleTime: hostSampleTime + sampleOffset, atRate: sampleRate)

            // Determine beats per bar from the active time signature at this tick
            let beatsPerBar = activeBeatsPerBar(atTick: beatTick, timeSignatures: sortedTimeSigs, ticksPerQuarter: tpq)

            // Determine if this is beat 1 of a bar
            let barStartTick = barStartTickBefore(beatTick, timeSignatures: sortedTimeSigs, ticksPerQuarter: tpq)
            let beatsFromBarStart = (beatTick - barStartTick) / tpq
            let isDownbeat = beatsFromBarStart % beatsPerBar == 0
            let buffer = isDownbeat ? downbeatBuf : upbeatBuf

            node.scheduleBuffer(buffer, at: scheduledTime, options: [], completionHandler: nil)
            beatTick += tpq
        }
    }

    /// Returns the number of beats per bar for the time signature active at `tick`.
    private func activeBeatsPerBar(atTick tick: Int, timeSignatures: [TimeSignatureEvent], ticksPerQuarter tpq: Int) -> Int {
        // Find the last time signature at or before this tick
        var activeSig: TimeSignatureEvent? = nil
        for sig in timeSignatures where sig.tick <= tick {
            activeSig = sig
        }
        guard let sig = activeSig else { return 4 } // default 4/4
        // For compound meters (6/8, 9/8, 12/8), the beat unit is a dotted quarter
        // but the metronome clicks on quarter-note divisions. Return numerator adjusted
        // for the denominator relative to quarter notes.
        // numerator/denominator: 4/4 → 4 beats, 3/4 → 3 beats, 6/8 → 6 eighth-note beats (3 dotted-quarter groups)
        // Since we click every quarter note (tpq ticks), adjust numerator:
        // denom=4 → 1 beat per quarter, denom=8 → 0.5 beats per quarter, denom=2 → 2 beats per quarter
        let beatsPerBar = sig.numerator * 4 / max(1, sig.denominator)
        return max(1, beatsPerBar)
    }

    /// Returns the tick of the most recent bar start at or before `tick`.
    private func barStartTickBefore(_ tick: Int, timeSignatures: [TimeSignatureEvent], ticksPerQuarter tpq: Int) -> Int {
        // Find the active time signature
        var activeSig = TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)
        for sig in timeSignatures where sig.tick <= tick {
            activeSig = sig
        }
        let beatsPerBar = max(1, activeSig.numerator * 4 / max(1, activeSig.denominator))
        let ticksPerBar = beatsPerBar * tpq
        let ticksSinceSigStart = tick - activeSig.tick
        let barsElapsed = ticksSinceSigStart / ticksPerBar
        return activeSig.tick + barsElapsed * ticksPerBar
    }

    /// Tear down metronome node.
    private func tearDownMetronomeOnAudioQueue() {
        if let node = metronomeNode {
            node.stop()
            withEnginePaused {
                engine.disconnectNodeOutput(node)
                engine.detach(node)
            }
            metronomeNode = nil
        }
    }

    /// Set automation data snapshot before starting playback.
    /// trackLanes maps track UUID → array of automation lanes with breakpoints.
    /// trackVolumes/trackPans are the base values that automation scales against.
    func setAutomationData(
        trackLanes: [UUID: [AutomationLane]],
        trackVolumes: [UUID: Float],
        trackPans: [UUID: Float]
    ) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.automationSnapshot = trackLanes
            self.automationTrackVolumes = trackVolumes
            self.automationTrackPans = trackPans
        }
    }

    /// Start the automation timer. Runs at 60Hz on the audioQueue, computing
    /// the current playback tick and applying interpolated automation values.
    private func startAutomationTimer(
        startTick: Int,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int
    ) {
        automationTimer?.cancel()

        // Only start if there's actually automation data
        let hasAutomation = automationSnapshot.values.contains { lanes in
            lanes.contains { !$0.points.isEmpty }
        }
        guard hasAutomation else { return }

        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))
        let startTime = DispatchTime.now()
        let startSeconds = seconds(atTick: startTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)

        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000
            let currentSeconds = startSeconds + elapsed
            let currentTick = self.tickAtSeconds(currentSeconds, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
            self.applyAutomation(atTick: currentTick)
        }
        automationTimer = timer
        timer.resume()
    }

    /// Stop the automation timer and clear snapshot.
    private func stopAutomationTimer() {
        automationTimer?.cancel()
        automationTimer = nil
    }

    /// Apply automation values for all tracks at the given tick.
    private func applyAutomation(atTick tick: Int) {
        for (trackID, lanes) in automationSnapshot {
            guard let submix = trackSubmixNodes[trackID] else { continue }
            for lane in lanes where !lane.points.isEmpty {
                let value = interpolateAutomation(lane.points, atTick: tick)
                switch lane.parameter {
                case .volume:
                    let baseVol = automationTrackVolumes[trackID] ?? 0.8
                    submix.outputVolume = Float(value) * baseVol
                case .pan:
                    // Automation value 0–1 maps to pan -1..+1
                    submix.pan = Float(value * 2.0 - 1.0)
                case .mute:
                    let baseVol = automationTrackVolumes[trackID] ?? 0.8
                    submix.outputVolume = value < 0.5 ? 0 : baseVol
                }
            }
        }
    }

    /// Interpolate automation value at a given tick using binary search and curve math.
    private func interpolateAutomation(_ points: [AutomationPoint], atTick tick: Int) -> Double {
        guard !points.isEmpty else { return 0.5 }
        if tick <= points[0].tick { return points[0].value }
        if tick >= points[points.count - 1].tick { return points[points.count - 1].value }

        // Binary search for surrounding points
        var lo = 0, hi = points.count - 1
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            if points[mid].tick <= tick { lo = mid } else { hi = mid }
        }

        let p0 = points[lo], p1 = points[hi]
        let span = Double(max(1, p1.tick - p0.tick))
        let t = Double(tick - p0.tick) / span

        switch p0.curveType {
        case .linear:
            return p0.value + (p1.value - p0.value) * t
        case .square:
            return t < 1.0 ? p0.value : p1.value
        case .slowStart:
            return p0.value + (p1.value - p0.value) * (t * t)
        case .slowEnd:
            return p0.value + (p1.value - p0.value) * (1.0 - (1.0 - t) * (1.0 - t))
        case .sCurve:
            let s = t * t * (3.0 - 2.0 * t) // smoothstep
            return p0.value + (p1.value - p0.value) * s
        }
    }

    /// Inverse of seconds(atTick:): given elapsed seconds, find the corresponding tick.
    private func tickAtSeconds(_ targetSeconds: Double, tempoMap: [TempoPoint], ticksPerQuarter: Int) -> Int {
        guard !tempoMap.isEmpty, targetSeconds > 0 else { return 0 }
        let tpq = Double(max(1, ticksPerQuarter))
        var accumulatedSeconds: Double = 0

        for index in tempoMap.indices {
            let current = tempoMap[index]
            let secsPerTick = 60.0 / (max(20, current.bpm) * tpq)
            let nextTick: Int
            if index + 1 < tempoMap.count {
                nextTick = tempoMap[index + 1].tick
            } else {
                // Last segment — compute remaining ticks to reach targetSeconds
                let remaining = targetSeconds - accumulatedSeconds
                return current.tick + Int((remaining / secsPerTick).rounded())
            }

            let segmentTicks = Double(nextTick - current.tick)
            let segmentSeconds = segmentTicks * secsPerTick

            if accumulatedSeconds + segmentSeconds >= targetSeconds {
                let remaining = targetSeconds - accumulatedSeconds
                return current.tick + Int((remaining / secsPerTick).rounded())
            }
            accumulatedSeconds += segmentSeconds
        }
        return 0
    }

    /// Update loop state on the running engine without restarting playback.
    func setLoopEnabled(_ enabled: Bool) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.hostedMIDILoopEnabled = enabled
            // Update the clock state's isLooping flag
            self.playbackClockLock.lock()
            if var state = self.playbackClockState {
                state.isLooping = enabled
                self.playbackClockState = state
            }
            self.playbackClockLock.unlock()
        }
    }

    private func setPlaybackClockState(
        startTick: Int,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int,
        lengthTicks: Int,
        isLooping: Bool
    ) {
        let clampedStartTick = min(max(0, startTick), max(0, lengthTicks - 1))
        let songDurationSeconds = seconds(atTick: max(1, lengthTicks), tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
        let startSeconds = seconds(atTick: clampedStartTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
        let state = PlaybackClockState(
            startUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            startSeconds: startSeconds,
            tempoMap: tempoMap,
            ticksPerQuarter: ticksPerQuarter,
            lengthTicks: max(1, lengthTicks),
            isLooping: isLooping,
            initialPassDurationSeconds: max(0, songDurationSeconds - startSeconds),
            loopDurationSeconds: max(0.001, songDurationSeconds)
        )
        playbackClockLock.lock()
        playbackClockState = state
        playbackClockLock.unlock()
    }

    private func clearPlaybackClockState() {
        playbackClockLock.lock()
        playbackClockState = nil
        playbackClockLock.unlock()
    }

    private func currentPlaybackPositionInBeats() -> Double {
        playbackClockLock.lock()
        let clockState = playbackClockState
        playbackClockLock.unlock()

        guard let clockState else {
            return sequencer?.currentPositionInBeats ?? 0
        }

        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - clockState.startUptimeNanoseconds) / 1_000_000_000
        let currentSeconds: Double
        if clockState.isLooping {
            if elapsedSeconds <= clockState.initialPassDurationSeconds {
                currentSeconds = clockState.startSeconds + elapsedSeconds
            } else {
                let loopElapsed = elapsedSeconds - clockState.initialPassDurationSeconds
                currentSeconds = loopElapsed.truncatingRemainder(dividingBy: clockState.loopDurationSeconds)
            }
        } else {
            currentSeconds = max(clockState.startSeconds, clockState.startSeconds + elapsedSeconds)
        }
        let currentTick = min(
            max(0, tickAtSeconds(currentSeconds, tempoMap: clockState.tempoMap, ticksPerQuarter: clockState.ticksPerQuarter)),
            max(0, clockState.lengthTicks - 1)
        )
        return Double(currentTick) / Double(max(1, clockState.ticksPerQuarter))
    }

    /// Returns the MIDI instrument node for the given mapping key.
    /// For AU instruments, returns nil (AU is handled separately via auInstrumentByMappingKey).
    /// For SoundFont instruments, returns or creates an AVAudioUnitSampler.
    private func sampler(for mappingKey: String, mapping: InstrumentMapping?) -> AVAudioUnitSampler {
        // If this mapping uses an Audio Unit, load it asynchronously and return a silent sampler
        if let mapping, mapping.effectiveSourceType == .audioUnit, let desc = mapping.audioComponentDescription {
            loadAudioUnitIfNeeded(mappingKey: mappingKey, mapping: mapping, description: desc)
            // Return a placeholder sampler (muted) — AU will handle audio
            if let existing = samplerByMappingKey[mappingKey] { return existing }
            let placeholder = AVAudioUnitSampler()
            withEnginePaused {
                engine.attach(placeholder)
                engine.connect(placeholder, to: engine.mainMixerNode, format: nil)
            }
            placeholder.volume = 0
            samplerByMappingKey[mappingKey] = placeholder
            return placeholder
        }

        if let existing = samplerByMappingKey[mappingKey] {
            loadInstrument(mapping, into: existing, mappingKey: mappingKey)
            return existing
        }

        let sampler = AVAudioUnitSampler()
        let maxFrames = recommendedMaximumFramesToRender()
        if !sampler.auAudioUnit.renderResourcesAllocated {
            sampler.auAudioUnit.maximumFramesToRender = maxFrames
        }
        withEnginePaused {
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
        }
        samplerByMappingKey[mappingKey] = sampler
        loadInstrument(mapping, into: sampler, mappingKey: mappingKey)
        return sampler
    }

    private func applyAUGain(_ gainDB: Double, mappingKey: String) {
        // Apply AU "gain" at the host mixer level to avoid touching AU parameter trees
        // during song transitions (some out-of-process AUs are unstable there).
        let clampedDB = min(max(gainDB, -96.0), 24.0)
        let linear = clampedDB <= -96.0 ? Float(0) : Float(pow(10.0, clampedDB / 20.0))
        if let panMixer = panMixerByMappingKey[mappingKey] {
            panMixer.outputVolume = linear
        }
    }

    /// Load an Audio Unit instrument plugin synchronously on the audio queue.
    /// Uses a semaphore to block until the AU is instantiated — safe because audio queue
    /// is not the main thread and AU instantiation happens out-of-process.
    private func loadAudioUnitIfNeeded(mappingKey: String, mapping: InstrumentMapping, description: AudioComponentDescription) {
        let sig = SamplerPatchSignature(
            soundBankPath: nil, bankMSB: 0, bankLSB: 0, program: 0,
            // Gain changes should not force AU tear-down/re-instantiation.
            // Gain is updated in-place on an existing AU node.
            gainDB: 0,
            auSubType: description.componentSubType,
            auManufacturer: description.componentManufacturer
        )
        if patchSignatureByMappingKey[mappingKey] == sig {
            if auInstrumentByMappingKey[mappingKey] != nil {
                applyAUGain(mapping.gainDB, mappingKey: mappingKey)
                return
            }
            // Signature was cached but AU is missing (e.g. failed previous load).
            // Clear stale cache so we retry instantiation.
            patchSignatureByMappingKey.removeValue(forKey: mappingKey)
        }

        // Remove old AU if exists
        if let oldAU = auInstrumentByMappingKey.removeValue(forKey: mappingKey) {
            auObservations.removeValue(forKey: mappingKey)
            let oldPanMixer = panMixerByMappingKey.removeValue(forKey: mappingKey)
            withEnginePaused {
                engine.disconnectNodeOutput(oldAU)
                engine.detach(oldAU)
                if let pm = oldPanMixer {
                    engine.disconnectNodeOutput(pm)
                    engine.detach(pm)
                }
            }
        }

        // Instantiate AU synchronously with timeout — blocks audio queue but NOT main thread.
        // Out-of-process loading prevents beach balls with large plugins.
        let semaphore = DispatchSemaphore(value: 0)
        let loadResult = AULoadResultBox()

        AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess) { audioUnit, error in
            loadResult.store(unit: audioUnit, error: error)
            semaphore.signal()
        }

        let timeout = semaphore.wait(timeout: .now() + 10.0) // 10s timeout for large plugins
        let (loadedUnit, loadError) = loadResult.snapshot()
        guard timeout == .success, let audioUnit = loadedUnit else {
            NSLog("[Engine] AU load timeout/failed for %@: %@", mappingKey, loadError?.localizedDescription ?? "timeout")
            patchSignatureByMappingKey.removeValue(forKey: mappingKey)
            return
        }

        // Insert a pan mixer between AU and mainMixer for per-channel pan control
        let panMixer = AVAudioMixerNode()
        let maxFrames = recommendedMaximumFramesToRender()
        if !audioUnit.auAudioUnit.renderResourcesAllocated {
            audioUnit.auAudioUnit.maximumFramesToRender = maxFrames
        }
        withEnginePaused {
            engine.attach(audioUnit)
            engine.attach(panMixer)
            engine.connect(audioUnit, to: panMixer, format: nil)
            engine.connect(panMixer, to: engine.mainMixerNode, format: nil)
        }
        panMixerByMappingKey[mappingKey] = panMixer
        applyAUGain(mapping.gainDB, mappingKey: mappingKey)

        // Restore preset if available (try plist first, fall back to JSON for legacy data)
        if let presetData = mapping.auPresetData {
            do {
                if let preset = try PropertyListSerialization.propertyList(from: presetData, format: nil) as? [String: Any] {
                    audioUnit.auAudioUnit.fullState = preset
                } else if let preset = try JSONSerialization.jsonObject(with: presetData) as? [String: Any] {
                    audioUnit.auAudioUnit.fullState = preset
                }
            } catch {
                NSLog("[Engine] Failed to restore AU preset for %@: %@", mappingKey, error.localizedDescription)
                reportError("Could not restore AU preset for \(mappingKey)")
            }
        }

        auInstrumentByMappingKey[mappingKey] = audioUnit

        // Observe AU render resources to detect out-of-process disconnect
        let observation = audioUnit.auAudioUnit.observe(\.renderResourcesAllocated, options: [.new]) { [weak self] au, change in
            if change.newValue == false {
                NSLog("[Engine] AU render resources deallocated for '%@' — disconnected", mappingKey)
                // Do NOT call engine.pause() from this KVO thread — it acquires
                // internal locks and risks deadlock. Dispatch to audioQueue.
                self?.audioQueue.async { [weak self] in
                    guard let self else { return }
                    // Skip if we intentionally detached this AU for re-initialization
                    // (isReconfiguring=true during playOnAudioQueue setup).
                    guard !self.isReconfiguring else { return }
                    self.handleAUDisconnect(mappingKey: mappingKey)
                }
            }
        }
        auObservations[mappingKey] = observation
        patchSignatureByMappingKey[mappingKey] = sig

        NSLog("[Engine] Loaded AU instrument for %@", mappingKey)
    }

    /// Handle an out-of-process AU that has disconnected.
    /// Removes the dead node from the graph and transparently recovers playback.
    private func handleAUDisconnect(mappingKey: String) {
        guard auInstrumentByMappingKey[mappingKey] != nil else { return }
        isReconfiguring = true
        let wasPlaying = isPlaying
        let savedPosition = currentPlaybackPositionInBeats()
        NSLog("[Engine] Handling AU disconnect for '%@' — wasPlaying=%d", mappingKey, wasPlaying ? 1 : 0)

        // Pause engine to safely modify the graph, then remove the dead AU node.
        if engine.isRunning { engineStopIsOursDepth += 1 }
        engine.pause()
        removeDeadAU(mappingKey: mappingKey)

        // Restart engine and resume playback if we were playing
        do {
            try engine.start()
            if wasPlaying, let seq = sequencer {
                seq.currentPositionInBeats = savedPosition
                seq.prepareToPlay()
                try seq.start()
                NSLog("[Engine] Sequencer resumed at beat %.2f after AU disconnect", savedPosition)
            } else if wasPlaying {
                patchSignatureByMappingKey = patchSignatureByMappingKey.filter { $1.auSubType != nil }
                onNeedsPlaybackRestart?(savedPosition)
            }
        } catch {
            NSLog("[Engine] Failed to restart after AU disconnect: %@", error.localizedDescription)
            reportError("Audio engine failed to restart: \(error.localizedDescription)")
            setPlaying(false)
        }

        isReconfiguring = false

        DispatchQueue.main.async { [weak self] in
            self?.onAUDisconnected?(mappingKey)
            self?.onPlaybackError?("Audio Unit crashed — reconnecting automatically...")
        }
    }

    /// Configure multi-output routing for AU instruments that provide multiple output buses.
    /// Each output bus is routed to a separate submix node for independent mixing.
    func configureMultiOutputAU(mappingKey: String, outputBusCount: Int) {
        audioQueue.async { [weak self] in
            guard let self, let au = self.auInstrumentByMappingKey[mappingKey] else { return }
            let busCount = min(outputBusCount, Int(au.auAudioUnit.outputBusses.count))
            guard busCount > 1 else { return }
            // Tear down any existing multi-output mixers for this key
            if let oldMixers = self.multiOutputMixersByMappingKey.removeValue(forKey: mappingKey) {
                self.withEnginePaused {
                    for m in oldMixers {
                        self.engine.disconnectNodeOutput(m)
                        self.engine.detach(m)
                    }
                }
            }
            // Disconnect default single-output routing and stale pan mixer
            self.withEnginePaused {
                if let stalePan = self.panMixerByMappingKey.removeValue(forKey: mappingKey) {
                    self.engine.disconnectNodeOutput(stalePan)
                    self.engine.detach(stalePan)
                }
                self.engine.disconnectNodeOutput(au)
                // Connect each output bus to a separate submix → mainMixer
                var busMixers: [AVAudioMixerNode] = []
                for bus in 0..<busCount {
                    let mixer = AVAudioMixerNode()
                    self.engine.attach(mixer)
                    self.engine.connect(au, to: mixer, fromBus: bus, toBus: 0, format: nil)
                    self.engine.connect(mixer, to: self.engine.mainMixerNode, format: nil)
                    busMixers.append(mixer)
                }
                self.multiOutputMixersByMappingKey[mappingKey] = busMixers
            }
            NSLog("[Engine] Configured %d output buses for AU %@", busCount, mappingKey)
        }
    }

    private func loadInstrument(_ mapping: InstrumentMapping?, into sampler: AVAudioUnitSampler, mappingKey: String) {
        let resolvedProgram = UInt8(min(max(mapping?.program ?? 0, 0), 127))
        let resolvedBankMSB = UInt8(min(max(mapping?.bankMSB ?? Int(kAUSampler_DefaultMelodicBankMSB), 0), 127))
        let bankLSB = UInt8(min(max(mapping?.bankLSB ?? 0, 0), 127))
        let gainDB = mapping?.gainDB ?? 0
        let gain = Float(gainDB)

        let soundBankPath = mapping?.sf2Path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let signature = SamplerPatchSignature(
            soundBankPath: soundBankPath?.isEmpty == true ? nil : soundBankPath,
            bankMSB: resolvedBankMSB,
            bankLSB: bankLSB,
            program: resolvedProgram,
            gainDB: gainDB,
            auSubType: nil,
            auManufacturer: nil
        )
        if patchSignatureByMappingKey[mappingKey] == signature {
            NSLog("[Engine] loadInstrument SKIPPED (cached) key=%@ sf2=%@",
                  mappingKey, soundBankPath ?? "nil")
            return
        }

        var loaded = false
        if let sf2Path = signature.soundBankPath, !sf2Path.isEmpty {
            let sf2URL = URL(fileURLWithPath: sf2Path)
            let exists = FileManager.default.fileExists(atPath: sf2URL.path)
            NSLog("[Engine] loadInstrument key=%@ sf2=%@ exists=%@ program=%d bankMSB=%d bankLSB=%d",
                  mappingKey, sf2URL.lastPathComponent, String(describing: exists),
                  resolvedProgram, resolvedBankMSB, bankLSB)
            if exists {

                // Retry chain for SF2 loading. The program-0 and default-bank
                // fallbacks must be reachable regardless of the initial bank values,
                // because setMappingSoundFontPath resets bank to 0 and many sparse
                // SF2 files only contain a single preset at program 0.
                do {
                    try sampler.loadSoundBankInstrument(
                        at: sf2URL,
                        program: resolvedProgram,
                        bankMSB: resolvedBankMSB,
                        bankLSB: bankLSB
                    )
                    loaded = true
                } catch {
                    // Retry with bank 0 if we weren't already at bank 0
                    if resolvedBankMSB != 0 || bankLSB != 0 {
                        do {
                            try sampler.loadSoundBankInstrument(
                                at: sf2URL,
                                program: resolvedProgram,
                                bankMSB: 0,
                                bankLSB: 0
                            )
                            loaded = true
                        } catch {
                            NSLog("[SF2] Bank 0/0 fallback failed for %@ (prog=%d): %@", mappingKey, resolvedProgram, error.localizedDescription)
                        }
                    }
                }

                // Retry with program 0 at bank 0 (reachable even when bank was already 0)
                if !loaded && resolvedProgram != 0 {
                    do {
                        try sampler.loadSoundBankInstrument(
                            at: sf2URL,
                            program: 0,
                            bankMSB: 0,
                            bankLSB: 0
                        )
                        loaded = true
                    } catch {
                        NSLog("[SF2] Program 0 bank 0/0 fallback failed for %@: %@", mappingKey, error.localizedDescription)
                    }
                }

                // Last resort: try Apple's default melodic bank MSB (0x79 / 121)
                if !loaded {
                    let defaultMelodicMSB = UInt8(kAUSampler_DefaultMelodicBankMSB)
                    do {
                        try sampler.loadSoundBankInstrument(
                            at: sf2URL,
                            program: resolvedProgram,
                            bankMSB: defaultMelodicMSB,
                            bankLSB: 0
                        )
                        loaded = true
                    } catch {
                        if resolvedProgram != 0 {
                            do {
                                try sampler.loadSoundBankInstrument(
                                    at: sf2URL,
                                    program: 0,
                                    bankMSB: defaultMelodicMSB,
                                    bankLSB: 0
                                )
                                loaded = true
                            } catch {
                                NSLog("[SF2] Apple default melodic bank prog 0 fallback failed for %@: %@", mappingKey, error.localizedDescription)
                            }
                        }
                    }
                }
            } else {
                NSLog("[Engine] File does not exist at path: %@", sf2URL.path)
            }
        } else {
            NSLog("[Engine] No sf2Path for mappingKey: %@", mappingKey)
        }

        // If no instrument was loaded, explicitly mute the sampler.
        // AVAudioUnitSampler / AUSampler initializes with an internal default
        // piano tone that plays even without an explicit loadSoundBankInstrument
        // call.  Setting gain to -96 dB effectively silences it.
        if !loaded {
            NSLog("[Engine] No instrument loaded for %@ — muting sampler", mappingKey)
            if let gainParam = sampler.auAudioUnit.parameterTree?.parameter(
                withAddress: AUParameterAddress(kAUSamplerParam_Gain)
            ) {
                gainParam.value = -96
            }
            sampler.volume = 0
        } else {
            if let gainParam = sampler.auAudioUnit.parameterTree?.parameter(
                withAddress: AUParameterAddress(kAUSamplerParam_Gain)
            ) {
                gainParam.value = gain
            }
            sampler.volume = 1
        }
        patchSignatureByMappingKey[mappingKey] = signature
    }

    private func schedulePlaybackEndWork(
        shouldLoop: Bool,
        tempoBPM: Double,
        lengthTicks: Int,
        ticksPerQuarter: Int,
        startTick: Int,
        tempoEvents: [TempoPoint],
        behavior: PlaybackEndBehavior
    ) {
        playbackStopWorkItem?.cancel()
        playbackStopWorkItem = nil

        guard !shouldLoop else { return }

        let maxTick = max(1, lengthTicks)
        let start = min(max(0, startTick), max(0, maxTick - 1))
        let tempoMap = normalizedTempoEvents(tempoEvents, fallbackTempo: tempoBPM, maxTick: maxTick)
        let rawDuration = max(0.1, seconds(atTick: maxTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter) - seconds(atTick: start, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter))
        let scheduledDuration: Double
        let timingLabel: String
        switch behavior {
        case .hostedMIDI:
            let tailSeconds = 0.08
            scheduledDuration = max(0.05, rawDuration + tailSeconds)
            timingLabel = "tail=\(String(format: "%.2f", tailSeconds))"
        case .sequencer:
            // Defensive lead time: preempt AVAudioSequencer's exact natural-end boundary and
            // give the engine enough room to tear down the old sequencer before the next song
            // is started. A lightweight "mark stopped but keep sequencer alive" transition left
            // SequencePlayer render callbacks running into the next handoff and caused TempoMap
            // / ScheduleMIDIEvents crashes on the IO thread.
            let endLeadSeconds = min(1.5, max(0.30, rawDuration * 0.08))
            scheduledDuration = max(0.05, rawDuration - endLeadSeconds)
            timingLabel = "lead=\(String(format: "%.2f", endLeadSeconds))"
        }

        NSLog("[Engine] Scheduled playback end in %.2f seconds (raw %.2f; %@; ticks %d→%d)", scheduledDuration, rawDuration, timingLabel, start, maxTick)
        fileLog("SCHEDULED end in \(String(format: "%.2f", scheduledDuration))s (raw=\(String(format: "%.2f", rawDuration)) \(timingLabel); ticks \(start)→\(maxTick), tpq=\(ticksPerQuarter))")
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSLog("[Engine] Playback end work item fired — stopping engine")
            self.fileLog("STOP: schedulePlaybackEndWork fired (natural end)")
            switch behavior {
            case .hostedMIDI:
                self.stopOnAudioQueue(pauseEngine: false)
            case .sequencer:
                // Natural-end transition: perform the full host-style stop slightly early so the
                // old sequencer is gone before the next song starts.
                self.stopOnAudioQueue()
            }
        }
        playbackStopWorkItem = work
        audioQueue.asyncAfter(deadline: .now() + scheduledDuration, execute: work)
    }

    private func sendImmediateMIDIEvent(_ bytes: [UInt8], to audioUnit: AVAudioUnit) {
        guard let scheduleMIDIEvent = audioUnit.auAudioUnit.scheduleMIDIEventBlock else { return }
        bytes.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            scheduleMIDIEvent(AUEventSampleTimeImmediate, 0, buffer.count, baseAddress)
        }
    }

    private func sendHostedMIDIEvent(_ event: HostedMIDIEvent) {
        if let auUnit = auInstrumentByMappingKey[event.mappingKey] {
            sendImmediateMIDIEvent(event.bytes, to: auUnit)
            return
        }

        if let sampler = samplerByMappingKey[event.mappingKey],
           sampler.auAudioUnit.scheduleMIDIEventBlock != nil {
            sendImmediateMIDIEvent(event.bytes, to: sampler)
            return
        }

        guard let sampler = samplerByMappingKey[event.mappingKey],
              event.bytes.count >= 3 else { return }

        let status = event.bytes[0] & 0xF0
        let channel = event.bytes[0] & 0x0F
        switch status {
        case 0x80:
            sampler.stopNote(event.bytes[1], onChannel: channel)
        case 0x90:
            if event.bytes[2] == 0 {
                sampler.stopNote(event.bytes[1], onChannel: channel)
            } else {
                sampler.startNote(event.bytes[1], withVelocity: event.bytes[2], onChannel: channel)
            }
        case 0xB0:
            sampler.sendController(event.bytes[1], withValue: event.bytes[2], onChannel: channel)
        default:
            break
        }
    }

    private func buildHostedMIDIEvents(
        noteGroups: [String: [PianoRollNote]],
        startTick: Int,
        lengthTicks: Int,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int
    ) -> [HostedMIDIEvent] {
        let transportChannel: UInt8 = 0
        let noteOnStatus = UInt8(0x90) | transportChannel
        let noteOffStatus = UInt8(0x80) | transportChannel
        let maxTick = max(1, lengthTicks)
        let clampedStartTick = min(max(0, startTick), max(0, maxTick - 1))
        let startSeconds = seconds(atTick: clampedStartTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)

        var events: [HostedMIDIEvent] = []
        events.reserveCapacity(noteGroups.values.reduce(0) { $0 + ($1.count * 2) })

        for (mappingKey, notes) in noteGroups {
            for note in notes {
                let pitch = UInt8(min(max(note.pitch, 0), 127))
                let velocity = UInt8(min(max(note.velocity, 1), 127))
                let noteStart = max(0, note.startTick)
                let noteEnd = min(maxTick, max(noteStart + 1, note.startTick + note.duration))
                guard noteEnd > clampedStartTick else { continue }

                if noteStart <= clampedStartTick {
                    events.append(
                        HostedMIDIEvent(
                            timeSeconds: 0,
                            sortPriority: 1,
                            mappingKey: mappingKey,
                            bytes: [noteOnStatus, pitch, velocity]
                        )
                    )
                } else if noteStart < maxTick {
                    let eventTime = max(0, seconds(atTick: noteStart, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter) - startSeconds)
                    events.append(
                        HostedMIDIEvent(
                            timeSeconds: eventTime,
                            sortPriority: 1,
                            mappingKey: mappingKey,
                            bytes: [noteOnStatus, pitch, velocity]
                        )
                    )
                }

                let noteOffTime = max(0, seconds(atTick: noteEnd, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter) - startSeconds)
                // Skip note-off at t=0 for straddle notes: sort puts note-off (priority 0)
                // before note-on (priority 1) at the same timestamp, causing a stuck note.
                if noteOffTime > 0 {
                    events.append(
                        HostedMIDIEvent(
                            timeSeconds: noteOffTime,
                            sortPriority: 0,
                            mappingKey: mappingKey,
                            bytes: [noteOffStatus, pitch, 0]
                        )
                    )
                }
            }
        }

        events.sort { lhs, rhs in
            if lhs.timeSeconds != rhs.timeSeconds { return lhs.timeSeconds < rhs.timeSeconds }
            if lhs.sortPriority != rhs.sortPriority { return lhs.sortPriority < rhs.sortPriority }
            return lhs.mappingKey.localizedStandardCompare(rhs.mappingKey) == .orderedAscending
        }
        return events
    }

    private func cancelHostedMIDIDelivery() {
        hostedMIDIDeliveryWorkItem?.cancel()
        hostedMIDIDeliveryWorkItem = nil
        hostedMIDIEvents.removeAll()
        hostedMIDILoopEvents.removeAll()
        hostedMIDIEventIndex = 0
        hostedMIDICycleStartUptimeNanoseconds = 0
        hostedMIDILoopEnabled = false
        clearPlaybackClockState()
    }

    private func scheduleNextHostedMIDIBatch() {
        hostedMIDIDeliveryWorkItem?.cancel()
        hostedMIDIDeliveryWorkItem = nil

        guard hostedMIDIEventIndex < hostedMIDIEvents.count else { return }
        playbackClockLock.lock()
        let clockState = playbackClockState
        playbackClockLock.unlock()
        guard let clockState else { return }

        let nextEvent = hostedMIDIEvents[hostedMIDIEventIndex]
        let cycleReference = hostedMIDICycleStartUptimeNanoseconds == 0 ? clockState.startUptimeNanoseconds : hostedMIDICycleStartUptimeNanoseconds
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - cycleReference) / 1_000_000_000
        let lookAheadSeconds = 0.006
        let delaySeconds = max(0, nextEvent.timeSeconds - elapsedSeconds - lookAheadSeconds)
        let work = DispatchWorkItem { [weak self] in
            self?.deliverHostedMIDIBatch(lookAheadSeconds: lookAheadSeconds)
        }
        hostedMIDIDeliveryWorkItem = work
        audioQueue.asyncAfter(deadline: .now() + delaySeconds, execute: work)
    }

    private func deliverHostedMIDIBatch(lookAheadSeconds: Double = 0.006) {
        playbackClockLock.lock()
        let clockState = playbackClockState
        playbackClockLock.unlock()
        guard let clockState else { return }

        let cycleReference = hostedMIDICycleStartUptimeNanoseconds == 0 ? clockState.startUptimeNanoseconds : hostedMIDICycleStartUptimeNanoseconds
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - cycleReference) / 1_000_000_000
        let cutoffSeconds = elapsedSeconds + lookAheadSeconds
        while hostedMIDIEventIndex < hostedMIDIEvents.count {
            let event = hostedMIDIEvents[hostedMIDIEventIndex]
            guard event.timeSeconds <= cutoffSeconds else { break }
            sendHostedMIDIEvent(event)
            hostedMIDIEventIndex += 1
        }

        if hostedMIDIEventIndex >= hostedMIDIEvents.count && hostedMIDILoopEnabled {
            hostedMIDIEvents = hostedMIDILoopEvents
            hostedMIDIEventIndex = 0
            hostedMIDICycleStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        }

        scheduleNextHostedMIDIBatch()
    }

    @discardableResult
    private func startHostedMIDIPlayback(
        noteGroups: [String: [PianoRollNote]],
        instrumentMappings: [String: InstrumentMapping],
        startTick: Int,
        lengthTicks: Int,
        ticksPerQuarter: Int,
        tempoBPM: Double,
        tempoEvents: [TempoPoint],
        loop: Bool
    ) -> Bool {
        let maxTick = max(1, lengthTicks)
        let clampedStartTick = min(max(0, startTick), max(0, maxTick - 1))
        let tempoMap = normalizedTempoEvents(tempoEvents, fallbackTempo: tempoBPM, maxTick: maxTick)
        let events = buildHostedMIDIEvents(
            noteGroups: noteGroups,
            startTick: clampedStartTick,
            lengthTicks: lengthTicks,
            tempoMap: tempoMap,
            ticksPerQuarter: ticksPerQuarter
        )
        // Build loop events for the loop region (A/B region or full song)
        let regionStart = loopRegionStartTick ?? 0
        let regionEnd = loopRegionEndTick ?? lengthTicks
        let loopEvents = loop ? buildHostedMIDIEvents(
            noteGroups: noteGroups,
            startTick: regionStart,
            lengthTicks: regionEnd,
            tempoMap: tempoMap,
            ticksPerQuarter: ticksPerQuarter
        ) : []

        var hasDestination = false
        for mappingKey in noteGroups.keys {
            if auInstrumentByMappingKey[mappingKey] != nil {
                hasDestination = true
                continue
            }
            if samplerByMappingKey[mappingKey] != nil {
                hasDestination = true
                continue
            }
            let samplerMapping = instrumentMappings[mappingKey]
            _ = sampler(for: mappingKey, mapping: samplerMapping)
            if samplerByMappingKey[mappingKey] != nil {
                hasDestination = true
            }
        }

        guard hasDestination else { return false }

        cancelHostedMIDIDelivery()
        sequencer = nil
        hostedMIDIEvents = events
        hostedMIDILoopEvents = loopEvents
        hostedMIDIEventIndex = 0
        hostedMIDICycleStartUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        hostedMIDILoopEnabled = loop
        setPlaybackClockState(
            startTick: clampedStartTick,
            tempoMap: tempoMap,
            ticksPerQuarter: ticksPerQuarter,
            lengthTicks: lengthTicks,
            isLooping: loop
        )
        deliverHostedMIDIBatch()
        return true
    }

    private func stopAllActiveNotes() {
        // StandardMIDIFileWriter emits each mapping to its own MIDI track on channel 0.
        // Send explicit note-offs instead of CC120/123 so transport stop behaves like a
        // DAW stop, not a global panic/reset that can upset some AUv3 instruments.
        let transportChannel: UInt8 = 0
        let sustainOffStatus = UInt8(0xB0) | transportChannel
        let noteOffStatus = UInt8(0x80) | transportChannel

        for sampler in samplerByMappingKey.values {
            sampler.sendController(64, withValue: 0, onChannel: transportChannel)
            for pitch in 0...127 {
                sampler.stopNote(UInt8(pitch), onChannel: transportChannel)
            }
        }

        for auUnit in auInstrumentByMappingKey.values {
            sendImmediateMIDIEvent([sustainOffStatus, 64, 0], to: auUnit)
            for pitch in 0...127 {
                sendImmediateMIDIEvent([noteOffStatus, UInt8(pitch), 0], to: auUnit)
            }
        }
    }

    /// Intentionally left as a no-op.
    /// AU reset-style recovery caused stability regressions in AUHostingServiceXPC_arrow.
    private func recoverAudioUnitsAfterEngineStart() {
        _ = auInstrumentByMappingKey
    }

    /// Pause the AVAudioEngine before topology changes (detach/disconnect/attach),
    /// then restart it afterward.  Prevents the IOThread from reading freed node
    /// buffers (EXC_BAD_ACCESS on com.apple.audio.IOThread.client).
    /// If the engine is already paused/stopped, the work runs directly with no restart.
    private func withEnginePaused(_ work: () -> Void) {
        // Only force pause/start cycles while transport is actively rendering MIDI.
        // A lightweight natural-end stop flips isPlaying=false before the old sequencer
        // has necessarily drained, so also respect the sequencer's live state.
        let sequencerStillPlaying = sequencer?.isPlaying ?? false
        let shouldPause = engine.isRunning && (isPlaying || sequencerStillPlaying)
        if shouldPause {
            engineStopIsOursDepth += 1
            fileLog("withEnginePaused: pause → depth=\(engineStopIsOursDepth)")
            engine.pause()
        }
        work()
        if shouldPause {
            do {
                try engine.start()
            } catch {
                // No AVAudioEngineConfigurationChange notification will arrive for this
                // failed restart, so decrement the depth counter to prevent swallowing
                // the next genuine hardware event.
                engineStopIsOursDepth -= 1
                fileLog("withEnginePaused: engine.start() FAILED at depth=\(engineStopIsOursDepth): \(error)")
                NSLog("[Engine] withEnginePaused: engine.start() failed: %@", error.localizedDescription)
                reportError("Audio engine restart failed: \(error.localizedDescription)")
            }
        }
    }

    private func configureAudioGraphIfNeeded() -> Bool {
        // Only do full graph setup (attach nodes, set buffer sizes) when the engine
        // is not already running. This avoids mid-playback interruptions.
        if !engine.isRunning {
            if samplerByMappingKey.isEmpty {
                _ = sampler(for: previewSamplerKey, mapping: nil)
            }
            engine.mainMixerNode.outputVolume = masterOutputVolume
            applyRenderBufferSettingsOnAudioQueue()
        }

        // Always call start() regardless of isRunning.
        // - If stopped: starts the engine fresh.
        // - If paused via engine.pause(): resumes audio output (isRunning can be
        //   true even after pause(), but audio won't flow until start() is called again).
        // - If truly running: start() is a no-op.
        //
        // Try synchronously first. If it fails, schedule non-blocking retries via
        // asyncAfter so we don't block the serial audioQueue during back-off.
        do {
            try engine.start()
            return true
        } catch {
            fileLog("engine.start() failed (attempt 1): \(error.localizedDescription) — scheduling async retries")
            retryEngineStart(attempt: 1, maxAttempts: 3)
            // Return false here; callers that need immediate success handle this path.
            return false
        }
    }

    /// Non-blocking retry helper — schedules back-off on audioQueue without sleeping.
    private func retryEngineStart(attempt: Int, maxAttempts: Int) {
        guard attempt < maxAttempts else {
            fileLog("engine.start() failed after \(maxAttempts) attempts — giving up")
            NSLog("[Engine] Failed to start after %d attempts", maxAttempts)
            return
        }
        audioQueue.asyncAfter(deadline: .now() + 0.15 * Double(attempt)) { [weak self] in
            guard let self else { return }
            do {
                try self.engine.start()
                self.fileLog("engine.start() succeeded on attempt \(attempt + 1)")
            } catch {
                self.fileLog("engine.start() failed (attempt \(attempt + 1)): \(error.localizedDescription)")
                self.retryEngineStart(attempt: attempt + 1, maxAttempts: maxAttempts)
            }
        }
    }

    private func playOnAudioQueue(
        notes: [PianoRollNote],
        lengthTicks: Int,
        ticksPerQuarter: Int,
        tempoBPM: Double,
        tempoEvents: [TempoPoint],
        loop: Bool,
        startTick: Int,
        trackChannelToMappingKey: [String: String],
        instrumentMappings: [String: InstrumentMapping],
        audioClips: [AudioClip],
        renderMode: PlaybackRenderMode,
        mutedTracks: Set<Int> = [],
        requestID: UInt64
    ) {
        playOnAudioQueue(
            notes: notes,
            lengthTicks: lengthTicks,
            ticksPerQuarter: ticksPerQuarter,
            tempoBPM: tempoBPM,
            tempoEvents: tempoEvents,
            loop: loop,
            startTick: startTick,
            trackChannelToMappingKey: trackChannelToMappingKey,
            instrumentMappings: instrumentMappings,
            audioClips: audioClips,
            renderMode: renderMode,
            mutedTracks: mutedTracks,
            allowRetryWithConservativeConfig: true,
            requestID: requestID
        )
    }

    private func playOnAudioQueue(
        notes: [PianoRollNote],
        lengthTicks: Int,
        ticksPerQuarter: Int,
        tempoBPM: Double,
        tempoEvents: [TempoPoint],
        loop: Bool,
        startTick: Int,
        trackChannelToMappingKey: [String: String],
        instrumentMappings: [String: InstrumentMapping],
        audioClips: [AudioClip],
        renderMode: PlaybackRenderMode,
        mutedTracks: Set<Int> = [],
        allowRetryWithConservativeConfig: Bool,
        requestID: UInt64
    ) {
        guard isPlayRequestCurrent(requestID) else { return }

        let shouldRenderMIDI = renderMode.includesMIDI
        let shouldRenderAudio = renderMode.includesAudio
        let hasAudio = shouldRenderAudio && audioClips.contains(where: { !$0.muted && !$0.filePath.isEmpty })

        guard (shouldRenderMIDI && !notes.isEmpty) || hasAudio else {
            stopOnAudioQueue()
            return
        }

        // Keep isReconfiguring = true through entire setup to suppress health check interference
        fileLog("playOnAudioQueue START (startTick=\(startTick) lengthTicks=\(lengthTicks))")
        stopOnAudioQueue(keepReconfiguring: true, preserveMainMixRecording: true)
        guard isPlayRequestCurrent(requestID) else {
            isReconfiguring = false
            return
        }
        clearScheduledAudioClips()

        let mutedKeys = Set(instrumentMappings.values.filter(\.muted).map(\.channelKey))
        var noteGroups: [String: [PianoRollNote]] = [:]

        if shouldRenderMIDI {
            for note in notes {
                guard !mutedTracks.contains(note.trackIndex) else { continue }
                let pairKey = "\(note.trackIndex):\(note.channel)"
                let mappingKey = trackChannelToMappingKey[pairKey] ?? "channel-\(note.channel + 1)"
                if mutedKeys.contains(mappingKey) {
                    continue
                }
                noteGroups[mappingKey, default: []].append(note)
            }
        }

        guard !noteGroups.isEmpty || hasAudio else {
            setPlaying(false)
            isReconfiguring = false
            return
        }

        let clampedStartTick = min(max(0, startTick), max(0, lengthTicks - 1))

        // Start the engine FIRST so it is in a stable running state before any
        // topology changes (AU attach/connect). Calling engine.connect() on a stopped
        // engine after AVAudioEngineConfigurationChange triggers UpdateGraphAfterReconfig
        // which throws NSException if the engine's internal state is still mid-reconfig.
        guard configureAudioGraphIfNeeded() else {
            setPlaying(false)
            isReconfiguring = false
            reportError("Audio engine could not start.")
            return
        }
        guard isPlayRequestCurrent(requestID) else {
            setPlaying(false)
            isReconfiguring = false
            return
        }

        // After each start/resume, force AUv3 transient-state recovery before connecting
        // sequencer tracks. This mitigates plugins that stay muted after transport stops.
        recoverAudioUnitsAfterEngineStart()

        if shouldRenderMIDI {
            let orderedMappingKeys = noteGroups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
            // Batch-create new samplers to minimize engine pause/start cycles.
            // Each individual withEnginePaused call does a full engine.pause() + engine.start()
            // cycle, which can trigger AVAudioEngineConfigurationChange notifications. With 20+
            // tracks, 20+ rapid pause/start cycles destabilize USB audio drivers and cause
            // spurious config-change notifications that trigger double-restarts.
            //
            // Solution: collect all new samplers, attach them ALL in ONE withEnginePaused block.
            // Existing cached samplers don't need attachment — just loadInstrument if sig changed.
            var newSamplerPairs: [(key: String, node: AVAudioUnitSampler, mapping: InstrumentMapping?)] = []
            for mappingKey in orderedMappingKeys {
                let mapping = instrumentMappings[mappingKey]
                if let mapping, mapping.effectiveSourceType == .audioUnit, let desc = mapping.audioComponentDescription {
                    // AU instruments are hosted directly; do not create placeholder sampler nodes
                    // during playback setup unless we actually need a silent fallback.
                    loadAudioUnitIfNeeded(mappingKey: mappingKey, mapping: mapping, description: desc)
                    guard isPlayRequestCurrent(requestID) else {
                        setPlaying(false)
                        isReconfiguring = false
                        return
                    }
                } else if samplerByMappingKey[mappingKey] == nil {
                    // New SF2 sampler needed — create node now, attach below in one batch
                    newSamplerPairs.append((key: mappingKey, node: AVAudioUnitSampler(), mapping: mapping))
                }
                // Existing samplers: instrument will be (re)loaded after attachment batch below
            }

            // Attach all new sampler nodes in a single engine pause (1 pause vs N pauses)
            if !newSamplerPairs.isEmpty {
                let maxFrames = recommendedMaximumFramesToRender()
                for pair in newSamplerPairs where !pair.node.auAudioUnit.renderResourcesAllocated {
                    pair.node.auAudioUnit.maximumFramesToRender = maxFrames
                }
                withEnginePaused {
                    for pair in newSamplerPairs {
                        engine.attach(pair.node)
                        engine.connect(pair.node, to: engine.mainMixerNode, format: nil)
                    }
                }
                guard isPlayRequestCurrent(requestID) else {
                    setPlaying(false)
                    isReconfiguring = false
                    return
                }
                for pair in newSamplerPairs {
                    samplerByMappingKey[pair.key] = pair.node
                    if pair.mapping != nil {
                        loadInstrument(pair.mapping, into: pair.node, mappingKey: pair.key)
                    }
                }
            }

            // For existing samplers, reload instrument if the patch signature changed
            for mappingKey in orderedMappingKeys {
                guard let existingSampler = samplerByMappingKey[mappingKey] else { continue }
                let mapping = instrumentMappings[mappingKey]
                guard mapping?.effectiveSourceType != .audioUnit else { continue }
                if !newSamplerPairs.contains(where: { $0.key == mappingKey }) {
                    loadInstrument(mapping, into: existingSampler, mappingKey: mappingKey)
                }
            }
        }

        let maxTickForTempo = max(1, lengthTicks)
        let tempoMapForAutomation = normalizedTempoEvents(tempoEvents, fallbackTempo: tempoBPM, maxTick: maxTickForTempo)
        let usesHostedMIDIScheduler = shouldRenderMIDI

        if usesHostedMIDIScheduler {
            guard !shouldRenderMIDI || startHostedMIDIPlayback(
                noteGroups: noteGroups,
                instrumentMappings: instrumentMappings,
                startTick: clampedStartTick,
                lengthTicks: lengthTicks,
                ticksPerQuarter: ticksPerQuarter,
                tempoBPM: tempoBPM,
                tempoEvents: tempoEvents,
                loop: loop && !shouldRenderAudio
            ) else {
                setPlaying(false)
                isReconfiguring = false
                reportError("Playback could not start for this selection.")
                return
            }

            engine.mainMixerNode.outputVolume = masterOutputVolume
            if shouldRenderAudio {
                scheduleAudioClips(
                    audioClips,
                    lengthTicks: lengthTicks,
                    ticksPerQuarter: ticksPerQuarter,
                    startTick: clampedStartTick,
                    tempoBPM: tempoBPM,
                    tempoEvents: tempoEvents
                )
            }
            setPlaying(true)

            startAutomationTimer(
                startTick: clampedStartTick,
                tempoMap: tempoMapForAutomation,
                ticksPerQuarter: ticksPerQuarter
            )

            installMeterTaps()
            startMeterPublishTimer()

            setupMetronomeNodeOnAudioQueue()
            scheduleMetronomeClicks(
                startTick: clampedStartTick,
                tempoMap: tempoMapForAutomation,
                ticksPerQuarter: ticksPerQuarter,
                lengthTicks: lengthTicks,
                timeSignatures: metronomeTimeSignatures
            )

            if isRecordingAudio && loopRecordingEnabled {
                startLoopRecordingTimer(
                    startTick: clampedStartTick,
                    tempoMap: tempoMapForAutomation,
                    ticksPerQuarter: ticksPerQuarter
                )
            }

            schedulePlaybackEndWork(
                shouldLoop: loop && !shouldRenderAudio,
                tempoBPM: tempoBPM,
                lengthTicks: lengthTicks,
                ticksPerQuarter: ticksPerQuarter,
                startTick: clampedStartTick,
                tempoEvents: tempoEvents,
                behavior: .hostedMIDI
            )
            fileLog("playOnAudioQueue DONE (hosted MIDI): engine.isRunning=\(engine.isRunning) depth=\(engineStopIsOursDepth)")
            audioQueue.async { [weak self] in
                self?.isReconfiguring = false
                self?.engineStopIsOursDepth = 0
                self?.fileLog("deferred: isReconfiguring=false depth=0 engine.isRunning=\(self?.engine.isRunning ?? false)")
            }
            return
        }

        // Build the MIDI file fresh — always rebuild to guarantee correct tempo.
        // AVAudioSequencer can retain stale tempo state from previous loads,
        // so we also recreate the sequencer instance each time.
        let sequence = StandardMIDIFileWriter.makeFile(
            noteGroups: noteGroups,
            lengthTicks: max(lengthTicks, 1),
            ticksPerQuarter: max(1, ticksPerQuarter),
            tempoBPM: max(20, tempoBPM),
            tempoEvents: tempoEvents
        )

        do {
            guard isPlayRequestCurrent(requestID) else {
                setPlaying(false)
                isReconfiguring = false
                return
            }
            // Recreate the sequencer to ensure a completely clean tempo state.
            // Reusing a sequencer across songs can cause it to play at the
            // previous song's tempo regardless of what the MIDI file says.
            let newSequencer = AVAudioSequencer(audioEngine: engine)
            sequencer = newSequencer

            try newSequencer.load(from: sequence.data, options: [])

            // Force the sequencer's playback rate to exactly 1.0 so it uses
            // the MIDI file's tempo track as-is, with no scaling.
            newSequencer.rate = 1.0

            let lengthBeats = Double(max(lengthTicks, 1)) / Double(max(ticksPerQuarter, 1))

            // Set loop ranges first (before any engine operations that could reorder tracks).
            for (index, track) in newSequencer.tracks.enumerated() {
                guard index > 0 else { continue }
                let sequencerLoopEnabled = loop && !shouldRenderAudio
                if !useConservativeSequencerConfig {
                    track.loopRange = AVBeatRange(start: 0, length: max(1, lengthBeats))
                    track.isLoopingEnabled = sequencerLoopEnabled
                } else {
                    track.isLoopingEnabled = false
                }
            }

            // The AU cache stays valid between songs. Route MIDI tracks directly to cached
            // AU instances and avoid creating silent sampler placeholders unless an AU failed
            // to load and we need a muted fallback.

            for (index, track) in newSequencer.tracks.enumerated() {
                guard index > 0 else { continue }
                guard index - 1 < sequence.noteTrackKeys.count else { continue }
                let mappingKey = sequence.noteTrackKeys[index - 1]
                let mapping = instrumentMappings[mappingKey]
                if mapping?.effectiveSourceType == .audioUnit,
                   let auUnit = auInstrumentByMappingKey[mappingKey] {
                    track.destinationAudioUnit = auUnit
                    NSLog("[Engine] MIDI track %d -> AU instrument for '%@' (component: %@)", index, mappingKey, auUnit.name)
                } else if mapping?.effectiveSourceType == .audioUnit {
                    let fallbackSampler = samplerByMappingKey[mappingKey] ?? sampler(for: mappingKey, mapping: nil)
                    track.destinationAudioUnit = fallbackSampler
                    NSLog("[Engine] MIDI track %d -> silent fallback sampler for '%@' (AU unavailable)", index, mappingKey)
                } else {
                    let sfSampler = sampler(for: mappingKey, mapping: mapping)
                    track.destinationAudioUnit = sfSampler
                }
            }

            // Ensure master volume is correct after engine restart cycles
            engine.mainMixerNode.outputVolume = masterOutputVolume

            let startBeats = Double(clampedStartTick) / Double(max(ticksPerQuarter, 1))
            newSequencer.currentPositionInBeats = startBeats
            newSequencer.prepareToPlay()
            try newSequencer.start()
            if shouldRenderAudio {
                scheduleAudioClips(
                    audioClips,
                    lengthTicks: lengthTicks,
                    ticksPerQuarter: ticksPerQuarter,
                    startTick: clampedStartTick,
                    tempoBPM: tempoBPM,
                    tempoEvents: tempoEvents
                )
            }
            setPlaying(true)

            // Start automation timer if automation data is loaded
            startAutomationTimer(
                startTick: clampedStartTick,
                tempoMap: tempoMapForAutomation,
                ticksPerQuarter: ticksPerQuarter
            )

            // Install metering taps on submix nodes and start publishing meter levels
            installMeterTaps()
            startMeterPublishTimer()

            // Setup and schedule metronome clicks
            setupMetronomeNodeOnAudioQueue()
            scheduleMetronomeClicks(
                startTick: clampedStartTick,
                tempoMap: tempoMapForAutomation,
                ticksPerQuarter: ticksPerQuarter,
                lengthTicks: lengthTicks,
                timeSignatures: metronomeTimeSignatures
            )

            // Start loop recording timer if recording + looping
            if isRecordingAudio && loopRecordingEnabled {
                startLoopRecordingTimer(
                    startTick: clampedStartTick,
                    tempoMap: tempoMapForAutomation,
                    ticksPerQuarter: ticksPerQuarter
                )
            }

            schedulePlaybackEndWork(
                shouldLoop: loop && !shouldRenderAudio,
                tempoBPM: tempoBPM,
                lengthTicks: lengthTicks,
                ticksPerQuarter: ticksPerQuarter,
                startTick: clampedStartTick,
                tempoEvents: tempoEvents,
                behavior: .sequencer
            )
            // Drain pending AVAudioEngineConfigurationChange notifications before clearing
            // isReconfiguring. During setup, withEnginePaused() calls engine.pause() then
            // engine.start() for each sampler. Each cycle can post 1-2 notifications that
            // are queued on audioQueue behind this work item. By queuing the isReconfiguring
            // clear AFTER returning from here, those notifications run first and see
            // isReconfiguring=true → return early without triggering spurious restarts.
            fileLog("playOnAudioQueue DONE: engine.isRunning=\(engine.isRunning) depth=\(engineStopIsOursDepth)")
            audioQueue.async { [weak self] in
                self?.isReconfiguring = false
                self?.engineStopIsOursDepth = 0
                self?.fileLog("deferred: isReconfiguring=false depth=0 engine.isRunning=\(self?.engine.isRunning ?? false)")
            }
        } catch {
            if allowRetryWithConservativeConfig && !useConservativeSequencerConfig {
                useConservativeSequencerConfig = true
                reportError("Playback fallback enabled after sequencer configuration error.")
                playOnAudioQueue(
                    notes: notes,
                    lengthTicks: lengthTicks,
                    ticksPerQuarter: ticksPerQuarter,
                    tempoBPM: tempoBPM,
                    tempoEvents: tempoEvents,
                    loop: loop,
                    startTick: startTick,
                    trackChannelToMappingKey: trackChannelToMappingKey,
                    instrumentMappings: instrumentMappings,
                    audioClips: audioClips,
                    renderMode: renderMode,
                    mutedTracks: mutedTracks,
                    allowRetryWithConservativeConfig: false,
                    requestID: requestID
                )
                return
            }
            reportError("Playback could not start for this selection.")
            stopOnAudioQueue()
        }
    }

    private func previewOnAudioQueue(pitch: Int, velocity: Int, duration: Double) {
        let sampler = sampler(for: previewSamplerKey, mapping: previewMapping)
        guard configureAudioGraphIfNeeded() else {
            return
        }

        let clampedPitch = UInt8(min(max(pitch, 0), 127))
        let clampedVelocity = UInt8(min(max(velocity, 1), 127))

        sampler.startNote(clampedPitch, withVelocity: clampedVelocity, onChannel: 0)
        audioQueue.asyncAfter(deadline: .now() + max(0.05, duration)) { [weak self] in
            guard let self,
                  let previewSampler = self.samplerByMappingKey[self.previewSamplerKey] else {
                return
            }
            previewSampler.stopNote(clampedPitch, onChannel: 0)
        }
    }

    private func scheduleAudioClips(
        _ clips: [AudioClip],
        lengthTicks: Int,
        ticksPerQuarter: Int,
        startTick: Int,
        tempoBPM: Double,
        tempoEvents: [TempoPoint]
    ) {
        clearScheduledAudioClips()

        let maxTick = max(1, lengthTicks)
        let clampedStartTick = min(max(0, startTick), max(0, maxTick - 1))
        let tempoMap = normalizedTempoEvents(tempoEvents, fallbackTempo: tempoBPM, maxTick: maxTick)
        let startSeconds = seconds(atTick: clampedStartTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)

        // Pre-load audio files and prepare node descriptions before touching the engine graph
        struct ClipSetup {
            let clip: AudioClip
            let audioFile: AVAudioFile
            let node: AVAudioPlayerNode
            let needsTimePitch: Bool
            let timePitch: AVAudioUnitTimePitch?
        }
        var setups: [ClipSetup] = []
        for clip in clips where !clip.muted && !clip.filePath.isEmpty {
            let url = URL(fileURLWithPath: clip.filePath)
            guard let audioFile = loadAudioFile(at: url) else { continue }
            let node = AVAudioPlayerNode()
            let needsTimePitch = clip.stretchRatio != 1.0 || clip.pitchCents != 0
            let timePitch: AVAudioUnitTimePitch? = needsTimePitch ? {
                let tp = AVAudioUnitTimePitch()
                tp.rate = Float(1.0 / max(0.25, clip.stretchRatio))
                tp.pitch = clip.pitchCents
                return tp
            }() : nil
            setups.append(ClipSetup(clip: clip, audioFile: audioFile, node: node,
                                    needsTimePitch: needsTimePitch, timePitch: timePitch))
        }
        guard !setups.isEmpty else { return }

        // Pause engine for all topology changes (attach/connect), then resume
        withEnginePaused {
            for setup in setups {
                audioPlayerNodes[setup.clip.id] = setup.node
                engine.attach(setup.node)

                let destNode: AVAudioNode
                if let trackID = setup.clip.trackID {
                    destNode = ensureTrackSubmix(trackID: trackID, format: setup.audioFile.processingFormat)
                } else {
                    destNode = engine.mainMixerNode
                }

                if let timePitch = setup.timePitch {
                    clipTimePitchNodes[setup.clip.id] = timePitch
                    engine.attach(timePitch)
                    engine.connect(setup.node, to: timePitch, format: setup.audioFile.processingFormat)
                    engine.connect(timePitch, to: destNode, format: setup.audioFile.processingFormat)
                } else {
                    engine.connect(setup.node, to: destNode, format: setup.audioFile.processingFormat)
                }
            }
        }

        // Now schedule audio segments on the (re-started) engine
        for setup in setups {
            let clip = setup.clip
            let audioFile = setup.audioFile
            let node = setup.node

            // Per-clip gain only (track volume/pan applied on submix node)
            node.volume = Float(pow(10.0, min(max(clip.gainDB, -24), 12) / 20.0))
            node.pan = Float(min(max(clip.pan, -1), 1))

            let clipStartTick = min(max(0, clip.startTick), max(0, maxTick - 1))
            let clipStartSeconds = seconds(atTick: clipStartTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
            let delaySeconds = clipStartSeconds - startSeconds

            let sampleRate = audioFile.processingFormat.sampleRate
            guard sampleRate > 0 else { continue }

            // Convert offsetTicks to audio frames — this is how far into the source
            // audio file to seek (for trimmed or split clips).
            // offsetTicks is relative to the original clip start, so we compute the
            // duration using the tempo map context at the clip's timeline position.
            let offsetSeconds: Double
            if clip.offsetTicks > 0 {
                // The original clip started at (startTick - offsetTicks) on the timeline
                // (before trimming moved startTick forward and added offsetTicks).
                // Compute the duration of offsetTicks using the tempo at that region.
                let originalStartTick = max(0, clip.startTick - clip.offsetTicks)
                let originalStartSec = seconds(atTick: originalStartTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
                let offsetEndSec = seconds(atTick: originalStartTick + clip.offsetTicks, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
                offsetSeconds = offsetEndSec - originalStartSec
            } else {
                offsetSeconds = 0.0
            }
            // When stretched, offset and mid-clip skip are in timeline time;
            // convert to source audio time by dividing by stretchRatio.
            let stretchDivisor = (clip.stretchRatio != 1.0) ? max(0.25, clip.stretchRatio) : 1.0
            let offsetFrames = AVAudioFramePosition(((offsetSeconds / stretchDivisor) * sampleRate).rounded())

            var startingFrame: AVAudioFramePosition = offsetFrames
            if delaySeconds < 0 {
                // Playback started mid-clip — skip additional source frames
                let skipSeconds = -delaySeconds / stretchDivisor
                startingFrame += AVAudioFramePosition((skipSeconds * sampleRate).rounded())
            }
            let remainingFrames = max(0, audioFile.length - startingFrame)
            guard remainingFrames > 0 else { continue }

            // Limit playback to the clip's durationTicks — without this, split clips
            // play the entire remaining audio file instead of stopping at the clip boundary.
            // Must use absolute positions (end - start) because tempo may vary across the clip.
            let clipEndTick = clip.startTick + clip.durationTicks
            let clipEndSeconds = seconds(atTick: clipEndTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
            let clipDurationSeconds = clipEndSeconds - clipStartSeconds
            // When time-stretched, the player node feeds source frames at natural speed
            // and the TimePitch node stretches the output. So we need source frame count
            // = timeline duration / stretchRatio.
            let sourceAudioSeconds = setup.needsTimePitch
                ? clipDurationSeconds / max(0.25, clip.stretchRatio)
                : clipDurationSeconds
            let durationFrames = AVAudioFramePosition((sourceAudioSeconds * sampleRate).rounded())

            // If we started mid-clip (negative delay), reduce the source duration accordingly
            let effectiveDurationFrames: AVAudioFramePosition
            if delaySeconds < 0 {
                let skippedSourceSeconds = -delaySeconds / stretchDivisor
                let skippedFrames = AVAudioFramePosition((skippedSourceSeconds * sampleRate).rounded())
                effectiveDurationFrames = max(0, durationFrames - skippedFrames)
            } else {
                effectiveDurationFrames = durationFrames
            }

            let frameCount = AVAudioFrameCount(min(
                min(remainingFrames, effectiveDurationFrames),
                AVAudioFramePosition(UInt32.max)
            ))
            guard frameCount > 0 else { continue }

            let baseVolume = node.volume
            clipBaseVolume[clip.id] = baseVolume

            // Compute fade durations in seconds
            let fadeInSeconds: Double
            if clip.fadeInTicks > 0 {
                let fadeInEndTick = clip.startTick + clip.fadeInTicks
                let fadeInEndSec = seconds(atTick: fadeInEndTick, tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
                fadeInSeconds = max(0, fadeInEndSec - clipStartSeconds)
            } else {
                fadeInSeconds = 0
            }

            let fadeOutSeconds: Double
            if clip.fadeOutTicks > 0 {
                let fadeOutStartTick = clip.startTick + clip.durationTicks - clip.fadeOutTicks
                let fadeOutStartSec = seconds(atTick: max(clip.startTick, fadeOutStartTick), tempoMap: tempoMap, ticksPerQuarter: ticksPerQuarter)
                fadeOutSeconds = max(0, clipEndSeconds - fadeOutStartSec)
            } else {
                fadeOutSeconds = 0
            }

            let fadeInExp = clip.fadeInExponent
            let fadeOutExp = clip.fadeOutExponent
            let clipID = clip.id
            let clipDurationSec = clipDurationSeconds

            // How far into the clip we are already (for mid-clip starts)
            let elapsedInClip: Double = delaySeconds < 0 ? -delaySeconds : 0

            let startClip: () -> Void = { [weak self] in
                guard let self else { return }
                guard let player = self.audioPlayerNodes[clipID] else { return }

                // Set initial volume for fade-in
                if fadeInSeconds > 0 && elapsedInClip < fadeInSeconds {
                    let t = min(1.0, elapsedInClip / fadeInSeconds)
                    player.volume = baseVolume * Float(pow(t, fadeInExp))
                }

                player.scheduleSegment(
                    audioFile,
                    startingFrame: startingFrame,
                    frameCount: frameCount,
                    at: nil,
                    completionHandler: nil
                )
                player.play()

                // Schedule fade automation if needed
                let hasFadeIn = fadeInSeconds > 0 && elapsedInClip < fadeInSeconds
                let hasFadeOut = fadeOutSeconds > 0
                if hasFadeIn || hasFadeOut {
                    self.scheduleFadeAutomation(
                        clipID: clipID,
                        baseVolume: baseVolume,
                        fadeInSeconds: fadeInSeconds,
                        fadeOutSeconds: fadeOutSeconds,
                        fadeInExponent: fadeInExp,
                        fadeOutExponent: fadeOutExp,
                        clipDurationSeconds: clipDurationSec,
                        elapsedAtStart: elapsedInClip
                    )
                }
            }

            if delaySeconds <= 0 {
                startClip()
            } else {
                let work = DispatchWorkItem(block: startClip)
                pendingAudioStartWorkItems[clip.id] = work
                audioQueue.asyncAfter(deadline: .now() + delaySeconds, execute: work)
            }
        }
    }

    /// Schedules a timer that ramps the player node volume for fade-in and fade-out.
    /// Runs on the audioQueue at ~60 updates/sec for smooth volume transitions.
    private func scheduleFadeAutomation(
        clipID: UUID,
        baseVolume: Float,
        fadeInSeconds: Double,
        fadeOutSeconds: Double,
        fadeInExponent: Double,
        fadeOutExponent: Double,
        clipDurationSeconds: Double,
        elapsedAtStart: Double
    ) {
        // Cancel any existing fade timer for this clip
        fadeTimers[clipID]?.cancel()

        let startTime = DispatchTime.now()
        let timer = DispatchSource.makeTimerSource(queue: audioQueue)
        // ~60 updates/sec for smooth fades
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(4))

        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard let player = self.audioPlayerNodes[clipID] else {
                self.fadeTimers[clipID]?.cancel()
                self.fadeTimers.removeValue(forKey: clipID)
                return
            }

            let elapsed = elapsedAtStart + Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000

            var volume: Float = baseVolume

            // Fade-in: ramp from 0 to baseVolume over fadeInSeconds
            if fadeInSeconds > 0 && elapsed < fadeInSeconds {
                let t = min(1.0, max(0, elapsed / fadeInSeconds))
                volume = baseVolume * Float(pow(t, fadeInExponent))
            }

            // Fade-out: ramp from baseVolume to 0 over fadeOutSeconds
            let fadeOutStart = clipDurationSeconds - fadeOutSeconds
            if fadeOutSeconds > 0 && elapsed >= fadeOutStart {
                let t = min(1.0, max(0, (elapsed - fadeOutStart) / fadeOutSeconds))
                // t goes 0→1 as we approach the end; volume goes baseVolume→0
                let fadeOutMultiplier = Float(pow(1.0 - t, fadeOutExponent))
                // If both fades overlap (very short clip), multiply them
                if fadeInSeconds > 0 && elapsed < fadeInSeconds {
                    let fadeInT = min(1.0, max(0, elapsed / fadeInSeconds))
                    volume = baseVolume * Float(pow(fadeInT, fadeInExponent)) * fadeOutMultiplier
                } else {
                    volume = baseVolume * fadeOutMultiplier
                }
            }

            player.volume = volume

            // Stop the timer once we're past the clip duration
            if elapsed >= clipDurationSeconds {
                self.fadeTimers[clipID]?.cancel()
                self.fadeTimers.removeValue(forKey: clipID)
            }
        }

        fadeTimers[clipID] = timer
        timer.resume()
    }

    private func clearScheduledAudioClips() {
        // Cancel all fade automation timers
        for timer in fadeTimers.values {
            timer.cancel()
        }
        fadeTimers.removeAll()
        clipBaseVolume.removeAll()

        for item in pendingAudioStartWorkItems.values {
            item.cancel()
        }
        pendingAudioStartWorkItems.removeAll()

        // Stop player nodes before detaching (stop is safe on a running engine)
        for node in audioPlayerNodes.values {
            node.stop()
        }

        // Pause engine to safely detach nodes without IOThread use-after-free
        withEnginePaused {
            for node in clipTimePitchNodes.values {
                engine.disconnectNodeOutput(node)
                engine.disconnectNodeInput(node)
                engine.detach(node)
            }
            for node in audioPlayerNodes.values {
                engine.disconnectNodeOutput(node)
                engine.detach(node)
            }
        }
        clipTimePitchNodes.removeAll()
        audioPlayerNodes.removeAll()
    }

    /// Clears the audio file cache. Call when switching songs/projects to reclaim memory.
    func clearAudioFileCache() {
        audioQueue.async { [weak self] in
            self?.audioFileCache.removeAll()
        }
    }

    private func loadAudioFile(at url: URL) -> AVAudioFile? {
        let path = url.standardizedFileURL.path
        if let cached = audioFileCache[path] {
            return cached
        }
        // FIFO eviction: remove oldest entry when cache hits 50 files
        if audioFileCache.count >= 50 {
            if let oldest = audioFileCache.keys.first {
                audioFileCache.removeValue(forKey: oldest)
            }
        }
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        audioFileCache[path] = file
        return file
    }

    private func normalizedTempoEvents(
        _ tempoEvents: [TempoPoint],
        fallbackTempo: Double,
        maxTick: Int
    ) -> [TempoPoint] {
        let boundedTick = max(1, maxTick)
        let source = tempoEvents.isEmpty ? [TempoPoint(tick: 0, bpm: fallbackTempo)] : tempoEvents
        var byTick: [Int: TempoPoint] = [:]
        for event in source {
            let tick = min(max(0, event.tick), boundedTick - 1)
            byTick[tick] = TempoPoint(tick: tick, bpm: max(20, min(event.bpm, 300)))
        }
        var normalized = byTick.values.sorted { $0.tick < $1.tick }
        if normalized.first?.tick != 0 {
            normalized.insert(TempoPoint(tick: 0, bpm: max(20, fallbackTempo)), at: 0)
        }
        return normalized
    }

    private func seconds(
        atTick tick: Int,
        tempoMap: [TempoPoint],
        ticksPerQuarter: Int
    ) -> Double {
        guard !tempoMap.isEmpty else { return 0 }
        let clampedTick = max(0, tick)
        if clampedTick == 0 { return 0 }

        let tpq = Double(max(1, ticksPerQuarter))
        var totalSeconds: Double = 0
        for index in tempoMap.indices {
            let current = tempoMap[index]
            let nextTick = (index + 1 < tempoMap.count) ? tempoMap[index + 1].tick : clampedTick
            if clampedTick <= current.tick { break }
            let segmentStart = current.tick
            let segmentEnd = min(clampedTick, nextTick)
            if segmentEnd > segmentStart {
                let ticks = Double(segmentEnd - segmentStart)
                totalSeconds += ticks * (60.0 / (max(20, current.bpm) * tpq))
            }
            if segmentEnd >= clampedTick { break }
        }
        return totalSeconds
    }

    // MARK: - Metering

    /// Copy float channel data out of an AVAudioPCMBuffer so it can be used after the tap callback returns.
    /// Returns (leftChannel, rightChannelOrNil, frameCount).
    nonisolated private static func copyChannelData(from buffer: AVAudioPCMBuffer) -> (left: [Float], right: [Float]?, frameCount: Int) {
        guard let floatData = buffer.floatChannelData else { return ([], nil, 0) }
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return ([], nil, 0) }
        let channelCount = Int(buffer.format.channelCount)

        let left = Array(UnsafeBufferPointer(start: floatData[0], count: frameCount))
        let right: [Float]? = channelCount >= 2
            ? Array(UnsafeBufferPointer(start: floatData[1], count: frameCount))
            : nil
        return (left, right, frameCount)
    }

    /// Deep-copy a float PCM buffer so it can be written off the audio thread.
    nonisolated private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let floatData = buffer.floatChannelData else { return nil }
        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return nil }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: frameCount) else {
            return nil
        }
        copy.frameLength = frameCount

        let channels = Int(buffer.format.channelCount)
        let samples = Int(frameCount)
        guard let copyData = copy.floatChannelData else { return nil }
        for channel in 0..<channels {
            copyData[channel].update(from: floatData[channel], count: samples)
        }
        return copy
    }

    /// Compute peak and RMS from pre-copied channel data using Accelerate/vDSP.
    nonisolated private static func computeLevelsFromCopy(left: [Float], right: [Float]?, frameCount: Int) -> MeterLevels {
        guard frameCount > 0 else { return .zero }
        let count = vDSP_Length(frameCount)

        var peakL: Float = 0
        var rmsL: Float = 0
        var peakR: Float = 0
        var rmsR: Float = 0

        left.withUnsafeBufferPointer { buf in
            vDSP_maxmgv(buf.baseAddress!, 1, &peakL, count)
            vDSP_rmsqv(buf.baseAddress!, 1, &rmsL, count)
        }

        if let right {
            right.withUnsafeBufferPointer { buf in
                vDSP_maxmgv(buf.baseAddress!, 1, &peakR, count)
                vDSP_rmsqv(buf.baseAddress!, 1, &rmsR, count)
            }
        } else {
            peakR = peakL
            rmsR = rmsL
        }

        let clipped = peakL >= 1.0 || peakR >= 1.0

        func toDB(_ v: Float) -> Float {
            20 * log10(max(v, 1e-8))
        }

        return MeterLevels(
            peakL: toDB(peakL), peakR: toDB(peakR),
            rmsL: toDB(rmsL), rmsR: toDB(rmsR),
            clipped: clipped
        )
    }

    private func installMeterTaps() {
        guard !meterTapsInstalled else { return }
        meterTapsInstalled = true
        let bufferSize: AVAudioFrameCount = 1024

        // Install tap on each track's submix node (skip detached nodes)
        let attached = engine.attachedNodes
        for (trackID, submix) in trackSubmixNodes {
            guard attached.contains(submix) else { continue }
            let tid = trackID  // capture for closure
            submix.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
                guard let self else { return }
                // Copy buffer data on the audio render thread (pointer only valid during callback)
                let (left, right, frameCount) = Self.copyChannelData(from: buffer)
                self.audioQueue.async { [weak self] in
                    guard let self else { return }
                    let levels = Self.computeLevelsFromCopy(left: left, right: right, frameCount: frameCount)
                    self.meterTapLevels[tid] = levels
                }
            }
        }

        // Install tap on master mixer
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
            guard let self else { return }
            os_unfair_lock_lock(&self.mixdownRecordingLock)
            let mixdownRecording = self.isRecordingMainMix
            let mixdownFile = self.mixdownRecordingFile
            os_unfair_lock_unlock(&self.mixdownRecordingLock)
            if mixdownRecording, let mixdownFile, let mixdownBuffer = Self.copyPCMBuffer(buffer) {
                self.mixdownWriteGroup.enter()
                self.mixdownWriterQueue.async { [weak self] in
                    defer { self?.mixdownWriteGroup.leave() }
                    do {
                        try mixdownFile.write(from: mixdownBuffer)
                    } catch {
                        self?.mixdownRecordingHadWriteError = true
                    }
                }
            }
            // Copy buffer data on the audio render thread (pointer only valid during callback)
            let (left, right, frameCount) = Self.copyChannelData(from: buffer)
            self.audioQueue.async { [weak self] in
                guard let self else { return }
                let levels = Self.computeLevelsFromCopy(left: left, right: right, frameCount: frameCount)
                self.masterMeterRaw = levels
            }
        }
    }

    private func removeMeterTaps() {
        guard meterTapsInstalled else { return }
        meterTapsInstalled = false
        for submix in trackSubmixNodes.values {
            submix.removeTap(onBus: 0)
        }
        // Only remove master tap if it was installed
        engine.mainMixerNode.removeTap(onBus: 0)
    }

    private func startMeterPublishTimer() {
        stopMeterPublishTimer()
        let timer = DispatchSource.makeTimerSource(flags: [], queue: audioQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(5))
        let decayPerFrame: Float = 24.0 / 30.0  // 24dB/sec at 30fps

        timer.setEventHandler { [weak self] in
            guard let self, self.isPlaying else { return }

            // Apply peak hold + decay for each track
            var publishLevels: [UUID: MeterLevels] = [:]
            for (trackID, raw) in self.meterTapLevels {
                var held = self.meterPeakHold[trackID] ?? (-160, -160)
                held.peakL = max(raw.peakL, held.peakL - decayPerFrame)
                held.peakR = max(raw.peakR, held.peakR - decayPerFrame)
                self.meterPeakHold[trackID] = held
                publishLevels[trackID] = MeterLevels(
                    peakL: held.peakL, peakR: held.peakR,
                    rmsL: raw.rmsL, rmsR: raw.rmsR,
                    clipped: raw.clipped
                )
            }

            // Master
            var masterHeld = self.masterPeakHold
            masterHeld.peakL = max(self.masterMeterRaw.peakL, masterHeld.peakL - decayPerFrame)
            masterHeld.peakR = max(self.masterMeterRaw.peakR, masterHeld.peakR - decayPerFrame)
            self.masterPeakHold = masterHeld
            let masterLevels = MeterLevels(
                peakL: masterHeld.peakL, peakR: masterHeld.peakR,
                rmsL: self.masterMeterRaw.rmsL, rmsR: self.masterMeterRaw.rmsR,
                clipped: self.masterMeterRaw.clipped
            )

            self.onMeterUpdate?(publishLevels, masterLevels)
        }
        timer.resume()
        meterPublishTimer = timer
    }

    private func stopMeterPublishTimer() {
        meterPublishTimer?.cancel()
        meterPublishTimer = nil
    }

    /// Compute peak and RMS from an audio buffer using Accelerate/vDSP.
    nonisolated private static func computeLevels(buffer: AVAudioPCMBuffer) -> MeterLevels {
        guard let floatData = buffer.floatChannelData else { return .zero }
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else { return .zero }
        let channelCount = Int(buffer.format.channelCount)

        var peakL: Float = 0
        var rmsL: Float = 0
        var peakR: Float = 0
        var rmsR: Float = 0

        // Left channel (channel 0)
        vDSP_maxmgv(floatData[0], 1, &peakL, frameCount)
        vDSP_rmsqv(floatData[0], 1, &rmsL, frameCount)

        // Right channel (channel 1, or duplicate left for mono)
        if channelCount >= 2 {
            vDSP_maxmgv(floatData[1], 1, &peakR, frameCount)
            vDSP_rmsqv(floatData[1], 1, &rmsR, frameCount)
        } else {
            peakR = peakL
            rmsR = rmsL
        }

        let clipped = peakL >= 1.0 || peakR >= 1.0

        // Convert to dB
        func toDB(_ v: Float) -> Float {
            20 * log10(max(v, 1e-8))
        }

        return MeterLevels(
            peakL: toDB(peakL), peakR: toDB(peakR),
            rmsL: toDB(rmsL), rmsR: toDB(rmsR),
            clipped: clipped
        )
    }

    /// - Parameter keepReconfiguring: When `true`, leaves `isReconfiguring` set so the
    ///   caller (e.g. `playOnAudioQueue`) can keep the health-check suppressed through
    ///   the entire setup flow. The caller is responsible for clearing it.
    /// - Parameter pauseEngine: Whether to pause the AVAudioEngine as part of stop.
    ///   Natural song-end transitions should pass `false` to avoid unnecessary AU
    ///   deallocation/reallocation cycles.
    /// - Parameter releaseSequencer: Whether to drop the current AVAudioSequencer instance.
    ///   Lightweight natural-end stops should keep it alive until the next play-start teardown.
    /// - Parameter lightweight: If true, only flip playback state and cancel timers that can
    ///   continue mutating while idle. Avoids graph/sequencer mutation in end-of-song callbacks.
    private func stopOnAudioQueue(
        keepReconfiguring: Bool = false,
        pauseEngine: Bool = true,
        releaseSequencer: Bool = true,
        lightweight: Bool = false,
        preserveMainMixRecording: Bool = false
    ) {
        isReconfiguring = true
        playbackStopWorkItem?.cancel()
        playbackStopWorkItem = nil

        if lightweight {
            stopAutomationTimer()
            stopLoopRecordingTimer()
            setPlaying(false)
            if !keepReconfiguring {
                isReconfiguring = false
            }
            return
        }
        // Pause only when required. During natural end transitions we avoid pause/resume
        // churn because some out-of-process AUs become unstable after repeated pauses.
        let shouldPauseEngine = pauseEngine && (isPlaying || sequencer != nil || isRecordingAudio || !inputMonitorNodes.isEmpty)
        // Only clear SF2 signatures when we really pause the engine. The reload is needed after
        // engine pause/resume cycles, but not for a host-style transport stop that leaves the
        // render graph alive.
        if !keepReconfiguring && shouldPauseEngine {
            patchSignatureByMappingKey = patchSignatureByMappingKey.filter { $1.auSubType != nil }
        }
        if shouldPauseEngine {
            if engine.isRunning { engineStopIsOursDepth += 1 }
            engine.pause()
        } else {
            // Flip transport state first so helper teardown paths don't trigger extra
            // engine.pause()/engine.start() churn while the engine is idling.
            setPlaying(false)
        }

        // Stop recording if active
        if isRecordingAudio {
            stopRecordingOnAudioQueue()
        }
        if isRecordingMainMix && !preserveMainMixRecording {
            stopMainMixRecordingOnAudioQueue()
        }

        // Tear down input monitoring (snapshot keys to avoid mutating dict during iteration)
        for trackID in Array(inputMonitorNodes.keys) {
            disableInputMonitoringOnAudioQueue(trackID: trackID)
        }

        stopAutomationTimer()
        stopLoopRecordingTimer()
        tearDownMetronomeOnAudioQueue()
        removeMeterTaps()
        stopMeterPublishTimer()
        cancelHostedMIDIDelivery()
        meterTapLevels.removeAll()
        meterPeakHold.removeAll()
        masterMeterRaw = .zero
        masterPeakHold = (-160, -160)

        // Never call AVAudioSequencer.stop() here.
        // AVAudioSequencer.stop() broadcasts CC 120 "All Sound Off" + CC 123 "All Notes Off"
        // to each track destination, which can leave some AUv3s permanently muted (BBC SO).
        // Also avoid mutating track.destinationAudioUnit during teardown: AVMusicTrack can
        // throw NSException in this state on natural-end transitions.
        // On a normal user stop we leave the engine running and send direct note-offs to the
        // loaded instruments. When we do need a deeper teardown, we still drop the sequencer
        // instance and rebuild it on the next play.
        if releaseSequencer {
            sequencer = nil
        }

        stopAllActiveNotes()
        clearScheduledAudioClips()

        setPlaying(false)
        if !keepReconfiguring {
            isReconfiguring = false
        }
    }

    private func recommendedMaximumFramesToRender() -> UInt32 {
        // Render bigger chunks than device IO buffer to reduce underruns under UI load.
        let base = max(preferredBufferFrames, 128)
        return min(max(base * 4, 1024), 16384)
    }

    private func applyRenderBufferSettingsOnAudioQueue() {
        let maxFrames = recommendedMaximumFramesToRender()
        withEnginePaused {
            if !engine.mainMixerNode.auAudioUnit.renderResourcesAllocated {
                engine.mainMixerNode.auAudioUnit.maximumFramesToRender = maxFrames
            }
            if !engine.outputNode.auAudioUnit.renderResourcesAllocated {
                engine.outputNode.auAudioUnit.maximumFramesToRender = maxFrames
            }
            for sampler in samplerByMappingKey.values {
                if !sampler.auAudioUnit.renderResourcesAllocated {
                    sampler.auAudioUnit.maximumFramesToRender = maxFrames
                }
            }
            for au in auInstrumentByMappingKey.values {
                if !au.auAudioUnit.renderResourcesAllocated {
                    au.auAudioUnit.maximumFramesToRender = maxFrames
                }
            }
        }
    }

    private func setPlaying(_ playing: Bool) {
        guard isPlaying != playing else { return }
        isPlaying = playing
        if !playing {
            NSLog("[Engine] setPlaying(false) called")
            fileLog("setPlaying(false) — isReconfiguring=\(isReconfiguring)")
        }
        onPlaybackStateChange?(playing)
    }

    private func reportError(_ message: String) {
        onPlaybackError?(message)
    }

    private func fileLog(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        if let data = line.data(using: .utf8) {
            let url = URL(fileURLWithPath: "/tmp/novotro-engine.log")
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

}

private enum StandardMIDIFileWriter {
    struct SequenceBuild {
        let data: Data
        let noteTrackKeys: [String]
    }

    private struct MIDIEvent {
        let tick: Int
        let sortPriority: Int
        let bytes: [UInt8]
    }

    static func makeFile(
        noteGroups: [String: [PianoRollNote]],
        lengthTicks: Int,
        ticksPerQuarter: Int,
        tempoBPM: Double,
        tempoEvents: [TempoPoint]
    ) -> SequenceBuild {
        let orderedKeys = noteGroups.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
        let header = makeHeader(trackCount: 1 + orderedKeys.count, ticksPerQuarter: ticksPerQuarter)
        let metaTrack = makeMetaTrack(lengthTicks: lengthTicks, tempoBPM: tempoBPM, tempoEvents: tempoEvents)
        let noteTracks = orderedKeys.map { key in
            makeNoteTrack(notes: noteGroups[key] ?? [], lengthTicks: lengthTicks, outputChannel: 0)
        }

        var data = Data()
        data.append(header)
        data.append(metaTrack)
        for track in noteTracks {
            data.append(track)
        }

        return SequenceBuild(data: data, noteTrackKeys: orderedKeys)
    }

    private static func makeHeader(trackCount: Int, ticksPerQuarter: Int) -> Data {
        var data = Data()
        data.append(contentsOf: Array("MThd".utf8))
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x06])
        data.append(contentsOf: [0x00, 0x01])
        data.append(contentsOf: [UInt8((trackCount >> 8) & 0xFF), UInt8(trackCount & 0xFF)])
        data.append(contentsOf: [UInt8((ticksPerQuarter >> 8) & 0xFF), UInt8(ticksPerQuarter & 0xFF)])
        return data
    }

    private static func makeMetaTrack(lengthTicks: Int, tempoBPM: Double, tempoEvents: [TempoPoint]) -> Data {
        var body = Data()
        body.append(contentsOf: [0x00, 0xFF, 0x03])
        let title = Array("Novotro Score".utf8)
        body.append(contentsOf: variableLengthQuantity(title.count))
        body.append(contentsOf: title)

        let normalizedTempo = normalizedTempoEvents(
            tempoEvents,
            fallbackTempoBPM: tempoBPM,
            maxTick: max(lengthTicks, 1)
        )

        var lastTick = 0
        for tempo in normalizedTempo {
            let delta = max(0, tempo.tick - lastTick)
            body.append(contentsOf: variableLengthQuantity(delta))
            body.append(contentsOf: [0xFF, 0x51, 0x03])
            let mpq = Int(max(1, min(0xFFFFFF, (60_000_000.0 / max(tempo.bpm, 20)).rounded())))
            body.append(contentsOf: [
                UInt8((mpq >> 16) & 0xFF),
                UInt8((mpq >> 8) & 0xFF),
                UInt8(mpq & 0xFF)
            ])
            lastTick = tempo.tick
        }

        body.append(contentsOf: variableLengthQuantity(max(0, max(lengthTicks, 1) - lastTick)))
        body.append(contentsOf: [0xFF, 0x2F, 0x00])

        return chunk(type: "MTrk", body: body)
    }

    private static func normalizedTempoEvents(
        _ tempoEvents: [TempoPoint],
        fallbackTempoBPM: Double,
        maxTick: Int
    ) -> [TempoPoint] {
        let boundedTick = max(1, maxTick)
        let events: [TempoPoint]
        if tempoEvents.isEmpty {
            events = [TempoPoint(tick: 0, bpm: fallbackTempoBPM)]
        } else {
            events = tempoEvents
        }

        var dedup: [Int: TempoPoint] = [:]
        for event in events {
            let tick = min(max(0, event.tick), boundedTick - 1)
            dedup[tick] = TempoPoint(tick: tick, bpm: event.bpm)
        }

        var sorted = dedup.values.sorted { $0.tick < $1.tick }
        if sorted.first?.tick != 0 {
            sorted.insert(TempoPoint(tick: 0, bpm: sorted.first?.bpm ?? fallbackTempoBPM), at: 0)
        }

        // Remove micro-variation events that differ by less than 0.5 BPM from
        // the previous retained event. These arise from FL Studio's internal
        // step-quantized tempo automation and are perceptually inaudible, but
        // writing hundreds of near-identical tempo events to the MIDI file can
        // cause playback instability in AVAudioSequencer.
        var filtered: [TempoPoint] = []
        for event in sorted {
            if let last = filtered.last, abs(event.bpm - last.bpm) < 0.5 {
                continue
            }
            filtered.append(event)
        }
        return filtered
    }

    private static func makeNoteTrack(notes: [PianoRollNote], lengthTicks: Int, outputChannel: Int) -> Data {
        var events: [MIDIEvent] = []
        events.reserveCapacity(notes.count * 2 + notes.count)

        let channel = UInt8(min(max(outputChannel, 0), 15))

        for note in notes {
            let pitch = UInt8(min(max(note.pitch, 0), 127))
            let velocity = UInt8(min(max(note.velocity, 1), 127))

            let start = max(0, note.startTick)
            let end = max(start + 1, note.startTick + note.duration)

            // FF 05 Lyric meta event — emitted just before note-on
            if let syllable = note.lyricSyllable, !syllable.isEmpty {
                let textBytes = Array(syllable.utf8)
                var lyricBytes: [UInt8] = [0xFF, 0x05]
                lyricBytes.append(contentsOf: variableLengthQuantity(textBytes.count))
                lyricBytes.append(contentsOf: textBytes)
                events.append(
                    MIDIEvent(
                        tick: start,
                        sortPriority: 1,  // after note-off (0), before note-on (2)
                        bytes: lyricBytes
                    )
                )
            }

            events.append(
                MIDIEvent(
                    tick: start,
                    sortPriority: 2,  // note-on comes last at same tick
                    bytes: [0x90 | channel, pitch, velocity]
                )
            )
            events.append(
                MIDIEvent(
                    tick: end,
                    sortPriority: 0,  // note-off comes first at same tick
                    bytes: [0x80 | channel, pitch, 0]
                )
            )
        }

        events.sort { lhs, rhs in
            if lhs.tick != rhs.tick { return lhs.tick < rhs.tick }
            return lhs.sortPriority < rhs.sortPriority
        }

        var body = Data()
        var lastTick = 0

        for event in events {
            let delta = max(0, event.tick - lastTick)
            body.append(contentsOf: variableLengthQuantity(delta))
            body.append(contentsOf: event.bytes)
            lastTick = event.tick
        }

        let remaining = max(0, lengthTicks - lastTick)
        body.append(contentsOf: variableLengthQuantity(remaining))
        body.append(contentsOf: [0xFF, 0x2F, 0x00])

        return chunk(type: "MTrk", body: body)
    }

    private static func chunk(type: String, body: Data) -> Data {
        var chunk = Data()
        chunk.append(contentsOf: Array(type.utf8))

        let len = body.count
        chunk.append(contentsOf: [
            UInt8((len >> 24) & 0xFF),
            UInt8((len >> 16) & 0xFF),
            UInt8((len >> 8) & 0xFF),
            UInt8(len & 0xFF)
        ])
        chunk.append(body)

        return chunk
    }

    private static func variableLengthQuantity(_ value: Int) -> [UInt8] {
        var working = max(0, value)
        var bytes: [UInt8] = [UInt8(working & 0x7F)]
        working >>= 7

        while working > 0 {
            bytes.insert(UInt8((working & 0x7F) | 0x80), at: 0)
            working >>= 7
        }

        return bytes
    }
}
