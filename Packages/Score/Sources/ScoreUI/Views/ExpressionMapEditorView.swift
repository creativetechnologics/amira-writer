import ProjectKit
import SwiftUI

/// A SwiftUI view for editing expression maps (articulation keyswitches and CC assignments).
@available(macOS 26.0, *)
struct ExpressionMapEditorView: View {
    @Bindable var store: ScoreStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedMapIndex: Int? = 0
    @State private var editingArticulation: ArticulationEntry?
    @State private var isAddingArticulation = false

    private var maps: [ExpressionMap] {
        store.expressionMaps
    }

    private var currentMap: ExpressionMap? {
        guard let idx = selectedMapIndex, idx < maps.count else { return nil }
        return maps[idx]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Expression Map Editor")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            HSplitView {
                // Map list
                VStack(alignment: .leading, spacing: 8) {
                    Text("Maps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)

                    List(selection: $selectedMapIndex) {
                        ForEach(maps.indices, id: \.self) { idx in
                            Text(maps[idx].name)
                                .tag(idx)
                        }
                    }
                    .listStyle(.sidebar)

                    HStack {
                        Button(action: addMap) {
                            Image(systemName: "plus")
                        }
                        Button(action: deleteCurrentMap) {
                            Image(systemName: "minus")
                        }
                        .disabled(maps.count <= 1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .frame(minWidth: 150, idealWidth: 180)

                // Articulation editor
                if let map = currentMap {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("Map Name", text: Binding(
                                get: { map.name },
                                set: { guard let idx = selectedMapIndex, idx < store.expressionMaps.count else { return }
                                        store.expressionMaps[idx].name = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 250)

                            Spacer()

                            Button("Set Active") {
                                store.activeExpressionMapID = map.id
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.activeExpressionMapID == map.id)

                            Button(action: {
                                isAddingArticulation = true
                                editingArticulation = ArticulationEntry(name: "New Articulation")
                            }) {
                                Label("Add Articulation", systemImage: "plus")
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal)

                        // Articulations table
                        Table(map.articulations) {
                            TableColumn("Name") { art in
                                Text(art.name)
                                    .font(.body.weight(.medium))
                            }
                            .width(min: 80, ideal: 120)

                            TableColumn("Short") { art in
                                Text(art.shortName)
                                    .font(.caption.monospaced())
                            }
                            .width(min: 40, ideal: 60)

                            TableColumn("Keyswitch") { art in
                                if let ks = art.keySwitchPitch {
                                    Text(noteName(ks))
                                        .font(.caption.monospaced())
                                } else {
                                    Text("—").foregroundStyle(.tertiary)
                                }
                            }
                            .width(min: 60, ideal: 80)

                            TableColumn("CC") { art in
                                if let cc = art.ccNumber, let val = art.ccValue {
                                    Text("CC\(cc)=\(val)")
                                        .font(.caption.monospaced())
                                } else {
                                    Text("—").foregroundStyle(.tertiary)
                                }
                            }
                            .width(min: 60, ideal: 80)

                            TableColumn("Color") { art in
                                if let hex = art.colorHex {
                                    Circle()
                                        .fill(Color(hex: hex))
                                        .frame(width: 14, height: 14)
                                } else {
                                    Circle()
                                        .fill(Color.gray.opacity(0.3))
                                        .frame(width: 14, height: 14)
                                }
                            }
                            .width(40)

                            TableColumn("") { art in
                                HStack(spacing: 4) {
                                    Button(action: { editingArticulation = art }) {
                                        Image(systemName: "pencil")
                                    }
                                    .buttonStyle(.borderless)
                                    Button(action: { deleteArticulation(art.id) }) {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.red)
                                }
                            }
                            .width(60)
                        }
                    }
                    .padding(.vertical, 8)
                } else {
                    VStack {
                        Spacer()
                        Text("Select an expression map")
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
        .frame(minWidth: 700, minHeight: 450)
        .sheet(item: $editingArticulation) { art in
            ArticulationEditSheet(
                articulation: art,
                onSave: { updated in
                    guard let mapIdx = selectedMapIndex, mapIdx < store.expressionMaps.count else { editingArticulation = nil; isAddingArticulation = false; return }
                    if isAddingArticulation {
                        store.expressionMaps[mapIdx].articulations.append(updated)
                    } else if let artIdx = store.expressionMaps[mapIdx].articulations.firstIndex(where: { $0.id == updated.id }) {
                        store.expressionMaps[mapIdx].articulations[artIdx] = updated
                    }
                    editingArticulation = nil
                    isAddingArticulation = false
                },
                onCancel: { editingArticulation = nil; isAddingArticulation = false }
            )
        }
    }

    private func addMap() {
        let newMap = ExpressionMap(name: "New Map")
        store.expressionMaps.append(newMap)
        selectedMapIndex = store.expressionMaps.count - 1
    }

    private func deleteCurrentMap() {
        guard maps.count > 1, let idx = selectedMapIndex else { return }
        store.expressionMaps.remove(at: idx)
        selectedMapIndex = min(idx, store.expressionMaps.count - 1)
    }

    private func deleteArticulation(_ id: UUID) {
        guard let idx = selectedMapIndex, idx < store.expressionMaps.count else { return }
        store.expressionMaps[idx].articulations.removeAll { $0.id == id }
    }

    private func noteName(_ pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let octave = pitch / 12 - 1
        return "\(names[pitch % 12])\(octave)"
    }
}

// MARK: - Articulation Edit Sheet

@available(macOS 26.0, *)
private struct ArticulationEditSheet: View {
    @State var articulation: ArticulationEntry
    let onSave: (ArticulationEntry) -> Void
    let onCancel: () -> Void

    @State private var keySwitchText: String = ""
    @State private var ccNumberText: String = ""
    @State private var ccValueText: String = ""
    @State private var colorHexText: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Articulation")
                .font(.headline)

            Form {
                TextField("Name", text: $articulation.name)
                TextField("Short Name", text: $articulation.shortName)
                TextField("Keyswitch (MIDI note 0-127)", text: $keySwitchText)
                TextField("CC Number", text: $ccNumberText)
                TextField("CC Value", text: $ccValueText)
                TextField("Color Hex (e.g. FF6644)", text: $colorHexText)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    articulation.keySwitchPitch = Int(keySwitchText)
                    articulation.ccNumber = Int(ccNumberText)
                    articulation.ccValue = Int(ccValueText)
                    articulation.colorHex = colorHexText.isEmpty ? nil : colorHexText
                    onSave(articulation)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            keySwitchText = articulation.keySwitchPitch.map(String.init) ?? ""
            ccNumberText = articulation.ccNumber.map(String.init) ?? ""
            ccValueText = articulation.ccValue.map(String.init) ?? ""
            colorHexText = articulation.colorHex ?? ""
        }
    }
}

// MARK: - Color hex helper (private, same as other views)

