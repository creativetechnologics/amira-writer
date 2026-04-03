import Foundation

public actor Amira3DRuntimeShell {
    public private(set) var state: EngineRuntimeState
    public private(set) var registries: RegistryBundle
    private let compiler: PlanCompiler

    public init(
        state: EngineRuntimeState = .init(),
        registries: RegistryBundle = .empty,
        compiler: PlanCompiler = .init()
    ) {
        self.state = state
        self.registries = registries
        self.compiler = compiler
    }

    public func replaceRegistries(_ registries: RegistryBundle) {
        self.registries = registries
    }

    public func preview(_ plan: ScenePlan) -> ApplyPreview {
        compiler.preview(plan: plan, currentState: state, registries: registries)
    }

    @discardableResult
    public func stage(_ plan: ScenePlan) -> ApplyPreview {
        let preview = compiler.preview(plan: plan, currentState: state, registries: registries)
        state.sceneID = plan.sceneID
        state.review.pendingCommands = plan.commands
        state.review.lastPreview = preview
        return preview
    }

    public func apply(_ preview: ApplyPreview) {
        for effect in preview.effects {
            switch effect.scope {
            case .worldState:
                if case .activate = effect.changeKind {
                    state.world.activeWorldID = WorldID(effect.target)
                }
            case .cameraState:
                if effect.target.isEmpty == false {
                    state.camera.activePresetID = CameraPresetID(effect.target)
                }
                if case .object(let payload) = effect.proposedValue,
                   case .string(let move)? = payload["move"] {
                    state.camera.move = move
                }
            case .styleState:
                state.style.activeStyleProfileID = StyleProfileID(effect.target)
            case .lightRig:
                state.style.activeLightRigID = LightRigID(effect.target)
            case .atmosphereState:
                state.style.activeAtmospherePresetID = AtmospherePresetID(effect.target)
            case .assetPlacement:
                state.world.assetPlacements[AssetID(effect.target)] = transform(from: effect.proposedValue)
            case .characterState:
                let id = CharacterID(effect.target)
                var existing = state.characters[id] ?? CharacterGraphState(characterID: id)
                if case .object(let payload) = effect.proposedValue,
                   case .string(let motionID)? = payload["motionId"] {
                    existing.motionID = MotionID(motionID)
                }
                state.characters[id] = existing
            case .faceState:
                let id = CharacterID(effect.target)
                var existing = state.characters[id] ?? CharacterGraphState(characterID: id)
                if case .object(let payload) = effect.proposedValue {
                    if case .string(let faceRigID)? = payload["faceRigId"] {
                        existing.face.faceRigID = FaceRigID(faceRigID)
                    }
                    if case .string(let expressionProfileID)? = payload["expressionProfileId"] {
                        existing.face.expressionProfileID = ExpressionProfileID(expressionProfileID)
                    }
                    if case .string(let expressionID)? = payload["expressionId"] {
                        existing.face.expressionID = expressionID
                    }
                    if case .string(let expressionCue)? = payload["expressionCue"] {
                        existing.face.expressionCue = expressionCue
                    }
                    if case .number(let intensity)? = payload["intensity"] {
                        existing.face.intensity = intensity
                    }
                }
                state.characters[id] = existing
            case .expressionState:
                let id = CharacterID(effect.target)
                var existing = state.characters[id] ?? CharacterGraphState(characterID: id)
                if case .object(let payload) = effect.proposedValue {
                    if case .string(let expressionProfileID)? = payload["expressionProfileId"] {
                        existing.face.expressionProfileID = ExpressionProfileID(expressionProfileID)
                    }
                    if case .string(let expressionID)? = payload["expressionId"] {
                        existing.face.expressionID = expressionID
                    }
                    if case .string(let cue)? = payload["expressionCue"] {
                        existing.face.expressionCue = cue
                    }
                    if case .number(let intensity)? = payload["intensity"] {
                        existing.face.intensity = intensity
                    }
                }
                state.characters[id] = existing
            case .mouthState:
                let id = CharacterID(effect.target)
                var existing = state.characters[id] ?? CharacterGraphState(characterID: id)
                if case .object(let payload) = effect.proposedValue,
                   case .string(let mouthProfileID)? = payload["mouthProfileId"] {
                    existing.face.mouthProfileID = MouthProfileID(mouthProfileID)
                }
                if case .object(let payload) = effect.proposedValue,
                   case .string(let visemeToken)? = payload["viseme"] {
                    existing.face.visemeToken = visemeToken
                }
                if case .object(let payload) = effect.proposedValue,
                   case .string(let cue)? = payload["mouthCue"] {
                    existing.face.expressionCue = cue
                }
                state.characters[id] = existing
            case .dialogueState:
                continue
            }
        }
        state.review.lastPreview = preview
        state.review.pendingCommands = []
    }

    private func transform(from value: JSONValue?) -> Transform3D {
        guard case .object(let payload) = value,
              case .object(let translation)? = payload["translation"] else {
            return .init()
        }
        return Transform3D(
            translation: Vector3(
                x: translation["x"]?.numberValue ?? 0,
                y: translation["y"]?.numberValue ?? 0,
                z: translation["z"]?.numberValue ?? 0
            )
        )
    }
}

private extension JSONValue {
    var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }
}
