import SwiftUI

@available(macOS 26.0, *)
struct Previs3DToolbar: View {
    @Binding var activeMode: PrevisMode
    @Binding var activeKeyframe: PrevisKeyframeLabel
    var onCapture: () -> Void
    var onGenerateLayout: (() -> Void)?
    var isGeneratingLayout: Bool = false
    var canGenerateLayout: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Picker("Mode", selection: $activeMode) {
                ForEach(PrevisMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            Divider()
                .frame(height: 20)

            Picker("Keyframe", selection: $activeKeyframe) {
                ForEach(PrevisKeyframeLabel.allCases, id: \.self) { kf in
                    Text(kf.rawValue).tag(kf)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            if let onGenerate = onGenerateLayout, canGenerateLayout {
                Button("Layout", systemImage: "wand.and.stars") {
                    onGenerate()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isGeneratingLayout)
            }

            Button("Capture", systemImage: "camera") {
                onCapture()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}

@available(macOS 26.0, *)
enum PrevisMode: String, CaseIterable {
    case select = "Select"
    case translate = "Move"
    case rotate = "Rotate"
    case scale = "Scale"
    case poseBone = "Pose"
}

@available(macOS 26.0, *)
enum PrevisKeyframeLabel: String, CaseIterable {
    case beginning = "Beginning"
    case middle = "Middle"
    case end = "End"
}
