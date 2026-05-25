import Accelerate
import AVFoundation

final class MeterManager {
    unowned let parent: MIDIPlaybackEngine

    // MARK: - Meter State

    var meterTapLevels: [UUID: MeterLevels] = [:]
    var masterMeterRaw: MeterLevels = .zero
    private var meterPublishTimer: DispatchSourceTimer?
    var meterTapsInstalled = false
    var meterPeakHold: [UUID: (peakL: Float, peakR: Float)] = [:]
    var masterPeakHold: (peakL: Float, peakR: Float) = (-160, -160)
    var onMeterUpdate: (([UUID: MeterLevels], MeterLevels) -> Void)?

    init(parent: MIDIPlaybackEngine) {
        self.parent = parent
    }

    // MARK: - Static Helpers

    static func copyChannelData(from buffer: AVAudioPCMBuffer) -> (left: [Float], right: [Float]?, frameCount: Int) {
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

    static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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

    static func computeLevelsFromCopy(left: [Float], right: [Float]?, frameCount: Int) -> MeterLevels {
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

    static func computeLevels(buffer: AVAudioPCMBuffer) -> MeterLevels {
        guard let floatData = buffer.floatChannelData else { return .zero }
        let frameCount = vDSP_Length(buffer.frameLength)
        guard frameCount > 0 else { return .zero }
        let channelCount = Int(buffer.format.channelCount)

        var peakL: Float = 0
        var rmsL: Float = 0
        var peakR: Float = 0
        var rmsR: Float = 0

        vDSP_maxmgv(floatData[0], 1, &peakL, frameCount)
        vDSP_rmsqv(floatData[0], 1, &rmsL, frameCount)

        if channelCount >= 2 {
            vDSP_maxmgv(floatData[1], 1, &peakR, frameCount)
            vDSP_rmsqv(floatData[1], 1, &rmsR, frameCount)
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

    // MARK: - Submix Tap Management

    func installSubmixTaps(submixNodes: [UUID: AVAudioMixerNode]) {
        guard !meterTapsInstalled else { return }
        meterTapsInstalled = true
        let bufferSize: AVAudioFrameCount = parent.exportTapBufferFrames > 0 ? parent.exportTapBufferFrames : 1024

        let attached = parent.engine.attachedNodes
        for (trackID, submix) in submixNodes {
            guard attached.contains(submix) else { continue }
            let tid = trackID
            submix.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
                guard let self else { return }
                let (left, right, frameCount) = Self.copyChannelData(from: buffer)
                self.parent.audioQueue.async { [weak self] in
                    guard let self else { return }
                    let levels = Self.computeLevelsFromCopy(left: left, right: right, frameCount: frameCount)
                    self.meterTapLevels[tid] = levels
                }
            }
        }
    }

    func removeSubmixTaps(submixNodes: [UUID: AVAudioMixerNode]) {
        guard meterTapsInstalled else { return }
        meterTapsInstalled = false
        for submix in submixNodes.values {
            submix.removeTap(onBus: 0)
        }
    }

    // MARK: - Publish Timer

    func startMeterPublishTimer() {
        stopMeterPublishTimer()
        let timer = DispatchSource.makeTimerSource(flags: [], queue: parent.audioQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(5))
        let decayPerFrame: Float = 24.0 / 30.0

        timer.setEventHandler { [weak self] in
            guard let self, parent.isPlaying else { return }

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

    func stopMeterPublishTimer() {
        meterPublishTimer?.cancel()
        meterPublishTimer = nil
    }

    // MARK: - State Reset

    func resetMeterState() {
        meterTapLevels.removeAll()
        meterPeakHold.removeAll()
        masterMeterRaw = .zero
        masterPeakHold = (-160, -160)
        meterTapsInstalled = false
    }

    // MARK: - Public API

    func getMeterLevels(completion: @escaping @Sendable ([UUID: MeterLevels], MeterLevels) -> Void) {
        parent.audioQueue.async { [weak self] in
            guard let self else {
                completion([:], .zero)
                return
            }
            let tracks = self.meterTapLevels
            let master = self.masterMeterRaw
            completion(tracks, master)
        }
    }
}
