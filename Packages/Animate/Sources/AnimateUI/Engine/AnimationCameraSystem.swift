import Foundation
import SceneKit
import simd

// MARK: - Animation Camera

/// Physical film camera model with focal length, sensor geometry, and depth of field.
/// Optical calculations use real-world formulae (Super 35mm sensor).
@available(macOS 26.0, *)
struct AnimationCamera: Sendable {

    /// Focal length in millimetres (24 wide … 135 telephoto).
    var focalLength: Double = 50.0

    /// Super 35mm sensor dimensions for FOV derivation.
    static let sensorWidth: Double  = 24.89  // mm
    static let sensorHeight: Double = 18.66  // mm  (2.39:1 anamorphic crop)

    /// Camera position in world space (metres).
    var position: SIMD3<Double> = .zero
    /// Look-at target in world space.
    var lookAt: SIMD3<Double> = SIMD3<Double>(0, 1, 0)
    /// Roll (Dutch angle) in radians.
    var roll: Double = 0

    /// Aperture f-stop (lower = shallower DOF).
    var aperture: Double = 2.8
    /// Distance to the focal plane in metres.
    var focusDistance: Double = 5.0
    /// Whether the renderer should apply depth-of-field blur.
    var dofEnabled: Bool = true

    /// Horizontal field of view in degrees.
    var horizontalFOV: Double {
        2.0 * atan(Self.sensorWidth / (2.0 * focalLength)) * (180.0 / .pi)
    }
    /// Vertical field of view in degrees.
    var verticalFOV: Double {
        2.0 * atan(Self.sensorHeight / (2.0 * focalLength)) * (180.0 / .pi)
    }
}

// MARK: - Focal Length / Shot Type Mapping

@available(macOS 26.0, *)
extension AnimationCamera {

    /// Focal-length range in mm for a cinematic shot type.
    struct FocalRange: Sendable {
        let min: Double, max: Double
        var mid: Double { (min + max) / 2.0 }
    }

    /// Maps a `CameraShot` to a physically motivated focal-length range.
    static func focalRange(for shot: CameraShot) -> FocalRange {
        switch shot {
        case .extremeWide:  FocalRange(min: 18, max: 24)
        case .wide:         FocalRange(min: 28, max: 35)
        case .medium:       FocalRange(min: 40, max: 50)
        case .mediumClose:  FocalRange(min: 50, max: 70)
        case .close:        FocalRange(min: 85, max: 100)
        case .extremeClose: FocalRange(min: 100, max: 135)
        }
    }

    /// Camera preset for the given shot type using its midpoint focal length.
    static func preset(for shot: CameraShot) -> AnimationCamera {
        var cam = AnimationCamera()
        cam.focalLength = focalRange(for: shot).mid
        return cam
    }
}

// MARK: - Depth of Field

@available(macOS 26.0, *)
extension AnimationCamera {

    /// Circle of confusion for Super 35mm (industry standard).
    private static let circleOfConfusion: Double = 0.019  // mm

    /// Hyperfocal distance in metres.
    var hyperfocalDistance: Double {
        (focalLength * focalLength) / (aperture * Self.circleOfConfusion * 1000.0)
            + focalLength / 1000.0
    }

    /// Near limit of acceptable sharpness in metres.
    var nearFocusLimit: Double {
        let h = hyperfocalDistance
        return (h * focusDistance) / (h + (focusDistance - focalLength / 1000.0))
    }

    /// Far limit of acceptable sharpness (infinity when beyond hyperfocal).
    var farFocusLimit: Double {
        let h = hyperfocalDistance
        let denom = h - (focusDistance - focalLength / 1000.0)
        guard denom > 0 else { return .infinity }
        return (h * focusDistance) / denom
    }

    /// Total depth of field span in metres.
    var depthOfField: Double { farFocusLimit - nearFocusLimit }

    /// Normalised blur radius (0 = sharp, 1 = max blur) for an object at the given distance.
    /// Uses thin-lens CoC model: CoC = |f^2 (S1-S2)| / (N S1 S2).
    /// Normalised against 0.5 mm max CoC.
    func blurRadius(atDistance objectDistance: Double) -> Double {
        guard dofEnabled, objectDistance > 0, focusDistance > 0 else { return 0 }
        let fM = focalLength / 1000.0
        let cocMM = abs(fM * fM * (focusDistance - objectDistance))
            / (aperture * focusDistance * objectDistance) * 1000.0
        return min(cocMM / 0.5, 1.0)
    }
}

// MARK: - Camera Rig

