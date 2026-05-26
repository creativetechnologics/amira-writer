import SwiftUI

@available(macOS 26.0, *)
struct CaptureSettingsView: View {
    @Bindable var store: AnimateStore
    @State private var useEnhancedTracking = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Capture Settings")
                .font(.headline)

            Toggle("Enhanced Tracking (slower)", isOn: $useEnhancedTracking)
                .help("Uses DWPose model for 133-keypoint whole-body tracking including hands and face. Requires DWPose.mlmodelc in the app bundle.")
                .onChange(of: useEnhancedTracking) {
                    do {
                        let mode: CaptureTrackingMode = useEnhancedTracking ? .enhanced : .standard
                        try store.setTrackingMode(mode)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                        useEnhancedTracking = false
                    }
                }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            if useEnhancedTracking {
                Text("133 keypoints: body + hands + face")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Standard: Apple Vision 3D body + face tracking")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
