import Foundation

public enum ApplyEffectScope: String, Codable, Hashable, Sendable {
    case worldState
    case assetPlacement
    case cameraState
    case characterState
    case faceState
    case expressionState
    case mouthState
    case styleState
    case lightRig
    case atmosphereState
    case dialogueState
}

public enum ChangeKind: String, Codable, Hashable, Sendable {
    case create
    case update
    case activate
    case deactivate
    case remove
}

public enum ValidationSeverity: String, Codable, Hashable, Sendable {
    case info
    case warning
    case error
}

public struct ValidationMessage: Hashable, Codable, Sendable {
    public var severity: ValidationSeverity
    public var commandID: String?
    public var detail: String

    public init(severity: ValidationSeverity, commandID: String? = nil, detail: String) {
        self.severity = severity
        self.commandID = commandID
        self.detail = detail
    }
}

public struct ApplyEffect: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var scope: ApplyEffectScope
    public var target: String
    public var changeKind: ChangeKind
    public var currentValue: JSONValue?
    public var proposedValue: JSONValue?
    public var detail: String

    public init(
        id: String,
        scope: ApplyEffectScope,
        target: String,
        changeKind: ChangeKind,
        currentValue: JSONValue?,
        proposedValue: JSONValue?,
        detail: String
    ) {
        self.id = id
        self.scope = scope
        self.target = target
        self.changeKind = changeKind
        self.currentValue = currentValue
        self.proposedValue = proposedValue
        self.detail = detail
    }
}

public struct ApplyPreview: Hashable, Codable, Sendable {
    public var schemaVersion: String
    public var project: String
    public var sceneID: SceneID
    public var effectCount: Int
    public var actionableEffectCount: Int
    public var warnings: [ValidationMessage]
    public var effects: [ApplyEffect]

    public init(
        schemaVersion: String = "0.1",
        project: String = "Amira",
        sceneID: SceneID,
        warnings: [ValidationMessage],
        effects: [ApplyEffect]
    ) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.sceneID = sceneID
        self.effectCount = effects.count
        self.actionableEffectCount = effects.count
        self.warnings = warnings
        self.effects = effects
    }
}
