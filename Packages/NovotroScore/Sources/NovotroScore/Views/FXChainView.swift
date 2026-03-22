import SwiftUI
@preconcurrency import AVFoundation
import AudioToolbox

/// Per-track FX chain editor: insert, remove, and reorder Audio Unit effects on a channel strip.
@available(macOS 26.0, *)
struct FXChainView: View {
    @Bindable var store: ScoreStore
    let channelKey: String
    @Environment(\.dismiss) private var dismiss

    @State private var fxSlots: [FXSlot] = []
    @State private var showAUPicker = false
    @State private var availableEffects: [AudioUnitManager.AUInstrumentInfo] = []

    struct FXSlot: Identifiable {
        let id = UUID()
        var name: String
        var componentDescription: AudioComponentDescription
        var bypass: Bool = false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("FX Chain")
                    .font(.headline)
                Spacer()
                Text(store.instrumentMappings[channelKey]?.displayName ?? channelKey)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()

            Divider()

            if fxSlots.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "waveform.path.ecg")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No effects inserted")
                        .foregroundStyle(.secondary)
                    Button("Add Effect") { showAUPicker = true }
                        .buttonStyle(.bordered)
                    Spacer()
                }
            } else {
                List {
                    ForEach(fxSlots) { slot in
                        HStack {
                            Button(action: { toggleBypass(slot.id) }) {
                                Circle()
                                    .fill(slot.bypass ? Color.orange : Color.green)
                                    .frame(width: 10, height: 10)
                            }
                            .buttonStyle(.plain)
                            .help(slot.bypass ? "Bypassed" : "Active")

                            Text(slot.name)
                                .font(.body.weight(.medium))

                            Spacer()

                            Button(action: { openPluginUI(slot) }) {
                                Image(systemName: "slider.vertical.3")
                            }
                            .buttonStyle(.borderless)

                            Button(action: { removeSlot(slot.id) }) {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .onMove(perform: moveSlots)
                }

                HStack {
                    Button(action: { showAUPicker = true }) {
                        Label("Add Effect", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                    Spacer()
                }
                .padding()
            }
        }
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            loadAvailableEffects()
        }
        .sheet(isPresented: $showAUPicker) {
            AUEffectPickerView(effects: availableEffects) { selected in
                addEffect(selected)
                showAUPicker = false
            } onCancel: {
                showAUPicker = false
            }
        }
    }

    private func loadAvailableEffects() {
        // For effects, we scan separately
        let effectTypes: [AudioComponentDescription] = {
            var descs: [AudioComponentDescription] = []
            var desc = AudioComponentDescription(
                componentType: kAudioUnitType_Effect,
                componentSubType: 0,
                componentManufacturer: 0,
                componentFlags: 0,
                componentFlagsMask: 0
            )
            var comp: AudioComponent? = AudioComponentFindNext(nil, &desc)
            while let c = comp {
                var d = AudioComponentDescription()
                AudioComponentGetDescription(c, &d)
                descs.append(d)
                comp = AudioComponentFindNext(c, &desc)
            }
            return descs
        }()

        availableEffects = effectTypes.compactMap { (desc: AudioComponentDescription) -> AudioUnitManager.AUInstrumentInfo? in
            var nameRef: Unmanaged<CFString>?
            var d = desc
            let comp = AudioComponentFindNext(nil, &d)
            guard let c = comp else { return nil }
            AudioComponentCopyName(c, &nameRef)
            let name = (nameRef?.takeRetainedValue() as String?) ?? "Unknown"
            return AudioUnitManager.AUInstrumentInfo(
                name: name,
                manufacturerName: "",
                componentType: desc.componentType,
                componentSubType: desc.componentSubType,
                manufacturer: desc.componentManufacturer,
                hasCustomView: false
            )
        }
    }

    private func addEffect(_ info: AudioUnitManager.AUInstrumentInfo) {
        let slot = FXSlot(name: info.name, componentDescription: info.audioComponentDescription)
        fxSlots.append(slot)
        applyChainToEngine()
    }

    private func removeSlot(_ id: UUID) {
        fxSlots.removeAll { $0.id == id }
        applyChainToEngine()
    }

    private func toggleBypass(_ id: UUID) {
        if let idx = fxSlots.firstIndex(where: { $0.id == id }) {
            fxSlots[idx].bypass.toggle()
            applyChainToEngine()
        }
    }

    private func moveSlots(from source: IndexSet, to destination: Int) {
        fxSlots.move(fromOffsets: source, toOffset: destination)
        applyChainToEngine()
    }

    private func applyChainToEngine() {
        // Instantiate non-bypassed effects and set on engine
        let activeSlots = fxSlots.filter { !$0.bypass }
        guard let trackID = store.instrumentMappings[channelKey]?.id else { return }

        if activeSlots.isEmpty {
            store.playbackEngine.setTrackFXChain(trackID: trackID, effects: [])
            return
        }

        let group = DispatchGroup()
        let lock = NSLock()
        nonisolated(unsafe) var effects: [(Int, AVAudioUnitEffect)] = []

        for (i, slot) in activeSlots.enumerated() {
            group.enter()
            AVAudioUnitEffect.instantiate(with: slot.componentDescription, options: .loadOutOfProcess) { unit, error in
                if let unit = unit as? AVAudioUnitEffect {
                    lock.withLock { effects.append((i, unit)) }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [store] in
            let sorted = effects.sorted { $0.0 < $1.0 }.map(\.1)
            store.playbackEngine.setTrackFXChain(trackID: trackID, effects: sorted)
        }
    }

    private func openPluginUI(_ slot: FXSlot) {
        // For FX chain AU plugin UI — would need to store references
        // For now, log
        NSLog("[FXChain] Plugin UI requested for %@", slot.name)
    }
}

// MARK: - AU Effect Picker

@available(macOS 26.0, *)
private struct AUEffectPickerView: View {
    let effects: [AudioUnitManager.AUInstrumentInfo]
    let onSelect: (AudioUnitManager.AUInstrumentInfo) -> Void
    let onCancel: () -> Void

    @State private var searchText = ""

    private var filtered: [AudioUnitManager.AUInstrumentInfo] {
        if searchText.isEmpty { return effects }
        let q = searchText.lowercased()
        return effects.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Select Effect")
                    .font(.headline)
                Spacer()
                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                Button("Cancel") { onCancel() }
            }
            .padding()

            Divider()

            List(filtered) { fx in
                Button(action: { onSelect(fx) }) {
                    Text(fx.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 350, minHeight: 300)
    }
}
