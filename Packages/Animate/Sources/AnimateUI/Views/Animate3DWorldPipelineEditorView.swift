import AppKit
import ProjectKit
import SwiftUI

@available(macOS 26.0, *)
struct Animate3DWorldPipelineEditorView: View {
    @Bindable var store: AnimateStore
    let selectedPlaceName: String?

    @State private var assetRegistry = Animate3DAssetRegistry()
    @State private var characterRegistry = Animate3DCharacterRegistry()
    @State private var motionRegistry = Animate3DMotionRegistry()
    @State private var worldCatalog = Animate3DWorldCatalog()
    @State private var styleProfiles = Animate3DStyleProfileManifest()
    @State private var cameraPresets = Animate3DCameraPresetManifest()
    @State private var lightRigs = Animate3DLightRigManifest()
    @State private var atmospherePresets = Animate3DAtmospherePresetManifest()

    private var projectURL: URL? {
        store.workingOWPURL ?? store.owpURL
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Registry Editor")
                        .font(.headline)
                    Text("Edit the project-local 3D asset, character, motion, world, style, camera, light, and atmosphere manifests directly in-app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reload") { reloadFromDisk() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(projectURL == nil)
                Button("Save All") { saveAll() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(projectURL == nil)
            }

            assetRegistrySection
            characterRegistrySection
            motionRegistrySection
            worldChunksSection
            styleProfilesSection
            cameraPresetsSection
            lightRigsSection
            atmosphereSection
        }
        .task(id: store.workingOWPURL?.path) {
            reloadFromDisk()
        }
    }
}

@available(macOS 26.0, *)
private extension Animate3DWorldPipelineEditorView {
    var assetRegistrySection: some View {
        bundleRegistrySection(
            title: "Asset Registry",
            subtitle: "Cross-scene 3D bundles that point at body models, face rigs, motion packs, and material sidecars.",
            bundles: $assetRegistry.bundles,
            addLabel: "Add Asset Bundle"
        )
    }

    var characterRegistrySection: some View {
        bundleRegistrySection(
            title: "Character Registry",
            subtitle: "Character-level overrides that tell the production preview which 3D sidecars to use for each slug/costume.",
            bundles: $characterRegistry.bundles,
            addLabel: "Add Character Bundle"
        )
    }

