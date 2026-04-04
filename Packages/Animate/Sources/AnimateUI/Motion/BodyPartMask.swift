import Foundation

/// Bitmask selecting which body-part joints a motion track controls.
/// Each bit corresponds to a joint group; presets combine common sets.
@available(macOS 26.0, *)
struct BodyPartMask: OptionSet, Codable, Sendable, Hashable {
    let rawValue: UInt32

    // Individual joint groups
    static let head         = BodyPartMask(rawValue: 1 << 0)
    static let face         = BodyPartMask(rawValue: 1 << 1)
    static let mouth        = BodyPartMask(rawValue: 1 << 2)
    static let neck         = BodyPartMask(rawValue: 1 << 3)
    static let spine        = BodyPartMask(rawValue: 1 << 4)
    static let leftArm      = BodyPartMask(rawValue: 1 << 5)
    static let rightArm     = BodyPartMask(rawValue: 1 << 6)
    static let leftHand     = BodyPartMask(rawValue: 1 << 7)
    static let rightHand    = BodyPartMask(rawValue: 1 << 8)
    static let hips         = BodyPartMask(rawValue: 1 << 9)
    static let leftLeg      = BodyPartMask(rawValue: 1 << 10)
    static let rightLeg     = BodyPartMask(rawValue: 1 << 11)
    static let leftFoot     = BodyPartMask(rawValue: 1 << 12)
    static let rightFoot    = BodyPartMask(rawValue: 1 << 13)

    // Presets
    static let fullBody: BodyPartMask = [
        .head, .face, .mouth, .neck, .spine,
        .leftArm, .rightArm, .leftHand, .rightHand,
        .hips, .leftLeg, .rightLeg, .leftFoot, .rightFoot
    ]
    static let upperBody: BodyPartMask = [
        .head, .face, .mouth, .neck, .spine,
        .leftArm, .rightArm, .leftHand, .rightHand
    ]
    static let lowerBody: BodyPartMask = [
        .hips, .leftLeg, .rightLeg, .leftFoot, .rightFoot
    ]
    static let faceAndMouth: BodyPartMask = [.face, .mouth]
    static let arms: BodyPartMask = [.leftArm, .rightArm, .leftHand, .rightHand]
    static let everything = fullBody

    /// All defined individual mask bits, paired with display labels.
    static let allParts: [(mask: BodyPartMask, label: String)] = [
        (.head, "Head"), (.face, "Face"), (.mouth, "Mouth"), (.neck, "Neck"),
        (.spine, "Spine"), (.leftArm, "Left Arm"), (.rightArm, "Right Arm"),
        (.leftHand, "Left Hand"), (.rightHand, "Right Hand"), (.hips, "Hips"),
        (.leftLeg, "Left Leg"), (.rightLeg, "Right Leg"),
        (.leftFoot, "Left Foot"), (.rightFoot, "Right Foot"),
    ]

    /// Named presets for the UI picker.
    static let presets: [(mask: BodyPartMask, label: String)] = [
        (.everything, "Everything"),
        (.fullBody, "Full Body"),
        (.upperBody, "Upper Body"),
        (.lowerBody, "Lower Body"),
        (.faceAndMouth, "Face & Mouth"),
        (.arms, "Arms"),
    ]

    /// Map a joint name string (from MotionClip joint keys) to its body-part bit.
    /// Returns nil for unknown joints (they pass through unmasked).
    static func partForJoint(_ jointName: String) -> BodyPartMask? {
        switch jointName {
        case "head", "Head":                    return .head
        case "jaw", "Jaw":                      return .mouth
        case "leftEye", "rightEye",
             "LeftEye", "RightEye":             return .face
        case "neck_01", "Neck":                 return .neck
        case "spine_01", "spine_02", "spine_03",
             "Spine", "Spine1", "Spine2":       return .spine
        case "leftShoulder", "leftUpperArm", "leftLowerArm",
             "LeftArm", "LeftForeArm",
             "LeftShoulder":                    return .leftArm
        case "rightShoulder", "rightUpperArm", "rightLowerArm",
             "RightArm", "RightForeArm",
             "RightShoulder":                   return .rightArm
        case "leftHand", "LeftHand",
             _ where jointName.hasPrefix("leftFinger"),
             _ where jointName.hasPrefix("LeftHand"):
                                                return .leftHand
        case "rightHand", "RightHand",
             _ where jointName.hasPrefix("rightFinger"),
             _ where jointName.hasPrefix("RightHand"):
                                                return .rightHand
        case "hips", "Hips":                    return .hips
        case "leftUpperLeg", "leftLowerLeg",
             "LeftUpLeg", "LeftLeg":            return .leftLeg
        case "rightUpperLeg", "rightLowerLeg",
             "RightUpLeg", "RightLeg":          return .rightLeg
        case "leftFoot", "leftToeBase",
             "LeftFoot", "LeftToeBase":         return .leftFoot
        case "rightFoot", "rightToeBase",
             "RightFoot", "RightToeBase":       return .rightFoot
        default:                                return nil
        }
    }
}
