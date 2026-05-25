#if os(macOS)
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct PlaybackEngineSelectorView: View {
    let masterInstrumentMode: InstrumentSourceType
    let helpText: String
    let onSelectMode: (InstrumentSourceType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Playback Engine")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(OperaChromeTheme.textTertiary)

            HStack(spacing: 6) {
                OperaChromeActionButton(
                    title: "Lightweight",
                    systemImage: "leaf",
                    isSelected: masterInstrumentMode == .soundFont
                ) {
                    onSelectMode(.soundFont)
                }
                OperaChromeActionButton(
                    title: "Heavyweight",
                    systemImage: "waveform",
                    isSelected: masterInstrumentMode == .audioUnit
                ) {
                    onSelectMode(.audioUnit)
                }
            }
            .help(helpText)
        }
    }
}

@available(macOS 26.0, *)
struct AllTracksFilterRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            // Placeholder for volume knob column.
            Image(systemName: "circle.grid.cross")
                .foregroundStyle(Color.white.opacity(0.55))
                .frame(width: 18)

            Text("All Tracks")
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 8)

            // Placeholder for speaker icon column; matches instrument rows.
            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(.clear)
                .padding(.leading, 4)
                .padding(.trailing, 1)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

@available(macOS 26.0, *)
struct InstrumentMappingQuickActionsView: View {
    let canOpenFX: Bool
    let onOpenExpressionMap: () -> Void
    let onOpenFX: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onOpenExpressionMap) {
                Label("Expr Map", systemImage: "music.note.list")
            }
            .controlSize(.small)

            if canOpenFX {
                Button(action: onOpenFX) {
                    Label("FX", systemImage: "waveform.path.ecg")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }
}

@available(macOS 26.0, *)
struct VoiceConfigSectionView: View {
    let gender: VocalGender
    let onSetGender: (VocalGender) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gender")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Gender", selection: Binding(
                    get: { gender },
                    set: { newGender in
                        onSetGender(newGender)
                    }
                )) {
                    ForEach(VocalGender.allCases) { gender in
                        Text(gender.title).tag(gender)
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
#endif