    var motionRegistrySection: some View {
        editorSection(
            title: "Motion Registry",
            subtitle: "Reusable motion clips and action sets that the one-shot pipeline can assign without manual staging."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($motionRegistry.motions) { $motion in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            inlineField("Title", text: $motion.title)
                            Button(role: .destructive) {
                                motionRegistry.motions.removeAll { $0.id == motion.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        HStack(spacing: 10) {
                            inlineField("Motion ID", text: $motion.motionID)
                            inlineField("Relative Path", text: $motion.relativePath)
                        }
                        inlineField("Tags", text: Binding(
                            get: { motion.tags.joined(separator: ", ") },
                            set: { motion.tags = commaSeparated($0) }
                        ))
                        inlineField("Notes", text: $motion.notes)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OperaChromeTheme.raisedBackground.opacity(0.35)))
                }

                Button {
                    motionRegistry.motions.append(
                        Animate3DMotionSetDescriptor(
                            motionID: "motion-\(motionRegistry.motions.count + 1)",
                            title: "Motion \(motionRegistry.motions.count + 1)",
                            relativePath: "Animate/characters/shared/motions/motion-\(motionRegistry.motions.count + 1).json"
                        )
                    )
                } label: {
                    Label("Add Motion Descriptor", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    var worldChunksSection: some View {
        editorSection(
            title: "World Chunks",
            subtitle: "Connect libretto places to explorable 3D regions, meshes, previews, and look presets."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($worldCatalog.chunks) { $chunk in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Chunk Title", text: $chunk.title)
                                .textFieldStyle(.roundedBorder)
                            Button(role: .destructive) {
                                removeWorldChunk(chunk.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        HStack(spacing: 10) {
                            inlineField("World ID", text: $chunk.worldID)
                            inlineField("Zone ID", text: $chunk.zoneID)
                        }

                        inlineField("Place Names", text: Binding(
                            get: { chunk.placeNames.joined(separator: ", ") },
                            set: { chunk.placeNames = commaSeparated($0) }
                        ))
                        inlineField("Mesh Path", text: optionalStringBinding($chunk.meshPath))
                        inlineField("Preview Image Path", text: optionalStringBinding($chunk.previewImagePath))

                        HStack(spacing: 10) {
                            inlineField("Light Rig ID", text: optionalStringBinding($chunk.lightRigID))
                            inlineField("Atmosphere ID", text: optionalStringBinding($chunk.atmospherePresetID))
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OperaChromeTheme.raisedBackground.opacity(0.35)))
                }

                Button {
                    addWorldChunk()
                } label: {
                    Label("Add World Chunk", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    var styleProfilesSection: some View {
        editorSection(
            title: "Style Profiles",
            subtitle: "Define cel bands and outline widths that the production preview should use."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($styleProfiles.profiles) { $profile in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            inlineField("Title", text: $profile.title)
                            Button(role: .destructive) {
                                styleProfiles.profiles.removeAll { $0.id == profile.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        HStack(spacing: 10) {
                            inlineField("Profile ID", text: $profile.profileID)
                            Stepper("Cel Bands: \(profile.celBands)", value: $profile.celBands, in: 2...6)
                        }
                        HStack(spacing: 10) {
                            Text("Outline Width")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $profile.outlineWidth, in: 0.5...3.0)
                            Text(String(format: "%.2f", profile.outlineWidth))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        inlineField("Notes", text: $profile.notes)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OperaChromeTheme.raisedBackground.opacity(0.35)))
                }

                Button {
                    styleProfiles.profiles.append(
                        Animate3DStyleProfileDescriptor(
                            profileID: "default-style-\(styleProfiles.profiles.count + 1)",
                            title: "Default Style \(styleProfiles.profiles.count + 1)",
                            celBands: 3,
                            outlineWidth: 1.0
                        )
                    )
                } label: {
                    Label("Add Style Profile", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    var cameraPresetsSection: some View {
        editorSection(
            title: "Camera Presets",
            subtitle: "Define deterministic focal-length presets that the compiler can map to shot vocabulary."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($cameraPresets.presets) { $preset in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            inlineField("Title", text: $preset.title)
                            Button(role: .destructive) {
                                cameraPresets.presets.removeAll { $0.id == preset.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        HStack(spacing: 10) {
                            inlineField("Preset ID", text: $preset.presetID)
                            inlineField("Shot Name", text: $preset.shotName)
                        }
                        HStack(spacing: 10) {
                            Text("Focal Length")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $preset.focalLength, in: 18...135)
                            Text(String(format: "%.0f mm", preset.focalLength))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        inlineField("Notes", text: $preset.notes)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OperaChromeTheme.raisedBackground.opacity(0.35)))
                }

                Button {
                    cameraPresets.presets.append(
                        Animate3DCameraPresetDescriptor(
                            presetID: "wide-\(cameraPresets.presets.count + 1)",
                            title: "Wide Preset \(cameraPresets.presets.count + 1)",
                            shotName: CameraShot.wide.rawValue,
                            focalLength: 32
                        )
                    )
                } label: {
                    Label("Add Camera Preset", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    var lightRigsSection: some View {
        editorSection(
            title: "Light Rigs",
            subtitle: "Control the key/fill/rim balance used by the production renderer."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($lightRigs.rigs) { $rig in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            inlineField("Title", text: $rig.title)
                            Button(role: .destructive) {
                                lightRigs.rigs.removeAll { $0.id == rig.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        inlineField("Rig ID", text: $rig.rigID)
                        metricSlider("Key", value: $rig.keyIntensity, range: 0...1800)
                        metricSlider("Fill", value: $rig.fillIntensity, range: 0...1200)
                        metricSlider("Rim", value: $rig.rimIntensity, range: 0...1200)
                        inlineField("Notes", text: $rig.notes)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OperaChromeTheme.raisedBackground.opacity(0.35)))
                }

                Button {
                    lightRigs.rigs.append(
                        Animate3DLightRigDescriptor(
                            rigID: "default-rig-\(lightRigs.rigs.count + 1)",
                            title: "Default Light Rig \(lightRigs.rigs.count + 1)",
                            keyIntensity: 1000,
                            fillIntensity: 400,
                            rimIntensity: 300
                        )
                    )
                } label: {
                    Label("Add Light Rig", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    var atmosphereSection: some View {
        editorSection(
            title: "Atmosphere Presets",
            subtitle: "Define fog, haze, and palette tints for world-space mood."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach($atmospherePresets.presets) { $preset in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            inlineField("Title", text: $preset.title)
                            Button(role: .destructive) {
                                atmospherePresets.presets.removeAll { $0.id == preset.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        HStack(spacing: 10) {
                            inlineField("Preset ID", text: $preset.presetID)
                            inlineField("Color Hex", text: $preset.colorHex)
                        }
                        metricSlider("Fog Density", value: $preset.fogDensity, range: 0...1)
                        metricSlider("Haze", value: $preset.haze, range: 0...1)
                        inlineField("Notes", text: $preset.notes)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OperaChromeTheme.raisedBackground.opacity(0.35)))
                }

                Button {
                    atmospherePresets.presets.append(
                        Animate3DAtmospherePresetDescriptor(
                            presetID: "default-atmo-\(atmospherePresets.presets.count + 1)",
                            title: "Default Atmosphere \(atmospherePresets.presets.count + 1)",
                            fogDensity: 0.2,
                            haze: 0.15,
                            colorHex: "#A9C6FF"
                        )
                    )
                } label: {
                    Label("Add Atmosphere Preset", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    func reloadFromDisk() {
        guard let projectURL else { return }
        ProjectDatabaseBridge.ensureAnimate3DRegistryScaffolding(projectURL: projectURL)
        assetRegistry = ProjectDatabaseBridge.loadAnimate3DAssetRegistryFromDisk(projectURL: projectURL) ?? Animate3DAssetRegistry()
        characterRegistry = ProjectDatabaseBridge.loadAnimate3DCharacterRegistryFromDisk(projectURL: projectURL) ?? Animate3DCharacterRegistry()
        motionRegistry = ProjectDatabaseBridge.loadAnimate3DMotionRegistryFromDisk(projectURL: projectURL) ?? Animate3DMotionRegistry()
        worldCatalog = ProjectDatabaseBridge.loadAnimate3DWorldCatalogFromDisk(projectURL: projectURL) ?? Animate3DWorldCatalog()
        styleProfiles = ProjectDatabaseBridge.loadAnimate3DStyleProfilesFromDisk(projectURL: projectURL) ?? Animate3DStyleProfileManifest()
        cameraPresets = ProjectDatabaseBridge.loadAnimate3DCameraPresetsFromDisk(projectURL: projectURL) ?? Animate3DCameraPresetManifest()
        lightRigs = ProjectDatabaseBridge.loadAnimate3DLightRigsFromDisk(projectURL: projectURL) ?? Animate3DLightRigManifest()
        atmospherePresets = ProjectDatabaseBridge.loadAnimate3DAtmospherePresetsFromDisk(projectURL: projectURL) ?? Animate3DAtmospherePresetManifest()
    }

    func saveAll() {
        guard let projectURL else { return }
        do {
            try ProjectDatabaseBridge.saveAnimate3DAssetRegistryToDisk(assetRegistry, projectURL: projectURL)
            try ProjectDatabaseBridge.saveAnimate3DCharacterRegistryToDisk(characterRegistry, projectURL: projectURL)
            try ProjectDatabaseBridge.saveAnimate3DMotionRegistryToDisk(motionRegistry, projectURL: projectURL)
            try ProjectDatabaseBridge.saveAnimate3DWorldCatalogToDisk(worldCatalog, projectURL: projectURL)
            try ProjectDatabaseBridge.saveAnimate3DStyleProfilesToDisk(styleProfiles, projectURL: projectURL)
            try ProjectDatabaseBridge.saveAnimate3DCameraPresetsToDisk(cameraPresets, projectURL: projectURL)
            try ProjectDatabaseBridge.saveAnimate3DLightRigsToDisk(lightRigs, projectURL: projectURL)
            try ProjectDatabaseBridge.saveAnimate3DAtmospherePresetsToDisk(atmospherePresets, projectURL: projectURL)
            store.statusMessage = "Saved Animate/3d registry edits"
        } catch {
            store.statusMessage = "Failed to save Animate/3d registries: \(error.localizedDescription)"
        }
    }

    func addWorldChunk() {
        let placeNames = selectedPlaceName.map { [$0] } ?? []
        worldCatalog.chunks.append(
            Animate3DWorldChunkDescriptor(
                worldID: "amira-world",
                zoneID: "zone-\(worldCatalog.chunks.count + 1)",
                title: selectedPlaceName.map { "\($0) Zone" } ?? "New Zone \(worldCatalog.chunks.count + 1)",
                placeNames: placeNames
            )
        )
    }

    func removeWorldChunk(_ id: UUID) {
        worldCatalog.chunks.removeAll { $0.id == id }
    }

    func commaSeparated(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    func optionalStringBinding(_ binding: Binding<String?>) -> Binding<String> {
        Binding<String>(
            get: { binding.wrappedValue ?? "" },
            set: { binding.wrappedValue = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        )
    }

    func bundleRegistrySection(
        title: String,
        subtitle: String,
        bundles: Binding<[Animate3DCharacterBundleDescriptor]>,
        addLabel: String
    ) -> some View {
        editorSection(
            title: title,
            subtitle: subtitle
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(bundles) { bundle in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            inlineField("Character Slug", text: bundle.characterSlug)
                            Button(role: .destructive) {
                                bundles.wrappedValue.removeAll { $0.id == bundle.wrappedValue.id }
                            } label: { Image(systemName: "trash") }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        HStack(spacing: 10) {
                            inlineField("Costume", text: bundle.costumeName)
                            inlineField("Body Model Path", text: bundle.bodyModelPath)
                        }
                        HStack(spacing: 10) {
                            inlineField("Face Rig Path", text: optionalStringBinding(bundle.faceRigPath))
                            inlineField("Mouth Profile Path", text: optionalStringBinding(bundle.mouthProfilePath))
                        }
                        HStack(spacing: 10) {
                            inlineField("Expression Library", text: optionalStringBinding(bundle.expressionLibraryPath))
                            inlineField("Material Profile", text: optionalStringBinding(bundle.materialProfilePath))
                        }
                        inlineField("Motion Set Paths", text: Binding(
                            get: { bundle.motionSetPaths.wrappedValue.joined(separator: ", ") },
                            set: { bundle.motionSetPaths.wrappedValue = commaSeparated($0) }
                        ))
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(OperaChromeTheme.raisedBackground.opacity(0.35)))
                }

                Button {
                    bundles.wrappedValue.append(
                        Animate3DCharacterBundleDescriptor(
                            characterSlug: "",
                            costumeName: "default",
                            bodyModelPath: "Animate/characters/slug/models/model.glb",
                            faceRigPath: "Animate/characters/slug/face-rigs/performance-profile.json",
                            mouthProfilePath: "Animate/characters/slug/mouth-profiles/default.performance.json",
                            expressionLibraryPath: nil,
                            motionSetPaths: [],
                            materialProfilePath: "Animate/characters/slug/materials/lookdev.json"
                        )
                    )
                } label: {
                    Label(addLabel, systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    func editorSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(OperaChromeTheme.raisedBackground.opacity(0.22))
        )
    }

    func inlineField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    func metricSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: "%.0f", value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
