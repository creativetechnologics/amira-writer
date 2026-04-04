import SwiftUI

/// Inspector panel for a selected NLA track. Shows blend mode, body mask,
/// influence, and per-clip settings.
@available(macOS 26.0, *)
struct NLATrackInspectorView: View {
    @Binding var track: NLATrack
    let clipNames: [UUID: String]  // motionClipID -> display name

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Track name
                Section {
                    TextField("Track Name", text: $track.name)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text("NAME").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                Divider()

                // Blend Mode
                Section {
                    Picker("Blend Mode", selection: $track.blendMode) {
                        ForEach(NLABlendMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("BLEND MODE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                Divider()

                // Influence
                Section {
                    HStack {
                        Slider(value: $track.influence, in: 0...1, step: 0.01)
                        Text("\(Int(track.influence * 100))%")
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 36, alignment: .trailing)
                    }
                } header: {
                    Text("INFLUENCE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                Divider()

                // Mute / Solo
                Section {
                    HStack(spacing: 16) {
                        Toggle("Muted", isOn: $track.muted)
                        Toggle("Solo", isOn: $track.solo)
                    }
                    .toggleStyle(.checkbox)
                } header: {
                    Text("STATE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                Divider()

                // Body Mask
                Section {
                    bodyMaskSection
                } header: {
                    Text("BODY MASK").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                Divider()

                // Color Tag
                Section {
                    Picker("Source Type", selection: $track.colorTag) {
                        ForEach(NLATrackColorTag.allCases, id: \.self) { tag in
                            Text(tag.displayName).tag(tag)
                        }
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("COLOR TAG").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }

                if !track.clips.isEmpty {
                    Divider()

                    // Clips list
                    Section {
                        ForEach(Array(track.clips.enumerated()), id: \.element.id) { index, clip in
                            clipRow(index: index, clip: clip)
                        }
                    } header: {
                        Text("CLIPS (\(track.clips.count))").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private var bodyMaskSection: some View {
        // Preset picker
        HStack {
            Text("Preset:")
                .font(.system(size: 11))
            Picker("", selection: Binding(
                get: {
                    BodyPartMask.presets.first { $0.mask == track.bodyMask }?.label ?? "Custom"
                },
                set: { newLabel in
                    if let preset = BodyPartMask.presets.first(where: { $0.label == newLabel }) {
                        track.bodyMask = preset.mask
                    }
                }
            )) {
                ForEach(BodyPartMask.presets, id: \.label) { preset in
                    Text(preset.label).tag(preset.label)
                }
                Text("Custom").tag("Custom")
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 140)
        }

        // Individual checkboxes in a 2-column grid
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 4),
            GridItem(.flexible(), spacing: 4),
        ], alignment: .leading, spacing: 4) {
            ForEach(BodyPartMask.allParts, id: \.label) { part in
                Toggle(part.label, isOn: Binding(
                    get: { track.bodyMask.contains(part.mask) },
                    set: { isOn in
                        if isOn {
                            track.bodyMask.insert(part.mask)
                        } else {
                            track.bodyMask.remove(part.mask)
                        }
                    }
                ))
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
            }
        }
    }

    @ViewBuilder
    private func clipRow(index: Int, clip: NLAClip) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(clipNames[clip.motionClipID] ?? "Unknown Clip")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("Frame \(clip.startFrame)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Label("Speed \(String(format: "%.1fx", clip.speed))", systemImage: "speedometer")
                Label("In \(clip.blendInFrames)f", systemImage: "arrow.right")
                Label("Out \(clip.blendOutFrames)f", systemImage: "arrow.left")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
