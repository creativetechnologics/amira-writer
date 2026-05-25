import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
struct AngleImageCard: View {
    let store: AnimateStore
    let angleImage: PlaceAngleImage
    let placeID: UUID

    @State private var isEditing: Bool = false
    @State private var editCameraShot: String = ""
    @State private var editAngle: String = ""
    @State private var editTimeOfDay: String = ""
    @State private var editNotes: String = ""

    private static let cameraShotOptions = ["", "wide", "medium", "medium close", "close", "extreme wide", "extreme close"]
    private static let angleOptions = ["", "front", "left", "right", "overhead", "low", "behind"]
    private static let timeOfDayOptions = ["", "day", "night", "dawn", "dusk", "golden hour"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                angleImageThumbnail
                    .frame(height: 110)
                    .frame(maxWidth: .infinity)
                    .clipped()

                HStack(spacing: 4) {
                    if let shot = angleImage.cameraShot, !shot.isEmpty { tagPill(shot) }
                    if let tod = angleImage.timeOfDay, !tod.isEmpty { tagPill(tod) }
                }
                .padding(6)
            }

            VStack(alignment: .leading, spacing: 4) {
                if let angle = angleImage.angle, !angle.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch").font(.caption2).foregroundStyle(.secondary)
                        Text(angle.capitalized).font(.caption)
                    }
                }

                if !angleImage.notes.isEmpty {
                    Text(angleImage.notes).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }

                HStack(spacing: 6) {
                    Button {
                        editCameraShot = angleImage.cameraShot ?? ""
                        editAngle = angleImage.angle ?? ""
                        editTimeOfDay = angleImage.timeOfDay ?? ""
                        editNotes = angleImage.notes
                        isEditing = true
                    } label: { Image(systemName: "pencil").font(.caption2) }
                    .buttonStyle(.borderless)

                    Spacer()

                    Button(role: .destructive) {
                        store.removeAngleImage(angleImage.id, placeID: placeID)
                    } label: { Image(systemName: "trash").font(.caption2) }
                    .buttonStyle(.borderless)
                }
            }
            .padding(8)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.quaternary.opacity(0.5)))
        .popover(isPresented: $isEditing) { angleImageEditor }
    }

    @ViewBuilder
    private var angleImageThumbnail: some View {
        if let url = store.resolvedCharacterAssetURL(for: angleImage.imagePath) {
            AsyncResolvedImageView(path: url.path, maxPixelSize: 360, contentMode: .fill)
        } else {
            ZStack {
                Color.gray.opacity(0.1)
                Image(systemName: "photo").foregroundStyle(.tertiary)
            }
        }
    }

    private func tagPill(_ text: String) -> some View {
        Text(text.capitalized)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var angleImageEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Angle Image").font(.headline)

            Picker("Camera Shot", selection: $editCameraShot) {
                ForEach(Self.cameraShotOptions, id: \.self) {
                    Text($0.isEmpty ? "None" : $0.capitalized).tag($0)
                }
            }

            Picker("Angle", selection: $editAngle) {
                ForEach(Self.angleOptions, id: \.self) {
                    Text($0.isEmpty ? "None" : $0.capitalized).tag($0)
                }
            }

            Picker("Time of Day", selection: $editTimeOfDay) {
                ForEach(Self.timeOfDayOptions, id: \.self) {
                    Text($0.isEmpty ? "None" : $0.capitalized).tag($0)
                }
            }

            TextField("Notes", text: $editNotes, axis: .vertical)
                .textFieldStyle(.roundedBorder).lineLimit(2...4)

            HStack {
                Button("Cancel") { isEditing = false }.buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    store.updateAngleImage(
                        angleImage.id, placeID: placeID,
                        cameraShot: editCameraShot.isEmpty ? nil : editCameraShot,
                        angle: editAngle.isEmpty ? nil : editAngle,
                        timeOfDay: editTimeOfDay.isEmpty ? nil : editTimeOfDay,
                        notes: editNotes
                    )
                    isEditing = false
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 300)
    }
}
