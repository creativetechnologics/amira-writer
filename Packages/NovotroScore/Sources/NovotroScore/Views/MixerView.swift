#if os(macOS)
import SwiftUI

// MARK: - Mixer View
// A SwiftUI view showing vertical channel strips for each instrument mapping.
// Each strip: volume fader (vertical slider), pan knob, solo/mute buttons, AU plugin button.
// Includes a master fader strip.

@available(macOS 26.0, *)
struct MixerView: View {

    @Bindable var store: ScoreStore
    @State private var draggingMappingKey: String?

    /// Sorted mapping keys for consistent display order.
    private var sortedMappingKeys: [String] {
        store.instrumentMappings.keys.sorted { lhs, rhs in
            let lm = store.instrumentMappings[lhs]
            let rm = store.instrumentMappings[rhs]
            let lo = lm?.sortOrder ?? Int.max
            let ro = rm?.sortOrder ?? Int.max
            if lo != ro { return lo < ro }
            return lhs < rhs
        }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .bottom, spacing: 2) {
                // Channel strips
                ForEach(sortedMappingKeys, id: \.self) { key in
                    if let mapping = store.instrumentMappings[key] {
                        ChannelStripView(
                            store: store,
                            channelKey: key,
                            mapping: mapping
                        )
                        .onDrag {
                            draggingMappingKey = key
                            return NSItemProvider(object: key as NSString)
                        }
                        .onDrop(of: [.plainText], delegate: MixerStripDropDelegate(
                            targetKey: key,
                            store: store,
                            draggingMappingKey: $draggingMappingKey
                        ))
                    }
                }

                // Suno render bus strip
                if store.sunoRenderLayer != nil {
                    SunoChannelStripView(store: store)
                }

                Divider()
                    .frame(height: 300)

                // Master fader
                MasterStripView(store: store)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

@available(macOS 26.0, *)
private struct MixerStripDropDelegate: DropDelegate {
    let targetKey: String
    let store: ScoreStore
    @Binding var draggingMappingKey: String?

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggingMappingKey = nil }
        guard let sourceKey = draggingMappingKey, sourceKey != targetKey else { return false }
        store.reorderTrack(from: sourceKey, before: targetKey)
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        draggingMappingKey != nil
    }
}

// MARK: - Channel Strip

@available(macOS 26.0, *)
private struct ChannelStripView: View {

    @Bindable var store: ScoreStore
    let channelKey: String
    let mapping: InstrumentMapping

    /// Volume in dB, mapped from gainDB. Range -60 to +12.
    private var volumeBinding: Binding<Double> {
        Binding(
            get: { store.instrumentMappings[channelKey]?.gainDB ?? mapping.gainDB },
            set: { newVal in
                let clamped = min(max(newVal, -60.0), 12.0)
                store.instrumentMappings[channelKey]?.gainDB = clamped
                store.isDirty = true
                // Record volume automation if armed
                if store.automationRecordArmed && store.automationRecordChannelKey == channelKey && store.automationRecordLaneType == .cc7Volume {
                    let normalized = (clamped + 60) / 72 // map -60..12 to 0..1
                    store.recordAutomationPoint(value: normalized)
                }
            }
        )
    }

    /// Pan binding: -1.0 to 1.0. Stored on ScoreStore and applied to the audio engine.
    private var panBinding: Binding<Double> {
        let key = channelKey
        return Binding(
            get: { store.channelPan[key] ?? 0 },
            set: { store.setChannelPan(key: key, pan: $0) }
        )
    }

    private var isMuted: Bool { store.instrumentMappings[channelKey]?.muted ?? mapping.muted }
    private var isSoloed: Bool { store.soloedTracks.contains(trackIndex) }

    private var trackIndex: Int {
        // Derive track index from channel key (format: "T0-C0" or similar)
        if let tPart = channelKey.split(separator: "-").first,
           let idx = Int(tPart.dropFirst()) {
            return idx
        }
        return 0
    }

