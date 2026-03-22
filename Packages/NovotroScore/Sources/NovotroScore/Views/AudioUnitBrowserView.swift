import SwiftUI

@available(macOS 26.0, *)
struct AudioUnitBrowserSheet: View {
    @Bindable var store: ScoreStore
    let targetKeys: [String]
    let onDismiss: () -> Void

    @State private var searchQuery = ""
    @State private var selectedManufacturer: String?

    private var manufacturers: [String] {
        let mfrs = Set(store.audioUnitManager.instruments.map(\.manufacturerName))
        return mfrs.sorted()
    }

    private var filteredInstruments: [AudioUnitManager.AUInstrumentInfo] {
        var list = store.audioUnitManager.instruments
        if let mfr = selectedManufacturer {
            list = list.filter { $0.manufacturerName == mfr }
        }
        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                $0.manufacturerName.lowercased().contains(q)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Audio Unit Instruments")
                    .font(.headline)
                Spacer()
                if store.audioUnitManager.isScanning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Rescan") {
                    Task { await store.audioUnitManager.scanInstalledAudioUnits() }
                }
                .controlSize(.small)
                Button("Done") { onDismiss() }
                    .controlSize(.small)
            }
            .padding()

            HStack(spacing: 0) {
                // Manufacturer sidebar
                List(selection: $selectedManufacturer) {
                    Text("All (\(store.audioUnitManager.instruments.count))")
                        .tag(Optional<String>.none)

                    ForEach(manufacturers, id: \.self) { mfr in
                        let count = store.audioUnitManager.instruments.filter { $0.manufacturerName == mfr }.count
                        Text("\(mfr) (\(count))")
                            .tag(Optional(mfr))
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 200)

                Divider()

                // Instruments list
                VStack(spacing: 0) {
                    TextField("Search instruments...", text: $searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .padding(.horizontal)
                        .padding(.vertical, 6)

                    List(filteredInstruments) { au in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(au.name)
                                    .font(.body)
                                Text(au.manufacturerName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Load") {
                                store.setMappingAudioUnit(
                                    for: targetKeys,
                                    description: au.audioComponentDescription,
                                    name: au.name
                                )
                                store.statusMessage = "Loaded Audio Unit: \(au.name)"
                                onDismiss()
                                // Auto-open the AU plugin UI
                                if let firstKey = targetKeys.first {
                                    store.openAudioUnitUI(for: firstKey)
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .frame(width: 640, height: 480)
    }
}
