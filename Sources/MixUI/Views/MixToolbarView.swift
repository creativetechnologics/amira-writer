import SwiftUI
import ProjectKit

// MARK: - Main Transport Bar

@available(macOS 26.0, *)
struct MixTransportBar: View {
    @Bindable var store: MixStore
    @Binding var pixelsPerSecond: Double
    @Binding var showMixerDock: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if store.toolbarAvailableWidth >= 950 {
                wideLayout
            } else if store.toolbarAvailableWidth >= 640 {
                mediumLayout
            } else {
                compactLayout
            }
        }
        .background(MixPalette.toolbarBottom)
        .overlay(alignment: .bottom) {
            Rectangle().fill(MixPalette.panelStroke).frame(height: 1)
        }
        .background {
            // Measure available width and feed back to store
            GeometryReader { geo in
                Color.clear.onAppear { store.toolbarAvailableWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, w in store.toolbarAvailableWidth = w }
            }
        }
    }

    // MARK: - Wide Layout (>=950pt)

    private var wideLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                sectionSceneInfo
                toolbarDivider
                sectionTransport
                toolbarDivider
                sectionLCD
                Spacer(minLength: 8)
                sectionAddTrack
            }
            .padding(.vertical, 6)

            toolbarRowDivider

            HStack(spacing: 0) {
                sectionTools
                toolbarDivider
                sectionSnap
                toolbarDivider
                sectionZoom
                toolbarDivider
                sectionNudge
                Spacer(minLength: 8)
                sectionStatusChips
                sectionMixerToggle
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Medium Layout (>=640pt)

    private var mediumLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                sectionTransport
                toolbarDivider
                sectionLCD
                Spacer(minLength: 8)
                sectionAddTrack
            }
            .padding(.vertical, 6)

            toolbarRowDivider

            HStack(spacing: 0) {
                sectionTools
                toolbarDivider
                sectionSnap
                toolbarDivider
                sectionZoom
                Spacer(minLength: 8)
                sectionStatusChips
                sectionMixerToggle
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 10)
    }

    // MARK: - Compact Layout (<640pt)

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                sectionTransportCompact
                toolbarDivider
                sectionLCDCompact
                Spacer(minLength: 4)
                sectionMixerToggle
            }
            .padding(.vertical, 6)

            toolbarRowDivider

            HStack(spacing: 0) {
                sectionTools
                toolbarDivider
                sectionZoom
                Spacer(minLength: 4)
                sectionStatusChipsCompact
            }
            .padding(.vertical, 6)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Toolbar Sections

    private var sectionSceneInfo: some View {
        toolbarSection {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.selectedScene?.displayTitle ?? "No scene")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                Text(selectionSummary)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
            .frame(minWidth: 120, maxWidth: 180, alignment: .leading)
        }
    }

    private var sectionTransport: some View {
        toolbarSection {
            HStack(spacing: 3) {
                MixDawButton(systemImage: "backward.end.fill", help: "Go to start", tint: MixPalette.steel) {
                    store.seekPlayhead(to: 0)
                }
                MixDawButton(systemImage: "backward.fill", help: "Back 5s", tint: MixPalette.steel) {
                    store.movePlayhead(by: -5)
                }
                MixDawButton(
                    systemImage: store.isPlaying ? "pause.fill" : "play.fill",
                    help: store.isPlaying ? "Pause" : "Play",
                    tint: store.isPlaying ? MixPalette.lime : .white,
                    isActive: store.isPlaying
                ) {
                    store.togglePlayback()
                }
                MixDawButton(
                    systemImage: "stop.fill",
                    help: "Stop",
                    tint: MixPalette.steel,
                    isDisabled: !store.isPlaying && store.playheadSeconds == 0
                ) {
                    store.stopTransport()
                }
                MixDawButton(systemImage: "forward.fill", help: "Forward 5s", tint: MixPalette.steel) {
                    store.movePlayhead(by: 5)
                }
                MixDawButton(
                    systemImage: "record.circle.fill",
                    help: store.isRecording ? "Stop recording" : "Record",
                    tint: MixPalette.recordArmed,
                    isActive: store.isRecording
                ) {
                    store.toggleRecording()
                }
            }
        }
    }

    private var sectionTransportCompact: some View {
        toolbarSection {
            HStack(spacing: 3) {
                MixDawButton(systemImage: "backward.end.fill", help: "Go to start", tint: MixPalette.steel) {
                    store.seekPlayhead(to: 0)
                }
                MixDawButton(
                    systemImage: store.isPlaying ? "pause.fill" : "play.fill",
                    help: store.isPlaying ? "Pause" : "Play",
                    tint: store.isPlaying ? MixPalette.lime : .white,
                    isActive: store.isPlaying
                ) {
                    store.togglePlayback()
                }
                MixDawButton(systemImage: "stop.fill", help: "Stop", tint: MixPalette.steel) {
                    store.stopTransport()
                }
                MixDawButton(
                    systemImage: "record.circle.fill",
                    help: "Record",
                    tint: MixPalette.recordArmed,
                    isActive: store.isRecording
                ) {
                    store.toggleRecording()
                }
            }
        }
    }

    private var sectionLCD: some View {
        toolbarSection {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(transportTimecode(store.playheadSeconds))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(MixPalette.displayText)
                Text("/ \(shortTimecode(store.activeSceneDurationSeconds))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(MixPalette.steel.opacity(0.75))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(MixPalette.displayBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(MixPalette.displayStroke, lineWidth: 1)
            )
        }
    }

    private var sectionLCDCompact: some View {
        toolbarSection {
            Text(transportTimecode(store.playheadSeconds))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(MixPalette.displayText)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MixPalette.displayBackground))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(MixPalette.displayStroke, lineWidth: 1))
        }
    }

    private var sectionAddTrack: some View {
        toolbarSection {
            HStack(spacing: 5) {
                MixLabelButton(title: "Track", systemImage: "plus") {
                    _ = store.addTrack()
                }
                MixLabelButton(title: "Vocals", systemImage: "mic.badge.plus") {
                    _ = store.addTrack(named: nil, armForRecording: true)
                }
            }
        }
    }

    private var sectionTools: some View {
        toolbarSection {
            HStack(spacing: 1) {
                toolSelectorButton(.pointer)
                toolSelectorButton(.split)
                toolSelectorButton(.automation)
                toolSelectorButton(.fade)
            }
        }
    }

    @ViewBuilder
    private func toolSelectorButton(_ tool: MixEditTool) -> some View {
        let isSelected = store.selectedTool == tool
        Button {
            store.selectedTool = tool
        } label: {
            VStack(spacing: 3) {
                Image(systemName: tool.iconName)
                    .font(.system(size: 12, weight: .semibold))
                Text(tool.shortLabel.uppercased())
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(isSelected ? MixPalette.gold : .white.opacity(0.72))
            .frame(width: 44, height: 32)
        }
        .buttonStyle(MixToolSelectorStyle(isSelected: isSelected))
        .help("\(tool.shortLabel) (\(toolShortcutKey(tool)))")
    }

    private func toolShortcutKey(_ tool: MixEditTool) -> String {
        switch tool {
        case .pointer: return "1"
        case .split: return "2"
        case .automation: return "3"
        case .fade: return "4"
        }
    }

    private var sectionNudge: some View {
        toolbarSection {
            HStack(spacing: 3) {
                MixDawButton(systemImage: "chevron.left", help: "Nudge selected clip left", tint: MixPalette.steel) {
                    if let clipID = store.currentSelectedClipID {
                        store.nudgeClip(clipID, by: -store.nudgeAmount)
                    }
                }
                MixDawButton(systemImage: "chevron.right", help: "Nudge selected clip right", tint: MixPalette.steel) {
                    if let clipID = store.currentSelectedClipID {
                        store.nudgeClip(clipID, by: store.nudgeAmount)
                    }
                }
            }
        }
    }

    private var sectionSnap: some View {
        toolbarSection {
            HStack(spacing: 3) {
                Text("SNAP")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))

                HStack(spacing: 2) {
                    snapButton(label: "Off", value: 0)
                    snapButton(label: "¼s", value: 0.25)
                    snapButton(label: "½s", value: 0.5)
                    snapButton(label: "1s",  value: 1.0)
                    // Beat-based snap — uses current session BPM
                    snapButton(label: "Beat", value: store.beatSnapSeconds)
                }
            }
        }
    }

    @ViewBuilder
    private func snapButton(label: String, value: Double) -> some View {
        let isOn = store.snapSeconds == value
        Button { store.snapSeconds = value } label: {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? MixPalette.gold : .white.opacity(0.6))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? MixPalette.gold.opacity(0.18) : .white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    private var sectionZoom: some View {
        toolbarSection {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
                    .accessibilityHidden(true)
                Slider(value: $pixelsPerSecond, in: 12...48)
                    .frame(width: 110)
                    .accessibilityLabel("Timeline zoom")
                    .accessibilityValue("\(Int(pixelsPerSecond.rounded())) pixels per second")
                Text("\(Int(pixelsPerSecond.rounded()))px")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 30, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    private var sectionStatusChips: some View {
        toolbarSection {
            HStack(spacing: 5) {
                MixStatusChip(title: "Tracks", value: "\(store.currentTracks.count)", tint: MixPalette.lime, compact: true)
                MixStatusChip(title: "Clips", value: "\(store.currentClips.count)", tint: MixPalette.gold, compact: true)
            }
        }
    }

    private var sectionStatusChipsCompact: some View {
        toolbarSection {
            Text("\(store.currentTracks.count)T \(store.currentClips.count)C")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.48))
        }
    }

    private var sectionMixerToggle: some View {
        toolbarSection {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showMixerDock.toggle() }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(showMixerDock ? MixPalette.cyan : .white.opacity(0.55))
            }
            .buttonStyle(MixHoverButtonStyle())
            .help(showMixerDock ? "Hide Mixer" : "Show Mixer")
        }
    }

    // MARK: - Helper Views

    private var toolbarRowDivider: some View {
        Rectangle()
            .fill(MixPalette.panelStroke.opacity(0.6))
            .frame(height: 1)
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(width: 1, height: 22)
            .padding(.horizontal, 4)
    }

    private func toolbarSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content().padding(.horizontal, 6)
    }

    // MARK: - Computed Strings

    private var selectionSummary: String {
        if let clip = store.selectedClip { return clip.name }
        if let track = store.selectedTrack { return track.name }
        return "No selection"
    }

    private func shortTimecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func transportTimecode(_ seconds: Double) -> String {
        let totalHundredths = Int((max(seconds, 0) * 100).rounded())
        let minutes = totalHundredths / 6000
        let remainingSeconds = (totalHundredths / 100) % 60
        let hundredths = totalHundredths % 100
        return String(format: "%02d:%02d.%02d", minutes, remainingSeconds, hundredths)
    }
}