    var body: some View {
        VStack(spacing: 4) {
            // Track name
            Text(mapping.displayName)
                .font(.system(size: 9, weight: .medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 64, height: 28)

            // Volume fader (vertical)
            VStack(spacing: 0) {
                // dB label
                Text(volumeLabel)
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44)

                // Vertical slider
                VerticalSlider(value: volumeBinding, range: -60...12)
                    .frame(width: 30, height: 180)
            }

            // Pan knob
            HStack(spacing: 2) {
                Text("L")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                Slider(value: panBinding, in: -1...1)
                    .frame(width: 50)
                Text("R")
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
            }

            // Solo / Mute buttons
            HStack(spacing: 4) {
                Button(action: {
                    store.toggleTrackSolo(trackIndex)
                }) {
                    Text("S")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isSoloed ? .white : .secondary)
                        .frame(width: 22, height: 18)
                        .background(isSoloed ? Color.yellow : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                Button(action: {
                    store.setMappingMuted(for: channelKey, muted: !isMuted)
                }) {
                    Text("M")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isMuted ? .white : .secondary)
                        .frame(width: 22, height: 18)
                        .background(isMuted ? Color.red : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
            }

            // AU plugin button (only for AU-based instruments)
            if mapping.effectiveSourceType == .audioUnit {
                Button(action: {
                    openPluginUI()
                }) {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 10))
                        .frame(width: 50, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            // Color indicator
            if let hex = mapping.colorHex {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: hex))
                    .frame(width: 50, height: 4)
            }
        }
        .frame(width: 70)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var volumeLabel: String {
        let db = mapping.gainDB
        if db <= -60 { return "-inf" }
        return String(format: "%.1f", db)
    }

    private func openPluginUI() {
        store.playbackEngine.getAudioUnit(for: channelKey) { auAudioUnit in
            if let auAudioUnit {
                showAudioUnitPluginPanel(audioUnit: auAudioUnit, title: mapping.displayName)
            } else {
                NSLog("[Mixer] No live AU loaded for %@", channelKey)
            }
        }
    }
}

// MARK: - Master Strip

@available(macOS 26.0, *)
private struct MasterStripView: View {

    @Bindable var store: ScoreStore

    /// Binding that converts store.masterVolume (0–1 linear) to/from dB for the slider.
    private var masterVolumeDB: Binding<Double> {
        Binding(
            get: {
                let linear = store.masterVolume
                return linear <= 0.001 ? -60.0 : 20.0 * log10(linear)
            },
            set: { dB in
                let linear = dB <= -60 ? 0.0 : pow(10.0, dB / 20.0)
                store.setMasterVolume(linear)
            }
        )
    }

    private var masterVolumeDBValue: Double {
        let linear = store.masterVolume
        return linear <= 0.001 ? -60.0 : 20.0 * log10(linear)
    }

    var body: some View {
        VStack(spacing: 4) {
            Text("Master")
                .font(.system(size: 10, weight: .bold))
                .frame(width: 64, height: 28)

            VStack(spacing: 0) {
                Text(masterVolumeDBValue <= -60 ? "-inf" : String(format: "%.1f", masterVolumeDBValue))
                    .font(.system(size: 8, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44)

                VerticalSlider(value: masterVolumeDB, range: -60...12)
                    .frame(width: 30, height: 180)
            }

            // Master meter
            MeterView(levels: store.masterMeterLevels)
                .frame(width: 20, height: 60)

            Spacer()
                .frame(height: 4)
        }
        .frame(width: 70)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        )
    }
}

// MARK: - Meter View

@available(macOS 26.0, *)
private struct MeterView: View {
    let levels: MeterLevels

    var body: some View {
        HStack(spacing: 2) {
            meterBar(dB: levels.peakL)
            meterBar(dB: levels.peakR)
        }
    }

    private func meterBar(dB: Float) -> some View {
        GeometryReader { geo in
            let height = geo.size.height
            let fraction = CGFloat(max(0, min(1, (dB + 60) / 72))) // -60 to +12 range
            let fillH = height * fraction
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.secondary.opacity(0.15))
                Rectangle()
                    .fill(dB > 0 ? Color.red : (dB > -12 ? Color.yellow : Color.green))
                    .frame(height: fillH)
            }
        }
    }
}

// MARK: - Vertical Slider

@available(macOS 26.0, *)
private struct VerticalSlider: View {

    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumbY = height * (1 - CGFloat(fraction))

            ZStack(alignment: .bottom) {
                // Track
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(width: 4, height: height)

                // Filled portion
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 4, height: max(0, height - thumbY))

                // Unity mark (0 dB line)
                let unityFraction = (0 - range.lowerBound) / (range.upperBound - range.lowerBound)
                let unityY = height * (1 - CGFloat(unityFraction))
                Rectangle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 14, height: 1)
                    .position(x: geo.size.width / 2, y: unityY)

                // Thumb
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .controlColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                    )
                    .frame(width: 20, height: 10)
                    .position(x: geo.size.width / 2, y: thumbY)
            }
            .frame(width: geo.size.width, height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let y = drag.location.y
                        let frac = 1 - min(max(y / height, 0), 1)
                        value = range.lowerBound + Double(frac) * (range.upperBound - range.lowerBound)
                    }
            )
        }
    }
}

// MARK: - Suno Channel Strip

@available(macOS 26.0, *)
private struct SunoChannelStripView: View {
    @Bindable var store: ScoreStore

    var body: some View {
        VStack(spacing: 4) {
            // Label
            Text("SUNO")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 28)
                .background(Color.purple.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 4))

            // Gain fader
            if let layer = store.sunoRenderLayer {
                VStack(spacing: 0) {
                    Text(String(format: "%.0f%%", layer.gain * 100))
                        .font(.system(size: 8, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44)

                    VerticalSlider(value: Binding(
                        get: { Double(layer.gain) },
                        set: { layer.gain = Float($0) }
                    ), range: 0...1.5)
                        .frame(width: 30, height: 180)
                }

                // Mode indicator
                Text(layer.playbackMode.rawValue)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.purple)
                    .frame(width: 50)

                // Mute button
                Button {
                    layer.isMuted.toggle()
                } label: {
                    Text("M")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(layer.isMuted ? .white : .secondary)
                        .frame(width: 22, height: 18)
                        .background(layer.isMuted ? Color.red : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)

                // A/B cycle button
                Button {
                    store.cycleSunoPlaybackMode()
                } label: {
                    Text("A/B")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.purple)
                        .frame(width: 50, height: 18)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

            // Purple indicator bar
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.purple)
                .frame(width: 50, height: 4)
        }
        .frame(width: 70)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
#endif