/// Wraps an `AnimationCamera` with dolly track, crane arm, and deterministic handheld shake.
@available(macOS 26.0, *)
struct CameraRig: Sendable {
    var camera: AnimationCamera
    /// Normalised dolly position along `dollyPath` (0…1).
    var dollyPosition: Double = 0
    /// World-space waypoints defining the dolly rail.
    var dollyPath: [SIMD3<Double>] = []
    /// Vertical offset from the dolly point (crane / jib arm).
    var craneHeight: Double = 0
    /// Handheld shake intensity: 0 = tripod-locked, 1 = full handheld.
    var handheldIntensity: Double = 0
    /// Seed for deterministic handheld noise (reproducible shake).
    var handheldSeed: UInt64 = 0

    /// Evaluates the dolly path via Catmull-Rom interpolation.
    var dollyWorldPosition: SIMD3<Double> {
        guard dollyPath.count >= 2 else { return dollyPath.first ?? camera.position }
        let t = max(0, min(1, dollyPosition))
        let raw = t * Double(dollyPath.count - 1)
        let idx = Int(raw), frac = raw - Double(idx)
        let i0 = max(idx - 1, 0), i1 = idx
        let i2 = min(idx + 1, dollyPath.count - 1)
        let i3 = min(idx + 2, dollyPath.count - 1)
        return catmullRom(p0: dollyPath[i0], p1: dollyPath[i1],
                          p2: dollyPath[i2], p3: dollyPath[i3], t: frac)
    }

    /// Final world-space camera position with crane and handheld shake applied.
    func evaluatedPosition(time: Double) -> SIMD3<Double> {
        var pos = dollyPath.isEmpty ? camera.position : dollyWorldPosition
        pos.y += craneHeight
        if handheldIntensity > 0 {
            pos += handheldOffset(time: time) * handheldIntensity
        }
        return pos
    }

    /// Deterministic handheld offset using layered sine waves (centimetre-scale).
    private func handheldOffset(time: Double) -> SIMD3<Double> {
        let s = Double(handheldSeed &+ 1)
        return SIMD3<Double>(
            0.012 * sin(2.7 * time + s * 1.1) + 0.006 * sin(7.3 * time + s * 0.7),
            0.015 * sin(3.1 * time + s * 2.3) + 0.008 * sin(5.9 * time + s * 1.4),
            0.008 * sin(1.9 * time + s * 3.7) + 0.004 * sin(9.1 * time + s * 0.3)
        )
    }
}

// MARK: - Camera Movement Application

@available(macOS 26.0, *)
extension CameraRig {

    /// Returns a new rig with the given `CameraMovement` applied at normalised time `t` (0…1).
    func applying(_ movement: CameraMovement, t: Double,
                  magnitude: Double = 1.0, time: Double = 0) -> CameraRig {
        var rig = self
        switch movement {
        case .zoomIn:
            let target = camera.focalLength + magnitude * 30.0
            rig.camera.focalLength = lerp(camera.focalLength, target, t: t)
        case .zoomOut:
            let target = max(12, camera.focalLength - magnitude * 30.0)
            rig.camera.focalLength = lerp(camera.focalLength, target, t: t)
        case .panLeft:
            let rad = magnitude * 15.0 * (.pi / 180.0)
            rig.camera.lookAt = rotateAroundUp(point: camera.lookAt,
                                                pivot: camera.position, angle: rad * t)
        case .panRight:
            let rad = magnitude * 15.0 * (.pi / 180.0)
            rig.camera.lookAt = rotateAroundUp(point: camera.lookAt,
                                                pivot: camera.position, angle: -rad * t)
        case .panUp:
            rig.camera.lookAt.y += magnitude * 0.5 * t
        case .panDown:
            rig.camera.lookAt.y -= magnitude * 0.5 * t
        case .track:
            rig.dollyPosition = min(1.0, dollyPosition + t)
        case .shake:
            rig.handheldIntensity = magnitude
        case .hold:
            break
        }
        return rig
    }
}

// MARK: - Camera Interpolation

@available(macOS 26.0, *)
extension AnimationCamera {

    /// Smoothly interpolates every camera parameter between two states.
    static func interpolate(from: AnimationCamera, to: AnimationCamera,
                            t: Double, easing: EasingCurve) -> AnimationCamera {
        let et = applyEasing(t, curve: easing)
        var r = AnimationCamera()
        r.focalLength  = lerp(from.focalLength, to.focalLength, t: et)
        r.position     = simd_mix(from.position, to.position, SIMD3(repeating: et))
        r.lookAt       = simd_mix(from.lookAt, to.lookAt, SIMD3(repeating: et))
        r.roll         = lerp(from.roll, to.roll, t: et)
        r.aperture     = lerp(from.aperture, to.aperture, t: et)
        r.focusDistance = lerp(from.focusDistance, to.focusDistance, t: et)
        r.dofEnabled   = et < 0.5 ? from.dofEnabled : to.dofEnabled
        return r
    }

