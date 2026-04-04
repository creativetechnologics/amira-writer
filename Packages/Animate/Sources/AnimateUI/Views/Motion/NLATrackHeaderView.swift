import SwiftUI

/// Header for a single NLA track lane. Sits to the left of the clip area.
/// Shows: track name (editable), mute/solo toggles, blend mode badge, influence.
@available(macOS 26.0, *)
struct NLATrackHeaderView: View {
    @Binding var track: NLATrack
    var isSelected: Bool
    var onDelete: () -> Void

    @State private var isEditingName = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Track name
                if isEditingName {
                    TextField("Track Name", text: $track.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, weight: .medium))
                        .onSubmit { isEditingName = false }
                } else {
                    Text(track.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .onTapGesture(count: 2) { isEditingName = true }
                }

                Spacer()

                // Blend mode badge
                Text(track.blendMode.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(blendModeBadgeColor.opacity(0.25))
                    )
                    .foregroundStyle(blendModeBadgeColor)
            }

            HStack(spacing: 8) {
                // Mute button
                Button {
                    track.muted.toggle()
                } label: {
                    Text("M")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(track.muted ? .red : .secondary)
                }
                .buttonStyle(.plain)
                .help(track.muted ? "Unmute track" : "Mute track")

                // Solo button
                Button {
                    track.solo.toggle()
                } label: {
                    Text("S")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(track.solo ? .yellow : .secondary)
                }
                .buttonStyle(.plain)
                .help(track.solo ? "Unsolo track" : "Solo track")

                // Influence slider (compact)
                Slider(value: $track.influence, in: 0...1)
                    .controlSize(.mini)
                    .frame(maxWidth: 60)

                Text("\(Int(track.influence * 100))%")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)

                Spacer()

                // Delete
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete track")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: 200, height: 40)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }

    private var blendModeBadgeColor: Color {
        switch track.blendMode {
        case .replace: .blue
        case .additive: .green
        case .override_: .orange
        }
    }
}