// MARK: - Button Styles

@available(macOS 26.0, *)
struct MixHoverButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(configuration.isPressed
                        ? Color.white.opacity(0.14)
                        : isHovered ? Color.white.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.07), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

@available(macOS 26.0, *)
struct MixToolSelectorStyle: ButtonStyle {
    var isSelected: Bool = false
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected
                        ? MixPalette.gold.opacity(configuration.isPressed ? 0.22 : 0.14)
                        : configuration.isPressed
                            ? Color.white.opacity(0.14)
                            : isHovered ? Color.white.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: 0.06), value: isHovered)
            .onHover { isHovered = $0 }
    }
}

// MARK: - Reusable Button Primitives

/// Icon-only DAW button with hover/press animation and optional tint.
@available(macOS 26.0, *)
struct MixDawButton: View {
    let systemImage: String
    var help: String = ""
    var tint: Color = .white
    var isActive: Bool = false
    var isDisabled: Bool = false
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    isActive ? .black.opacity(0.85)
                    : isDisabled ? .white.opacity(0.26)
                    : tint.opacity(0.88)
                )
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? tint : isHovered ? Color.white.opacity(0.09) : .clear)
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.07), value: isHovered)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Label button (icon + text) for less-used actions.
@available(macOS 26.0, *)
struct MixLabelButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MixPalette.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(MixPalette.panelStroke.opacity(0.8), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Legacy Button Types (kept for backward compatibility with existing views)

@available(macOS 26.0, *)
struct MixToolbarButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        MixLabelButton(title: title, systemImage: systemImage, action: action)
    }
}

