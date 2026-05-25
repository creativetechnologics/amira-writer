import SwiftUI

@available(macOS 26.0, *)
struct ExportInspectorView: View {
    @Bindable var store: ScoreStore

    private let buttonColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Exports")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: buttonColumns, spacing: 6) {
                inspectorButton("Full Mix WAV", systemImage: "waveform", isProminent: true) {
                    store.exportFullMixToWavWithPanel()
                }
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel)

                inspectorButton("Export Instrumental WAV", systemImage: "waveform.path.ecg") {
                    store.exportInstrumentalMixToWavWithPanel()
                }
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel)

                inspectorButton("Export All WAVs", systemImage: "waveform.badge.plus") {
                    store.exportAllSongsToWavsWithPanel()
                }
                .disabled(store.midiAssets.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel || store.isBatchExporting)

                inspectorButton("Export All Instrumental WAVs", systemImage: "waveform.path.ecg.rectangle") {
                    store.exportAllSongsToInstrumentalWavsWithPanel()
                }
                .disabled(store.midiAssets.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel || store.isBatchExporting)

                inspectorButton("Rehearsal Track", systemImage: "music.note.list") {
                    store.exportRehearsalTrackWithPanel()
                }
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel)

                inspectorButton("Track Stems", systemImage: "square.stack.3d.up") {
                    store.exportStemsWithPanel()
                }
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel)
            }

            if store.isExportingFullMix {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: store.fullMixExportProgress)
                        .progressViewStyle(.linear)
                    Text("\(Int(store.fullMixExportProgress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Text("Mix Integration")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: buttonColumns, spacing: 6) {
                inspectorButton("Send to Mix", systemImage: "arrow.right.to.line", isProminent: true) {
                    store.exportCurrentSongToMix()
                }
                .disabled(store.pianoRollNotes.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel || store.isBatchExporting)

                inspectorButton("Send All to Mix", systemImage: "arrow.right.to.line.circle") {
                    Task { await store.exportAllSongsToMix() }
                }
                .disabled(store.midiAssets.isEmpty || store.isExportingFullMix || store.isPresentingFullMixExportPanel || store.isBatchExporting)
            }

            if store.isBatchExporting {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: store.batchExportProgress)
                        .progressViewStyle(.linear)
                    Text(store.batchExportStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if !store.batchExportStatus.isEmpty {
                Text(store.batchExportStatus)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            if !store.fullMixExportStatus.isEmpty {
                Text("Status")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(store.fullMixExportStatus)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !store.fullMixExportDetailStatus.isEmpty {
                Text(store.fullMixExportDetailStatus)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func inspectorButton(
        _ title: String,
        systemImage: String,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        if isProminent {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        } else {
            Button(action: action) {
                Label(title, systemImage: systemImage)
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .multilineTextAlignment(.center)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
