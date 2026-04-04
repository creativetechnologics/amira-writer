import AVFoundation
import SwiftUI

@available(macOS 26.0, *)
struct CameraPreviewRepresentable: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.session = session
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.session !== session {
            nsView.session = session
        }
    }
}

@available(macOS 26.0, *)
final class CameraPreviewNSView: NSView {
    var session: AVCaptureSession? {
        didSet {
            guard let session else {
                previewLayer?.session = nil
                return
            }
            if previewLayer == nil {
                let layer = AVCaptureVideoPreviewLayer()
                layer.videoGravity = .resizeAspectFill
                self.wantsLayer = true
                self.layer = CALayer()
                self.layer?.addSublayer(layer)
                previewLayer = layer
            }
            previewLayer?.session = session
        }
    }

    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}

@available(macOS 26.0, *)
struct SkeletonOverlayView: View {
    let poseFrame: UnifiedPoseFrame?
    let viewSize: CGSize

    var body: some View {
        Canvas { context, size in
            guard let joints = poseFrame?.bodyJoints else { return }
            let confidences = poseFrame?.bodyConfidences ?? [:]

            for (startJoint, endJoint) in SkeletonTopology.bodyBones {
                guard let startPos = joints[startJoint],
                      let endPos = joints[endJoint] else { continue }

                let startPoint = projectToScreen(startPos, in: size)
                let endPoint = projectToScreen(endPos, in: size)

                let startConf = confidences[startJoint] ?? 0
                let endConf = confidences[endJoint] ?? 0
                let avgConf = (startConf + endConf) / 2.0

                var path = Path()
                path.move(to: startPoint)
                path.addLine(to: endPoint)

                context.stroke(
                    path,
                    with: .color(boneColor(confidence: avgConf)),
                    lineWidth: 3
                )
            }

            for (jointName, position) in joints {
                let point = projectToScreen(position, in: size)
                let confidence = confidences[jointName] ?? 0
                let radius: CGFloat = jointName == .head ? 8 : 5

                let rect = CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )

                context.fill(
                    Path(ellipseIn: rect),
                    with: .color(jointColor(confidence: confidence))
                )
            }
        }
    }

    private func projectToScreen(_ position: SIMD3<Float>, in size: CGSize) -> CGPoint {
        let scale = min(size.width, size.height) * 0.4
        let centerX = size.width / 2.0
        let centerY = size.height / 2.0

        let x = centerX - CGFloat(position.x) * scale
        let y = centerY - CGFloat(position.y) * scale

        return CGPoint(x: x, y: y)
    }

    private func boneColor(confidence: Float) -> Color {
        if confidence > 0.5 {
            return Color.green.opacity(Double(confidence))
        } else if confidence > 0.1 {
            return Color.yellow.opacity(0.7)
        } else {
            return Color.red.opacity(0.4)
        }
    }

    private func jointColor(confidence: Float) -> Color {
        if confidence > 0.5 {
            return Color.white
        } else if confidence > 0.1 {
            return Color.yellow
        } else {
            return Color.red.opacity(0.6)
        }
    }
}

@available(macOS 26.0, *)
struct CapturePreviewView: View {
    let captureSession: AVCaptureSession?
    let poseFrame: UnifiedPoseFrame?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let session = captureSession {
                    CameraPreviewRepresentable(session: session)
                } else {
                    Rectangle()
                        .fill(Color.black)
                    Text("No camera feed")
                        .foregroundStyle(.secondary)
                }

                SkeletonOverlayView(
                    poseFrame: poseFrame,
                    viewSize: geo.size
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}