import SwiftUI

/// A SwiftUI overlay that shows named section markers (rehearsal marks) above the ruler.
/// Uses the existing `pianoRollMarkers: [MixMarker]` on ScoreStore.
/// Renders as colored flags/labels at each marker position.
/// Supports adding markers via double-click, editing name via popover.
/// Auto-generates rehearsal letters (A, B, C...) if name is empty.
@available(macOS 26.0, *)
struct RehearsalMarkView: View {
    @Bindable var store: ScoreStore
    var pixelsPerTick: CGFloat
    var scrollOffset: CGFloat
    var visibleWidth: CGFloat

    @State private var editingMarkerID: UUID? = nil
    @State private var editText: String = ""
    @State private var showAddPopover: Bool = false
    @State private var addPopoverTick: Int = 0

    private let height: CGFloat = 28

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(store.pianoRollMarkers.enumerated()), id: \.element.id) { index, marker in
                let x = CGFloat(marker.tick) * pixelsPerTick - scrollOffset
                if x > -120 && x < visibleWidth + 120 {
                    rehearsalFlag(marker: marker, index: index, x: x)
                }
            }
        }
        .frame(height: height)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { location in
            let tick = Int((location.x + scrollOffset) / pixelsPerTick)
            addPopoverTick = tick
            showAddPopover = true
        }
        .popover(isPresented: $showAddPopover) {
            addMarkerPopover
        }
    }

    private func displayName(for marker: MixMarker, index: Int) -> String {
        if !marker.name.isEmpty {
            return marker.name
        }
        return rehearsalLetter(for: index)
    }

    private func rehearsalLetter(for index: Int) -> String {
        if index < 26 {
            return String(Character(UnicodeScalar(65 + index)!))
        }
        // AA, AB, etc. for > 26
        let first = index / 26 - 1
        let second = index % 26
        return String(Character(UnicodeScalar(65 + first)!)) + String(Character(UnicodeScalar(65 + second)!))
    }

    private func flagColor(for marker: MixMarker) -> Color {
        if let hex = marker.colorHex, !hex.isEmpty {
            return Color(hex: hex)
        }
        return .orange
    }

    @ViewBuilder
    private func rehearsalFlag(marker: MixMarker, index: Int, x: CGFloat) -> some View {
        let color = flagColor(for: marker)
        let name = displayName(for: marker, index: index)

        VStack(spacing: 0) {
            if editingMarkerID == marker.id {
                TextField("Name", text: $editText, onCommit: {
                    if let idx = store.pianoRollMarkers.firstIndex(where: { $0.id == marker.id }) {
                        store.pianoRollMarkers[idx].name = editText
                    }
                    editingMarkerID = nil
                })
                .textFieldStyle(.plain)
                .font(.system(size: 10, weight: .bold))
                .frame(width: 60)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.3))
                        .stroke(color, lineWidth: 1)
                )
            } else {
                HStack(spacing: 2) {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 8))
                    Text(name)
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                )
                .onTapGesture {
                    // Single click: seek playhead to this marker
                    store.seekToMarkerTick(marker.tick)
                }
                .onTapGesture(count: 2) {
                    // Double click: edit marker name
                    editingMarkerID = marker.id
                    editText = marker.name
                }
                .contextMenu {
                    Button("Jump to Marker") {
                        store.seekToMarkerTick(marker.tick)
                    }
                    Divider()
                    Button("Edit Name") {
                        editingMarkerID = marker.id
                        editText = marker.name
                    }
                    Button("Delete", role: .destructive) {
                        store.pianoRollMarkers.removeAll(where: { $0.id == marker.id })
                    }
                }
            }

            // Flag pole
            Rectangle()
                .fill(color)
                .frame(width: 1, height: 8)
        }
        .position(x: x, y: height / 2)
    }

    @ViewBuilder
    private var addMarkerPopover: some View {
        VStack(spacing: 8) {
            Text("Add Rehearsal Mark")
                .font(.caption.bold())
            Text("Tick: \(addPopoverTick)")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Name (leave empty for auto letter)", text: $editText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .onSubmit { commitAddMarker() }
            HStack {
                Button("Cancel") {
                    showAddPopover = false
                    editText = ""
                }
                Button("Add") { commitAddMarker() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .onAppear { editText = "" }
    }

    private func commitAddMarker() {
        let marker = MixMarker(tick: addPopoverTick, name: editText)
        store.pianoRollMarkers.append(marker)
        store.pianoRollMarkers.sort(by: { $0.tick < $1.tick })
        showAddPopover = false
        editText = ""
    }
}

// MARK: - Color hex helper

