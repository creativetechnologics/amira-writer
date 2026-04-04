import Foundation
import simd

/// Exports a MotionClip to BVH (Biovision Hierarchy) format.
@available(macOS 26.0, *)
struct BVHExporter: Sendable {

    /// Standard BVH skeleton hierarchy.
    /// Each entry: (joint name, parent index (-1 for root), offset x/y/z)
    static let hierarchy: [(name: String, parentIndex: Int, offset: SIMD3<Float>)] = [
        ("Pelvis",     -1, SIMD3<Float>(0, 0, 0)),
        ("Spine1",      0, SIMD3<Float>(0, 0.1, 0)),
        ("Spine2",      1, SIMD3<Float>(0, 0.1, 0)),
        ("Spine3",      2, SIMD3<Float>(0, 0.1, 0)),
        ("Neck",        3, SIMD3<Float>(0, 0.08, 0)),
        ("Head",        4, SIMD3<Float>(0, 0.08, 0)),
        ("L_Collar",    3, SIMD3<Float>(0.02, 0.06, 0)),
        ("L_Shoulder",  6, SIMD3<Float>(0.12, 0, 0)),
        ("L_Elbow",     7, SIMD3<Float>(0.25, 0, 0)),
        ("L_Wrist",     8, SIMD3<Float>(0.22, 0, 0)),
        ("R_Collar",    3, SIMD3<Float>(-0.02, 0.06, 0)),
        ("R_Shoulder", 10, SIMD3<Float>(-0.12, 0, 0)),
        ("R_Elbow",    11, SIMD3<Float>(-0.25, 0, 0)),
        ("R_Wrist",    12, SIMD3<Float>(-0.22, 0, 0)),
        ("L_Hip",       0, SIMD3<Float>(0.1, 0, 0)),
        ("L_Knee",     14, SIMD3<Float>(0, -0.4, 0)),
        ("L_Ankle",    15, SIMD3<Float>(0, -0.4, 0)),
        ("L_Foot",     16, SIMD3<Float>(0, -0.04, 0.08)),
        ("R_Hip",       0, SIMD3<Float>(-0.1, 0, 0)),
        ("R_Knee",     18, SIMD3<Float>(0, -0.4, 0)),
        ("R_Ankle",    19, SIMD3<Float>(0, -0.4, 0)),
        ("R_Foot",     20, SIMD3<Float>(0, -0.04, 0.08)),
    ]

    /// Convert a quaternion (stored as SIMD4<Float>: x=ix, y=iy, z=iz, w=r) to ZXY Euler angles in degrees.
    static func quaternionToEulerDegrees(_ v: SIMD4<Float>) -> SIMD3<Float> {
        let q = simd_quatf(ix: v.x, iy: v.y, iz: v.z, r: v.w)
        let m = simd_float3x3(q)
        // ZXY decomposition
        let x = asin(max(-1, min(1, m[2][1])))
        let y: Float
        let z: Float
        if abs(m[2][1]) < 0.9999 {
            y = atan2(-m[2][0], m[2][2])
            z = atan2(-m[0][1], m[1][1])
        } else {
            y = atan2(m[0][2], m[0][0])
            z = 0
        }
        let toDeg: Float = 180.0 / .pi
        return SIMD3<Float>(x * toDeg, y * toDeg, z * toDeg)
    }

    /// Export a MotionClip to BVH string.
    static func export(_ clip: MotionClip) -> String {
        var lines: [String] = []

        // --- HIERARCHY section ---
        lines.append("HIERARCHY")
        var indentStack: [Int] = []

        func indent() -> String { String(repeating: "\t", count: indentStack.count) }

        for (i, joint) in hierarchy.enumerated() {
            // Close braces for nodes that are no longer ancestors
            while let parentIdx = indentStack.last, parentIdx != joint.parentIndex {
                indentStack.removeLast()
                lines.append("\(indent())}")
            }

            let prefix = indent()
            if joint.parentIndex == -1 {
                lines.append("\(prefix)ROOT \(joint.name)")
            } else {
                lines.append("\(prefix)JOINT \(joint.name)")
            }
            lines.append("\(prefix){")
            indentStack.append(i)

            let off = joint.offset
            lines.append("\(prefix)\tOFFSET \(String(format: "%.4f %.4f %.4f", off.x, off.y, off.z))")

            if joint.parentIndex == -1 {
                lines.append("\(prefix)\tCHANNELS 6 Xposition Yposition Zposition Zrotation Xrotation Yrotation")
            } else {
                lines.append("\(prefix)\tCHANNELS 3 Zrotation Xrotation Yrotation")
            }

            // Check if this joint has children in hierarchy
            let hasChildren = hierarchy.dropFirst(i + 1).contains { $0.parentIndex == i }
            if !hasChildren {
                lines.append("\(prefix)\tEnd Site")
                lines.append("\(prefix)\t{")
                lines.append("\(prefix)\t\tOFFSET 0.0000 0.0200 0.0000")
                lines.append("\(prefix)\t}")
            }
        }

        // Close remaining braces
        while !indentStack.isEmpty {
            indentStack.removeLast()
            lines.append("\(indent())}")
        }

        // --- MOTION section ---
        let frameCount = clip.frameCount
        let frameTime = clip.fps > 0 ? 1.0 / Double(clip.fps) : 1.0 / 30.0
        let identity = SIMD4<Float>(0, 0, 0, 1)

        lines.append("MOTION")
        lines.append("Frames: \(frameCount)")
        lines.append("Frame Time: \(String(format: "%.6f", frameTime))")

        for frameIdx in 0..<frameCount {
            var values: [String] = []

            for (i, joint) in hierarchy.enumerated() {
                let quatVec = clip.jointRotations[joint.name]?[frameIdx] ?? identity
                let euler = quaternionToEulerDegrees(quatVec)

                if i == 0 {
                    // Root: position + rotation
                    let pos = clip.rootPositions.count > frameIdx
                        ? clip.rootPositions[frameIdx]
                        : SIMD3<Float>.zero
                    values.append(String(format: "%.4f", pos.x))
                    values.append(String(format: "%.4f", pos.y))
                    values.append(String(format: "%.4f", pos.z))
                }

                // ZXY order
                values.append(String(format: "%.4f", euler.z))
                values.append(String(format: "%.4f", euler.x))
                values.append(String(format: "%.4f", euler.y))
            }

            lines.append(values.joined(separator: " "))
        }

        return lines.joined(separator: "\n")
    }

    /// Export and write to a file URL.
    static func exportToFile(_ clip: MotionClip, url: URL) throws {
        let bvhString = export(clip)
        try bvhString.write(to: url, atomically: true, encoding: .utf8)
    }
}
