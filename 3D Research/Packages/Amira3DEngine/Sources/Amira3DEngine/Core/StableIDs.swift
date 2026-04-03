import Foundation

public protocol StableStringID: Hashable, Codable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    var rawValue: String { get }
    init(_ rawValue: String)
}

extension StableStringID {
    public init(stringLiteral value: String) {
        self.init(value)
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SceneID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct ShotID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct WorldID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct AssetID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct CharacterID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct CameraPresetID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct StyleProfileID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct MotionID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct LightRigID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct AtmospherePresetID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct MouthProfileID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct ExpressionProfileID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct FaceRigID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

public struct SkeletonProfileID: StableStringID {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}
