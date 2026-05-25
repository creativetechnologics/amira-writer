import SwiftUI

@available(macOS 26.0, *)
struct AutomateView: View {
    @Bindable var store: ScoreStore

    private var hasAudioClips: Bool {
        !store.pianoRollAudioClips.isEmpty
    }

    var body: some View {
        VStack(spacing: 10) {
            // Automation Recording
            automationRecordSection

            Divider().padding(.horizontal, 8)

            automateButton(
                title: "Humanize MIDI",
                subtitle: "Add realistic dynamics, timing, and expression",
                icon: "person.and.background.dotted",
                action: humanizeMIDI
            )

            automateButton(
                title: "Reconstruct WAV to MIDI",
                subtitle: hasAudioClips
                    ? clipSummary
                    : "Drop a WAV in the arrangement first",
                icon: "waveform.arrow.triangle.branch.right",
                disabled: !hasAudioClips,
                action: reconstructWAV
            )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Button Template

    @ViewBuilder
    private func automateButton(
        title: String,
        subtitle: String,
        icon: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundStyle(disabled ? .tertiary : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(disabled ? .tertiary : .primary)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(disabled ? .quaternary : .secondary)
                        .lineLimit(2)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(disabled ? .quaternary : .tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(disabled ? 0.02 : 0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(disabled ? 0.03 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    // MARK: - Automation Recording Section

    private var automationRecordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: store.automationRecordArmed ? "record.circle.fill" : "record.circle")
                    .foregroundStyle(store.automationRecordArmed ? .red : .secondary)
                Text("Automation Record")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Toggle("", isOn: Binding(
                    get: { store.automationRecordArmed },
                    set: { store.automationRecordArmed = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
            }

            if store.automationRecordArmed {
                Picker("Lane", selection: Binding(
                    get: { store.automationRecordLaneType },
                    set: { store.automationRecordLaneType = $0 }
                )) {
                    ForEach(AutomationLaneType.allCases) { lane in
                        Text(lane.rawValue).tag(lane)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)

                Picker("Channel", selection: Binding(
                    get: { store.automationRecordChannelKey ?? "" },
                    set: { store.automationRecordChannelKey = $0.isEmpty ? nil : $0 }
                )) {
                    Text("None").tag("")
                    ForEach(store.instrumentMappings.keys.sorted(), id: \.self) { key in
                        Text(store.instrumentMappings[key]?.displayName ?? key).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)

                Text("Move faders/pan during playback to record automation points.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(store.automationRecordArmed ? Color.red.opacity(0.08) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(store.automationRecordArmed ? Color.red.opacity(0.3) : Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Clip Summary

    private var clipSummary: String {
        let clips = store.pianoRollAudioClips
        let count = clips.count
        let names = clips.prefix(2).map(\.displayName).joined(separator: ", ")
        if count == 1 {
            return names
        } else if count == 2 {
            return names
        } else {
            return "\(names) + \(count - 2) more"
        }
    }

    // MARK: - Actions

    private func humanizeMIDI() {
        store.statusMessage = "Use an external AI agent via MCP to humanize MIDI"
    }

    private func reconstructWAV() {
        store.statusMessage = "Use an external AI agent via MCP to reconstruct WAV to MIDI"
    }
}
