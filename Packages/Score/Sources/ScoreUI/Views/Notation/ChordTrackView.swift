import SwiftUI

/// A SwiftUI overlay view that displays chord symbols above the piano roll ruler.
/// Shows both analyzed chords from `store.currentChordProgression` and manually entered `ChordMarker`s.
@available(macOS 26.0, *)
struct ChordTrackView: View {
    @Bindable var store: ScoreStore
    var pixelsPerTick: CGFloat
    var scrollOffset: CGFloat
    var visibleWidth: CGFloat

    @State private var editingMarkerID: UUID? = nil
    @State private var editText: String = ""
    @State private var showAddPopover: Bool = false
    @State private var addPopoverTick: Int = 0
    @State private var addPopoverText: String = ""

    private let height: CGFloat = 24

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Analyzed chords from chord progression
            if let progression = store.currentChordProgression {
                ForEach(progression.chords, id: \.self) { chord in
                    let x = CGFloat(chord.tick) * pixelsPerTick - scrollOffset
                    if x > -100 && x < visibleWidth + 100 {
                        Text(chord.displayName)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(.regularMaterial)
                            )
                            .position(x: x, y: height / 2)
                    }
                }
            }

            // Manual chord markers
            ForEach(store.chordMarkers) { marker in
                let x = CGFloat(marker.tick) * pixelsPerTick - scrollOffset
                if x > -100 && x < visibleWidth + 100 {
                    chordMarkerLabel(marker, x: x)
                }
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { location in
            let tick = Int((location.x + scrollOffset) / pixelsPerTick)
            addPopoverTick = tick
            addPopoverText = ""
            showAddPopover = true
        }
        .popover(isPresented: $showAddPopover) {
            addChordPopover
        }
    }

    @ViewBuilder
    private func chordMarkerLabel(_ marker: ChordMarker, x: CGFloat) -> some View {
        Group {
            if editingMarkerID == marker.id {
                TextField("Chord", text: $editText, onCommit: {
                    if let idx = store.chordMarkers.firstIndex(where: { $0.id == marker.id }) {
                        store.chordMarkers[idx].name = editText
                    }
                    editingMarkerID = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .frame(width: 60)
                .padding(.horizontal, 3)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.accentColor.opacity(0.2))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.accentColor, lineWidth: 1)
                )
                .position(x: x, y: height / 2)
            } else {
                Text(marker.name)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.15))
                    )
                    .position(x: x, y: height / 2)
                    .onTapGesture {
                        editingMarkerID = marker.id
                        editText = marker.name
                    }
                    .contextMenu {
                        Button("Edit") {
                            editingMarkerID = marker.id
                            editText = marker.name
                        }
                        Button("Delete", role: .destructive) {
                            store.chordMarkers.removeAll(where: { $0.id == marker.id })
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var addChordPopover: some View {
        VStack(spacing: 8) {
            Text("Add Chord at tick \(addPopoverTick)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Chord name (e.g. Cmaj7)", text: $addPopoverText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onSubmit {
                    guard !addPopoverText.isEmpty else { return }
                    let marker = ChordMarker(tick: addPopoverTick, name: addPopoverText)
                    store.chordMarkers.append(marker)
                    store.chordMarkers.sort(by: { $0.tick < $1.tick })
                    showAddPopover = false
                }
            HStack {
                Button("Cancel") { showAddPopover = false }
                Button("Add") {
                    guard !addPopoverText.isEmpty else { return }
                    let marker = ChordMarker(tick: addPopoverTick, name: addPopoverText)
                    store.chordMarkers.append(marker)
                    store.chordMarkers.sort(by: { $0.tick < $1.tick })
                    showAddPopover = false
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}
