import Foundation

@available(macOS 26.0, *)
struct ShotPrevis3DState: Codable, Sendable, Equatable, Hashable {
    var keyframes: [PrevisKeyframe] = [
        PrevisKeyframe(label: "beginning", position: [2, 1.6, 3], lookAt: [0, 1.2, 0], fov: 50),
        PrevisKeyframe(label: "middle", position: [2, 1.6, 3], lookAt: [0, 1.2, 0], fov: 50),
        PrevisKeyframe(label: "end", position: [2, 1.6, 3], lookAt: [0, 1.2, 0], fov: 50)
    ]
    var characterPoses: [String: CharacterPose3D] = [:]
    var objectTransforms: [UUID: ObjectTransform3D] = [:]
    var environmentConfig: PrevisEnvironmentConfig = PrevisEnvironmentConfig()
    var lightingPreset: String = "golden-hour"
}

@available(macOS 26.0, *)
struct PrevisKeyframe: Codable, Sendable, Equatable, Hashable {
    var label: String
    var position: [Double]
    var lookAt: [Double]
    var fov: Double
}

@available(macOS 26.0, *)
struct CharacterPose3D: Codable, Sendable, Equatable, Hashable {
    var characterSlug: String
    var costumeName: String
    var position: [Double]
    var rotation: [Double]
    var scale: Double
    var boneRotations: [String: [Double]]?
}

@available(macOS 26.0, *)
struct ObjectTransform3D: Codable, Sendable, Equatable, Hashable {
    var objectID: UUID
    var position: [Double]
    var rotation: [Double]
    var scale: Double
}

@available(macOS 26.0, *)
struct PrevisEnvironmentConfig: Codable, Sendable, Equatable, Hashable {
    var placeID: String? = nil
    var groundType: String = "grid"
    var backdropColor: String = "#1a1f27"
}
