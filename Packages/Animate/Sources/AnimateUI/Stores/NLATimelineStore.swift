import Foundation

@available(macOS 26.0, *)
@MainActor
final class NLATimelineStore {
    unowned let parent: AnimateStore
    init(parent: AnimateStore) { self.parent = parent }

    func evaluateNLAAtCurrentFrame() {
        guard let timeline = parent.nlaTimeline, !timeline.tracks.isEmpty else {
            parent.nlaBlendedPose = nil
            return
        }
        parent.nlaBlendedPose = NLAEvaluator.evaluate(timeline: timeline, frame: parent.currentFrame) { [cache = parent.motionClipDataCache] clipID in
            cache[clipID]
        }
    }

    func registerMotionClipData(id: UUID, data: NLAEvaluator.MotionClipData) {
        parent.motionClipDataCache[id] = data
    }

    func unregisterMotionClipData(id: UUID) {
        parent.motionClipDataCache.removeValue(forKey: id)
    }

    func clearMotionClipDataCache() {
        parent.motionClipDataCache.removeAll()
    }

    func saveNLATimeline() {
        guard let sceneID = parent.selectedSceneID, let animateDir = parent.animateURL, let timeline = parent.nlaTimeline else { return }
        do { try NLATimelinePersistence.save(timeline: timeline, animateDir: animateDir, sceneID: sceneID) }
        catch { print("[AnimateStore] Failed to save NLA timeline: \(error)") }
    }

    func addMotionClipToTimeline(_ clip: MotionClip) {
        if !parent.motionClips.contains(where: { $0.id == clip.id }) { parent.motionClips.append(clip) }
        if parent.nlaTimeline == nil { parent.nlaTimeline = NLATimeline(fps: parent.fps) }
        if parent.nlaTimeline!.tracks.isEmpty { parent.nlaTimeline!.addTrack(NLATrack(name: "Base", colorTag: .imported)) }
        guard let trackIdx = parent.nlaTimeline!.tracks.indices.first else { return }
        let lastEnd = parent.nlaTimeline!.tracks[trackIdx].clips.map { $0.startFrame + $0.timelineDuration(motionClipFrameCount: clip.frameCount) }.max() ?? 0
        parent.nlaTimeline!.tracks[trackIdx].clips.append(NLAClip(motionClipID: clip.id, startFrame: lastEnd, speed: 1.0, blendInFrames: 0, blendOutFrames: 0))
        let clipEndTime = Double(lastEnd + clip.frameCount) / Double(max(parent.fps, 1))
        parent.nlaTimeline!.duration = max(parent.nlaTimeline!.duration, clipEndTime)
        saveNLATimeline()
        evaluateNLAAtCurrentFrame()
    }

    func addMotionClipToLipSyncTrack(_ clip: MotionClip) {
        if !parent.motionClips.contains(where: { $0.id == clip.id }) { parent.motionClips.append(clip) }
        if parent.nlaTimeline == nil { parent.nlaTimeline = NLATimeline(fps: parent.fps) }
        let lipSyncTrackIdx: Int
        if let idx = parent.nlaTimeline!.tracks.firstIndex(where: { $0.name == "Lip Sync" }) { lipSyncTrackIdx = idx }
        else {
            var track = NLATrack(name: "Lip Sync", bodyMask: .mouth, colorTag: .webcam)
            track.sortOrder = (parent.nlaTimeline!.tracks.map(\.sortOrder).max() ?? -1) + 1
            parent.nlaTimeline!.tracks.append(track)
            lipSyncTrackIdx = parent.nlaTimeline!.tracks.count - 1
        }
        let lastEnd = parent.nlaTimeline!.tracks[lipSyncTrackIdx].clips.map { $0.startFrame + $0.timelineDuration(motionClipFrameCount: clip.frameCount) }.max() ?? 0
        parent.nlaTimeline!.tracks[lipSyncTrackIdx].clips.append(NLAClip(motionClipID: clip.id, startFrame: lastEnd, speed: 1.0, blendInFrames: 0, blendOutFrames: 0))
        saveNLATimeline()
        evaluateNLAAtCurrentFrame()
    }

    func deleteMotionClip(id: UUID) {
        parent.motionClips.removeAll { $0.id == id }
        if parent.selectedMotionClipID == id { parent.selectedMotionClipID = nil }
        if let animateDir = parent.animateURL { try? MotionClipPersistence.delete(clipID: id, animateURL: animateDir) }
    }

    func renameMotionClip(id: UUID, newName: String) {
        guard let index = parent.motionClips.firstIndex(where: { $0.id == id }) else { return }
        parent.motionClips[index].name = newName
    }

    func importBVHFile(url: URL) throws {
        let clip = try BVHParser.parse(url: url)
        parent.addMotionClip(clip)
    }

    func setClipSpeed(clipID: UUID, speed: Float) {
        guard var timeline = parent.nlaTimeline else { return }
        for trackIdx in timeline.tracks.indices {
            if let clipIdx = timeline.tracks[trackIdx].clips.firstIndex(where: { $0.id == clipID }) {
                timeline.tracks[trackIdx].clips[clipIdx].speed = max(0.1, min(4.0, speed))
            }
        }
        parent.nlaTimeline = timeline
    }
}
