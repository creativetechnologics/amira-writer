import SwiftUI

@available(macOS 26.0, *)
struct ExportInspectorView: View {
    @Bindable var store: ScoreStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Exports")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                store.exportFullMixToWavWithPanel()
            } label: {
                Label("Full Mix WAV", systemImage: "waveform")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix)

            Button {
                store.exportRehearsalTrackWithPanel()
            } label: {
                Label("Rehearsal Track", systemImage: "music.note.list")
            }
            .controlSize(.small)
            .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix)

            Button {
                store.exportStemsWithPanel()
            } label: {
                Label("Track Stems", systemImage: "square.stack.3d.up")
            }
            .controlSize(.small)
            .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix)

            Divider()

            Text("Suno Prep")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Button {
                store.generateSunoChunkPlan()
            } label: {
                Label("Refresh Suno Plan", systemImage: "wand.and.stars")
            }
            .controlSize(.small)
            .disabled(store.selectedMidiID == nil || store.pianoRollNotes.isEmpty)

            Button {
                store.exportForManualSuno()
            } label: {
                Label("Export Suno Chunks", systemImage: "sparkles.rectangle.stack")
            }
            .controlSize(.small)
            .disabled(store.activeChunkPlan == nil)

            if !store.fullMixExportStatus.isEmpty {
                Divider()
                Text("Status")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(store.fullMixExportStatus)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
