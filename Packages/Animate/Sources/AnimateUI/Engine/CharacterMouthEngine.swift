import Foundation

@available(macOS 26.0, *)
struct CharacterLipsyncBeat: Sendable, Hashable {
    var startFrame: Int
    var endFrame: Int
    var mode: String
    var songName: String?
}

@available(macOS 26.0, *)
struct CharacterMouthState: Sendable, Hashable {
    var cue: String
    var viseme: PrestonBlairViseme
    var jawOpen: Double
    var mouthWidth: Double
    var mouthHeight: Double
    var pucker: Double
    var smileBlend: Double

    static let rest = CharacterMouthState(
        cue: "rest",
        viseme: .rest,
        jawOpen: 0.02,
        mouthWidth: 0.42,
        mouthHeight: 0.08,
        pucker: 0,
        smileBlend: 0
    )

    func withCue(_ cue: String, viseme: PrestonBlairViseme? = nil) -> CharacterMouthState {
        var copy = self
        copy.cue = cue
        if let viseme {
            copy.viseme = viseme
        }
        return copy
    }

    func applying(_ preset: CharacterPerformanceMouthPreset) -> CharacterMouthState {
        CharacterMouthState(
            cue: cue,
            viseme: viseme,
            jawOpen: preset.jawOpen,
            mouthWidth: preset.mouthWidth,
            mouthHeight: preset.mouthHeight,
            pucker: preset.pucker,
            smileBlend: preset.smileBlend
        )
    }
}

@available(macOS 26.0, *)
struct CharacterMouthEngine: Sendable {
    func state(
        for characterName: String,
        blocking: CharacterBlockingPlan,
        frame: Int,
        liveCue: String?,
        baseFPS: Int,
        profile: Character3DPerformanceProfile? = nil
    ) -> CharacterMouthState {
        if let viseme = resolveLiveViseme(liveCue) {
            return canonicalized(state: state(for: viseme), profile: profile)
        }

        if let beat = blocking.lipsyncBeats.first(where: { $0.startFrame <= frame && frame <= $0.endFrame }) {
            let keyframes = syntheticKeyframes(in: beat, baseFPS: baseFPS, characterName: characterName, profile: profile)
            if !keyframes.isEmpty {
                let snapshot = VisemeBlendEngine.blendedState(at: frame, keyframes: keyframes, transitionFrames: 3, fps: baseFPS)
                let currentViseme = syntheticViseme(in: beat, frame: frame, baseFPS: baseFPS, characterName: characterName, profile: profile)
                return canonicalized(
                    state: mouthState(from: snapshot, viseme: currentViseme),
                    profile: profile
                )
            }
            return canonicalized(
                state: state(for: syntheticViseme(in: beat, frame: frame, baseFPS: baseFPS, characterName: characterName, profile: profile)),
                profile: profile
            )
        }

        if blocking.actingBeats.contains(where: { $0.startFrame <= frame && frame <= $0.endFrame && talksOrSings($0.action) }) {
            let cycle = plannedCycle(
                base: [.consonant, .ai, .e, .o, .rest],
                profile: profile
            )
            let step = max(1, baseFPS / 12)
            let index = (frame / step) % cycle.count
            return canonicalized(state: state(for: cycle[index]), profile: profile)
        }

        return canonicalized(state: .rest, profile: profile)
    }
}

@available(macOS 26.0, *)
private extension CharacterMouthEngine {
    func resolveLiveViseme(_ cue: String?) -> PrestonBlairViseme? {
        guard let normalized = CharacterRenderSelectionContext.normalizeMouth(cue) else {
            return nil
        }
        return PrestonBlairViseme.allCases.first(where: { $0.token == normalized })
            ?? mapApproximateCue(normalized)
    }

    func syntheticViseme(
        in beat: CharacterLipsyncBeat,
        frame: Int,
        baseFPS: Int,
        characterName: String,
        profile: Character3DPerformanceProfile?
    ) -> PrestonBlairViseme {
        let mode = beat.mode.lowercased()
        let singingCycle = plannedCycle(
            base: [.ai, .o, .e, .u, .ai, .rest],
            profile: profile
        )
        let speechCycle = plannedCycle(
            base: [.consonant, .ai, .e, .mbp, .o, .rest],
            profile: profile
        )
        let cycle = mode.contains("sing") ? singingCycle : speechCycle
        let step = max(1, baseFPS / (mode.contains("sing") ? 8 : 12))
        let phase = ((frame - beat.startFrame) / step + abs(characterName.hashValue % cycle.count)) % cycle.count
        return cycle[phase]
    }