@available(macOS 26.0, *)
struct MixToolbarIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.86))
                .frame(width: 28, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(MixPalette.controlFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(MixPalette.panelStroke.opacity(0.8), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

@available(macOS 26.0, *)
struct MixToolButton: View {
    let tool: MixEditTool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: tool.iconName)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(tool.shortLabel.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(isSelected ? .black.opacity(0.86) : .white.opacity(0.82))
            .frame(width: 52, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? MixPalette.gold : MixPalette.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(isSelected ? MixPalette.gold.opacity(0.45) : MixPalette.panelStroke.opacity(0.8), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

@available(macOS 26.0, *)
struct MixTransportButton: View {
    let systemImage: String
    let title: String
    let tint: Color
    var isActive = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12.5, weight: .bold))
                Text(title.uppercased())
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(isActive ? .black.opacity(0.85) : .white.opacity(isDisabled ? 0.34 : 0.82))
            .frame(width: 56, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? tint : MixPalette.controlFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isActive ? tint.opacity(0.5) : MixPalette.panelStroke.opacity(0.8), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

@available(macOS 26.0, *)
struct MixStatusChip: View {
    let title: String
    let value: String
    let tint: Color
    var compact = false
    var isEmphasized = false

    var body: some View {
        HStack(spacing: compact ? 5 : 6) {
            Text(title.uppercased())
                .font(.system(size: compact ? 8 : 8.5, weight: .bold, design: .monospaced))
                .foregroundStyle(tint.opacity(isEmphasized ? 0.96 : 0.76))
            Text(value)
                .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 4 : 5)
        .background(
            Capsule()
                .fill(isEmphasized ? tint.opacity(0.18) : MixPalette.controlFill.opacity(0.92))
        )
        .overlay(
            Capsule()
                .stroke(isEmphasized ? tint.opacity(0.45) : MixPalette.panelStroke.opacity(0.75), lineWidth: 1)
        )
    }
}

@available(macOS 26.0, *)
struct MixTrackButton: View {
    let title: String
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(isOn ? .black.opacity(0.84) : .white.opacity(0.74))
                .frame(width: 24, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isOn ? tint : MixPalette.controlFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isOn ? tint.opacity(0.4) : MixPalette.panelStroke.opacity(0.6), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

@available(macOS 26.0, *)
struct MixSectionLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 8.5, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.45))
            .frame(minWidth: 24, alignment: .leading)
    }
}

@available(macOS 26.0, *)
struct MixVerticalMeterView: View {
    let level: Double

    var body: some View {
        GeometryReader { proxy in
            let clamped = min(max(level, 0), 1)
            let fillHeight = max(proxy.size.height * clamped, 2)

            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(MixPalette.meterRail)

                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [MixPalette.meterGreen, MixPalette.meterYellow, MixPalette.meterPeak],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: fillHeight)

                VStack(spacing: 2) {
                    ForEach(0..<12, id: \.self) { _ in
                        Rectangle()
                            .fill(.black.opacity(0.22))
                            .frame(height: 1)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}