    /// Evaluate an `EasingCurve` at linear parameter `t`.
    private static func applyEasing(_ t: Double, curve: EasingCurve) -> Double {
        let t = max(0, min(1, t))
        switch curve {
        case .linear:  return t
        case .stepped: return t < 1.0 ? 0.0 : 1.0
        case .easeIn:  return t * t
        case .easeOut: return 1.0 - (1.0 - t) * (1.0 - t)
        case .easeInOut:
            return t < 0.5 ? 2.0 * t * t : 1.0 - pow(-2.0 * t + 2.0, 2) / 2.0
        case .custom(let cx1, let cy1, let cx2, let cy2):
            return cubicBezierSolve(t, cx1: Double(cx1), cy1: Double(cy1),
                                       cx2: Double(cx2), cy2: Double(cy2))
        }
    }

    /// Newton-Raphson solver for a cubic Bezier easing curve.
    private static func cubicBezierSolve(_ x: Double, cx1: Double, cy1: Double,
                                          cx2: Double, cy2: Double) -> Double {
        var u = x
        for _ in 0..<8 {
            let bx = 3 * (1 - u) * (1 - u) * u * cx1
                   + 3 * (1 - u) * u * u * cx2 + u * u * u
            let dbx = 3 * (1 - u) * (1 - u) * cx1
                    + 6 * (1 - u) * u * (cx2 - cx1) + 3 * u * u * (1 - cx2)
            guard abs(dbx) > 1e-12 else { break }
            u = max(0, min(1, u - (bx - x) / dbx))
        }
        return 3 * (1 - u) * (1 - u) * u * cy1
             + 3 * (1 - u) * u * u * cy2 + u * u * u
    }
}

// MARK: - SceneKit Integration

@available(macOS 26.0, *)
extension AnimationCamera {

    /// Applies this camera state to a SceneKit camera node, setting FOV, DOF, position,
    /// and orientation (including Dutch angle).
    func apply(to cameraNode: SCNNode) {
        let scnCamera = cameraNode.camera ?? SCNCamera()
        cameraNode.camera = scnCamera

        scnCamera.fieldOfView = CGFloat(horizontalFOV)
        scnCamera.projectionDirection = .horizontal

        scnCamera.wantsDepthOfField = dofEnabled
        if dofEnabled {
            scnCamera.focusDistance = CGFloat(focusDistance)
            scnCamera.fStop = CGFloat(aperture)
            scnCamera.focalLength = CGFloat(focalLength)
            scnCamera.sensorHeight = CGFloat(Self.sensorHeight)
        }

        scnCamera.zNear = 0.1
        scnCamera.zFar = 500.0

        cameraNode.position = SCNVector3(Float(position.x), Float(position.y), Float(position.z))
        cameraNode.look(at: SCNVector3(Float(lookAt.x), Float(lookAt.y), Float(lookAt.z)))

        // Dutch angle (roll around local Z)
        if abs(roll) > 1e-6 {
            let cur = cameraNode.transform
            let r = SCNMatrix4MakeRotation(CGFloat(roll), 0, 0, 1)
            cameraNode.transform = SCNMatrix4Mult(r, cur)
        }
    }
}

// MARK: - Utility Functions

@inline(__always)
private func lerp(_ a: Double, _ b: Double, t: Double) -> Double { a + (b - a) * t }

/// Catmull-Rom spline interpolation between four control points.
private func catmullRom(p0: SIMD3<Double>, p1: SIMD3<Double>,
                        p2: SIMD3<Double>, p3: SIMD3<Double>, t: Double) -> SIMD3<Double> {
    let t2: Double = t * t
    let t3: Double = t2 * t
    let a: SIMD3<Double> = 2.0 * p1
    let diff1: SIMD3<Double> = p2 - p0
    let b: SIMD3<Double> = diff1 * t
    let c0: SIMD3<Double> = 2.0 * p0 - 5.0 * p1
    let c1: SIMD3<Double> = c0 + 4.0 * p2 - p3
    let c: SIMD3<Double> = c1 * t2
    let d0: SIMD3<Double> = 3.0 * p1 - p0
    let d1: SIMD3<Double> = d0 - 3.0 * p2 + p3
    let d: SIMD3<Double> = d1 * t3
    let sum: SIMD3<Double> = a + b + c + d
    return 0.5 * sum
}

/// Rotate `point` around world-up (Y) axis centred at `pivot`.
private func rotateAroundUp(point: SIMD3<Double>, pivot: SIMD3<Double>,
                            angle: Double) -> SIMD3<Double> {
    let l = point - pivot
    let c = cos(angle), s = sin(angle)
    return SIMD3<Double>(l.x * c - l.z * s, l.y, l.x * s + l.z * c) + pivot
}
