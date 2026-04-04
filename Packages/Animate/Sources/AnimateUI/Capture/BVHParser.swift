import Foundation
import simd

/// Parses BVH (Biovision Hierarchy) motion capture files into MotionClip format.
///
/// BVH files contain two sections:
///   1. HIERARCHY — bone names, parent relationships, channel order, offsets
///   2. MOTION — frame count, frame time, then float data per frame
///
/// Euler angles from BVH channels are converted to quaternions for MotionClip storage.
@available(macOS 26.0, *)
struct BVHParser: Sendable {

    // MARK: - Skeleton Model

    struct BVHJoint: Sendable {
        let name: String
        let parentIndex: Int?          // nil for root
        let offset: SIMD3<Float>       // rest-pose offset from parent
        let channelCount: Int          // 3 or 6
        let channelOrder: [BVHChannel] // order of Euler channels
        let channelStartIndex: Int     // index into the per-frame float array
    }

    enum BVHChannel: String, Sendable {
        case xPosition = "Xposition"
        case yPosition = "Yposition"
        case zPosition = "Zposition"
        case xRotation = "Xrotation"
        case yRotation = "Yrotation"
        case zRotation = "Zrotation"
    }

    // MARK: - Parse Result

    struct BVHData: Sendable {
        let joints: [BVHJoint]
        let frameCount: Int
        let frameTime: Double
        let frames: [[Float]]  // [frameIndex][channelIndex]
    }

    // MARK: - Errors

