import SwiftUI

@available(macOS 26.0, *)
struct MotionCaptureDeck: View {
    @Bindable var store: AnimateStore

    @State private var availableCameras: [(id: String, name: String)] = []
    @State private var selectedCameraID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Camera", selection: $selectedCameraID) {
                    Text("Default").tag(nil as String?)
                    ForEach(availableCameras, id: \.id) { camera in
                        Text(camera.name).tag(camera.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                Spacer()

                Toggle("Smooth", isOn: Binding(
                    get: { store.mocapFilterEnabled },
                    set: { store.mocapFilterEnabled = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Text("\(store.mocapFrameCount) frames")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    if store.mocapIsRunning {
                        store.stopMocap()
                    } else {
                        store.mocapCameraID = selectedCameraID
                        store.startMocap()
                    }
                } label: {
                    Label(
                        store.mocapIsRunning ? "Stop" : "Start Capture",
                        systemImage: store.mocapIsRunning ? "stop.circle.fill" : "camera.fill"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(store.mocapIsRunning ? .red : .accentColor)
                .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if store.mocapIsRunning {
                CapturePreviewView(
                    captureSession: store.mocapCaptureSession?.captureSession,
                    poseFrame: store.mocapLatestPoseFrame
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "figure.walk.motion")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("Motion Capture")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text("Connect a webcam and press Start Capture to begin 3D body tracking.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let error = store.mocapErrorMessage {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") {
                        store.mocapErrorMessage = nil
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.yellow.opacity(0.1))
            }

            if let frame = store.mocapLatestPoseFrame,
               let joints = frame.bodyJoints {
                HStack(spacing: 16) {
                    Label("\(joints.count) joints", systemImage: "figure.stand")
                    if let confidences = frame.bodyConfidences {
                        let avgConf = confidences.values.reduce(0, +) / max(Float(confidences.count), 1)
                        Label(
                            String(format: "%.0f%% avg confidence", avgConf * 100),
                            systemImage: "gauge.with.dots.needle.33percent"
                        )
                    }
                    Spacer()
                    Text(String(format: "t=%.2fs", frame.timestamp))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.2))
            }
        }
        .onAppear {
            availableCameras = CaptureSession.availableCameras()
        }
        .onDisappear {
            if store.mocapIsRunning {
                store.stopMocap()
            }
        }
    }
}