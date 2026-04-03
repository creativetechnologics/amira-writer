import Foundation

public struct PlanCompiler: Sendable {
    public init() {}

    public func preview(
        plan: ScenePlan,
        currentState: EngineRuntimeState = .init(),
        registries: RegistryBundle = .empty
    ) -> ApplyPreview {
        var warnings: [ValidationMessage] = []
        var effects: [ApplyEffect] = []

        for command in plan.commands {
            warnings.append(contentsOf: validate(command: command, registries: registries))
            effects.append(
                ApplyEffect(
                    id: command.id,
                    scope: scope(for: command.family),
                    target: command.target,
                    changeKind: changeKind(for: command.action),
                    currentValue: currentValue(for: command, in: currentState),
                    proposedValue: .object(command.parameters),
                    detail: buildDetail(for: command)
                )
            )
        }

        return ApplyPreview(
            sceneID: plan.sceneID,
            warnings: warnings,
            effects: effects
        )
    }

    private func validate(command: SceneCommand, registries: RegistryBundle) -> [ValidationMessage] {
        switch command.family {
        case .world:
            if !registries.containsWorld(WorldID(command.target)), registries.worldCatalog != nil {
                return [.init(severity: .warning, commandID: command.id, detail: "Unknown world ID: \(command.target)")]
            }
        case .asset:
            if !registries.containsAsset(AssetID(command.target)), registries.assetRegistry != nil {
                return [.init(severity: .warning, commandID: command.id, detail: "Unknown asset ID: \(command.target)")]
            }
        case .character, .face, .expression, .mouth:
            if !registries.containsCharacter(CharacterID(command.target)), registries.characterRegistry != nil {
                return [.init(severity: .warning, commandID: command.id, detail: "Unknown character ID: \(command.target)")]
            }
            if let faceRigID = stringParameter("faceRigId", in: command.parameters),
               registries.faceRigCatalog != nil,
               !registries.containsFaceRig(FaceRigID(faceRigID)) {
                return [.init(severity: .warning, commandID: command.id, detail: "Unknown face rig ID: \(faceRigID)")]
            }
            if let expressionProfileID = stringParameter("expressionProfileId", in: command.parameters),
               registries.expressionProfileCatalog != nil,
               !registries.containsExpressionProfile(ExpressionProfileID(expressionProfileID)) {
                return [.init(severity: .warning, commandID: command.id, detail: "Unknown expression profile ID: \(expressionProfileID)")]
            }
            if let mouthProfileID = stringParameter("mouthProfileId", in: command.parameters),
               registries.mouthProfileCatalog != nil,
               !registries.containsMouthProfile(MouthProfileID(mouthProfileID)) {
                return [.init(severity: .warning, commandID: command.id, detail: "Unknown mouth profile ID: \(mouthProfileID)")]
            }
        default:
            break
        }
        return []
    }

    private func scope(for family: SceneCommandFamily) -> ApplyEffectScope {
        switch family {
        case .world:
            return .worldState
        case .asset:
            return .assetPlacement
        case .camera:
            return .cameraState
        case .character:
            return .characterState
        case .face:
            return .faceState
        case .expression:
            return .expressionState
        case .mouth:
            return .mouthState
        case .style:
            return .styleState
        case .light:
            return .lightRig
        case .atmosphere:
            return .atmosphereState
        case .dialogue:
            return .dialogueState
        }
    }

    private func changeKind(for action: String) -> ChangeKind {
        switch action.lowercased() {
        case "activate":
            return .activate
        case "deactivate":
            return .deactivate
        case "remove", "clear":
            return .remove
        case "create", "place", "spawn":
            return .create
        default:
            return .update
        }
    }

    private func currentValue(for command: SceneCommand, in state: EngineRuntimeState) -> JSONValue? {
        switch command.family {
        case .world:
            return state.world.activeWorldID.map { .string($0.rawValue) }
        case .camera:
            return state.camera.activePresetID.map { .string($0.rawValue) }
        case .style:
            return state.style.activeStyleProfileID.map { .string($0.rawValue) }
        case .light:
            return state.style.activeLightRigID.map { .string($0.rawValue) }
        case .atmosphere:
            return state.style.activeAtmospherePresetID.map { .string($0.rawValue) }
        case .asset:
            if let transform = state.world.assetPlacements[AssetID(command.target)] {
                return .object([
                    "translation": .object([
                        "x": .number(transform.translation.x),
                        "y": .number(transform.translation.y),
                        "z": .number(transform.translation.z)
                    ])
                ])
            }
            return nil
        case .character, .face, .expression, .mouth, .dialogue:
            guard let faceState = state.characters[CharacterID(command.target)]?.face else {
                return nil
            }
            return faceJSON(for: faceState)
        }
    }

    private func buildDetail(for command: SceneCommand) -> String {
        var detail = "\(command.family.rawValue.capitalized) \(command.action) on \(command.target)"
        if let shotID = command.timing?.shotID?.rawValue {
            detail += " in shot \(shotID)"
        }
        if let notes = command.notes, !notes.isEmpty {
            detail += " — \(notes)"
        }
        return detail
    }

    private func stringParameter(_ key: String, in parameters: [String: JSONValue]) -> String? {
        guard case .string(let value)? = parameters[key] else { return nil }
        return value
    }

    private func faceJSON(for faceState: FaceGraphState) -> JSONValue {
        var payload: [String: JSONValue] = [
            "faceRigId": faceState.faceRigID.map { .string($0.rawValue) } ?? .null,
            "expressionProfileId": faceState.expressionProfileID.map { .string($0.rawValue) } ?? .null,
            "expressionId": faceState.expressionID.map { .string($0) } ?? .null,
            "expressionCue": faceState.expressionCue.map { .string($0) } ?? .null,
            "mouthProfileId": faceState.mouthProfileID.map { .string($0.rawValue) } ?? .null,
            "viseme": faceState.visemeToken.map { .string($0) } ?? .null,
            "blinkState": faceState.blinkState.map { .string($0) } ?? .null,
            "intensity": .number(faceState.intensity)
        ]
        if let gazeTarget = faceState.gazeTarget {
            payload["gazeTarget"] = .object([
                "x": .number(gazeTarget.x),
                "y": .number(gazeTarget.y),
                "z": .number(gazeTarget.z)
            ])
        } else {
            payload["gazeTarget"] = .null
        }
        return .object(payload)
    }
}