    func state(for viseme: PrestonBlairViseme) -> CharacterMouthState {
        switch viseme {
        case .rest:
            return .rest
        case .ai:
            return CharacterMouthState(cue: viseme.token, viseme: viseme, jawOpen: 0.85, mouthWidth: 0.72, mouthHeight: 0.9, pucker: 0, smileBlend: 0.04)
        case .e:
            return CharacterMouthState(cue: viseme.token, viseme: viseme, jawOpen: 0.52, mouthWidth: 0.82, mouthHeight: 0.46, pucker: 0, smileBlend: 0.12)
        case .o:
            return CharacterMouthState(cue: viseme.token, viseme: viseme, jawOpen: 0.58, mouthWidth: 0.5, mouthHeight: 0.64, pucker: 0.45, smileBlend: 0)
        case .u:
            return CharacterMouthState(cue: viseme.token, viseme: viseme, jawOpen: 0.42, mouthWidth: 0.38, mouthHeight: 0.48, pucker: 0.68, smileBlend: 0)
        case .consonant:
            return CharacterMouthState(cue: viseme.token, viseme: viseme, jawOpen: 0.28, mouthWidth: 0.62, mouthHeight: 0.22, pucker: 0.05, smileBlend: 0)
        case .fv:
            return CharacterMouthState(cue: viseme.token, viseme: viseme, jawOpen: 0.2, mouthWidth: 0.66, mouthHeight: 0.2, pucker: 0.04, smileBlend: 0)
        case .l:
            return CharacterMouthState(cue: viseme.token, viseme: viseme, jawOpen: 0.34, mouthWidth: 0.68, mouthHeight: 0.3, pucker: 0, smileBlend: 0)
        case .mbp:
            return CharacterMouthState(cue: viseme.token, viseme: viseme, jawOpen: 0.06, mouthWidth: 0.52, mouthHeight: 0.08, pucker: 0, smileBlend: 0)
        case .wq:
            return CharacterMouthState(cue: viseme.token, viseme: viseme, jawOpen: 0.2, mouthWidth: 0.34, mouthHeight: 0.2, pucker: 0.9, smileBlend: 0)
        }
    }

    func mapApproximateCue(_ cue: String) -> PrestonBlairViseme? {
        switch cue {
        case _ where cue.contains("sing") || cue.contains("belt"):
            return .ai
        case _ where cue.contains("speak") || cue.contains("talk"):
            return .consonant
        case _ where cue.contains("closed") || cue.contains("rest"):
            return .rest
        default:
            return nil
        }
    }

    func talksOrSings(_ action: String) -> Bool {
        let value = action.lowercased()
        return value.contains("speak") || value.contains("sing") || value.contains("shout") || value.contains("call")
    }

    func plannedCycle(
        base: [PrestonBlairViseme],
        profile: Character3DPerformanceProfile?
    ) -> [PrestonBlairViseme] {
        guard let profile else {
            return base
        }

        let available = profile.availableVisemes()
        guard !available.isEmpty else {
            return base
        }

        var ordered: [PrestonBlairViseme] = []
        for viseme in base where available.contains(viseme) && !ordered.contains(viseme) {
            ordered.append(viseme)
        }

        if !ordered.isEmpty {
            return ordered
        }

        return available
    }

    func mouthState(from snapshot: VisemeBlendEngine.MouthSnapshot, viseme: PrestonBlairViseme) -> CharacterMouthState {
        CharacterMouthState(
            cue: viseme.token,
            viseme: viseme,
            jawOpen: snapshot.jawOpen,
            mouthWidth: snapshot.mouthWidth,
            mouthHeight: snapshot.mouthHeight,
            pucker: snapshot.pucker,
            smileBlend: snapshot.smileBlend
        )
    }

    /// Build a full sequence of `TimedViseme` keyframes covering the lipsync beat,
    /// suitable for smooth interpolation via `VisemeBlendEngine`.
    func syntheticKeyframes(
        in beat: CharacterLipsyncBeat,
        baseFPS: Int,
        characterName: String,
        profile: Character3DPerformanceProfile?
    ) -> [VisemeBlendEngine.TimedViseme] {
        let mode = beat.mode.lowercased()
        let singingCycle = plannedCycle(
            base: [.ai, .o, .e, .u, .ai, .rest],
            profile: profile
        )
        let speechCycle = plannedCycle(
            base: [.consonant, .ai, .e, .mbp, .o, .rest],
            profile: profile
        )
        let cycle = mode.contains("sing") ? singingCycle : speechCycle
        guard !cycle.isEmpty else { return [] }

        let step = max(1, baseFPS / (mode.contains("sing") ? 8 : 12))
        let phaseOffset = abs(characterName.hashValue % cycle.count)

        var keyframes: [VisemeBlendEngine.TimedViseme] = []
        var f = beat.startFrame
        while f <= beat.endFrame {
            let phase = ((f - beat.startFrame) / step + phaseOffset) % cycle.count
            let nextStepFrame = min(beat.endFrame + 1, f + step)
            let duration = nextStepFrame - f
            keyframes.append(VisemeBlendEngine.TimedViseme(
                frame: f,
                viseme: cycle[phase],
                durationFrames: duration
            ))
            f = nextStepFrame
        }
        return keyframes
    }

    func canonicalized(
        state: CharacterMouthState,
        profile: Character3DPerformanceProfile?
    ) -> CharacterMouthState {
        guard let profile,
              let canonicalCue = profile.resolvedVisemeCue(for: state),
              canonicalCue.caseInsensitiveCompare(state.cue) != .orderedSame else {
            return state
        }
        let canonicalViseme = profile.canonicalVisemeToken(for: state)
        return state.withCue(canonicalCue, viseme: canonicalViseme)
    }
}
