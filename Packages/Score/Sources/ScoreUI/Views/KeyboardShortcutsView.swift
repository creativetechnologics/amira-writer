import SwiftUI

/// A sheet that lists all keyboard shortcuts organized by category.
@available(macOS 26.0, *)
struct KeyboardShortcutsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    shortcutSection("File") {
                        shortcutRow("Open Project", "Cmd + O")
                        shortcutRow("Save", "Cmd + S")
                        shortcutRow("Export Audio", "Cmd + Shift + E")
                    }

                    shortcutSection("Edit") {
                        shortcutRow("Undo", "Cmd + Z")
                        shortcutRow("Redo", "Cmd + Shift + Z")
                        shortcutRow("Select All Notes", "Cmd + A")
                        shortcutRow("Delete Selected", "Delete")
                        shortcutRow("Quantize Selected", "Cmd + Q")
                    }

                    shortcutSection("Playback") {
                        shortcutRow("Play / Stop", "Cmd + Return")
                        shortcutRow("Play / Pause", "Space")
                        shortcutRow("Cycle Suno A/B Mode", "Cmd + Shift + U")
                    }

                    shortcutSection("Piano Roll Tools") {
                        shortcutRow("Select Tool", "E")
                        shortcutRow("Draw Tool", "P")
                        shortcutRow("Erase Tool", "D")
                        shortcutRow("Mute Tool", "T")
                        shortcutRow("Slice Tool", "C")
                    }

                    shortcutSection("Navigation") {
                        shortcutRow("Zoom In", "Cmd + =")
                        shortcutRow("Zoom Out", "Cmd + -")
                        shortcutRow("Scroll", "Trackpad / Scroll Wheel")
                    }
                }
                .padding()
            }
        }
        .frame(width: 380, height: 480)
    }

    @ViewBuilder
    private func shortcutSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func shortcutRow(_ action: String, _ keys: String) -> some View {
        HStack {
            Text(action)
                .font(.body)
            Spacer()
            Text(keys)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.12))
                )
        }
    }
}