    enum BVHError: Error, LocalizedError {
        case invalidFormat(String)
        case missingMotionSection
        case channelCountMismatch(expected: Int, got: Int)

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let msg): return "Invalid BVH format: \(msg)"
            case .missingMotionSection: return "BVH file has no MOTION section"
            case .channelCountMismatch(let expected, let got):
                return "Expected \(expected) channels per frame, got \(got)"
            }
        }
    }

    // MARK: - Public API

    /// Parse a BVH file and return a MotionClip.
    static func parse(url: URL) throws -> MotionClip {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let bvhData = try parseRaw(contents)
        return convertToMotionClip(bvhData: bvhData, sourceURL: url)
    }

    /// Parse a BVH string and return a MotionClip.
    static func parse(string: String, name: String = "BVH Import") throws -> MotionClip {
        let bvhData = try parseRaw(string)
        return convertToMotionClip(bvhData: bvhData, name: name)
    }

    // MARK: - Raw Parsing

    static func parseRaw(_ text: String) throws -> BVHData {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var lineIndex = 0
        var joints: [BVHJoint] = []
        var parentStack: [Int] = []  // stack of parent joint indices
        var totalChannels = 0

        // --- Parse HIERARCHY ---
        guard lineIndex < lines.count, lines[lineIndex] == "HIERARCHY" else {
            throw BVHError.invalidFormat("Expected HIERARCHY at start")
        }
        lineIndex += 1

        func parseJoint(isRoot: Bool) throws {
            guard lineIndex < lines.count else { return }
            let tokens = lines[lineIndex].split(separator: " ")
            guard tokens.count >= 2 else {
                throw BVHError.invalidFormat("Expected joint name at line \(lineIndex)")
            }

            let jointName = String(tokens[1])
            let parentIndex = parentStack.last
            lineIndex += 1

            // Expect opening brace
            guard lineIndex < lines.count, lines[lineIndex] == "{" else {
                throw BVHError.invalidFormat("Expected '{' after joint \(jointName)")
            }
            lineIndex += 1

            // Parse OFFSET
            guard lineIndex < lines.count else {
                throw BVHError.invalidFormat("Unexpected end in joint \(jointName)")
            }
            let offsetTokens = lines[lineIndex].split(separator: " ")
            guard offsetTokens.count >= 4,
                  offsetTokens[0].uppercased() == "OFFSET",
                  let ox = Float(offsetTokens[1]),
                  let oy = Float(offsetTokens[2]),
                  let oz = Float(offsetTokens[3]) else {
                throw BVHError.invalidFormat("Expected OFFSET in joint \(jointName)")
            }
            let offset = SIMD3<Float>(ox, oy, oz)
            lineIndex += 1

            // Parse CHANNELS (optional — End Site joints have none)
            var channelCount = 0
            var channels: [BVHChannel] = []

            if lineIndex < lines.count {
                let channelTokens = lines[lineIndex].split(separator: " ")
                if channelTokens.count >= 2 && channelTokens[0].uppercased() == "CHANNELS",
                   let count = Int(channelTokens[1]) {
                    channelCount = count
                    for i in 2..<min(2 + channelCount, channelTokens.count) {
                        if let ch = BVHChannel(rawValue: String(channelTokens[i])) {
                            channels.append(ch)
                        }
                    }
                    lineIndex += 1
                }
            }

            let jointIndex = joints.count
            joints.append(BVHJoint(
                name: jointName,
                parentIndex: parentIndex,
                offset: offset,
                channelCount: channelCount,
                channelOrder: channels,
                channelStartIndex: totalChannels
            ))
            totalChannels += channelCount

            // Push this joint as parent for children
            parentStack.append(jointIndex)

            // Parse children until closing brace
            while lineIndex < lines.count {
                let line = lines[lineIndex]
                if line == "}" {
                    lineIndex += 1
                    break
                } else if line.hasPrefix("JOINT") {
                    try parseJoint(isRoot: false)
                } else if line.hasPrefix("End Site") || line.hasPrefix("End") {
                    // Skip end site block
                    lineIndex += 1 // "End Site"
                    if lineIndex < lines.count, lines[lineIndex] == "{" {
                        lineIndex += 1 // "{"
                        while lineIndex < lines.count, lines[lineIndex] != "}" {
                            lineIndex += 1
                        }
                        if lineIndex < lines.count { lineIndex += 1 } // "}"
                    }
                } else {
                    lineIndex += 1
                }
            }

            parentStack.removeLast()
        }

        // Parse root
        guard lineIndex < lines.count,
              lines[lineIndex].uppercased().hasPrefix("ROOT") else {
            throw BVHError.invalidFormat("Expected ROOT joint")
        }
        try parseJoint(isRoot: true)

        // --- Parse MOTION ---
        guard lineIndex < lines.count, lines[lineIndex] == "MOTION" else {
            throw BVHError.missingMotionSection
        }
        lineIndex += 1

        // Frames: N
        guard lineIndex < lines.count else { throw BVHError.missingMotionSection }
        let framesTokens = lines[lineIndex].split(separator: " ")
        guard framesTokens.count >= 2,
              let frameCount = Int(framesTokens[1]) else {
            throw BVHError.invalidFormat("Expected 'Frames: N'")
        }
        lineIndex += 1

        // Frame Time: F
        guard lineIndex < lines.count else { throw BVHError.missingMotionSection }
        let ftTokens = lines[lineIndex].split(separator: " ")
        guard ftTokens.count >= 3,
              let frameTime = Double(ftTokens[2]) else {
            throw BVHError.invalidFormat("Expected 'Frame Time: F'")
        }
        lineIndex += 1

        // Parse frame data
        var frames: [[Float]] = []
        for _ in 0..<frameCount {
            guard lineIndex < lines.count else { break }
            let values = lines[lineIndex].split(separator: " ").compactMap { Float($0) }
            if values.count != totalChannels {
                throw BVHError.channelCountMismatch(expected: totalChannels, got: values.count)
            }
            frames.append(values)
            lineIndex += 1
        }

        return BVHData(
            joints: joints,
            frameCount: frameCount,
            frameTime: frameTime,
            frames: frames
        )
    }

    // MARK: - Conversion to MotionClip

    static func convertToMotionClip(
        bvhData: BVHData,
        sourceURL: URL? = nil,
        name: String? = nil
    ) -> MotionClip {
        let clipName = name ?? sourceURL?.deletingPathExtension().lastPathComponent ?? "BVH Import"
        let fps = Int(round(1.0 / max(bvhData.frameTime, 0.001)))

        var jointRotations: [String: [SIMD4<Float>]] = [:]
        var rootPositions: [SIMD3<Float>] = []

        // Initialize arrays
        for joint in bvhData.joints {
            if joint.channelCount > 0 {
                jointRotations[joint.name] = []
            }
        }

        for (frameIndex, frameValues) in bvhData.frames.enumerated() {
            for joint in bvhData.joints {
                guard joint.channelCount > 0 else { continue }
                let start = joint.channelStartIndex
                var position: SIMD3<Float>?
                var eulerX: Float = 0
                var eulerY: Float = 0
                var eulerZ: Float = 0

                for (i, channel) in joint.channelOrder.enumerated() {
                    guard start + i < frameValues.count else { break }
                    let value = frameValues[start + i]
                    switch channel {
                    case .xPosition:
                        if position == nil { position = .zero }
                        position!.x = value
                    case .yPosition:
                        if position == nil { position = .zero }
                        position!.y = value
                    case .zPosition:
                        if position == nil { position = .zero }
                        position!.z = value
                    case .xRotation: eulerX = value
                    case .yRotation: eulerY = value
                    case .zRotation: eulerZ = value
                    }
                }

                // Convert Euler (degrees) to quaternion
                let quat = eulerToQuaternion(
                    xDeg: eulerX, yDeg: eulerY, zDeg: eulerZ,
                    order: joint.channelOrder
                )
                let stored = SIMD4<Float>(quat.imag.x, quat.imag.y, quat.imag.z, quat.real)
                jointRotations[joint.name]?.append(stored)

                // Root position (only for the first joint with position channels)
                if joint.parentIndex == nil, let pos = position, rootPositions.count <= frameIndex {
                    rootPositions.append(pos)
                }
            }

            // If no root position was found for this frame, append zero
            if rootPositions.count <= frameIndex {
                rootPositions.append(.zero)
            }
        }

        // Ensure rootPositions matches frame count
        while rootPositions.count < bvhData.frameCount {
            rootPositions.append(rootPositions.last ?? .zero)
        }

        let duration = Double(bvhData.frameCount) * bvhData.frameTime

        return MotionClip(
            name: clipName,
            source: .importedBVH(filePath: sourceURL?.path ?? ""),
            fps: fps,
            frameCount: bvhData.frameCount,
            duration: duration,
            jointRotations: jointRotations,
            rootPositions: rootPositions,
            createdAt: Date()
        )
    }

    // MARK: - Euler to Quaternion

    /// Convert Euler angles (in degrees) to a quaternion, respecting channel order.
    /// BVH Euler angles are applied in the order they appear in the CHANNELS line.
    static func eulerToQuaternion(
        xDeg: Float, yDeg: Float, zDeg: Float,
        order: [BVHChannel]
    ) -> simd_quatf {
        let xRad = xDeg * .pi / 180
        let yRad = yDeg * .pi / 180
        let zRad = zDeg * .pi / 180

        let qx = simd_quatf(angle: xRad, axis: SIMD3<Float>(1, 0, 0))
        let qy = simd_quatf(angle: yRad, axis: SIMD3<Float>(0, 1, 0))
        let qz = simd_quatf(angle: zRad, axis: SIMD3<Float>(0, 0, 1))

        // Apply rotations in the order specified by channels (first channel = outermost)
        let rotationChannels = order.filter {
            $0 == .xRotation || $0 == .yRotation || $0 == .zRotation
        }

        var result = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        for channel in rotationChannels {
            switch channel {
            case .xRotation: result = result * qx
            case .yRotation: result = result * qy
            case .zRotation: result = result * qz
            default: break
            }
        }

        return result
    }
}
