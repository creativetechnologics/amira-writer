import SwiftUI

@available(macOS 26.0, *)
struct ShotFrameCard: View {
    let title: String  // "First Frame" or "Last Frame"
    let imagePath: String?
    let prompt: String
    let variants: [String]
    let isApproved: Bool
    let onGenerate: () -> Void
    let onQueueToggle: () -> Void
    @Binding var promptText: String
    @State private var isQueued = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))

            // Image preview
            if imagePath != nil {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.1))
                    .frame(height: 160)
                    .overlay {
                        Text("Frame Preview").font(.caption).foregroundStyle(.secondary)
                    }
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.05))
                    .frame(height: 160)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                            Text("No frame generated").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
            }

            // Prompt editor
            TextEditor(text: $promptText)
                .font(.caption)
                .frame(minHeight: 60, maxHeight: 80)
                .padding(4)
                .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                Button(action: onGenerate) {
                    Label("Generate", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Toggle(isOn: $isQueued) {
                    Text("Queue")
                }
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: isQueued) { _, _ in onQueueToggle() }

                Spacer()

                if !variants.isEmpty {
                    Text("Variants: \(variants.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isApproved {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
