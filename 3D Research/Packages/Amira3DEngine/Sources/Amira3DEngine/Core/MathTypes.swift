import Foundation

public struct Vector3: Hashable, Codable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
}

public struct Transform3D: Hashable, Codable, Sendable {
    public var translation: Vector3
    public var rotationEulerDegrees: Vector3
    public var scale: Vector3

    public init(
        translation: Vector3 = .init(),
        rotationEulerDegrees: Vector3 = .init(),
        scale: Vector3 = .init(x: 1, y: 1, z: 1)
    ) {
        self.translation = translation
        self.rotationEulerDegrees = rotationEulerDegrees
        self.scale = scale
    }
}
